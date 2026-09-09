#!/bin/bash
# install.sh -- rocprofiler-sdk node-wedging overlay for affected ROCm 10 builds.
#
# WHAT THIS FIXES
# ---------------
# In ROCm 10.0 and early 10.1 builds, a race in rocprofiler-sdk's shutdown
# path could, under concurrent per-GPU rocprofv3 sessions, leave the GPU
# with a dangling pointer into host memory and destabilize the node. It
# was fixed in a later 10.1 nightly by
# https://github.com/ROCm/rocm-systems/pull/10219
#
# WHY AN OVERLAY AND NOT A PATCH
# ------------------------------
# The fix lives entirely in librocprofiler-sdk.so, and cannot be applied
# to an installed tree: the affected functions have internal linkage and
# the shipped library exports only the public rocprofiler_* API, so there
# is no dynamic symbol for an LD_PRELOAD shim to interpose:
#   nm -D --defined-only lib/librocprofiler-sdk.so.1 | grep code_object   # empty
# Replacing the library is the only option, and it need not be compiled
# here -- every post-fix build already contains it.  This script takes the
# rocprofiler-sdk libraries out of such a build and shadows the site
# install with them.
#
# VERIFYING A DONOR
# -----------------
# The 10.x libraries ship unstripped, so donor_has_fix() reads the fix out
# of the candidate binary rather than trusting its version string; the
# build date is consulted only when the binary cannot be inspected
# (stripped donor, or no binutils on the build host).
#
# HOW THE OVERLAY WINS AT RUNTIME
# -------------------------------
# rocprofv3 LD_PRELOADs the SDK by absolute path, so an LD_LIBRARY_PATH
# overlay cannot shadow it (same reason rocprof-sys needs the SDK symlink
# swap).  Two mechanisms:
#
#   wrapper (default)  rocprofv3 --rocm-root DIR overrides its ROCm root
#                      wholesale.  Build a symlink farm of the site install
#                      with only the rocprofiler-sdk libs replaced, and put
#                      a one-line rocprofv3 wrapper on PATH via the
#                      modulefile.  The ROCm install is untouched;
#                      `module unload` undoes it.
#   swap               fallback for a rocprofv3 without --rocm-root: move
#                      the distribution library aside as .orig and symlink
#                      it to the overlay copy.
#
# Idempotent; a re-run rebuilds the farm in place, so do it when no
# profiling session is live.  Exit 0 = applied/already applied, 43 = soft
# no-op (nothing to fix here, or no post-fix donor), 1 = real error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_NAME="$(basename "$(dirname "${SCRIPT_DIR}")")"     # rocm-patches-<VER>
ROCM_VERSION="${ROCM_VERSION:-${OVERLAY_NAME#rocm-patches-}}"

# First build known to carry PR #10219.  Only a fallback: donor_has_fix()
# below reads the fix out of the library itself, and the date is consulted
# only when that check cannot run.
FIX_MIN_DATE=20260901

ROCM_PATH="${ROCM_PATH:-/opt/rocm-${ROCM_VERSION}}"
MODULEFILE="${MODULEFILE:-}"
FIXED_ROCM="${FIXED_ROCM:-}"
MODE="${MODE:-auto}"
FORCE=0

# An exported SUDO (even empty, as the container paths in the sibling
# *_setup.sh scripts do) wins over the uid probe.
if [ -z "${SUDO+x}" ]; then
   SUDO=""
   [ "${EUID:-$(id -u)}" -eq 0 ] || SUDO="sudo"
fi

usage() {
   echo "Usage: install.sh [options]"
   echo "  --rocm-path   DIR   site ROCm install to protect  (default ${ROCM_PATH})"
   echo "  --fixed-rocm  DIR   post-fix ROCm tree to take librocprofiler-sdk* from"
   echo "                      (default: scan siblings of --rocm-path for a"
   echo "                       10.x build dated >= ${FIX_MIN_DATE})"
   echo "  --module-file PATH  modulefile to wire            (default: autodetected)"
   echo "  --mode        M     auto | wrapper | swap         (default auto)"
   echo "  --force             accept a donor tree whose date cannot be verified"
   exit 1
}

while [ $# -gt 0 ]; do
   case "${1}" in
      --rocm-path)   shift; ROCM_PATH="${1}" ;;
      --fixed-rocm)  shift; FIXED_ROCM="${1}" ;;
      --module-file) shift; MODULEFILE="${1}" ;;
      --mode)        shift; MODE="${1}" ;;
      --force)       FORCE=1 ;;
      --help)        usage ;;
      *)             echo "Unsupported argument :: ${1}" >&2; usage ;;
   esac
   shift
done

OVR_BIN="${SCRIPT_DIR}/bin"
OVR_ROOT="${SCRIPT_DIR}/root"
# The staged libraries have to live INSIDE the farm's lib dir, not beside
# it: their RUNPATH is $ORIGIN/rocm_sysdeps/lib:$ORIGIN/llvm/lib:$ORIGIN
# (and $ORIGIN/../... for the tool libs), and ld.so expands $ORIGIN from
# the resolved path of the loaded file.  Staged in the farm, those lookups
# land on the farm's symlinks to the site tree and resolve without help
# from LD_LIBRARY_PATH; staged anywhere else, libamd_comgr and the
# vendored rocm_sysdeps libraries go missing.
OVR_LIB="${OVR_ROOT}/lib"
DIST_ROCPROFV3="${ROCM_PATH}/bin/rocprofv3"

echo "[node-wedging] ROCM_VERSION = ${ROCM_VERSION}"
echo "[node-wedging] ROCM_PATH    = ${ROCM_PATH}"

# ── 0. is there anything to fix here? ───────────────────────────────
if [ ! -x "${DIST_ROCPROFV3}" ]; then
   echo "[node-wedging] no rocprofv3 at ${DIST_ROCPROFV3}; nothing to overlay (soft no-op)"
   exit 43
fi

# ── 1. find a post-fix rocprofiler-sdk to take the libraries from ───
# Version strings on the nightly line look like 10.1.0a20260901; the
# trailing yyyymmdd is the fallback signal when the binary cannot be read.
version_date() {
   local v="${1}"
   [[ "${v}" =~ a([0-9]{8}) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

# Print the first versioned librocprofiler-sdk.so in a lib dir, or nothing.
# Deliberately pipe-free: under `set -o pipefail` a reader that closes early
# (head, grep -m1, grep -q) makes the whole pipeline report SIGPIPE, which
# both aborts the script and can invert the fix check below.
first_versioned_sdk_so() {
   local f
   for f in "${1}"/librocprofiler-sdk.so.[0-9]*.[0-9]*.[0-9]*; do
      if [ -f "${f}" ]; then echo "${f}"; return 0; fi
   done
   return 0
}

sdk_library_in() {
   first_versioned_sdk_so "${1}/lib"
}

# Read the fix out of the candidate library rather than trusting its
# version string.  The 10.x libraries ship unstripped, so finalize() is in
# .symtab (as a local symbol) and its prologue can be disassembled: with
# the fix it takes the destroy mutex before testing is_shutdown, so the
# mutex object is referenced within the first few instructions.  Without
# the fix, finalize() never touches that mutex at all.
#   0 = fix present   1 = fix absent   2 = cannot tell (stripped, or no binutils)
donor_has_fix() {
   local so="${1}" line addr prologue
   command -v nm >/dev/null 2>&1 && command -v objdump >/dev/null 2>&1 || return 2
   line="$(nm --defined-only "${so}" 2>/dev/null \
            | grep '_ZN11rocprofiler11code_object8finalizeEv$' || true)"
   [ -n "${line}" ] || return 2
   addr="0x${line%% *}"
   prologue="$(objdump -d --start-address="${addr}" \
                       --stop-address="$(( addr + 0x60 ))" "${so}" 2>/dev/null || true)"
   case "${prologue}" in
      *get_destroy_mutex*) return 0 ;;
      *)                   return 1 ;;
   esac
}

if [ -z "${FIXED_ROCM}" ]; then
   _parent="$(dirname "${ROCM_PATH}")"
   _best=""
   _best_date=""
   for _cand in "${_parent}"/rocm-10*; do
      [ -d "${_cand}" ]                                  || continue
      [ "$(readlink -f "${_cand}")" != "$(readlink -f "${ROCM_PATH}")" ] || continue
      _cso="$(sdk_library_in "${_cand}")"
      [ -n "${_cso}" ]                                   || continue
      # `|| _fx=$?` and not a bare call: under `set -e` a bare call to a
      # function that returns non-zero exits the script.
      _fx=0; donor_has_fix "${_cso}" || _fx=$?
      [ "${_fx}" -eq 1 ] && continue
      _d="$(version_date "$(basename "${_cand}")")"
      if [ "${_fx}" -ne 0 ]; then
         [ -n "${_d}" ] && [ "${_d}" -ge "${FIX_MIN_DATE}" ] || continue
      fi
      if [ -z "${_best_date}" ] || [ "${_d:-0}" -gt "${_best_date}" ]; then
         _best="${_cand}"; _best_date="${_d:-0}"
      fi
   done
   FIXED_ROCM="${_best}"
   [ -n "${FIXED_ROCM}" ] && echo "[node-wedging] donor autodetected: ${FIXED_ROCM}"
fi

if [ -z "${FIXED_ROCM}" ]; then
   cat >&2 <<-MSG
	[node-wedging] no post-fix rocprofiler-sdk available (soft no-op).
	             Point --fixed-rocm at a ROCm 10.x tree built on or after
	             ${FIX_MIN_DATE} (the first nightly carrying PR #10219), e.g. an
	             unpacked https://nightly.repo.amd.com/rocm/core/tarball/
	             therock-dist-linux-gfx94X-dcgpu-10.1.0a${FIX_MIN_DATE}.tar.gz
	             or any newer nightly already staged on this cluster.
	MSG
   exit 43
fi

[ -d "${FIXED_ROCM}" ] || { echo "[node-wedging] ERROR: ${FIXED_ROCM} is not a directory" >&2; exit 1; }
_donor_so="$(sdk_library_in "${FIXED_ROCM}")"
[ -n "${_donor_so}" ] \
   || { echo "[node-wedging] ERROR: ${FIXED_ROCM}/lib has no versioned librocprofiler-sdk.so" >&2; exit 1; }

_donor_fx=0; donor_has_fix "${_donor_so}" || _donor_fx=$?
case "${_donor_fx}" in
   0) echo "[node-wedging] donor verified in the binary: finalize() takes the destroy mutex" ;;
   1) echo "[node-wedging] ERROR: donor $(basename "${_donor_so}") does NOT carry the fix:" >&2
      echo "[node-wedging]        finalize() never references the destroy mutex." >&2
      [ "${FORCE}" -eq 1 ] || exit 1
      echo "[node-wedging]        --force given; continuing anyway." >&2 ;;
   *) # Stripped donor, or no binutils here: fall back to the build date.
      _donor_date="$(version_date "$(basename "${FIXED_ROCM}")")"
      echo "[node-wedging] cannot read the fix out of the donor library; using the build date"
      if [ -z "${_donor_date}" ] && [ "${FORCE}" -eq 0 ]; then
         echo "[node-wedging] ERROR: no build date in '$(basename "${FIXED_ROCM}")' either." >&2
         echo "[node-wedging]        Confirm it postdates the fix and re-run with --force." >&2
         exit 1
      fi
      if [ -n "${_donor_date}" ] && [ "${_donor_date}" -lt "${FIX_MIN_DATE}" ] && [ "${FORCE}" -eq 0 ]; then
         echo "[node-wedging] ERROR: donor ${FIXED_ROCM} predates the fix (${_donor_date} < ${FIX_MIN_DATE})." >&2
         exit 1
      fi ;;
esac

# ── 2. symlink farm: the site install with only the SDK replaced ────
# Everything the profiled process reaches through the SDK -- the counter
# definition YAMLs under share/, bin/rocprofv3-avail, the HSA runtime --
# must still resolve, so the farm mirrors the whole prefix and overrides
# exactly the rocprofiler-sdk entries.  Built before staging, because the
# staged libraries land in it (see OVR_LIB above), and after the donor
# checks, so a bad donor never costs us a working overlay.
build_farm() {
   rm -rf "${OVR_ROOT}"
   mkdir -p "${OVR_ROOT}/lib"
   local e n
   while IFS= read -r e; do
      n="$(basename "${e}")"
      [ "${n}" = "lib" ] && continue
      ln -sfn "${e}" "${OVR_ROOT}/${n}"
   done < <(find "${ROCM_PATH}/." -mindepth 1 -maxdepth 1)
   while IFS= read -r e; do
      n="$(basename "${e}")"
      case "${n}" in librocprofiler-sdk*|rocprofiler-sdk) continue ;; esac
      ln -sfn "${e}" "${OVR_ROOT}/lib/${n}"
   done < <(find "${ROCM_PATH}/lib/." -mindepth 1 -maxdepth 1)
}

build_farm
echo "[node-wedging] farm: ${OVR_ROOT} (lib/librocprofiler-sdk* -> overlay)"

# ── 3. stage the donor's rocprofiler-sdk libraries into the farm ─────
# The tool library and the SDK library are one ABI unit, so they are
# taken as a set -- never a newer SDK against the site's tool library.
mkdir -p "${OVR_LIB}" "${OVR_BIN}"
ls "${FIXED_ROCM}"/lib/librocprofiler-sdk.so.* >/dev/null 2>&1 \
   || { echo "[node-wedging] ERROR: ${FIXED_ROCM}/lib has no librocprofiler-sdk.so.*" >&2; exit 1; }
echo "[node-wedging] staging rocprofiler-sdk libraries from ${FIXED_ROCM}/lib"
cp -a "${FIXED_ROCM}"/lib/librocprofiler-sdk*.so* "${OVR_LIB}/"
if [ -d "${FIXED_ROCM}/lib/rocprofiler-sdk" ]; then
   rm -rf "${OVR_LIB}/rocprofiler-sdk"
   cp -a "${FIXED_ROCM}/lib/rocprofiler-sdk" "${OVR_LIB}/"
fi

_sdk_so="$(first_versioned_sdk_so "${OVR_LIB}")"
[ -n "${_sdk_so}" ] || { echo "[node-wedging] ERROR: donor has no versioned librocprofiler-sdk.so" >&2; exit 1; }
echo "[node-wedging]   $(basename "${_sdk_so}")"

# ── 4. pick the mechanism ───────────────────────────────────────────
if [ "${MODE}" = "auto" ]; then
   if grep -q -- "--rocm-root" "${DIST_ROCPROFV3}"; then
      MODE=wrapper
   else
      echo "[node-wedging] ${DIST_ROCPROFV3} has no --rocm-root option; falling back to swap mode"
      MODE=swap
   fi
fi

case "${MODE}" in
   wrapper)
      cat > "${OVR_BIN}/rocprofv3" <<-EOF
	#!/bin/bash
	# rocprofiler-sdk node-wedging overlay wrapper -- see ${SCRIPT_DIR}/install.sh for the bug.
	# Runs the distribution rocprofv3 against a symlink farm of this ROCm
	# install whose only difference is a rocprofiler-sdk carrying PR #10219,
	# so concurrent per-GPU profiling sessions cannot reset the node.
	# An explicit user --rocm-root always wins.
	for _a in "\$@"; do
	   [ "\${_a}" = "--" ] && break
	   case "\${_a}" in --rocm-root|--rocm-root=*) exec "${DIST_ROCPROFV3}" "\$@" ;; esac
	done
	exec "${DIST_ROCPROFV3}" --rocm-root "${OVR_ROOT}" "\$@"
	EOF
      chmod 0755 "${OVR_BIN}/rocprofv3"
      echo "[node-wedging] wrapper: ${OVR_BIN}/rocprofv3"
      ;;
   swap)
      _dist="${ROCM_PATH}/lib/$(basename "${_sdk_so}")"
      if [ -L "${_dist}" ] && [ "$(readlink -f "${_dist}")" = "$(readlink -f "${_sdk_so}")" ]; then
         echo "[node-wedging] ${_dist} already points at the overlay"
      elif [ ! -e "${_dist}" ]; then
         echo "[node-wedging] ERROR: ${_dist} not present; donor/site soversions differ" >&2
         exit 1
      else
         [ -e "${_dist}.orig" ] || ${SUDO} mv -n "${_dist}" "${_dist}.orig"
         ${SUDO} ln -sfn "${_sdk_so}" "${_dist}"
         echo "[node-wedging] ${_dist} -> ${_sdk_so} (original kept as .orig)"
      fi
      ;;
   *)
      echo "[node-wedging] ERROR: unknown --mode '${MODE}'" >&2; exit 1 ;;
esac

# ── 5. wire the modulefile ──────────────────────────────────────────
# Only wrapper mode needs a modulefile entry; swap mode is already live
# for every consumer of the install.
if [ "${MODE}" = "wrapper" ]; then
   if [ -z "${MODULEFILE}" ]; then
      for _cand in "/etc/lmod/modules/ROCm/rocm/${ROCM_VERSION}.lua" \
                   "/shared/apps/modules/ubuntu/lmodfiles/base/rocm/${ROCM_VERSION}.lua" \
                   "/nfsapps/modules/base/rocm/${ROCM_VERSION}.lua"; do
         [ -f "${_cand}" ] && { MODULEFILE="${_cand}"; break; }
      done
   fi

   MARKER="rocprofiler-sdk node-wedging overlay"
   if [ -z "${MODULEFILE}" ] || [ ! -f "${MODULEFILE}" ]; then
      echo "[node-wedging] WARNING: no modulefile found for rocm/${ROCM_VERSION};" >&2
      echo "[node-wedging]          add manually: prepend_path(\"PATH\", \"${OVR_BIN}\")" >&2
   elif grep -Fq "${MARKER}" "${MODULEFILE}"; then
      echo "[node-wedging] modulefile already wired (${MODULEFILE})"
   else
      # prepend_path is LIFO, so this must land AFTER the SDK's own bin
      # entry to end up ahead of it in the resolved PATH.
      BLOCK=$(printf '\n-- %s: rocprofv3 wrapper that runs the distribution launcher\n-- against a rocprofiler-sdk carrying https://github.com/ROCm/rocm-systems/pull/10219,\n-- for concurrent per-GPU rocprofv3 stability. See %s/install.sh.\nprepend_path("PATH", "%s")\n' \
              "${MARKER}" "${SCRIPT_DIR}" "${OVR_BIN}")
      TMP="$(mktemp)"
      awk -v block="${BLOCK}" '
         { print }
         /^[[:space:]]*prepend_path\("PATH",[[:space:]]*pathJoin\(base, "bin"\)\)[[:space:]]*$/ && !done {
            print block; done = 1
         }
         END { if (!done) print block }
      ' "${MODULEFILE}" > "${TMP}"
      ${SUDO} install -m 0644 "${TMP}" "${MODULEFILE}"
      rm -f "${TMP}"
      grep -Fq "${MARKER}" "${MODULEFILE}" \
         || { echo "[node-wedging] ERROR: modulefile edit did not take" >&2; exit 1; }
      echo "[node-wedging] wired ${MODULEFILE}"
   fi
fi

# ── 6. verify the overlay is loadable and actually in front ─────────
_missing="$(ldd "${_sdk_so}" 2>/dev/null | grep 'not found' || true)"
if [ -n "${_missing}" ]; then
   echo "[node-wedging] WARNING: overlay library has unresolved dependencies:" >&2
   echo "${_missing}" | sed 's/^/[node-wedging]   /' >&2
   echo "[node-wedging]          the donor build is probably too far from ${ROCM_VERSION};" >&2
   echo "[node-wedging]          pick a closer nightly or fall back to a source build." >&2
fi

if [ "${MODE}" = "wrapper" ]; then
   if PATH="${OVR_BIN}:${PATH}" rocprofv3 --version >/dev/null 2>&1; then
      echo "[node-wedging] 'rocprofv3 --version' through the wrapper: OK"
   else
      echo "[node-wedging] WARNING: 'rocprofv3 --version' through the wrapper failed;" >&2
      echo "[node-wedging]          run it by hand to see why before trusting the overlay." >&2
   fi
fi

echo "[node-wedging] DONE (mode=${MODE})"
echo "[node-wedging] the donor is a binary from a different build than this install:"
echo "[node-wedging] validate on a drainable node by running one rocprofv3 --kernel-trace"
echo "[node-wedging] session per GPU concurrently, and confirm boot_id is unchanged after."
