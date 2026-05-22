#!/bin/bash
#
# hipblaslt_patch_setup.sh
# ------------------------
# Apply two vendored hipBLASLt fixes on top of the SDK installed by
# rocm/scripts/rocm_setup.sh at /opt/rocm-${ROCM_VERSION}, and expose
# them as an auto-loaded `hipblaslt/patched` Lmod module.
#
# Both fixes ride together in one overlay tree:
#
#   1. SPX heuristic restoration (228-CU). The gfx942 Equality
#      heuristic for the small-N fp16 OP_T*OP_N EPILOGUE_BIAS GEMM
#      family regressed between rocm/6.4.1 and rocm/7.1.0; we append
#      exact-match rows in 3 SPX .dat files mapping each shape to its
#      6.4.1 winner kernel.
#
#   2. CPX WorkGroupMappingXCC predicate fix (38-CU). gfx942_38cu
#      kernels in 7.x ship with WGMXCC=4; the runtime predicate
#      `(WGMXCCG=38) % (WGMXCC=4) != 0` rejects them on CPX. AMD PR
#      #5009 fixed this in source but the cherry-pick was reverted
#      from release/rocm-rel-7.2 (#5398) for release-policy reasons.
#      We rewrite WGMXCC: 4 -> 1 in the .dat msgpack.
#
# fp32 is intentionally NOT patched: there is no clear-cut fail line
# (the .dat carries Equality+GridBased so a miss degrades silently to
# a slower-but-valid GridBased pick rather than the fp16 short-circuit
# that returns 0 solutions), so we cannot reliably tell when a patch
# helps vs. hurts. Same for bf16 / fp64: see commit history.
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
# Currently handled ROCm versions (others exit NOOP_RC):
#   * 7.1.0, 7.1.1  -- family A
#   * 7.2.0         -- family B
#   * 7.2.2, 7.2.3  -- family C
#   * 7.13.0        -- family D (per-arch lib subdir gfx942/; CPX
#                     WGMXCC=4 defect already fixed upstream so the
#                     CPX rewrite step is a sentinel-only no-op there)
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
case "${ROCM_VERSION}" in
   7.1.0|7.1.1|7.2.0|7.2.2|7.2.3|7.13.0) ;;
   *)
      echo "[hipblaslt_patch] no fix vendored for rocm/${ROCM_VERSION}; exiting NOOP (rc=${NOOP_RC})"
      exit ${NOOP_RC}
      ;;
esac

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
if [ -d "${SRC_LIBDIR}/gfx942" ] && compgen -G "${SRC_LIBDIR}/gfx942/*.dat" >/dev/null; then
   ARCH_SUBDIR="gfx942"
fi
EFFECTIVE_SRC_LIBDIR="${SRC_LIBDIR}${ARCH_SUBDIR:+/${ARCH_SUBDIR}}"
EFFECTIVE_DST_LIBDIR="${DST_LIBDIR}${ARCH_SUBDIR:+/${ARCH_SUBDIR}}"

# Sentinel: CPX-patched .dat embeds an in-band msgpack marker.
SENTINEL_DAT="${EFFECTIVE_DST_LIBDIR}/TensileLibrary_HH_HH_HA_Bias_SAV_UA_Type_HH_HPA_Contraction_l_Alik_Bljk_Cijk_Dijk_CU38_gfx942.dat"

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
   has_sentinel=$(python3 - "${SENTINEL_DAT}" <<'PYEOF'
import sys, msgpack
try:
    d = msgpack.unpack(open(sys.argv[1], "rb"), raw=False, strict_map_key=False)
    print(1 if "__cpx_patch_v1__" in d["library"]["rows"][0]["library"] else 0)
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

echo "[hipblaslt_patch] running inline patcher (SPX heuristic + CPX WGMXCC) ..."
python3 - --rocm-version "${ROCM_VERSION}" \
          --src-libdir "${EFFECTIVE_SRC_LIBDIR}" \
          --dst-libdir "${WORKDIR}" <<'PYEOF'
"""Inline patcher for hipBLASLt .dat libraries (SPX heuristic + CPX WGMXCC).

Three SPX shapes (heuristic-row append) and three CPX shapes (WGMXCC=4 -> 1
rewrite) per ROCm version, all fp16. Idempotent on the CPX side via an
in-band msgpack sentinel at library.rows[0].library['__cpx_patch_v1__'].
"""
import argparse
import os
import pathlib
import sys

import msgpack

# fp16-only: HH = fp16 in / fp16 out / fp32 accumulate (the HPA path,
# what nn.Linear(...).half() lands on). fp32 / bf16 / fp64 are not
# patched (see header comment).
DAT_PREFIXES = {
    "HH": "TensileLibrary_HH_HH_HA_Bias_SAV_UA_Type_HH_HPA_Contraction_l_",
}

# SPX heuristic-table rows to patch.
#
# Forward (`Alik_Bljk_Cijk_Dijk_gfx942.dat`, transA=T, transB=N): rocm/7.x
# has lost equality rows for a whole family of small-N forward GEMMs. We
# patch the full 5 x 6 x 4 = 120-shape grid:
#   batches  bs  in {32, 64, 128, 256, 512, 1024}
#   classes  nc  in {10, 100, 256, 1000, 2048}
#   hiddens  hd  in {512, 1024, 2048, 4096}
# all to one fp16 kernel per version (MT16x16x256, MI16x16x32, WGMXCC=1).
#
# Backward (Ailk_Bljk + Ailk_Bjlk on CU228): we keep 1 row each
# defensively against future upstream regressions.
SPX_SHAPES = (
    [("HH", "Alik_Bljk_Cijk_Dijk_gfx942.dat",        nc,  bs, 1, hd)
     for nc in (10, 100, 256, 1000, 2048)
     for bs in (32, 64, 128, 256, 512, 1024)
     for hd in (512, 1024, 2048, 4096)]
    +
    [("HH", "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat", 2048, 256, 1,  100),
     ("HH", "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat", 2048, 100, 1,  256)]
)

# CPX WGMXCC=4 catalogue defect is in the HH_HH gfx942 38cu kernels.
# SS_SS 38cu already ships with WGMXCC=1 across all 5 versions.
CPX_DATS = [
    ("HH", "Alik_Bljk_Cijk_Dijk_CU38_gfx942.dat"),
    ("HH", "Ailk_Bljk_Cijk_Dijk_CU38_gfx942.dat"),
    ("HH", "Ailk_Bjlk_Cijk_Dijk_CU38_gfx942.dat"),
]

# SOLUTION_INDEX[v][(dtype_tag, suffix)] -> kernel solution index in
# that version's .dat catalogue. Indices vary between versions because
# the catalogue is reordered each release; the kernel NAME / tile
# signature is the version-stable identifier we hand-verified.
SOLUTION_INDEX = {
    "7.1.0": {("HH", "Alik_Bljk_Cijk_Dijk_gfx942.dat"):       299906,
              ("HH", "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat"): 291111,
              ("HH", "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat"): 287925},
    "7.1.1": {("HH", "Alik_Bljk_Cijk_Dijk_gfx942.dat"):       299906,
              ("HH", "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat"): 291111,
              ("HH", "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat"): 287925},
    "7.2.0": {("HH", "Alik_Bljk_Cijk_Dijk_gfx942.dat"):       347698,
              ("HH", "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat"): 338868,
              ("HH", "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat"): 335682},
    "7.2.2": {("HH", "Alik_Bljk_Cijk_Dijk_gfx942.dat"):       348921,
              ("HH", "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat"): 340091,
              ("HH", "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat"): 336905},
    "7.2.3": {("HH", "Alik_Bljk_Cijk_Dijk_gfx942.dat"):       348921,
              ("HH", "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat"): 340091,
              ("HH", "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat"): 336905},
    # rocm/7.13.0: catalogue was substantially regenerated -- the
    # 7.2.x indices don't survive. Mapped by tile signature:
    # MT16x16x256/MI16x16x1/WGMXCC1/GSU1 for fwd, MT128x{32,16}x32
    # for the two backward variants. CPX side is a sentinel-only
    # no-op here because every CU38 solution already ships with
    # workGroupMappingXCC=1 upstream.
    "7.13.0":{("HH", "Alik_Bljk_Cijk_Dijk_gfx942.dat"):       236740,
              ("HH", "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat"): 225772,
              ("HH", "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat"): 222586},
}
CPX_SENTINEL = "__cpx_patch_v1__"


def equality_matching(data):
    for r in data["library"]["rows"]:
        inner, pred = r.get("library", {}), r.get("predicate", {})
        if (pred.get("type") == "EqualityMatching"
                and inner.get("type") == "Matching"
                and inner.get("distance") == "Equality"):
            return inner
    raise SystemExit("no EqualityMatching row in .dat")


def _patch_one_row(table, key, idx):
    for entry in table:
        if entry.get("key") == key:
            entry["index"] = idx
            entry["speed"] = 0.0
            return "updated"
    table.append({"key": key, "index": idx, "speed": 0.0})
    return "added"


def patch_spx(src, dst, shapes_for_file, idx):
    """Patch one SPX .dat with all `shapes_for_file` rows in one pass.

    A single read+write per file is required when multiple rows share a
    filename, otherwise the second write would overwrite the first.
    """
    data = msgpack.unpack(open(src, "rb"), raw=False, strict_map_key=False)
    table = equality_matching(data)["table"]
    actions = []
    for M, N, B, K in shapes_for_file:
        actions.append((M, N, B, K, _patch_one_row(table, [M, N, B, K], idx)))
    dst.parent.mkdir(parents=True, exist_ok=True)
    with open(dst, "wb") as f:
        msgpack.pack(data, f)
    print(f"  [spx] {dst.name}: {len(actions)} row(s) -> solution {idx}")
    for M, N, B, K, what in actions:
        print(f"           {what:7s}  [{M}, {N}, {B}, {K}]")


def find_wgmxcc_predicate(pp):
    if not isinstance(pp, dict):
        return None
    for entry in pp.get("value", []):
        if isinstance(entry, dict) and entry.get("type") == "WorkgroupMappingXCCCheck":
            return entry
    return None


def patch_cpx(src, dst, target=1):
    data = msgpack.unpack(open(src, "rb"), raw=False, strict_map_key=False)
    inner = data["library"]["rows"][0]["library"]
    if CPX_SENTINEL in inner:
        dst.parent.mkdir(parents=True, exist_ok=True)
        with open(dst, "wb") as f:
            msgpack.pack(data, f)
        print(f"  [cpx] {dst.name}: already patched (sentinel present)")
        return
    sm_changed = pp_changed = 0
    for s in data["solutions"]:
        if s["sizeMapping"]["workGroupMappingXCC"] != target:
            s["sizeMapping"]["workGroupMappingXCC"] = target
            sm_changed += 1
        pred = find_wgmxcc_predicate(s["problemPredicate"])
        if pred is not None:
            v = pred["value"]
            if isinstance(v, list):
                if v[0] != target:
                    new_v = list(v); new_v[0] = target
                    pred["value"] = new_v
                    pp_changed += 1
            elif v != target:
                pred["value"] = target
                pp_changed += 1
    inner[CPX_SENTINEL] = {
        "target_wgmxcc": target,
        "sm_changed": sm_changed,
        "pp_changed": pp_changed,
        "rows_added": 0,
        "tool_version": 1,
    }
    dst.parent.mkdir(parents=True, exist_ok=True)
    # use_bin_type=True matches the v1 CPX patcher's on-disk encoding so
    # md5sums are stable across re-runs against a promoted overlay.
    with open(dst, "wb") as f:
        msgpack.pack(data, f, use_bin_type=True)
    print(f"  [cpx] {dst.name}: {sm_changed} sizeMapping + {pp_changed} predicate edits")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rocm-version", required=True)
    ap.add_argument("--src-libdir",   required=True)
    ap.add_argument("--dst-libdir",   required=True)
    args = ap.parse_args()
    if args.rocm_version not in SOLUTION_INDEX:
        sys.exit(f"unsupported rocm version {args.rocm_version}; "
                 f"have {sorted(SOLUTION_INDEX)}")
    sdir = pathlib.Path(args.src_libdir)
    ddir = pathlib.Path(args.dst_libdir)
    idx_map = SOLUTION_INDEX[args.rocm_version]
    # Group shapes by (dtype_tag, suffix): each file is read+written
    # once with all matching rows applied.
    by_file = {}
    for tag, suffix, M, N, B, K in SPX_SHAPES:
        by_file.setdefault((tag, suffix), []).append((M, N, B, K))
    for (tag, suffix), shapes in by_file.items():
        prefix = DAT_PREFIXES[tag]
        patch_spx(sdir / (prefix + suffix), ddir / (prefix + suffix),
                  shapes, idx_map[(tag, suffix)])
    for tag, suffix in CPX_DATS:
        prefix = DAT_PREFIXES[tag]
        patch_cpx(sdir / (prefix + suffix), ddir / (prefix + suffix))


if __name__ == "__main__":
    main()
PYEOF

# ── install into DST_LIBDIR ─────────────────────────────────────────
${SUDO} mkdir -p "${EFFECTIVE_DST_LIBDIR}"

HH_PREFIX="TensileLibrary_HH_HH_HA_Bias_SAV_UA_Type_HH_HPA_Contraction_l_"
PATCHED_FILES=(
   "${HH_PREFIX}Alik_Bljk_Cijk_Dijk_gfx942.dat"           # SPX fwd      fp16
   "${HH_PREFIX}Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat"     # SPX bwd_grad fp16
   "${HH_PREFIX}Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat"     # SPX bwd_wei  fp16
   "${HH_PREFIX}Alik_Bljk_Cijk_Dijk_CU38_gfx942.dat"      # CPX fwd      fp16 (WGMXCC rewrite)
   "${HH_PREFIX}Ailk_Bljk_Cijk_Dijk_CU38_gfx942.dat"      # CPX bwd_grad fp16 (WGMXCC rewrite)
   "${HH_PREFIX}Ailk_Bjlk_Cijk_Dijk_CU38_gfx942.dat"      # CPX bwd_wei  fp16 (WGMXCC rewrite)
)
for fname in "${PATCHED_FILES[@]}"; do
   ${SUDO} cp -p "${WORKDIR}/${fname}" "${EFFECTIVE_DST_LIBDIR}/${fname}"
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
${SUDO} mkdir -p "${DST_DOCDIR}"
cat <<-EOF | ${SUDO} tee "${DST_DOCDIR}/README.md" >/dev/null
	hipblaslt opt-in overlay for rocm/${ROCM_VERSION}
	==================================================

	Produced by ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY}).

	Two fp16 regressions on MI300A:

	* SPX heuristic-table hole -- adds exact-match rows to 3 CU228 .dat
	  files routing the failing shapes to known-good 6.4.1 kernels.
	* CPX WorkGroupMappingXCC=4 predicate failure -- rewrites WGMXCC=1
	  in every solution of 3 CU38 .dat files.

	Layout: ${DST_LIBDIR}/ contains the 6 patched .dat plus symlinks
	back into ${SRC_LIBDIR}/ for everything else.

	Activate:    module load rocm/${ROCM_VERSION}  (auto-loads the overlay)
	Deactivate:  module unload hipblaslt/patched   (HIPBLASLT_TENSILE_LIBPATH
	             is the only thing this module sets; base SDK is untouched.)
EOF

${SUDO} mkdir -p "$(dirname "${MODULE_FILE}")"
cat <<-EOF | ${SUDO} tee "${MODULE_FILE}" >/dev/null
	-- ${MODULE_FILE}
	--
	-- Opt-in fp16 hipBLASLt overlay for rocm/${ROCM_VERSION}:
	--   1. SPX heuristic restoration (CU228) -- 3 .dat files.
	--   2. CPX WGMXCC: 4 -> 1 predicate fix  (CU38)  -- 3 .dat files.
	--
	-- Selected via HIPBLASLT_TENSILE_LIBPATH; base SDK byte-for-byte
	-- untouched. Overlay lives in ${INSTALL_PREFIX}/hipblaslt/library/.

	whatis("Name: hipBLASLt heuristic-regression overlay (SPX + CPX)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: patched (rocm-${ROCM_VERSION} base)")
	whatis("Category: AMD")
	whatis("Description: Restores perf on MI300A SPX and CPX for skinny fp16 GEMMs")

	-- No prereq("rocm/${ROCM_VERSION}"): structural via MODULEPATH-scoping
	-- under rocmplus-${ROCM_VERSION}/. A real prereq() also breaks the
	-- auto-load from inside rocm/${ROCM_VERSION}.lua.

	local libpath = "${DST_LIBDIR}"
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
echo "  overlay tree : ${DST_LIBDIR}  (6 patched .dat + ${sl_count} symlinks)"
echo "  modulefile   : ${MODULE_FILE}"
echo ""
echo "[hipblaslt_patch] verify (single command, auto-loads the overlay):"
echo "    module load rocm/${ROCM_VERSION}"
echo "    echo \\\$HIPBLASLT_OVERLAY        # expect rocm-patches-${ROCM_VERSION}/hipblaslt/library"

exit 0
