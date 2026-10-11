#!/bin/bash
# install.sh -- ROCM-25067 workaround: `import torch` spins forever on some ROCm trees.
#
# WHAT THIS FIXES
# ---------------
# On ROCm 7.13.0, a plain `import torch` with PyTorch 2.12.0 never returns. It is
# NOT a deadlock: the thread stays runnable at 99% CPU and perf attributes 89% of
# samples to libomp.so [.] __kmp_wait_4_ptr (plus 11% __sched_yield), with no
# completion after a 900 s leash. __kmp_wait_4_ptr is libomp's spin on a 4-byte
# init flag, i.e. libomp waiting on its own initialization:
#
#   libomp init -> ompt_start_tool() in librocprofiler-sdk -> dlopen ->
#   re-enters libomp -> spins on the init flag its own caller still holds.
#
# The precondition is PyTorch-side: only builds whose libtorch_cpu.so both defines
# rocprofiler_configure and lists librocprofiler-sdk.so.1 as NEEDED pull the SDK in
# as an OMPT tool at import time. 2.9.1 and 2.11.0 have neither and never hang.
#
# WHY NOT A LIBRARY SWAP
# ----------------------
# This is deliberately NOT modelled on rocprofiler-sdk-node-wedging-fix. There is no
# post-fix library to drop in. Substituting, one at a time and verified by checksum
# and by LD_DEBUG that the farm copy is the one loaded:
#   librocprofiler-sdk      1.1.0 / 1.3.2 / 1.3.5 / 1.4.1 into 7.13.0  -> still spins
#   libomp                  from 7.2.4 (a tree that works) into 7.13.0 -> still spins
#   librocprofiler-register from 7.2.4 into 7.13.0                     -> still spins
# and in the reverse direction, 7.13.0's libomp and librocprofiler-register dropped
# into the working 7.2.4 tree do NOT break it. Notably sdk 1.1.0, which works
# natively on 7.2.4, still spins inside 7.13.0 -- so the SDK version is not the
# determinant and a version bump would ship a no-op.
#
# An earlier LD_PRELOAD experiment appeared to show "fixed in sdk >= 1.3.2". It was
# confounded: preloading the site's OWN pre-fix 1.3.0 also clears the hang, because
# preloading completes the SDK's DT_INIT before libomp's and so removes the
# re-entry. Load order, not library content.
#
# WHAT IT DOES INSTEAD
# --------------------
# Breaks the re-entrancy at the only lever proven to work without touching the
# install: OMP_TOOL=disabled, which makes libomp skip tool discovery entirely
# (import completes in ~4 s). It is set on the PYTORCH modulefile, not the ROCm one,
# so OMPT tooling -- rocprof-sys and anything else using it -- stays available for
# every other consumer of this ROCm tree. The guard honours a user who sets OMP_TOOL
# themselves, so profiling PyTorch under an OMPT tool remains possible by opting in.
#
# Idempotent. Exit 0 = applied/already applied, 43 = soft no-op (no pytorch
# modulefile here, or none of them carry the precondition), 1 = real error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_NAME="$(basename "$(dirname "${SCRIPT_DIR}")")"     # rocm-patches-<VER>
ROCM_VERSION="${ROCM_VERSION:-${OVERLAY_NAME#rocm-patches-}}"

ROCM_PATH="${ROCM_PATH:-/opt/rocm-${ROCM_VERSION}}"
MODULEFILE="${MODULEFILE:-}"        # the ROCm modulefile; used to locate the tree
MODULE_ROOT="${MODULE_ROOT:-}"      # base of the lmod tree (holds rocmplus-<ver>/)
PYTORCH_MODULES="${PYTORCH_MODULES:-}"   # explicit list, bypasses discovery
FORCE=0

if [ -z "${SUDO+x}" ]; then
   SUDO=""
   [ "${EUID:-$(id -u)}" -eq 0 ] || SUDO="sudo"
fi

usage() {
   echo "Usage: install.sh [options]"
   echo "  --module-root    DIR   lmod tree holding rocmplus-<ver>/pytorch/*.lua"
   echo "  --pytorch-module PATH  a specific pytorch modulefile (repeatable)"
   echo "  --force                patch even modulefiles whose torch lacks the"
   echo "                         rocprofiler-sdk precondition"
   exit 1
}

while [ $# -gt 0 ]; do
   case "${1}" in
      --module-root)    shift; MODULE_ROOT="${1}" ;;
      --pytorch-module) shift; PYTORCH_MODULES="${PYTORCH_MODULES} ${1}" ;;
      --force)          FORCE=1 ;;
      --help)           usage ;;
      *)                echo "Unsupported argument :: ${1}" >&2; usage ;;
   esac
   shift
done

MARKER="ROCM-25067 OMPT re-entrancy workaround"

echo "[ompt-reentrancy] ROCM_VERSION = ${ROCM_VERSION}"

# ── 1. locate the pytorch modulefiles for this ROCm version ─────────
# Layout: <root>/base/rocm/<ver>.lua for ROCm, <root>/rocmplus-<ver>/pytorch/*.lua
# for the dependent packages, so the root is three levels above the ROCm
# modulefile. Derive it rather than hardcoding a site path.
if [ -z "${MODULE_ROOT}" ] && [ -n "${MODULEFILE}" ]; then
   MODULE_ROOT="$(cd "$(dirname "$(dirname "$(dirname "${MODULEFILE}")")")" 2>/dev/null && pwd || true)"
fi

if [ -z "${PYTORCH_MODULES// /}" ]; then
   if [ -z "${MODULE_ROOT}" ] || [ ! -d "${MODULE_ROOT}" ]; then
      echo "[ompt-reentrancy] no module root (pass --module-root or MODULEFILE); soft no-op"
      exit 43
   fi
   _dir="${MODULE_ROOT}/rocmplus-${ROCM_VERSION}/pytorch"
   if [ ! -d "${_dir}" ]; then
      echo "[ompt-reentrancy] no ${_dir}; nothing to patch (soft no-op)"
      exit 43
   fi
   for _f in "${_dir}"/*.lua; do
      [ -f "${_f}" ] && PYTORCH_MODULES="${PYTORCH_MODULES} ${_f}"
   done
fi

if [ -z "${PYTORCH_MODULES// /}" ]; then
   echo "[ompt-reentrancy] no pytorch modulefiles for ROCm ${ROCM_VERSION} (soft no-op)"
   exit 43
fi

# ── 2. does this build actually carry the precondition? ─────────────
# Read it out of libtorch_cpu.so rather than trusting the version string: the hang
# needs BOTH the rocprofiler_configure definition and the NEEDED entry that drags
# the SDK in at import. A build with neither cannot spin, so patching it would be
# noise. Returns 0 = affected, 1 = not affected, 2 = cannot tell.
torch_is_affected() {
   local mf="${1}" prefix so
   command -v objdump >/dev/null 2>&1 && command -v nm >/dev/null 2>&1 || return 2
   # The modulefile's own prefix tells us where the payload lives.
   prefix="$(grep -oE '"[^"]*/pytorch[^"]*"' "${mf}" 2>/dev/null \
              | tr -d '"' | grep -m1 'site-packages' || true)"
   if [ -z "${prefix}" ]; then
      prefix="$(grep -oE '"/[^"]*pytorch-v[^"]*"' "${mf}" 2>/dev/null | tr -d '"' | head -1 || true)"
   fi
   [ -n "${prefix}" ] || return 2
   so="$(find "${prefix%/}" -maxdepth 6 -name libtorch_cpu.so 2>/dev/null | head -1)"
   [ -n "${so}" ] && [ -f "${so}" ] || return 2
   objdump -p "${so}" 2>/dev/null | grep -q 'NEEDED.*librocprofiler-sdk' || return 1
   nm -D --defined-only "${so}" 2>/dev/null | grep -q ' rocprofiler_configure$' || return 1
   return 0
}

# ── 3. patch ────────────────────────────────────────────────────────
# prepend_path is LIFO but setenv is not order-sensitive, so the block simply goes
# at end of file; no anchor line to fight.
read -r -d '' BLOCK <<-EOF || true

	-- ${MARKER}
	-- librocprofiler-sdk's OMPT bring-up re-enters libomp during \`import torch\`,
	-- which then spins unbounded in __kmp_wait_4_ptr (99% CPU, no completion in
	-- 900 s). No librocprofiler-sdk, libomp or librocprofiler-register version
	-- fixes it in place -- verified by substitution in both directions -- so the
	-- re-entrancy is broken here instead, by skipping OMPT tool discovery.
	-- Scoped to this pytorch module so OMPT stays available to rocprof-sys and
	-- every other consumer of ROCm ${ROCM_VERSION}.
	-- Opt back in with \`export OMP_TOOL=enabled\` before loading this module.
	-- See ${SCRIPT_DIR}/install.sh.
	if os.getenv("OMP_TOOL") == nil then
	   setenv("OMP_TOOL", "disabled")
	end
EOF

patched=0
skipped=0
for mf in ${PYTORCH_MODULES}; do
   if [ ! -f "${mf}" ]; then
      echo "[ompt-reentrancy] WARNING: ${mf} is not a file; skipping" >&2
      continue
   fi
   if grep -Fq "${MARKER}" "${mf}"; then
      echo "[ompt-reentrancy] already patched: ${mf}"
      patched=$((patched + 1))
      continue
   fi

   _aff=0; torch_is_affected "${mf}" || _aff=$?
   case "${_aff}" in
      0) : ;;
      1) if [ "${FORCE}" -eq 0 ]; then
            echo "[ompt-reentrancy] not affected (torch does not link the SDK): $(basename "${mf}")"
            skipped=$((skipped + 1)); continue
         fi ;;
      *) if [ "${FORCE}" -eq 0 ]; then
            echo "[ompt-reentrancy] cannot inspect torch for $(basename "${mf}"); skipping (use --force)"
            skipped=$((skipped + 1)); continue
         fi ;;
   esac

   printf '%s\n' "${BLOCK}" | ${SUDO} tee -a "${mf}" >/dev/null
   grep -Fq "${MARKER}" "${mf}" \
      || { echo "[ompt-reentrancy] ERROR: edit of ${mf} did not take" >&2; exit 1; }
   echo "[ompt-reentrancy] patched ${mf}"
   patched=$((patched + 1))
done

if [ "${patched}" -eq 0 ]; then
   echo "[ompt-reentrancy] nothing affected here (${skipped} skipped); soft no-op"
   exit 43
fi

echo "[ompt-reentrancy] DONE (${patched} modulefile(s) patched, ${skipped} skipped)"
echo "[ompt-reentrancy] verify with: module load rocm/${ROCM_VERSION} pytorch && \\"
echo "[ompt-reentrancy]              time python3 -c 'import torch'   # expect a few seconds"
