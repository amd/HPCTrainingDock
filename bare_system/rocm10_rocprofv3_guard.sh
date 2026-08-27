#!/bin/bash
# ---------------------------------------------------------------------------
# rocm10_rocprofv3_guard.sh - install the ROCm-10.x rocprofv3 SERIALIZER shim
# and PATH-prepend it in one or more ROCm 10.x Lmod modulefiles (idempotent).
#
# WHY: under ROCm >= 10.x on MI300A, concurrent per-kernel-dispatch rocprofv3
# profiling across a node's GPUs hard-crashes the node (firmware-first
# uncorrected-cache MCA). The shim serializes concurrent profiling to one
# session/node via flock; single-session profiling (roofline/counters/traces)
# is unaffected. Full evidence + reproducer: /shared/rocm-sweep .
#
# This is the single source of truth used by BOTH:
#   * the nightly build leaf (run_rocm_therock_install.sh, Phase 5b) via
#       --modulefile <the-just-built 10.x .lua>
#   * the manual tree-wide deployer (/shared/rocm-sweep/guard_deploy.sh) via
#       --module-root <dir> (guards every 10.*.lua it finds)
#
# It is safe to re-run: files already carrying the guard marker are skipped,
# and only modulefiles whose version is 10.x are ever touched.
#
# Usage:
#   rocm10_rocprofv3_guard.sh --guard-dir DIR (--modulefile F | --module-root D)
#                             [--shim-src PATH] [--sudo|--no-sudo] [--dry-run]
#
#   --guard-dir DIR    bin dir the shim is installed into and prepended to PATH
#                      (e.g. /nfsapps/ubuntu-24.04-nightlies/opt/rocm10-guard/bin)
#   --modulefile F     guard exactly this one modulefile (must be a 10.x file)
#   --module-root D    guard every D/10.*.lua modulefile
#   --shim-src PATH    shim to install (default: rocm10-guard/rocprofv3 next to
#                      this script)
#   --sudo/--no-sudo   run privileged ops (install/edit) via sudo (default: auto
#                      -> sudo unless already root)
#   --dry-run          print what would happen; change nothing
# ---------------------------------------------------------------------------
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MARK="ROCM10_ROCPROFV3_GUARD"
STAMP="$(date +%Y%m%d-%H%M%S)"

GUARD_DIR=""
MODULEFILE=""
MODULE_ROOT=""
SHIM_SRC="${SELF_DIR}/rocm10-guard/rocprofv3"
DRYRUN=0
# auto sudo: use sudo unless we are already root
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

die(){ echo "rocm10-guard: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --guard-dir)   GUARD_DIR="${2:?}"; shift 2;;
        --modulefile)  MODULEFILE="${2:?}"; shift 2;;
        --module-root) MODULE_ROOT="${2:?}"; shift 2;;
        --shim-src)    SHIM_SRC="${2:?}"; shift 2;;
        --sudo)        SUDO="sudo"; shift;;
        --no-sudo)     SUDO=""; shift;;
        --dry-run)     DRYRUN=1; shift;;
        -h|--help)     sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0;;
        *)             die "unknown arg: $1";;
    esac
done

[ -n "${GUARD_DIR}" ]   || die "missing --guard-dir"
[ -f "${SHIM_SRC}" ]    || die "shim source not found: ${SHIM_SRC}"
if [ -n "${MODULEFILE}" ] && [ -n "${MODULE_ROOT}" ]; then
    die "use --modulefile OR --module-root, not both"
fi
[ -n "${MODULEFILE}${MODULE_ROOT}" ] || die "need --modulefile or --module-root"

run(){ if [ "${DRYRUN}" = 1 ]; then echo "  [dry-run] $*"; else eval "$*"; fi; }

# basename version is 10.x? (accepts 10.x.lua or extensionless 10.x)
is_10x(){ case "$(basename "$1")" in 10.*) return 0;; *) return 1;; esac; }

# ---- install the shim (idempotent) --------------------------------------
echo "== installing serializer shim =="
if [ "${DRYRUN}" = 1 ]; then
    echo "  [dry-run] ${SUDO} install -D -m 0755 '${SHIM_SRC}' '${GUARD_DIR}/rocprofv3'"
else
    ${SUDO} install -D -m 0755 "${SHIM_SRC}" "${GUARD_DIR}/rocprofv3" \
        || die "failed to install shim into ${GUARD_DIR}"
fi
echo "  -> ${GUARD_DIR}/rocprofv3"

# ---- collect target modulefiles -----------------------------------------
targets=()
if [ -n "${MODULEFILE}" ]; then
    targets=("${MODULEFILE}")
else
    shopt -s nullglob
    # One glob (Lmod .lua and extensionless Cray modulefiles both start "10.");
    # explicitly skip our own backups and editor/tmp leftovers so re-runs never
    # re-guard a *.bak-guard-* copy.
    for f in "${MODULE_ROOT}"/10.*; do
        [ -f "$f" ] || continue
        case "$f" in *.bak*|*~|*.orig|*.swp|*.tmp|*.rpmsave) continue;; esac
        targets+=("$f")
    done
    shopt -u nullglob
fi
[ "${#targets[@]}" -gt 0 ] || { echo "== no 10.x modulefiles to guard =="; exit 0; }

guarded=0; skipped=0; ignored=0
for f in "${targets[@]}"; do
    b="$(basename "$f")"
    if ! is_10x "$f"; then echo "  ignore (not 10.x): ${b}"; ignored=$((ignored+1)); continue; fi
    if ! ${SUDO} test -f "$f"; then echo "  ignore (missing): ${b}"; ignored=$((ignored+1)); continue; fi
    if ${SUDO} grep -q "${MARK}" "$f" 2>/dev/null; then echo "  skip (already guarded): ${b}"; skipped=$((skipped+1)); continue; fi

    if [ "${DRYRUN}" = 1 ]; then
        echo "  [dry-run] would back up ${f} -> ${f}.bak-guard-${STAMP} and append guard block"
        guarded=$((guarded+1)); continue
    fi

    ${SUDO} cp -a "$f" "$f.bak-guard-${STAMP}" || die "backup failed for ${f}"
    block="$(cat <<EOF

-- ${MARK} (added ${STAMP}): serialize concurrent rocprofv3 profiling on MI300A
-- under ROCm 10.x (confirmed node-crash regression: per-kernel-dispatch GPU-queue
-- interception run concurrently across the node's GPUs triggers a fatal
-- uncorrected-cache MCA that hard-resets the node). The shim below queues
-- concurrent profiling to one session/node via flock; single-session profiling
-- (roofline/counters/traces) is unaffected. Evidence/reproducer: /shared/rocm-sweep .
-- Revert: delete this block (or restore ${f}.bak-guard-*), then rm -rf $(dirname "${GUARD_DIR}").
prepend_path("PATH", "${GUARD_DIR}")
EOF
)"
    printf '%s\n' "${block}" | ${SUDO} tee -a "$f" >/dev/null || die "append failed for ${f}"
    echo "  guarded: ${b}"
    guarded=$((guarded+1))
done

echo "== done: guarded ${guarded}, already-guarded ${skipped}, ignored ${ignored} =="
