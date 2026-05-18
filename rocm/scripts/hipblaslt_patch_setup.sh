#!/bin/bash
#
# hipblaslt_patch_setup.sh
# ------------------------
# Apply two vendored hipBLASLt fixes on top of the SDK that
# rocm/scripts/rocm_setup.sh just installed at /opt/rocm-${ROCM_VERSION},
# and expose them as a single opt-in `hipblaslt/patched` Lmod module.
#
# Both fixes ride together in one overlay tree:
#
#   1. SPX heuristic restoration (228-CU partition). The gfx942 Equality
#      heuristic for the small-N fp16 OP_T*OP_N EPILOGUE_BIAS GEMM family
#      regressed between rocm/6.4.1 and rocm/7.1.0; append exact-match
#      rows in 3 SPX .dat files mapping each shape to its 6.4.1 winner
#      kernel (still present in the 7.x library, just no longer reachable).
#      As of 2026-05-18 the forward .dat carries 12 rows covering the
#      full {num_classes in {10,100,1000}} x {batch_size in {64,128,256,512}}
#      with K=2048 sweep, after the regression test
#      (HPCTrainingExamples/tests/hipblaslt_regression_check.sh) found
#      that the upstream gap covered the whole family, not just the
#      hand-measured (M=100, N=256, K=2048) point. The other 2 SPX .dat
#      files (backward grad + backward weight) carry 1 row each.
#
#   2. CPX WorkGroupMappingXCC predicate fix (38-CU partition). gfx942_38cu
#      kernels in 7.x ship with WGMXCC=4; runtime predicate
#      `(WGMXCCG=38) % (WGMXCC=4) != 0` rejects them on CPX. AMD PR #5009
#      fixed this in source (WGMXCC: 4 -> 1) but the cherry-pick to
#      release/rocm-rel-7.2 (#5144) was reverted by #5398 for
#      release-policy reasons. Rewrite WGMXCC: 4 -> 1 in the .dat msgpack
#      on every solution of the 3 CPX .dat files. Per upstream PR #5009's
#      YAML-only diff, kernel binaries (.co) do not bake WGMXCC into the
#      hot path -- evidence the data-level rewrite is equivalent to a
#      source rebuild for these shapes.
#
# The buggy artefacts here are compiled Tensile `.dat` libraries (not
# source text), so the fix is data manipulation rather than a `git am`-
# style cherry-pick. We therefore inline the Python patcher and the
# per-rocm-version solution-index table directly into this script (as
# a heredoc), rather than vendoring a sister-dir under
# sources/rocm-patches/. Single file, no separate bundle to keep in sync.
#
# Conventions match the sibling rocm/scripts/*_setup.sh leaves and
# rocm_patches.sh in particular:
#   * --rocm-version <X.Y.Z>          required
#   * --replace                       force re-apply even if sentinel present
#   * --module-path <DIR>             base of the lmod tree (default
#                                     /etc/lmod/modules/ROCm/rocm,
#                                     matching rocm_setup.sh's mbase)
#   * --install-prefix <DIR>          where the overlay tree lands
#                                     (default /opt/rocm-patches-${ROCM_VERSION})
#   * --rocm-path <DIR>               base SDK dir (default
#                                     /opt/rocm-${ROCM_VERSION})
#   * exit 0  -- did work, or already up to date
#   * exit 43 -- intentional no-op (this ROCm version has no vendored fix)
#   * exit 1  -- real error
#
# Idempotent: re-running with the same ROCM_VERSION while the patched
# overlay is already in place (CPX sentinel `__cpx_patch_v1__` present
# in the staged .dat) is a fast check-and-exit-0. Pass --replace to
# rebuild from scratch.
#
# Currently handled ROCm versions (others exit NOOP_RC):
#   * 7.1.0, 7.1.1  -- family A: identical .dat content after patch
#   * 7.2.0         -- family B
#   * 7.2.2, 7.2.3  -- family C: identical .dat content after patch
#
# See ~admin/hipblaslt_heuristic_regression.md for the user-facing
# regression report + reproducer, and the comparison_report*.md files
# under ~admin/scope-work/ and ~admin/CPX_hipblaslt_scope_work/ for the
# FACT/INFERENCE/OPINION-tagged validation evidence.

set -euo pipefail

# Capture this script's absolute path BEFORE any cd, so the git-provenance
# block lower down can resolve the script in the repo even after the
# build has cd'd into a temp dir.
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
      "--*")                 send-error "Unsupported argument at position $((${n} + 1)) :: ${1}" ;;
      *)                     last ${1} ;;
   esac
   n=$((${n} + 1))
   shift
done

[ -n "${ROCM_VERSION}" ] || send-error "--rocm-version is required"

# ── version gate ────────────────────────────────────────────────────
case "${ROCM_VERSION}" in
   7.1.0|7.1.1|7.2.0|7.2.2|7.2.3) ;;
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
# Modulefile target: /etc/lmod/modules/ROCm/rocm/rocmplus-${V}/hipblaslt/patched.lua
# Loaded automatically once `rocm/${V}` is in the modulelist because the
# base rocm/${V} modulefile prepend_path's its `rocmplus-${V}/` subdir
# onto MODULEPATH (see rocm_setup.sh ~L860).
MODULE_FILE="${MODULE_PATH}/rocmplus-${ROCM_VERSION}/hipblaslt/patched.lua"

# Sentinel: CPX-patched .dat embeds an in-band msgpack marker. Cheapest
# of the 6 .dat to msgpack-decode.
SENTINEL_DAT="${DST_LIBDIR}/TensileLibrary_HH_HH_HA_Bias_SAV_UA_Type_HH_HPA_Contraction_l_Alik_Bljk_Cijk_Dijk_CU38_gfx942.dat"

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
          --src-libdir "${SRC_LIBDIR}" \
          --dst-libdir "${WORKDIR}" <<'PYEOF'
"""Inline patcher for hipBLASLt .dat libraries (SPX heuristic + CPX WGMXCC).

Three SPX shapes (heuristic-row append) and three CPX shapes (WGMXCC=4 -> 1
rewrite) per ROCm version. Idempotent on the CPX side via an in-band
msgpack sentinel at library.rows[0].library['__cpx_patch_v1__'].

The per-version solution-index table below was extracted from the deployed
patched .dat files on this cluster on 2026-05-17. Different ROCm releases
renumber their kernel registries, so we look up the integer index that
points at the same 6.4.1 winner kernel inside each release.
"""
import argparse
import os
import pathlib
import sys

import msgpack

DAT_PREFIX = "TensileLibrary_HH_HH_HA_Bias_SAV_UA_Type_HH_HPA_Contraction_l_"

# (basename-suffix, M, N, B, K): SPX heuristic-table rows to patch.
#
# Forward direction (`Alik_Bljk_Cijk_Dijk_gfx942.dat`, transA=T, transB=N):
# the upstream rocm/7.x gfx942 heuristic has lost equality rows for a
# WHOLE FAMILY of small-N fp16 forward GEMMs, not just the original
# (100, 256, 2048) point. The regression test discovers gaps across:
#   batches  bs  in {32, 64, 128, 256, 512, 1024}
#   classes  nc  in {10, 100, 256, 1000, 2048}
#   hiddens  hd  in {512, 1024, 2048, 4096}
# 5 x 6 x 4 = 120 forward shapes. We patch all of them with a single
# kernel (per-version index in SOLUTION_INDEX below); the chosen
# kernel's predicates are permissive (M >= 1, N >= 1, K >= 32 = 512 in
# our minimum, fp16 inputs, bias on, gfx942) so every cell in the
# 120-shape grid is correctness-compatible. Macro tile MT16x16x256
# launches enough workgroups to fill the SPX 228-CU partition across
# the whole range. Upstream PR / ticket reference: this is what the
# 6.4.1 -> 7.1.0 retune dropped.
#
# Backward directions (`Ailk_Bljk_..._CU228`, `Ailk_Bjlk_..._CU228`):
# the upstream backward heuristic was still healthy on this cluster's
# measurements (the regression test reports only forward misses), so
# we keep only the 2 originally-investigated shapes defensively
# (idempotent + cheap; protects against future upstream regressions
# of cells we know matter to ResNet finetuning).
SPX_SHAPES = (
    # forward: (M=num_classes, N=batch_size, B=1, K=hidden)
    [("Alik_Bljk_Cijk_Dijk_gfx942.dat",        nc,  bs, 1, hd)
     for nc in (10, 100, 256, 1000, 2048)
     for bs in (32, 64, 128, 256, 512, 1024)
     for hd in (512, 1024, 2048, 4096)]
    +
    # backward grad + backward weight (original SPX investigation).
    [("Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat", 2048, 256, 1,  100),
     ("Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat", 2048, 100, 1,  256)]
)
CPX_DATS = [
    "Alik_Bljk_Cijk_Dijk_CU38_gfx942.dat",
    "Ailk_Bljk_Cijk_Dijk_CU38_gfx942.dat",
    "Ailk_Bjlk_Cijk_Dijk_CU38_gfx942.dat",
]
SOLUTION_INDEX = {
    "7.1.0": {"Alik_Bljk_Cijk_Dijk_gfx942.dat":       299906,
              "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat": 291111,
              "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat": 287925},
    "7.1.1": {"Alik_Bljk_Cijk_Dijk_gfx942.dat":       299906,
              "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat": 291111,
              "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat": 287925},
    "7.2.0": {"Alik_Bljk_Cijk_Dijk_gfx942.dat":       347698,
              "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat": 338868,
              "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat": 335682},
    "7.2.2": {"Alik_Bljk_Cijk_Dijk_gfx942.dat":       348921,
              "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat": 340091,
              "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat": 336905},
    "7.2.3": {"Alik_Bljk_Cijk_Dijk_gfx942.dat":       348921,
              "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat": 340091,
              "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat": 336905},
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

    `shapes_for_file` is a list of (M, N, B, K) tuples that all live in
    this single .dat (the same OperationIdentifier transpose pattern).
    Reading + writing once per file is REQUIRED when multiple rows share
    a filename, otherwise the second write would overwrite the first.
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
        # Already patched (rare path; the bash wrapper short-circuits this
        # case via the same sentinel before we get here). Copy through.
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
        "rows_added": 0,  # kept for byte-equivalence with the v1 deployment
        "tool_version": 1,
    }
    dst.parent.mkdir(parents=True, exist_ok=True)
    # use_bin_type=True matches the v1 CPX patcher's on-disk encoding so
    # md5sums are stable across re-runs against an already-promoted overlay.
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
    # Group shapes by .dat filename: each file is read+written once,
    # with all matching rows applied. Preserves declaration order
    # within each file (and thus determinism of the encoded bytes).
    by_file = {}
    for suffix, M, N, B, K in SPX_SHAPES:
        by_file.setdefault(suffix, []).append((M, N, B, K))
    for suffix, shapes in by_file.items():
        patch_spx(sdir / (DAT_PREFIX + suffix), ddir / (DAT_PREFIX + suffix),
                  shapes, idx_map[suffix])
    for suffix in CPX_DATS:
        patch_cpx(sdir / (DAT_PREFIX + suffix), ddir / (DAT_PREFIX + suffix))


if __name__ == "__main__":
    main()
PYEOF

# ── install into DST_LIBDIR ─────────────────────────────────────────
${SUDO} mkdir -p "${DST_LIBDIR}"

DAT_PREFIX="TensileLibrary_HH_HH_HA_Bias_SAV_UA_Type_HH_HPA_Contraction_l_"
PATCHED_SUFFIXES=(
   "Alik_Bljk_Cijk_Dijk_gfx942.dat"
   "Ailk_Bljk_Cijk_Dijk_CU228_gfx942.dat"
   "Ailk_Bjlk_Cijk_Dijk_CU228_gfx942.dat"
   "Alik_Bljk_Cijk_Dijk_CU38_gfx942.dat"
   "Ailk_Bljk_Cijk_Dijk_CU38_gfx942.dat"
   "Ailk_Bjlk_Cijk_Dijk_CU38_gfx942.dat"
)
for suffix in "${PATCHED_SUFFIXES[@]}"; do
   ${SUDO} cp -p "${WORKDIR}/${DAT_PREFIX}${suffix}" "${DST_LIBDIR}/${DAT_PREFIX}${suffix}"
   ${SUDO} chmod 0644 "${DST_LIBDIR}/${DAT_PREFIX}${suffix}"
done

# Symlink farm: everything in the SDK library dir we didn't patch.
PATCHED_SET=""
for suffix in "${PATCHED_SUFFIXES[@]}"; do
   PATCHED_SET+=" ${DAT_PREFIX}${suffix}"
done
sl_count=0
for f in "${SRC_LIBDIR}"/*; do
   base="$(basename "${f}")"
   case " ${PATCHED_SET} " in
      *" ${base} "*) continue ;;
   esac
   ${SUDO} ln -sfn "${f}" "${DST_LIBDIR}/${base}"
   sl_count=$((sl_count + 1))
done

# ── install README and modulefile ───────────────────────────────────
${SUDO} mkdir -p "${DST_DOCDIR}"
cat <<-EOF | ${SUDO} tee "${DST_DOCDIR}/README.md" >/dev/null
	hipblaslt opt-in overlay for rocm/${ROCM_VERSION}
	==================================================

	Produced by ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY}).

	Fixes two independent regressions on MI300A:

	* SPX heuristic-table hole (3 small-N fp16 GEMM shapes) -- adds
	  exact-match rows to 3 patched CU228/shared-lib .dat files.
	* CPX WorkGroupMappingXCC=4 predicate failure -- rewrites WGMXCC
	  to 1 in every solution of 3 patched CU38 .dat files.

	Layout: ${DST_LIBDIR}/ contains the 6 patched .dat plus symlinks
	back into ${SRC_LIBDIR}/ for everything else.

	Activate:    module load rocm/${ROCM_VERSION}; module load hipblaslt/patched
	Deactivate:  module unload hipblaslt/patched (overlay is purely
	             additive via HIPBLASLT_TENSILE_LIBPATH; the base
	             rocm/${ROCM_VERSION} install is byte-for-byte unchanged).

	See ~admin/hipblaslt_heuristic_regression.md for the regression
	report and reproducer.
EOF

${SUDO} mkdir -p "$(dirname "${MODULE_FILE}")"
cat <<-EOF | ${SUDO} tee "${MODULE_FILE}" >/dev/null
	-- ${MODULE_FILE}
	--
	-- Opt-in overlay for hipBLASLt on rocm/${ROCM_VERSION} that restores
	-- rocm/6.4.1-class perf for the three skinny-GEMM shapes hit by
	-- single_process.sh (and any similar small-N fp16 GEMM workload) on
	-- MI300A. Two distinct fixes ride together in this single overlay
	-- tree, both activated by one \`module load hipblaslt/patched\`:
	--
	--   1. SPX heuristic restoration (228-CU). Appends missing
	--      gfx942 Equality rows in 3 .dat files; routes the failing
	--      shapes to known-good 6.4.1 winner kernels.
	--   2. CPX WGMXCC predicate fix (38-CU). Rewrites WGMXCC: 4 -> 1
	--      in every solution of 3 CU38 .dat files (mirrors AMD
	--      PR #5009, which was reverted from release/rocm-rel-7.2 by
	--      PR #5398 for release-policy reasons).
	--
	-- Both fixes are non-destructive: the overlay lives in
	-- ${INSTALL_PREFIX}/hipblaslt/library/ and is selected via
	-- HIPBLASLT_TENSILE_LIBPATH. The base rocm/${ROCM_VERSION} install
	-- is byte-for-byte untouched.

	whatis("Name: hipBLASLt heuristic-regression overlay (SPX + CPX)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: patched (rocm-${ROCM_VERSION} base)")
	whatis("Category: AMD")
	whatis("Description: Restores rocm/6.4.1-class perf on MI300A SPX and CPX for skinny fp16 GEMMs")

	-- No prereq("rocm/${ROCM_VERSION}") on purpose: this modulefile lives in
	-- the rocmplus-${ROCM_VERSION}/ tree which is only on MODULEPATH when
	-- rocm/${ROCM_VERSION} is loaded, so the prerequisite is structural.
	-- Adding prereq() here also breaks the auto-load from inside
	-- rocm/${ROCM_VERSION}.lua, because Lmod treats the parent module as
	-- "not yet loaded" while it is being processed.

	local libpath = "${DST_LIBDIR}"
	setenv("HIPBLASLT_TENSILE_LIBPATH", libpath)

	-- Sentinel env var: \`env | grep HIPBLASLT_OVERLAY\` confirms the overlay is active.
	setenv("HIPBLASLT_OVERLAY", "rocm-patches-${ROCM_VERSION}/hipblaslt/library")
EOF

# ── wire auto-load into the base rocm/${ROCM_VERSION}.lua ───────────
# Append `load("hipblaslt/patched")` so users get the overlay just by
# loading rocm/${ROCM_VERSION}. Idempotent: skip if the line is already
# in the file. Per-file backup saved on first wire-up as
# <rocm-modulefile>.bak-pre-hipblaslt-autoload.
#
# Why this works without a `prereq()` chicken-and-egg: the patched
# modulefile lives under rocmplus-${ROCM_VERSION}/hipblaslt/, which is
# only on MODULEPATH because the rocm/${ROCM_VERSION}.lua just above
# this `load()` line prepended it. The structural dependency is
# guaranteed by the modulepath, not by a runtime prereq() check (which
# would fail here because Lmod treats the parent module as "still
# loading" until its modulefile finishes).
ROCM_MODULE_FILE="${MODULE_PATH}/${ROCM_VERSION}.lua"
if [ -f "${ROCM_MODULE_FILE}" ]; then
   if grep -q 'hipblaslt/patched' "${ROCM_MODULE_FILE}"; then
      echo "[hipblaslt_patch] auto-load already wired in ${ROCM_MODULE_FILE}"
   else
      ROCM_MF_BAK="${ROCM_MODULE_FILE}.bak-pre-hipblaslt-autoload"
      [ -f "${ROCM_MF_BAK}" ] || ${SUDO} cp -p "${ROCM_MODULE_FILE}" "${ROCM_MF_BAK}"
      cat <<-AUTO_EOF | ${SUDO} tee -a "${ROCM_MODULE_FILE}" >/dev/null

	-- hipBLASLt heuristic-regression overlay (SPX 228-CU + CPX 38-CU).
	-- The overlay modulefile lives at rocmplus-${ROCM_VERSION}/hipblaslt/patched.lua
	-- (already on MODULEPATH via the rocmplus-${ROCM_VERSION} prepend above).
	-- Auto-loaded so every user of rocm/${ROCM_VERSION} gets the perf
	-- fix transparently. Opt out for a session with:
	--    module unload hipblaslt/patched
	-- Or revert the auto-load by restoring ${ROCM_MF_BAK}.
	load("hipblaslt/patched")
AUTO_EOF
      echo "[hipblaslt_patch] wired auto-load into ${ROCM_MODULE_FILE} (backup: ${ROCM_MF_BAK})"
   fi
else
   echo "[hipblaslt_patch] WARN: rocm modulefile ${ROCM_MODULE_FILE} not found;"
   echo "[hipblaslt_patch]       auto-load NOT wired. Users will need to run"
   echo "[hipblaslt_patch]       'module load hipblaslt/patched' manually."
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
