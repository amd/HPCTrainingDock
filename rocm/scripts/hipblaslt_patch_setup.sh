#!/bin/bash
#
# hipblaslt_patch_setup.sh
# ------------------------
# Apply a vendored hipBLASLt fix on top of the SDK installed by
# rocm/scripts/rocm_setup.sh at /opt/rocm-${ROCM_VERSION}, and expose it as an
# auto-loaded `hipblaslt/patched` Lmod module.
#
# The fix (patch_general_xcc): the generic (no-CU) gfx942 fallback libraries
# ship solutions whose workGroupMappingXCC must divide the active partition CU
# count to pass the runtime predicate. On MI300A the dominant tag is WGMXCC=8
# (~99% of the fallback solutions; the rest are mostly 16/32, a few 2/4/86),
# and 8/16/32/86 divide neither 228 (SPX) nor 38 (CPX) -- so those solutions are
# rejected, the heuristic empties, the empty result is not cached, and the full
# search is paid on every call. (These libraries are valid on MI300X, whose 304
# CUs are divisible by 8; MI300A's 228/38 are not, hence the regression is
# MI300A-specific.) The symptom is twofold: a flat ~500 ms across fp16/bf16/fp32
# and all transpose layouts, and returnAlgoCount=0 heuristic misses on the
# small-N fp16 OP_T*OP_N family (same mechanism -- the preferred candidates are
# all WGMXCC-rejected). We rewrite WGMXCC -> 1 (the only value valid on every
# partition; the few 2/4 are normalized along the way) in those fallbacks.
# Version-agnostic
# by construction: it rewrites whatever the SDK ships (flat *.dat or nested
# gfx942/*.dat.zlib), so new releases need no code change. This single rewrite
# supersedes the older per-shape equality-row + CU38 patches (AMD PR #5009,
# reverted from rocm-rel-7.2 by #5398): verified on MI300A SPX and CPX that it
# cures both the heuristic misses and the slow cells those patches targeted,
# and the slow cells they did not. See patch_general_xcc().
#
# CLI matches the sibling *_setup.sh leaves:
#   --rocm-version <X.Y.Z>     required
#   --replace                  force re-apply even if sentinel present
#   --module-path <DIR>        lmod base (default /etc/lmod/modules/ROCm/rocm)
#   --install-prefix <DIR>     overlay tree (default /opt/rocm-patches-${V})
#   --rocm-path <DIR>          base SDK dir (default /opt/rocm-${V})
#   --rocm-modulefile <PATH>   base rocm modulefile to wire auto-load into
#                              (default: auto-probe ${MODULE_PATH}/${V}.lua
#                              then ${MODULE_PATH}/base/rocm/${V}.lua)
#
# Exit codes: 0 ok / already up-to-date, 43 NOOP (no fix for this V), 1 error.
#
# Handled ROCm versions: every rocm >= 7.1.0 (the defect is present from 7.1.0
# onward). Layout is auto-detected: flat *.dat for 7.1.x/7.2.x, nested
# gfx942/*.dat for 7.13.0, nested gfx942/*.dat.zlib for 7.14+/10.x. Anything
# below 7.1.0 exits NOOP_RC.
#

set -euo pipefail

# Capture this script's absolute path before any cd so the git-provenance
# block below can resolve it after the build cd's into a temp dir.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
LEAF_DIR="$(dirname "${LEAF_SCRIPT_PATH}")"

LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
LEAF_SCRIPT_COMMIT=unknown
LEAF_SCRIPT_DIRTY=unknown
if [ -d "${LEAF_DIR}" ] && command -v git >/dev/null 2>&1 \
   && git -C "${LEAF_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
   _commit="$(git -C "${LEAF_DIR}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
   [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
   unset _commit
   if [ -n "$(git -C "${LEAF_DIR}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
      LEAF_SCRIPT_DIRTY=dirty
   else
      LEAF_SCRIPT_DIRTY=clean
   fi
fi

# ── defaults ────────────────────────────────────────────────────────
: ${ROCM_VERSION:=""}
REPLACE=0
MODULE_PATH=/etc/lmod/modules/ROCm/rocm
INSTALL_PREFIX=""
ROCM_PATH_OVERRIDE=""
ROCM_MODULEFILE_OVERRIDE=""
NOOP_RC=43

# ── distro / sudo plumbing (matches sibling *_setup.sh) ─────────────
DISTRO=$(cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]')
DISTRO_VERSION=$(cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]')
SUDO="sudo"
if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
fi
PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")

usage() {
   echo "Usage:"
   echo "  --rocm-version       [ X.Y.Z ]      required (e.g. 7.2.0)"
   echo "  --replace                           force re-apply even if sentinel present"
   echo "  --module-path        [ DIR ]        default ${MODULE_PATH}"
   echo "  --install-prefix     [ DIR ]        default /opt/rocm-patches-\${ROCM_VERSION}"
   echo "  --rocm-path          [ DIR ]        default /opt/rocm-\${ROCM_VERSION}"
   echo "  --rocm-modulefile    [ PATH ]       base rocm modulefile to wire auto-load into"
   echo "                                      (default: auto-probe under --module-path)"
   echo "  --help                              print this usage information"
   exit 1
}

send-error() {
   usage
   echo -e "\nError: ${@}"
   exit 1
}

reset-last() {
   last() { send-error "Unsupported argument :: ${1}"; }
}

n=0
while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--help")              usage ;;
      "--rocm-version")      shift; ROCM_VERSION=${1};         reset-last ;;
      "--replace")           REPLACE=1;                        reset-last ;;
      "--module-path")       shift; MODULE_PATH=${1};          reset-last ;;
      "--install-prefix")    shift; INSTALL_PREFIX=${1};       reset-last ;;
      "--rocm-path")         shift; ROCM_PATH_OVERRIDE=${1};   reset-last ;;
      "--rocm-modulefile")   shift; ROCM_MODULEFILE_OVERRIDE=${1}; reset-last ;;
      "--*")                 send-error "Unsupported argument at position $((${n} + 1)) :: ${1}" ;;
      *)                     last ${1} ;;
   esac
   n=$((${n} + 1))
   shift
done

[ -n "${ROCM_VERSION}" ] || send-error "--rocm-version is required"

# ── version gate ────────────────────────────────────────────────────
# The WGMXCC defect is present from rocm/7.1.0 onward, and the general rewrite
# is version-agnostic (it rewrites whatever the SDK ships), so every rocm
# >= 7.1.0 is handled without a per-version list. Anything older is a NOOP.
ver_ge() {  # ver_ge A B -> 0 (true) if A >= B, dotted-numeric, suffix-tolerant
   [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}
if ! ver_ge "${ROCM_VERSION}" "7.1.0"; then
   echo "[hipblaslt_patch] no fix vendored for rocm/${ROCM_VERSION}; exiting NOOP (rc=${NOOP_RC})"
   exit ${NOOP_RC}
fi

# ── derived paths ───────────────────────────────────────────────────
ROCM_PATH="${ROCM_PATH_OVERRIDE:-/opt/rocm-${ROCM_VERSION}}"
[ -d "${ROCM_PATH}/lib/hipblaslt/library" ] \
   || send-error "ROCm SDK hipblaslt library dir not found: ${ROCM_PATH}/lib/hipblaslt/library"

[ -n "${INSTALL_PREFIX}" ] || INSTALL_PREFIX="/opt/rocm-patches-${ROCM_VERSION}"

SRC_LIBDIR="${ROCM_PATH}/lib/hipblaslt/library"
DST_LIBDIR="${INSTALL_PREFIX}/hipblaslt/library"
DST_DOCDIR="${INSTALL_PREFIX}/hipblaslt"
MODULE_FILE="${MODULE_PATH}/rocmplus-${ROCM_VERSION}/hipblaslt/patched.lua"

# Layout probe: rocm/7.13.0+ stages the gfx942 .dat files under a
# per-arch subdir (lib/hipblaslt/library/gfx942/...), while 7.1.x and
# 7.2.x ship them flat in lib/hipblaslt/library/. We mirror whichever
# layout the SDK uses so HIPBLASLT_TENSILE_LIBPATH=${DST_LIBDIR}
# resolves the same way after the overlay is selected.
ARCH_SUBDIR=""
if [ -d "${SRC_LIBDIR}/gfx942" ] \
   && { compgen -G "${SRC_LIBDIR}/gfx942/*.dat" >/dev/null \
        || compgen -G "${SRC_LIBDIR}/gfx942/*.dat.zlib" >/dev/null; }; then
   ARCH_SUBDIR="gfx942"
fi
EFFECTIVE_SRC_LIBDIR="${SRC_LIBDIR}${ARCH_SUBDIR:+/${ARCH_SUBDIR}}"
EFFECTIVE_DST_LIBDIR="${DST_LIBDIR}${ARCH_SUBDIR:+/${ARCH_SUBDIR}}"

# Sentinel: a patched .dat embeds an in-band msgpack marker in rows[0].library.
# We mark the generic SS fallback the rewrite touches (patched on every
# supported version). Nested *.dat.zlib layouts ship it compressed, so match
# that suffix.
SENTINEL_KEY="__general_xcc_patch_v1__"
SENTINEL_BASE="TensileLibrary_SS_SS_UA_Type_SS_Contraction_l_Alik_Bjlk_Cijk_Dijk_gfx942.dat"
[ -f "${EFFECTIVE_SRC_LIBDIR}/${SENTINEL_BASE}.zlib" ] && SENTINEL_BASE="${SENTINEL_BASE}.zlib"
SENTINEL_DAT="${EFFECTIVE_DST_LIBDIR}/${SENTINEL_BASE}"

echo ""
echo "=================================="
echo "hipblaslt_patch_setup.sh"
echo "  ROCM_VERSION    : ${ROCM_VERSION}"
echo "  ROCM_PATH       : ${ROCM_PATH}"
echo "  INSTALL_PREFIX  : ${INSTALL_PREFIX}"
echo "  MODULE_FILE     : ${MODULE_FILE}"
echo "  REPLACE         : ${REPLACE}"
echo "  DISTRO          : ${DISTRO} ${DISTRO_VERSION}"
echo "  built by        : ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"
echo "=================================="

# ── ensure msgpack is available for the inline python patcher ───────
if ! python3 -c 'import msgpack' 2>/dev/null; then
   echo "[hipblaslt_patch] installing python3-msgpack (apt) ..."
   if [ "${DISTRO}" = "ubuntu" ]; then
      ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y python3-msgpack
   else
      send-error "msgpack not available for python3 and don't know how to install it on ${DISTRO}"
   fi
fi

# ── idempotency check ───────────────────────────────────────────────
if [ "${REPLACE}" -eq 0 ] && [ -f "${SENTINEL_DAT}" ] && [ ! -L "${SENTINEL_DAT}" ]; then
   has_sentinel=$(python3 - "${SENTINEL_DAT}" "${SENTINEL_KEY}" <<'PYEOF'
import sys, zlib, msgpack
try:
    raw = open(sys.argv[1], "rb").read()
    if sys.argv[1].endswith(".zlib"):
        raw = zlib.decompress(raw)
    d = msgpack.unpackb(raw, raw=False, strict_map_key=False)
    print(1 if sys.argv[2] in d["library"]["rows"][0]["library"] else 0)
except Exception as e:
    sys.stderr.write(f"sentinel check failed: {e}\n"); print(0)
PYEOF
)
   if [ "${has_sentinel}" = "1" ]; then
      echo "[hipblaslt_patch] already applied (sentinel present in ${SENTINEL_DAT##*/})."
      echo "[hipblaslt_patch] use --replace to force re-apply. Exiting 0."
      exit 0
   fi
fi

# ── stage + patch ───────────────────────────────────────────────────
WORKDIR=$(mktemp -d -t hipblaslt-patch.XXXXXX)
trap '[ -n "${WORKDIR:-}" ] && rm -rf "${WORKDIR}"' EXIT

echo "[hipblaslt_patch] running inline patcher ..."
python3 - --rocm-version "${ROCM_VERSION}" \
          --src-libdir "${EFFECTIVE_SRC_LIBDIR}" \
          --dst-libdir "${WORKDIR}" <<'PYEOF'
"""Inline patcher for hipBLASLt .dat libraries.

Two strategies (see the script header): a GENERAL workGroupMappingXCC -> 1
rewrite of the generic (no-CU) gfx942 fallbacks (patch_general_xcc), applied
uniformly to every supported rocm version. Idempotent via an in-band msgpack
sentinel in rows[0].library.
"""
import argparse
import os
import pathlib
import sys
import zlib

import msgpack

GENERAL_XCC_SENTINEL = "__general_xcc_patch_v1__"


def _read_lib(path):
    raw = open(path, "rb").read()
    if str(path).endswith(".zlib"):
        raw = zlib.decompress(raw)
    return msgpack.unpackb(raw, raw=False, strict_map_key=False)


def _write_lib(data, path):
    """Serialize `data` to `path`, zlib-compressing iff the name ends .zlib
    (so the overlay file matches the SDK's on-disk encoding for that version)."""
    blob = msgpack.packb(data, use_bin_type=True)
    if str(path).endswith(".zlib"):
        blob = zlib.compress(blob, 9)
    with open(path, "wb") as f:
        f.write(blob)


def _rewrite_wgmxcc(data, target=1):
    """Set every solution's workGroupMappingXCC (sizeMapping + the
    WorkgroupMappingXCCCheck predicate) to `target`, leaving auto/disabled
    values (None/-1/0) and already-`target` ones untouched. Returns the number
    of sizeMapping and predicate edits made."""
    sm = pp = 0
    for s in data.get("solutions", []):
        w = s.get("sizeMapping", {}).get("workGroupMappingXCC")
        if w not in (None, -1, 0, target):
            s["sizeMapping"]["workGroupMappingXCC"] = target
            sm += 1
        stack = [s.get("problemPredicate", {})]
        while stack:
            d = stack.pop()
            if isinstance(d, dict):
                if d.get("type") == "WorkgroupMappingXCCCheck":
                    v = d.get("value")
                    if isinstance(v, list) and v and v[0] not in (None, -1, 0, target):
                        nv = list(v); nv[0] = target; d["value"] = nv; pp += 1
                    elif not isinstance(v, list) and v not in (None, -1, 0, target):
                        d["value"] = target; pp += 1
                stack.extend(d.values())
            elif isinstance(d, list):
                stack.extend(d)
    return sm, pp


def patch_general_xcc(sdir, ddir, target=1):
    """General-path fix (see script header): rewrite WGMXCC->1 in
    every generic (no-CU) gfx942 fallback library. Handles both the flat
    uncompressed layout (7.2.x) and the nested gfx942/ *.dat.zlib layout
    (7.14+, 10.x); the caller passes the arch subdir as sdir, and we key
    (de)compression off the .zlib suffix. CU-specific sublibraries
    (..._CU38_/_CU64_/_CU80_/_CU152_/_CU228_...) are tuned per partition and are
    left untouched. A file that needs no edit is skipped so it stays a symlink
    into the base SDK. Idempotent via an in-band sentinel in rows[0].library."""
    import re
    cu = re.compile(r"_CU\d+_")
    files = sorted(list(sdir.glob("TensileLibrary_*_Cijk_Dijk_gfx942.dat"))
                   + list(sdir.glob("TensileLibrary_*_Cijk_Dijk_gfx942.dat.zlib")))
    ddir.mkdir(parents=True, exist_ok=True)
    patched = tot_sm = tot_pp = 0
    for f in files:
        if cu.search(f.name):
            continue
        data = _read_lib(f)
        sm, pp = _rewrite_wgmxcc(data, target)
        if sm == 0 and pp == 0:
            continue
        rows = data.get("library", {}).get("rows", [])
        if rows and isinstance(rows[0].get("library"), dict):
            rows[0]["library"][GENERAL_XCC_SENTINEL] = {
                "target_wgmxcc": target, "sm_changed": sm,
                "pp_changed": pp, "tool_version": 1}
        _write_lib(data, ddir / f.name)
        patched += 1; tot_sm += sm; tot_pp += pp
    print(f"  [general-xcc] {patched} generic fallback .dat patched "
          f"({tot_sm} sizeMapping + {tot_pp} predicate edits)")
    if patched == 0:
        sys.exit("general-xcc: no generic fallback needed patching (unexpected)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rocm-version", required=True)
    ap.add_argument("--src-libdir",   required=True)
    ap.add_argument("--dst-libdir",   required=True)
    args = ap.parse_args()
    patch_general_xcc(pathlib.Path(args.src_libdir),
                      pathlib.Path(args.dst_libdir))


if __name__ == "__main__":
    main()
PYEOF

# ── install into DST_LIBDIR ─────────────────────────────────────────
${SUDO} mkdir -p "${EFFECTIVE_DST_LIBDIR}"

# The set of patched .dat is whatever the inline patcher actually wrote into
# WORKDIR (the rewritten generic fallbacks). Deriving it here rather than
# hard-coding keeps this section correct as coverage changes.
mapfile -t PATCHED_FILES < <(cd "${WORKDIR}" && ls -1 2>/dev/null | grep -E '\.dat(\.zlib)?$')
[ "${#PATCHED_FILES[@]}" -gt 0 ] \
   || send-error "inline patcher produced no .dat files in ${WORKDIR}"
for fname in "${PATCHED_FILES[@]}"; do
   # --remove-destination is REQUIRED: on a --replace re-run the dst may
   # already be a symlink into the base SDK (from a prior run's symlink
   # farm, for files that weren't patched then but are now). A plain
   # `cp` FOLLOWS that symlink and writes THROUGH to the base SDK,
   # silently corrupting it. --remove-destination unlinks the dst first
   # so we always write a real file into the overlay and never touch
   # the base tree.
   ${SUDO} cp -p --remove-destination "${WORKDIR}/${fname}" "${EFFECTIVE_DST_LIBDIR}/${fname}"
   ${SUDO} chmod 0644 "${EFFECTIVE_DST_LIBDIR}/${fname}"
done

# Symlink farm: everything in the SDK library dir we didn't patch.
# For flat layout (7.1.x / 7.2.x): single pass over ${SRC_LIBDIR}.
# For nested layout (7.13.0+):     pass 1 mirrors top-level files
#                                  (extop_*.co, hipblasltTransform.hsaco,
#                                  hipblasltExtOpLibrary.dat, ...) without
#                                  filtering since they aren't patch
#                                  targets; pass 2 walks the gfx942/ subdir
#                                  and applies the patched-file filter
#                                  there.
PATCHED_SET=""
for fname in "${PATCHED_FILES[@]}"; do
   PATCHED_SET+=" ${fname}"
done
sl_count=0
for f in "${SRC_LIBDIR}"/*; do
   base="$(basename "${f}")"
   if [ -d "${f}" ]; then
      continue
   fi
   if [ -z "${ARCH_SUBDIR}" ]; then
      case " ${PATCHED_SET} " in
         *" ${base} "*) continue ;;
      esac
   fi
   ${SUDO} ln -sfn "${f}" "${DST_LIBDIR}/${base}"
   sl_count=$((sl_count + 1))
done
if [ -n "${ARCH_SUBDIR}" ]; then
   ${SUDO} mkdir -p "${DST_LIBDIR}/${ARCH_SUBDIR}"
   for f in "${SRC_LIBDIR}/${ARCH_SUBDIR}"/*; do
      base="$(basename "${f}")"
      case " ${PATCHED_SET} " in
         *" ${base} "*) continue ;;
      esac
      ${SUDO} ln -sfn "${f}" "${DST_LIBDIR}/${ARCH_SUBDIR}/${base}"
      sl_count=$((sl_count + 1))
   done
fi

# ── install README and modulefile ───────────────────────────────────
FIX_SUMMARY="Rewrites workGroupMappingXCC->1 in every generic (no-CU) gfx942 fallback library. The dominant tag is WGMXCC=8 (plus some 16/32), which divides neither 228 (SPX) nor 38 (CPX), so the predicate rejects those solutions -- the uncached empty-search defect behind the flat ~500ms GEMMs and the small-N fp16 heuristic misses, across fp16/bf16/fp32 and all layouts. WGMXCC=1 is the only value valid on every partition."
FIX_WHATIS="Restores perf on MI300A SPX+CPX by fixing the generic-fallback WGMXCC divisibility defect (fp16/bf16/fp32, all layouts)"
${SUDO} mkdir -p "${DST_DOCDIR}"
cat <<-EOF | ${SUDO} tee "${DST_DOCDIR}/README.md" >/dev/null
	hipblaslt opt-in overlay for rocm/${ROCM_VERSION}
	==================================================

	Produced by ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY}).

	hipBLASLt heuristic/dispatch regression fix on MI300A:
	${FIX_SUMMARY}

	Layout: ${DST_LIBDIR}/ contains ${#PATCHED_FILES[@]} patched .dat plus
	symlinks back into ${SRC_LIBDIR}/ for everything else.

	Activate:    module load rocm/${ROCM_VERSION}  (auto-loads the overlay)
	Deactivate:  module unload hipblaslt/patched   (HIPBLASLT_TENSILE_LIBPATH
	             is the only thing this module sets; base SDK is untouched.)
EOF

${SUDO} mkdir -p "$(dirname "${MODULE_FILE}")"
cat <<-EOF | ${SUDO} tee "${MODULE_FILE}" >/dev/null
	-- ${MODULE_FILE}
	--
	-- Opt-in hipBLASLt overlay for rocm/${ROCM_VERSION}:
	--   ${FIX_SUMMARY}
	-- ${#PATCHED_FILES[@]} patched .dat total this version.
	--
	-- Selected via HIPBLASLT_TENSILE_LIBPATH; base SDK byte-for-byte
	-- untouched. Overlay lives in ${INSTALL_PREFIX}/hipblaslt/library/.

	whatis("Name: hipBLASLt heuristic-regression overlay (SPX + CPX)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: patched (rocm-${ROCM_VERSION} base)")
	whatis("Category: AMD")
	whatis("Description: ${FIX_WHATIS}")

	-- No prereq("rocm/${ROCM_VERSION}"): structural via MODULEPATH-scoping
	-- under rocmplus-${ROCM_VERSION}/. A real prereq() also breaks the
	-- auto-load from inside rocm/${ROCM_VERSION}.lua.

	local libpath = "${EFFECTIVE_DST_LIBDIR}"
	setenv("HIPBLASLT_TENSILE_LIBPATH", libpath)

	-- Sentinel: \`env | grep HIPBLASLT_OVERLAY\` confirms the overlay is active.
	setenv("HIPBLASLT_OVERLAY", "rocm-patches-${ROCM_VERSION}/hipblaslt/library")
EOF

# ── wire auto-load into the base rocm/${ROCM_VERSION}.lua ───────────
# Idempotent append; the structural dependency (overlay modulefile on
# MODULEPATH) is provided by the rocmplus-${V}/ prepend already in
# the base file, so no prereq() needed (and adding one would break
# the auto-load from inside the parent module).
#
# Layouts vary across sites: the original /etc/lmod/modules/ROCm/rocm/
# layout keeps base modulefiles next to rocmplus-${V}/ (flat), while
# some sites split them (e.g. base/rocm/${V}.lua next to rocmplus-${V}/).
# --rocm-modulefile lets the caller pin an exact path; otherwise we
# auto-probe the two known layouts.
if [ -n "${ROCM_MODULEFILE_OVERRIDE}" ]; then
   ROCM_MODULE_FILE="${ROCM_MODULEFILE_OVERRIDE}"
else
   ROCM_MODULE_FILE=""
   for _cand in "${MODULE_PATH}/${ROCM_VERSION}.lua" \
                "${MODULE_PATH}/base/rocm/${ROCM_VERSION}.lua"; do
      if [ -f "${_cand}" ]; then
         ROCM_MODULE_FILE="${_cand}"
         break
      fi
   done
   unset _cand
fi
if [ -n "${ROCM_MODULE_FILE}" ] && [ -f "${ROCM_MODULE_FILE}" ]; then
   if grep -q 'hipblaslt/patched' "${ROCM_MODULE_FILE}"; then
      echo "[hipblaslt_patch] auto-load already wired in ${ROCM_MODULE_FILE}"
   else
      ROCM_MF_BAK="${ROCM_MODULE_FILE}.bak-pre-hipblaslt-autoload"
      [ -f "${ROCM_MF_BAK}" ] || ${SUDO} cp -p "${ROCM_MODULE_FILE}" "${ROCM_MF_BAK}"
      cat <<-AUTO_EOF | ${SUDO} tee -a "${ROCM_MODULE_FILE}" >/dev/null

	-- hipBLASLt heuristic-regression overlay (SPX 228-CU + CPX 38-CU).
	-- Modulefile lives at rocmplus-${ROCM_VERSION}/hipblaslt/patched.lua
	-- (on MODULEPATH via the rocmplus-${ROCM_VERSION} prepend above).
	-- Opt out for a session: \`module unload hipblaslt/patched\`.
	-- Revert auto-load: restore ${ROCM_MF_BAK}.
	load("hipblaslt/patched")
AUTO_EOF
      echo "[hipblaslt_patch] wired auto-load into ${ROCM_MODULE_FILE} (backup: ${ROCM_MF_BAK})"
   fi
else
   echo "[hipblaslt_patch] WARN: no rocm base modulefile found under ${MODULE_PATH}"
   echo "[hipblaslt_patch]       (probed: ${MODULE_PATH}/${ROCM_VERSION}.lua and"
   echo "[hipblaslt_patch]                ${MODULE_PATH}/base/rocm/${ROCM_VERSION}.lua);"
   echo "[hipblaslt_patch]       auto-load NOT wired. Either pass --rocm-modulefile <PATH>"
   echo "[hipblaslt_patch]       or run 'module load hipblaslt/patched' manually."
fi

echo ""
echo "[hipblaslt_patch] done."
echo "  overlay tree : ${DST_LIBDIR}  (${#PATCHED_FILES[@]} patched .dat + ${sl_count} symlinks)"
echo "  modulefile   : ${MODULE_FILE}"
echo ""
echo "[hipblaslt_patch] verify (single command, auto-loads the overlay):"
echo "    module load rocm/${ROCM_VERSION}"
echo "    echo \\\$HIPBLASLT_OVERLAY        # expect rocm-patches-${ROCM_VERSION}/hipblaslt/library"

exit 0
