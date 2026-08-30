#!/bin/bash
# ---------------------------------------------------------------------------
# Migrate ROCm 10.x modulefiles from the Layer-1 rocprofv3 PATH-shim to the
# Layer-2 rocprofiler-sdk tool interposer (librocprof_guard.so).
#
#   apply_layer2.sh --all          # every 10.x modulefile in both trees
#   apply_layer2.sh --revert-all   # restore the newest pre-change backup
#   apply_layer2.sh --list
#   apply_layer2.sh <modulefile.lua> <tree_root>
#
# Each file is (1) backed up, (2) stripped of the Layer-1 ROCM10_ROCPROFV3_GUARD
# block (the CLI shim -- Layer 2 now owns serialization, and keeping both makes
# the shim's held node-lock deadlock against the tool's), and (3) given the
# Layer-2 block: prepend our tool to ROCP_TOOL_LIBRARIES + unset the PC-sampling/
# SPM/ATT beta opt-ins. The tool STANDS DOWN for non-profiling GPU apps.
# ---------------------------------------------------------------------------
set -euo pipefail
TAG='ROCM10_GUARD_LAYER2'
L1TAG='ROCM10_ROCPROFV3_GUARD'
TREES=(/nfsapps/ubuntu-24.04 /nfsapps/ubuntu-24.04-nightlies)

strip_l1() {   # remove the Layer-1 shim block (comment lines + its PATH prepend)
    sudo -n python3 - "$1" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
pat = re.compile(r'\n?-- ROCM10_ROCPROFV3_GUARD .*?prepend_path\("PATH",\s*"[^"]*rocm10-guard/bin"\)\n?', re.S)
open(p, 'w').write(pat.sub('\n', s))
PY
}

apply_one() {
    local mf="$1" tree="$2"
    local so="$tree/opt/rocm10-guard/lib/librocprof_guard.so"
    [ -f "$mf" ] || { echo "  no such modulefile: $mf" >&2; return 1; }
    [ -f "$so" ] || { echo "  missing guard lib: $so" >&2; return 1; }
    local has_l1=0 has_l2=0
    grep -q "$L1TAG" "$mf" && has_l1=1
    grep -q "$TAG"   "$mf" && has_l2=1
    if [ $has_l1 -eq 0 ] && [ $has_l2 -eq 1 ]; then echo "  SKIP (already migrated): $mf"; return 0; fi
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    sudo -n cp -a "$mf" "$mf.bak-l2guard-$ts"
    [ $has_l1 -eq 1 ] && { strip_l1 "$mf"; echo "  - removed Layer-1 shim: $mf"; }
    if [ $has_l2 -eq 0 ]; then
        sudo -n tee -a "$mf" >/dev/null <<EOF

-- $TAG (added $ts): rocprofiler-sdk tool interposer -- the single durable guard
-- for MI300A profiling. Every modern front-end (rocprofv3, rocprof-sys,
-- rocprof-compute, PyTorch/roctracer) initializes through rocprofiler-sdk, so this
-- one tool covers them all; there is no rocprofv2/rocprof to wrap. On MI300A it
-- (a) STRIPS the PC-sampling/SPM/ATT beta HW modes that hard-reset the node even
-- single-session, and (b) SERIALIZES concurrent profiling sessions node-wide
-- (per-SLURM_JOB leader election so MPI ranks never deadlock; inherits an
-- ancestor's guard instead of re-locking). It STANDS DOWN for non-profiling GPU
-- apps, so ordinary GPU work is unaffected. Src/tests: /shared/rocm-sweep/rocm10-guard-layer2 .
-- Revert: apply_layer2.sh --revert-all  (restores $mf.bak-l2guard-$ts).
prepend_path("ROCP_TOOL_LIBRARIES", "$so", ":")
unsetenv("ROCPROFILER_PC_SAMPLING_BETA_ENABLED")
unsetenv("ROCPROFILER_SPM_BETA_ENABLED")
unsetenv("ROCPROF_ATT_LIBRARY_PATH")
EOF
        echo "  + applied Layer-2: $mf"
    fi
}

revert_one() {
    local mf="$1"
    local bak; bak=$(ls -1t "$mf".bak-l2guard-* 2>/dev/null | head -1 || true)
    if [ -n "$bak" ]; then sudo -n cp -a "$bak" "$mf"; echo "  restored $mf  <- $(basename "$bak")";
    else echo "  (no backup) $mf"; fi
}

list_files() {
    for t in "${TREES[@]}"; do
        for f in "$t"/modules/base/rocm/10.*.lua; do
            [[ "$f" == *.bak* ]] && continue
            [ -e "$f" ] || continue
            echo "$f|$t"
        done
    done
}

case "${1:-}" in
    --all)        list_files | while IFS='|' read -r f t; do apply_one "$f" "$t"; done ;;
    --revert-all) list_files | while IFS='|' read -r f t; do revert_one "$f"; done ;;
    --list)       list_files | sed 's/|/   <- tree /' ;;
    "")           echo "usage: $0 --all | --revert-all | --list | <modulefile> <tree>" >&2; exit 2 ;;
    *)            apply_one "$1" "$2" ;;
esac
