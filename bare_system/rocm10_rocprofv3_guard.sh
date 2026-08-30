#!/bin/bash
# ---------------------------------------------------------------------------
# rocm10_rocprofv3_guard.sh - install the ROCm-10.x profiling guard and wire it
# into one or more ROCm 10.x Lmod modulefiles (idempotent).
#
# LAYER 2 (2026-08-30): this now installs a rocprofiler-sdk TOOL interposer
# (librocprof_guard.so), NOT the old rocprofv3 PATH shim. Every modern profiler
# front-end -- rocprofv3, rocprof-sys (formerly omnitrace), rocprof-compute, and
# the PyTorch/roctracer path -- initializes through rocprofiler-sdk, so a single
# tool at that layer covers them all; there is no rocprofv2/rocprof to wrap. The
# tool is injected via ROCP_TOOL_LIBRARIES and, on MI300A only:
#   * STRIPS the PC-sampling/SPM/ATT *beta* HW modes (these hard-reset the node
#     even single-session, and even on ROCm 7.x) -- the modulefile also unsets
#     their env as the primary block;
#   * SERIALIZES concurrent profiling *sessions* node-wide via a flock, with
#     per-SLURM_JOB leader election so MPI ranks never deadlock and an
#     ancestor-guard check so it never re-locks under a parent guard;
#   * MARKS the run guarded (holds the node-lock fd + ROCPROFV3_GUARDED=1) for
#     the rocprof-watch detector.
# It STANDS DOWN for non-profiling GPU apps (rocprofiler-sdk core is initialized
# for every HIP app on 10.x), so ordinary GPU work is unaffected. This installer
# also REMOVES any legacy Layer-1 ROCM10_ROCPROFV3_GUARD shim block it finds, so
# the two serializers never fight over the same lock.
# Full evidence + reproducer + self-tests: /shared/rocm-sweep/rocm10-guard-layer2 .
#
# Single source of truth used by BOTH:
#   * the nightly build leaf (run_rocm_therock_install.sh) via --modulefile
#   * the manual tree-wide deployer (/shared/rocm-sweep/guard_deploy.sh) via
#       --module-root <dir>
#
# Usage:
#   rocm10_rocprofv3_guard.sh --guard-dir DIR (--modulefile F | --module-root D)
#                             [--src rocprof_guard.c] [--sudo|--no-sudo] [--dry-run]
#
#   --guard-dir DIR    the opt/rocm10-guard/BIN dir (kept for CLI compat); the
#                      .so is installed next to it in ../lib/librocprof_guard.so
#   --modulefile F     migrate exactly this one modulefile (must be a 10.x file)
#   --module-root D    migrate every D/10.* modulefile
#   --src PATH         interposer C source (default: rocm10-guard-layer2/rocprof_guard.c)
#   --shim-src PATH    accepted but IGNORED (the Layer-1 shim is retired)
#   --sudo/--no-sudo   run privileged ops via sudo (default: auto)
#   --dry-run          print what would happen; change nothing
# ---------------------------------------------------------------------------
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MARK="ROCM10_GUARD_LAYER2"
L1MARK="ROCM10_ROCPROFV3_GUARD"
STAMP="$(date +%Y%m%d-%H%M%S)"

GUARD_DIR=""
MODULEFILE=""
MODULE_ROOT=""
SRC="${SELF_DIR}/rocm10-guard-layer2/rocprof_guard.c"
DRYRUN=0
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

die(){ echo "rocm10-guard: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --guard-dir)   GUARD_DIR="${2:?}"; shift 2;;
        --modulefile)  MODULEFILE="${2:?}"; shift 2;;
        --module-root) MODULE_ROOT="${2:?}"; shift 2;;
        --src)         SRC="${2:?}"; shift 2;;
        --shim-src)    shift 2;;                 # retired; ignore for back-compat
        --sudo)        SUDO="sudo"; shift;;
        --no-sudo)     SUDO=""; shift;;
        --dry-run)     DRYRUN=1; shift;;
        -h|--help)     sed -n '2,44p' "${BASH_SOURCE[0]}"; exit 0;;
        *)             die "unknown arg: $1";;
    esac
done

[ -n "${GUARD_DIR}" ] || die "missing --guard-dir"
[ -f "${SRC}" ]       || die "interposer source not found: ${SRC}"
if [ -n "${MODULEFILE}" ] && [ -n "${MODULE_ROOT}" ]; then
    die "use --modulefile OR --module-root, not both"
fi
[ -n "${MODULEFILE}${MODULE_ROOT}" ] || die "need --modulefile or --module-root"

LIBDIR="$(dirname "${GUARD_DIR}")/lib"
SO="${LIBDIR}/librocprof_guard.so"

# ---- build + install the interposer (pure libc; ROCm-version independent) ----
echo "== building + installing Layer-2 interposer =="
if [ "${DRYRUN}" = 1 ]; then
    echo "  [dry-run] gcc -shared '${SRC}' -> '${SO}'"
else
    tmpso="$(mktemp --suffix=.so)" || die "mktemp failed"
    gcc -O2 -Wall -fPIC -shared -Wl,-soname,librocprof_guard.so -o "${tmpso}" "${SRC}" \
        || die "compile failed for ${SRC}"
    nm -D --defined-only "${tmpso}" | grep -qw rocprofiler_configure \
        || die "built .so is missing the rocprofiler_configure entry point"
    ${SUDO} install -D -m 0755 "${tmpso}" "${SO}" || die "failed to install ${SO}"
    rm -f "${tmpso}"
fi
echo "  -> ${SO}"

# ---- collect target modulefiles -----------------------------------------
targets=()
if [ -n "${MODULEFILE}" ]; then
    targets=("${MODULEFILE}")
else
    shopt -s nullglob
    for f in "${MODULE_ROOT}"/10.*; do
        [ -f "$f" ] || continue
        case "$f" in *.bak*|*~|*.orig|*.swp|*.tmp|*.rpmsave) continue;; esac
        targets+=("$f")
    done
    shopt -u nullglob
fi
[ "${#targets[@]}" -gt 0 ] || { echo "== no 10.x modulefiles to guard =="; exit 0; }

is_10x(){ case "$(basename "$1")" in 10.*) return 0;; *) return 1;; esac; }

# strip a legacy Layer-1 shim block from a file (root-owned; run under sudo)
strip_l1(){
    ${SUDO} python3 - "$1" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
pat = re.compile(r'\n?-- ROCM10_ROCPROFV3_GUARD .*?prepend_path\("PATH",\s*"[^"]*rocm10-guard/bin"\)\n?', re.S)
open(p, 'w').write(pat.sub('\n', s))
PY
}

migrated=0; skipped=0; ignored=0
for f in "${targets[@]}"; do
    b="$(basename "$f")"
    if ! is_10x "$f"; then echo "  ignore (not 10.x): ${b}"; ignored=$((ignored+1)); continue; fi
    if ! ${SUDO} test -f "$f"; then echo "  ignore (missing): ${b}"; ignored=$((ignored+1)); continue; fi

    has_l1=0; has_l2=0
    ${SUDO} grep -q "${L1MARK}" "$f" 2>/dev/null && has_l1=1
    ${SUDO} grep -q "${MARK}"   "$f" 2>/dev/null && has_l2=1
    if [ $has_l1 -eq 0 ] && [ $has_l2 -eq 1 ]; then
        echo "  skip (already migrated): ${b}"; skipped=$((skipped+1)); continue
    fi

    if [ "${DRYRUN}" = 1 ]; then
        echo "  [dry-run] would back up ${b}, strip L1=${has_l1}, append L2=$((1-has_l2))"
        migrated=$((migrated+1)); continue
    fi

    ${SUDO} cp -a "$f" "$f.bak-l2guard-${STAMP}" || die "backup failed for ${f}"
    [ $has_l1 -eq 1 ] && { strip_l1 "$f"; echo "  - removed legacy Layer-1 shim: ${b}"; }
    if [ $has_l2 -eq 0 ]; then
        ${SUDO} tee -a "$f" >/dev/null <<EOF

-- ${MARK} (added ${STAMP}): rocprofiler-sdk tool interposer -- the single durable
-- guard for MI300A profiling. Every modern front-end (rocprofv3, rocprof-sys,
-- rocprof-compute, PyTorch/roctracer) initializes through rocprofiler-sdk, so this
-- one tool covers them all; there is no rocprofv2/rocprof to wrap. On MI300A it
-- (a) STRIPS the PC-sampling/SPM/ATT beta HW modes that hard-reset the node even
-- single-session, and (b) SERIALIZES concurrent profiling sessions node-wide
-- (per-SLURM_JOB leader election; inherits an ancestor guard instead of re-locking).
-- It STANDS DOWN for non-profiling GPU apps. Src/tests: /shared/rocm-sweep/rocm10-guard-layer2 .
-- Revert: restore ${f}.bak-l2guard-${STAMP}.
prepend_path("ROCP_TOOL_LIBRARIES", "${SO}", ":")
unsetenv("ROCPROFILER_PC_SAMPLING_BETA_ENABLED")
unsetenv("ROCPROFILER_SPM_BETA_ENABLED")
unsetenv("ROCPROF_ATT_LIBRARY_PATH")
EOF
        echo "  + wired Layer-2: ${b}"
    fi
    migrated=$((migrated+1))
done

echo "== done: migrated ${migrated}, already-migrated ${skipped}, ignored ${ignored} =="
