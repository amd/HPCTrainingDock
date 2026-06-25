#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# ── Preflight: declare and load required Lmod modules ─────────────────
# Inlined (formerly bare_system/lib/preflight.sh) so this script is
# self-contained and can be copied/run standalone. preflight_modules
# loads each module in order; on the first failure it prints the Lmod
# diagnostic and returns MISSING_PREREQ_RC=42, which the parent
# main_setup.sh re-classifies as SKIPPED rather than FAILED.
MISSING_PREREQ_RC=42
if ! type module >/dev/null 2>&1; then
   [ -r /etc/profile.d/lmod.sh ]            && . /etc/profile.d/lmod.sh
   [ -r /usr/share/lmod/lmod/init/bash ]    && . /usr/share/lmod/lmod/init/bash
fi
preflight_modules() {
   [ "$#" -eq 0 ] && return 0
   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command not available; needed:$(printf ' %s' "$@")" >&2
      return ${MISSING_PREREQ_RC}
   fi
   echo "preflight: required modules:$(printf ' %s' "$@")"
   local m err
   err=$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)
   for m in "$@"; do
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         [ -s "${err}" ] && sed 's/^/  module> /' "${err}" >&2
         rm -f "${err}"
         return ${MISSING_PREREQ_RC}
      fi
   done
   rm -f "${err}"
   echo "preflight: all required modules loaded."
}

# Variables controlling setup process
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
BUILD_MAGMA=0
ROCM_VERSION=6.2.0
# MAGMA_VERSION holds the BARE numeric version (no leading 'v'); the
# script prepends 'v' where the upstream needs it (git tag) and uses
# the bare form everywhere else (install dir 'magma-v${VERSION}',
# modulefile '${VERSION}.lua') so we match the fftw / hdf5 / petsc
# convention. Old default was 'v2.10.0' which produced 'magma-vv2.10.0'
# and 'v2.10.0.lua' (job 8065 audit). User input is normalized below
# (strip optional leading 'v') so '--magma-version v2.10.0' still works.
MAGMA_VERSION=2.10.0
OPENBLAS_VERSION=0.3.33

# --install-path and --module-path are now both BASE directories. The
# script appends /magma-v${MAGMA_VERSION} and /openblas-v${OPENBLAS_VERSION}
# to the install base, and /magma + /openblas (unversioned dirs holding
# <version>.lua files) to the module base. Multiple magma releases
# coexist as siblings; same for openblas.
INSTALL_PATH_BASE=/opt/rocmplus-${ROCM_VERSION}
MODULE_PATH_BASE=/etc/lmod/modules/ROCmPlus
MAGMA_PATH_INPUT=""
MODULE_PATH_INPUT=""
OPENBLAS_PATH=""
# magma is multi-component (magma + optionally openblas built by the
# same script). Like openmpi_setup.sh's --replace-xpmem/--replace-ucx
# split we expose one knob per top-level install dir:
#   --replace-magma     removes <base>/magma + ${MAGMA_VERSION}.lua
#   --replace-openblas  removes <base>/openblas + ${OPENBLAS_VERSION}.lua
#                       (only meaningful if openblas would actually be
#                        rebuilt -- has no effect when the system
#                        libopenblas-dev path is taken)
# --replace is a convenience alias that flips both on and is what
# main_setup.sh threads through from --replace-existing.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
REPLACE_MAGMA=0
REPLACE_OPENBLAS=0
KEEP_FAILED_INSTALLS=0
# Tracks whether we actually built openblas in this run, so the EXIT
# trap doesn't blow away a system openblas-dev install we never touched.
_OPENBLAS_BUILT=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is autodetected"
   echo "  --build-magma [ BUILD_MAGMA ], set to 1 to build Magma, default is $BUILD_MAGMA"
   echo "  --magma-version [ MAGMA_VERSION ] default $MAGMA_VERSION"
   echo "  --openblas-version [ OPENBLAS_VERSION ] default $OPENBLAS_VERSION"
   echo "  --openblas-path [ OPENBLAS_PATH ] path to existing OpenBLAS installation, autodetected if not specified"
   echo "  --accept-system-openblas [ 0|1 ] accept system OpenBLAS at any version (skip OPENBLAS_VERSION check); default ${OPENBLAS_ACCEPT_SYSTEM:-0}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --module-path [ MODULE_PATH_BASE ] BASE dir; magma module goes in <base>/magma, openblas module (when built) in <base>/openblas; default $MODULE_PATH_BASE"
   echo "  --install-path [ INSTALL_PATH_BASE ] BASE dir; magma installs to <base>/magma-v\${MAGMA_VERSION}, openblas (when built) to <base>/openblas-v\${OPENBLAS_VERSION}; default $INSTALL_PATH_BASE"
   echo "  --replace [ 0|1 ] convenience: same as --replace-magma 1 --replace-openblas 1, default $REPLACE"
   echo "  --replace-magma [ 0|1 ] remove prior magma install + modulefile before building, default $REPLACE_MAGMA"
   echo "  --replace-openblas [ 0|1 ] remove prior built-from-source openblas install + modulefile before building, default $REPLACE_OPENBLAS"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: this usage information"
   exit 1
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--build-magma")
          shift
          BUILD_MAGMA=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--magma-version")
          shift
          # Strip optional leading 'v' so callers that pass either
          # 'v2.10.0' (old main_setup.sh default) or '2.10.0' both
          # land in the same canonical form. See MAGMA_VERSION
          # comment near the top of this file.
          MAGMA_VERSION=${1#v}
          reset-last
          ;;
      "--openblas-version")
          shift
          OPENBLAS_VERSION=${1}
          reset-last
          ;;
      "--openblas-path")
          shift
          OPENBLAS_PATH=${1}
          reset-last
          ;;
      "--accept-system-openblas")
          # Accepts an explicit value (0|1); also tolerates the bareword
          # form `--accept-system-openblas` (no value) as a synonym for 1.
          # Whatever the form, the result lands in the env var
          # OPENBLAS_ACCEPT_SYSTEM that the detection block below reads.
          if [[ $# -ge 2 && "${2}" =~ ^[01]$ ]]; then
             shift
             OPENBLAS_ACCEPT_SYSTEM=${1}
          else
             OPENBLAS_ACCEPT_SYSTEM=1
          fi
          export OPENBLAS_ACCEPT_SYSTEM
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          MAGMA_PATH_INPUT=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--replace-magma")
          shift
          REPLACE_MAGMA=${1}
          reset-last
          ;;
      "--replace-openblas")
          shift
          REPLACE_OPENBLAS=${1}
          reset-last
          ;;
      "--keep-failed-installs")
          shift
          KEEP_FAILED_INSTALLS=${1}
          reset-last
          ;;
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

# Resolve install / module BASE dirs.
#
# Both --install-path and --module-path are now base directories; we
# append /magma-v${MAGMA_VERSION} and /openblas-v${OPENBLAS_VERSION}
# to the install base, and /magma + /openblas to the module base.
# Default INSTALL_PATH_BASE off ROCM_VERSION (which may have come in
# via --rocm-version). Back-compat: if the operator passed a legacy
# leaf path that already ends in /magma or /magma-v..., strip it so
# the version-suffixed dir doesn't get appended twice.
if [ -n "${MAGMA_PATH_INPUT}" ]; then
   INSTALL_PATH_BASE="${MAGMA_PATH_INPUT%/}"
   INSTALL_PATH_BASE="${INSTALL_PATH_BASE%/magma}"
   INSTALL_PATH_BASE="${INSTALL_PATH_BASE%/magma-v${MAGMA_VERSION}}"
else
   INSTALL_PATH_BASE=/opt/rocmplus-${ROCM_VERSION}
fi
if [ -n "${MODULE_PATH_INPUT}" ]; then
   MODULE_PATH_BASE="${MODULE_PATH_INPUT%/}"
   MODULE_PATH_BASE="${MODULE_PATH_BASE%/magma}"
fi

MAGMA_PATH="${INSTALL_PATH_BASE}/magma-v${MAGMA_VERSION}"
MAGMA_MODULE_DIR="${MODULE_PATH_BASE}/magma"
# OpenBLAS sibling paths (used by --replace-openblas and the EXIT trap;
# only ACTUALLY removed if openblas is in scope, see _OPENBLAS_BUILT below).
_MAGMA_OPENBLAS_INSTALL_DIR="${INSTALL_PATH_BASE}/openblas-v${OPENBLAS_VERSION}"
_MAGMA_OPENBLAS_MODULE_DIR="${MODULE_PATH_BASE}/openblas"

# ── BUILD_MAGMA=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_MAGMA}" = "0" ]; then
   echo "[magma BUILD_MAGMA=0] operator opt-out; skipping (no magma build, no openblas build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── Install-path sudo (computed EARLY, before afar-skip/--replace) ────
# These blocks rm -rf the install dir + modulefiles with ${SUDO}. The
# leaf default is SUDO=sudo, which on a cluster with no passwordless sudo
# and a user-owned install tree (this Cray) makes --replace / afar-skip
# die on a password prompt before the build even starts. Probe the
# nearest existing ancestor of the install BASE for user-writability and
# drop sudo when we own it. Mirrors the petsc/rocshmem writability probe.
# The same SUDO then governs the openblas + magma install dirs + chowns
# in the build branch below. EUID 0 never needs sudo.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :  # already cleared (e.g. Singularity)
else
   _iprobe="${INSTALL_PATH_BASE}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .magma-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "magma: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "magma: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── afar SDK incompatibility detection ───────────────────────────────
# AMD's pre-release "AFAR" ROCm drops (rocm-afar-22.x, rocm-afar-7.0.5)
# are runtime-only / partial SDKs. Verified empirically on this cluster
# (audit_2026_05_06, job 8490, log_magma_05_06_2026.txt:14192):
#
#   afar-22.1.0  $ find <ROCM_PATH> -name 'hipblas-config.cmake'
#                -> 0 matches  (and 0 for rocblas, rocthrust, miopen, ...)
#   afar-22.2.0  $ same probe -> 1 match (cmake configs present)
#   rocm-7.2.1   $ same probe -> 1 match
#
# magma's CMakeLists.txt:473 calls target_link_libraries(magma roc::hipblas);
# without hipblas-config.cmake the imported target is never registered
# and CMake fails with "Target ... links to: roc::hipblas but the target
# was not found." Skipping here turns 8490-style FAILED magma(rc=1) into
# the correct SKIPPED(no-op) bucket on afar-22.1.0 (afar-22.2.0 ships
# the cmake configs; the probe correctly lets that case through).
#
# Probe shape: gated on `${ROCM_PATH}` matching `*afar*` AND no
# hipblas-config.cmake present. Self-corrects if AMD ships the cmake
# metadata in a future afar drop (matches the rocm-bundled hipfort
# policy in extras/scripts/hipfort_setup.sh).
if [[ "${ROCM_PATH:-}" == *afar* ]]; then
   if [[ -z "${ROCM_PATH:-}" ]] && type module >/dev/null 2>&1; then
      module load "rocm/${ROCM_VERSION}" 2>/dev/null || true
   fi
   if [ ! -f "${ROCM_PATH}/lib/cmake/hipblas/hipblas-config.cmake" ]; then
      echo ""
      echo "[magma afar-skip] ROCM_PATH=${ROCM_PATH} is an AMD AFAR partial SDK"
      echo "                  missing : <ROCM_PATH>/lib/cmake/hipblas/hipblas-config.cmake"
      echo "                  magma requires roc::hipblas imported target; cannot build on afar SDK."
      echo "                  Skipping (no magma build, no openblas build, no cache restore)."
      echo ""
      if [ -d "${MAGMA_PATH}" ]; then
         echo "[magma afar-skip] removing stale from-source install: ${MAGMA_PATH}"
         ${SUDO} rm -rf "${MAGMA_PATH}"
      fi
      if [ -f "${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua" ]; then
         echo "[magma afar-skip] removing stale modulefile: ${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua"
         ${SUDO} rm -f "${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua"
      fi
      # ── Drop a SKIPPED marker so the inventory tool can distinguish ──
      # "skipped on this SDK" from "absent / failed". See
      # bare_system/inventory_packages.py ('N' symbol -- Not possible to build on this SDK).
      _SKIP_MARKER_DIR="$(dirname "${MAGMA_PATH}")"
      ${SUDO} mkdir -p "${_SKIP_MARKER_DIR}" 2>/dev/null || true
      if [ -d "${_SKIP_MARKER_DIR}" ]; then
         ${SUDO} tee "${_SKIP_MARKER_DIR}/magma.SKIPPED" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: magma
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    magma_setup.sh (afar-skip guard)
Reason:          AFAR SDK is missing
                 <ROCM_PATH>/lib/cmake/hipblas/hipblas-config.cmake.
                 magma's CMake requires the roc::hipblas imported target;
                 cannot build on this SDK.
                 Self-corrects on the next sweep if AMD ships a more
                 complete AFAR drop.
MARKER_EOF
      fi
      unset _SKIP_MARKER_DIR
      exit ${NOOP_RC}
   fi
fi

# ── --replace: remove prior installs + modulefiles BEFORE building ───
if [ "${REPLACE}" = "1" ]; then
   REPLACE_MAGMA=1
   REPLACE_OPENBLAS=1
fi
if [ "${REPLACE_MAGMA}" = "1" ]; then
   echo "[magma --replace-magma 1] removing prior magma install + modulefile if present"
   echo "  install dir: ${MAGMA_PATH}"
   echo "  modulefile:  ${MAGMA_MODULE_DIR}/${MAGMA_VERSION}{.lua,} (both flavors)"
   ${SUDO} rm -rf "${MAGMA_PATH}"
   ${SUDO} rm -f  "${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua" "${MAGMA_MODULE_DIR}/${MAGMA_VERSION}"
fi
if [ "${REPLACE_OPENBLAS}" = "1" ]; then
   # Best-effort: removes any openblas install that previously lived in
   # the magma sibling slot. If the system libopenblas-dev path is taken
   # below, we won't rebuild it -- the directory just stays gone, which
   # is fine (no module pointing at it).
   echo "[magma --replace-openblas 1] removing prior built-from-source openblas install + modulefile if present"
   echo "  install dir: ${_MAGMA_OPENBLAS_INSTALL_DIR}"
   echo "  modulefile:  ${_MAGMA_OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}{.lua,} (both flavors)"
   ${SUDO} rm -rf "${_MAGMA_OPENBLAS_INSTALL_DIR}"
   ${SUDO} rm -f  "${_MAGMA_OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}.lua" "${_MAGMA_OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Multi-component: only the magma half is checked here. OpenBLAS may
# come from EITHER the system package (libopenblas-dev) OR the sibling
# install at ${_MAGMA_OPENBLAS_INSTALL_DIR}; the script decides which
# later, after evaluating the system OpenBLAS version. Mirroring the
# decision here would duplicate that logic, so we just match what
# main_setup.sh's `[[ ! -d magma-v${MAGMA_VERSION} ]]` guard did.
# Implication: if magma is on disk but the sibling openblas was wiped
# (and no system openblas), the magma modulefile's `prereq openblas/...`
# will fail at module-load time -- pass --replace-magma 1 (or --replace 1)
# to force a clean reinstall in that situation.
NOOP_RC=43
if [ -d "${MAGMA_PATH}" ]; then
   echo ""
   echo "[magma existence-check] ${MAGMA_PATH} already installed; skipping."
   echo "                        pass --replace 1 (or --replace-magma 1) to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of magma + (optionally) openblas ─────────
# Always cleans the magma install on failure. OpenBLAS is only cleaned
# if this run actually rebuilt it (_OPENBLAS_BUILT=1, set by the
# build-openblas branch below) so we never blow away a system or
# pre-existing openblas we just *consumed*. Replaces main_setup.sh
# PKG_CLEAN_*[magma]/[openblas].
_magma_on_exit() {
   local rc=$?
   # Build-dir cleanup. MAGMA_BUILD_ROOT is a per-job mktemp dir owned by
   # the build user, so plain rm (never sudo) always works -- and avoids a
   # spurious sudo password prompt at end-of-run when SUDO was probed empty
   # (a user-writable install tree on a no-passwordless-sudo Cray).
   [ -n "${MAGMA_BUILD_ROOT:-}" ] && rm -rf "${MAGMA_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[magma fail-cleanup] rc=${rc}: removing partial magma install + modulefile"
      ${SUDO} rm -rf "${MAGMA_PATH}"
      ${SUDO} rm -f  "${MAGMA_MODULE_DIR}/${MAGMA_VERSION}.lua" "${MAGMA_MODULE_DIR}/${MAGMA_VERSION}"
      if [ "${_OPENBLAS_BUILT}" = "1" ]; then
         echo "[magma fail-cleanup] also removing partial openblas install + modulefile (this run built it)"
         ${SUDO} rm -rf "${_MAGMA_OPENBLAS_INSTALL_DIR}"
         ${SUDO} rm -f  "${_MAGMA_OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}.lua" "${_MAGMA_OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}"
      fi
   elif [ ${rc} -ne 0 ]; then
      echo "[magma fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _magma_on_exit EXIT

echo ""
echo "==================================="
echo "Starting Magma Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_MAGMA: $BUILD_MAGMA"
echo "MAGMA_VERSION: $MAGMA_VERSION"
echo "OPENBLAS_VERSION: $OPENBLAS_VERSION"
echo "OPENBLAS_ACCEPT_SYSTEM: ${OPENBLAS_ACCEPT_SYSTEM:-0}"
echo "INSTALL_PATH_BASE: $INSTALL_PATH_BASE"
echo "MODULE_PATH_BASE: $MODULE_PATH_BASE"
echo "MAGMA_PATH: $MAGMA_PATH"
echo "MAGMA_MODULE_DIR: $MAGMA_MODULE_DIR"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

if [ "${BUILD_MAGMA}" = "0" ]; then

   echo "Magma will not be built, according to the specified value of BUILD_MAGMA"
   echo "BUILD_MAGMA: $BUILD_MAGMA"
   exit

else

   # Derive the rocm modulefile token to (re-)load. Three sources, in
   # decreasing order of authority:
   #   1. LMOD's LOADEDMODULES: the literal modulefile name currently
   #      loaded (e.g. rocm/therock-afar-23.2.1). Only source that
   #      handles the therock-afar dual scheme where install dir is
   #      rocm-therock-afar-<NUMERIC> but the module is keyed on the
   #      release tag (rocm/therock-afar-<RELEASE>).
   #   2. ROCM_PATH basename: install-dir basename minus the `rocm-`
   #      prefix. Correct for regular releases + afar (install-dir
   #      basename == module name) but wrong for therock-afar.
   #   3. rocm/${ROCM_VERSION}: standalone-invocation fallback when
   #      neither LOADEDMODULES nor ROCM_PATH is populated.
   # Two-pass over LOADEDMODULES: prefer a rocm/* matching the requested
   # ROCM_VERSION before falling back to the first rocm/*. A Cray
   # PrgEnv-amd-new shell can have several rocm/* loaded at once (e.g.
   # rocm/7.0.3 AND rocm/7.2.3 alongside the PrgEnv's rocm-new/7.2.3);
   # taking the first match would key the build + modulefile on the wrong SDK.
   ROCM_MODULE_NAME=""
   if [[ -n "${LOADEDMODULES:-}" ]]; then
      _OLD_IFS="${IFS}"; IFS=":"
      for _m in ${LOADEDMODULES}; do
         case "${_m}" in
            rocm/${ROCM_VERSION}) ROCM_MODULE_NAME="${_m}"; break ;;
         esac
      done
      if [[ -z "${ROCM_MODULE_NAME}" ]]; then
         for _m in ${LOADEDMODULES}; do
            case "${_m}" in
               rocm/*) ROCM_MODULE_NAME="${_m}"; break ;;
            esac
         done
      fi
      IFS="${_OLD_IFS}"; unset _OLD_IFS _m
   fi
   if [[ -z "${ROCM_MODULE_NAME}" ]]; then
      if [[ -n "${ROCM_PATH:-}" ]]; then
         _rp_bn="${ROCM_PATH##*/}"
         ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
         unset _rp_bn
      else
         ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
      fi
   fi

   # Provenance: capture this leaf script's git state for the modulefile
   # whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured
   # at the top of this script before any cd) so this works even after
   # the script has cd'd into a temp build dir. Self-contained: falls
   # back to "unknown" when run from a stripped-of-.git context (Docker
   # layer, release tarball, or git binary missing).
   LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
   LEAF_SCRIPT_COMMIT=unknown
   LEAF_SCRIPT_DIRTY=unknown
   _leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
   if [ -d "${_leaf_dir}" ] && command -v git >/dev/null 2>&1 \
      && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
      [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
      unset _commit
      if [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
         LEAF_SCRIPT_DIRTY=dirty
      else
         LEAF_SCRIPT_DIRTY=clean
      fi
   fi
   unset _leaf_dir

   # (Install-path SUDO was probed early, before the afar-skip/--replace
   # blocks; it governs the openblas + magma install dirs and chowns.)

   REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" )
   preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

   # amdclang compiler module (hierarchical; only visible after rocm).
   # Some ROCm packagings ship LLVM/clang as a SEPARATE module instead of
   # bundling it under ${ROCM_PATH}/lib/llvm, in which case hipcc cannot
   # find clang++/amdclang++ until amdclang is loaded. On a Cray
   # PrgEnv-amd-new there is no amdclang module (rocm provides hipcc's
   # toolchain directly), so probe + load it only when present rather than
   # hard-requiring it (which would wrongly SKIP magma here). Mirrors
   # rocshmem_setup.sh.
   if module --redirect -t avail amdclang 2>/dev/null | grep -qi '^amdclang'; then
      echo "preflight: amdclang module present -> loading it for the hipcc toolchain"
      if ! module load amdclang 2>&1; then
         echo "ERROR: amdclang module is available but failed to load." >&2
         exit ${MISSING_PREREQ_RC}
      fi
   else
      echo "preflight: no amdclang module visible; assuming rocm provides hipcc's clang toolchain"
   fi

   # ── Modulefile flavor + module-write sudo (shared by openblas+magma) ──
   # Flavor: Lmod consumes <ver>.lua; classic Tcl Environment Modules
   # consumes an extensionless Tcl file. Detect Lmod via its env markers;
   # default to Tcl when Lmod is absent (this Cray runs Tcl Environment
   # Modules). Without this the .lua files are invisible to a Tcl `module`
   # and `module load magma/...` fails. Mirrors hdf5/netcdf/fftw/petsc.
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      MODFLAVOR="lua"; MODEXT=".lua"
   else
      MODFLAVOR="tcl"; MODEXT=""
   fi
   # MOD_SUDO: probe the module tree for user-writability so a user-owned
   # module tree (a Cray $HOME deployment or a standalone run) needs no
   # sudo, and forcing it would hit a password prompt that fails where the
   # user has no sudo. Mirrors petsc/netcdf_setup.sh. Used for BOTH the
   # openblas and magma modulefile writes below.
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      MOD_SUDO=""
   else
      _mprobe="${MODULE_PATH_BASE}"
      while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
      _mtest=$(mktemp --tmpdir="${_mprobe}" .magma-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         MOD_SUDO=""
         echo "magma: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         MOD_SUDO="sudo"
         echo "magma: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
      fi
      unset _mprobe _mtest
   fi

   ## OpenBLAS resolution.
   ##
   ## Build OpenBLAS from source as the default path. Only TWO override
   ## cases skip the build:
   ##
   ##   (A) --openblas-path PATH or --accept-system-openblas:
   ##       operator-explicit opt-in to use an existing copy.
   ##
   ##   (B) The system libopenblas-dev version exactly matches the
   ##       requested OPENBLAS_VERSION (deterministic match -- otherwise
   ##       our pinned version would silently degrade to whatever the
   ##       distro shipped, which is the bug audited in
   ##       logs_05_02_2026/rocm-7.2.1_8016/log_magma_05_02_2026.txt:7).
   ##
   ## When we build OpenBLAS we install it at INSTALL_PATH_BASE/openblas
   ## (sibling of magma) and create a standalone openblas modulefile.
   ## The magma modulefile then `load("openblas")` so the OPENBLAS_*
   ## env vars come from a single source of truth. When we reuse a
   ## system or operator-supplied OpenBLAS we inline the env vars in
   ## the magma modulefile because no openblas module exists.
   OPENBLAS_BUILD=1

   # _probe_system_openblas_version: print the system libopenblas-dev
   # patch-level version (e.g. "0.3.20"), or empty on failure.
   # Prefers dpkg-query on Debian/Ubuntu (deterministic); falls back to
   # parsing the SOVERSION of the resolved /usr/lib*/libopenblas.so for
   # RHEL-family hosts.
   _probe_system_openblas_version() {
      local v
      v=$(dpkg-query -W -f='${Version}' libopenblas-dev 2>/dev/null \
            | sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
      if [ -n "${v}" ]; then echo "${v}"; return; fi
      local libdir
      for libdir in /usr/lib64 /usr/lib /usr/lib/x86_64-linux-gnu /usr/local/lib /usr/local/lib64; do
         if [ -f "${libdir}/libopenblas.so" ]; then
            basename "$(readlink -f "${libdir}/libopenblas.so")" \
               | sed -nE 's/.*r?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'
            return
         fi
      done
   }

   # _find_system_openblas_root: print the install prefix that owns the
   # system libopenblas.so (e.g. "/usr"), or empty if none is found.
   # Defined as the parent of the libdir that contains libopenblas.so.
   _find_system_openblas_root() {
      local libdir
      for libdir in /usr/lib64 /usr/lib /usr/lib/x86_64-linux-gnu /usr/local/lib /usr/local/lib64; do
         if [ -f "${libdir}/libopenblas.so" ]; then
            case "${libdir}" in
               /usr/lib/x86_64-linux-gnu) echo "/usr"; return ;;
               /usr/lib|/usr/lib64)        echo "/usr"; return ;;
               /usr/local/lib|/usr/local/lib64) echo "/usr/local"; return ;;
            esac
         fi
      done
   }

   # ── Override A: operator-explicit opt-in ──
   if [ -n "${OPENBLAS_PATH}" ]; then
      if ls ${OPENBLAS_PATH}/lib/libopenblas.* 1>/dev/null 2>&1; then
         echo "Using OpenBLAS at ${OPENBLAS_PATH} (--openblas-path; no version check)"
         OPENBLAS_BUILD=0
      else
         echo "WARNING: --openblas-path=${OPENBLAS_PATH} contains no libopenblas; falling through to build"
         OPENBLAS_PATH=""
      fi
   elif [ "${OPENBLAS_ACCEPT_SYSTEM:-0}" = "1" ]; then
      sysroot=$(_find_system_openblas_root)
      if [ -n "${sysroot}" ]; then
         OPENBLAS_PATH="${sysroot}"
         OPENBLAS_BUILD=0
         sysver=$(_probe_system_openblas_version)
         echo "Using system OpenBLAS ${sysver:-<unknown>} at ${OPENBLAS_PATH} (--accept-system-openblas; no version check)"
      else
         echo "WARNING: --accept-system-openblas set but no system OpenBLAS found; will build from source"
      fi
   fi

   # ── Override B: system libopenblas-dev exactly matches request ──
   if [ "${OPENBLAS_BUILD}" = "1" ]; then
      sysver=$(_probe_system_openblas_version)
      if [ -n "${sysver}" ] && [ "${sysver}" = "${OPENBLAS_VERSION}" ]; then
         OPENBLAS_PATH=$(_find_system_openblas_root)
         OPENBLAS_BUILD=0
         echo "System libopenblas-dev ${sysver} matches OPENBLAS_VERSION; using ${OPENBLAS_PATH}"
      else
         echo "System libopenblas-dev=${sysver:-<absent>} != requested ${OPENBLAS_VERSION}; will build from source"
      fi
   fi

   if [ "${OPENBLAS_BUILD}" = "1" ]; then
      echo ""
      echo "============================"
      echo " Building OpenBLAS ${OPENBLAS_VERSION}"
      echo "============================"
      echo ""

      # Versioned openblas install dir (sibling of the versioned magma
      # install). Tracked by _MAGMA_OPENBLAS_INSTALL_DIR computed up
      # near the --replace block; recompute literally here to keep the
      # local read self-explanatory.
      OPENBLAS_PATH="${INSTALL_PATH_BASE}/openblas-v${OPENBLAS_VERSION}"
      # Mark openblas as in-scope for fail-cleanup -- the _magma_on_exit
      # trap will rm -rf this path + the matching modulefile if the
      # script exits non-zero, but ONLY because we're about to write to
      # it. A system-libopenblas-dev path leaves _OPENBLAS_BUILT=0 and
      # the trap leaves the system install untouched.
      _OPENBLAS_BUILT=1

      ${SUDO} mkdir -p ${OPENBLAS_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${OPENBLAS_PATH}
      fi

      # Per-job throwaway build dir; replaces a fixed `cd /tmp;
      # rm -rf openblas_build` pattern that would race with -- and
      # clobber -- any other concurrent magma/openblas build on the
      # same node. NOTE: build-dir cleanup is consolidated into the
      # _magma_on_exit trap installed earlier (so the same EXIT
      # handler also fail-cleans the magma + openblas installs).
      MAGMA_BUILD_ROOT=$(mktemp -d -t magma-build.XXXXXX)
      cd "${MAGMA_BUILD_ROOT}"
      mkdir openblas_build && cd openblas_build
      curl -LO https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v${OPENBLAS_VERSION}.tar.gz
      tar xf v${OPENBLAS_VERSION}.tar.gz
      cd OpenBLAS-${OPENBLAS_VERSION}/

      # ── OpenBLAS toolchain: All-GNU (system gcc + gfortran) ───────────
      # OpenBLAS has zero device code (pure CPU BLAS / netlib LAPACK)
      # and ships no Fortran .mod files; consumers (magma's CBLAS
      # interface, PyTorch's BLAS=OpenBLAS extern "C" calls) reach it
      # only through C headers + name-mangled F77 symbols, which gcc
      # and gfortran produce identically to amdclang/amdflang.
      #
      # Why force GCC instead of relying on the amdclang module env:
      #   1. amdflang in ROCm 7.1.1 (and possibly other 7.x versions)
      #      doesn't implement OpenMP-5.0 array sections in `task depend`
      #      clauses, which OpenBLAS-0.3.33's
      #      lapack-netlib/SRC/ssytrd_sb2st.F:492 uses. amdflang aborts
      #      with "LLVM ERROR: aborting" mid-build (slurm 8067, rocm-7.1.1).
      #   2. Mixed OMP runtime: if we keep CC=amdclang but force
      #      FC=gfortran for (1), libopenblas.so links BOTH libomp
      #      (amdclang's OpenMP) and libgomp (gfortran's). Two OpenMP
      #      runtimes inside a single .so is undefined behavior --
      #      crashes at exit, oversubscription, wrong reductions.
      # All-GNU avoids both: gcc + gfortran with -fopenmp both link
      # libgomp, libopenblas.so is internally consistent. The runtime
      # mix in PyTorch processes (libtorch_cpu+libopenblas as libgomp,
      # libtorch_hip+libmagma as libomp) is unchanged from the existing
      # configuration -- this is the upstream-supported deployment.
      GCC_BIN="$(command -v gcc      || echo gcc)"
      GFORTRAN_BIN="$(command -v gfortran || echo gfortran)"
      echo "openblas: forcing CC=${GCC_BIN}, FC=${GFORTRAN_BIN} (All-GNU; see comment block)"
      make -j MAKE_NB_JOBS=0 ARCH=x86_64 TARGET=ZEN USE_LOCKING=1 USE_OPENMP=1 USE_THREAD=1 RANLIB=ranlib CC="${GCC_BIN}" FC="${GFORTRAN_BIN}" libs netlib shared
      make install PREFIX=${OPENBLAS_PATH} MAKE_NB_JOBS=0 ARCH=x86_64 TARGET=ZEN USE_LOCKING=1 USE_OPENMP=1 USE_THREAD=1 RANLIB=ranlib CC="${GCC_BIN}" FC="${GFORTRAN_BIN}"

      # trap handles cleanup of ${MAGMA_BUILD_ROOT}/openblas_build

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${OPENBLAS_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${OPENBLAS_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} chmod go-w ${OPENBLAS_PATH}
      fi

      # Create a standalone openblas modulefile. Lives at the symmetric
      # MODULE_PATH_BASE/openblas dir so users can `module load openblas`
      # directly, and so the magma module (below) can load it to get
      # OPENBLAS_PATH / LD_LIBRARY_PATH from a single source of truth
      # instead of duplicating the env block. We set OPENBLAS_PATH plus
      # the three common aliases (HOME, ROOT, DIR) so downstream CMake
      # consumers (PyTorch's BLAS=OpenBLAS path, future ginkgo,
      # spack-installed packages) all find it under whatever convention
      # they use. Written in the detected flavor (Lua for Lmod, Tcl
      # otherwise) so it actually loads on this Tcl-modules Cray.
      OPENBLAS_MODULE_DIR="${MODULE_PATH_BASE}/openblas"
      ${MOD_SUDO} mkdir -p "${OPENBLAS_MODULE_DIR}"
      if [ "${MODFLAVOR}" = "lua" ]; then
         cat <<-EOF | ${MOD_SUDO} tee "${OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}${MODEXT}"
	whatis("OpenBLAS ${OPENBLAS_VERSION} (built from source as a magma dependency)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	setenv("OPENBLAS_PATH","${OPENBLAS_PATH}")
	setenv("OPENBLAS_HOME","${OPENBLAS_PATH}")
	setenv("OPENBLAS_ROOT","${OPENBLAS_PATH}")
	setenv("OPENBLAS_DIR","${OPENBLAS_PATH}")
	prepend_path("LD_LIBRARY_PATH","${OPENBLAS_PATH}/lib")
	prepend_path("LIBRARY_PATH","${OPENBLAS_PATH}/lib")
	prepend_path("CPATH","${OPENBLAS_PATH}/include")
	prepend_path("PKG_CONFIG_PATH","${OPENBLAS_PATH}/lib/pkgconfig")
	EOF
      else
         cat <<-EOF | ${MOD_SUDO} tee "${OPENBLAS_MODULE_DIR}/${OPENBLAS_VERSION}${MODEXT}"
	#%Module1.0
	module-whatis "OpenBLAS ${OPENBLAS_VERSION} (built from source as a magma dependency)"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"
	setenv OPENBLAS_PATH "${OPENBLAS_PATH}"
	setenv OPENBLAS_HOME "${OPENBLAS_PATH}"
	setenv OPENBLAS_ROOT "${OPENBLAS_PATH}"
	setenv OPENBLAS_DIR "${OPENBLAS_PATH}"
	prepend-path LD_LIBRARY_PATH "${OPENBLAS_PATH}/lib"
	prepend-path LIBRARY_PATH "${OPENBLAS_PATH}/lib"
	prepend-path CPATH "${OPENBLAS_PATH}/include"
	prepend-path PKG_CONFIG_PATH "${OPENBLAS_PATH}/lib/pkgconfig"
	EOF
      fi
   fi

   if [ -n "${OPENBLAS_PATH}" ]; then
      export LD_LIBRARY_PATH=${OPENBLAS_PATH}/lib:${LD_LIBRARY_PATH}
   fi

   echo ""
   echo "============================"
   echo " Building Magma ${MAGMA_VERSION}"
   echo "============================"
   echo ""

   ${SUDO} mkdir -p ${MAGMA_PATH}
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod -R a+w ${MAGMA_PATH}
   fi

   CMAKE_PREFIX_PATHS="${ROCM_PATH}"
   if [ -n "${OPENBLAS_PATH}" ]; then
      CMAKE_PREFIX_PATHS="${OPENBLAS_PATH};${ROCM_PATH}"
   fi

   # MAGMA_BUILD_ROOT was created in the openblas-build branch above
   # when OPENBLAS_BUILD=1; create one now if the openblas branch
   # was skipped (cached or already-installed openblas). The
   # _magma_on_exit trap (installed near the top of the script) handles
   # cleanup either way -- it inspects ${MAGMA_BUILD_ROOT:-} at exit.
   if [ -z "${MAGMA_BUILD_ROOT:-}" ]; then
      MAGMA_BUILD_ROOT=$(mktemp -d -t magma-build.XXXXXX)
   fi
   cd "${MAGMA_BUILD_ROOT}"
   mkdir magma_build && cd magma_build
   # Magma upstream tags are 'v<MAJ>.<MIN>.<MIC>' (e.g. v2.10.0); we
   # store MAGMA_VERSION as the bare numeric form, so prepend 'v' here.
   git clone https://github.com/icl-utk-edu/magma.git -b v${MAGMA_VERSION}
   cd magma
   echo -e "BACKEND = hip\nFORT = true\nGPU_TARGET = ${AMDGPU_GFXMODEL}" > make.inc
   make -f make.gen.hipMAGMA -j
   make generate
   mkdir build && cd build

   # C compiler: force GNU gcc. On a Cray PE the default `cc` is the
   # craype wrapper (clang under the hood); magma's CMake runs
   # FortranCInterface to detect Fortran name mangling and write
   # include/magma_mangling_cmake.h (which defines MAGMA_GLOBAL). That
   # detection links a C object against a gfortran object; with the Cray
   # `cc` wrapper the link test fails, magma_mangling_cmake.h comes out
   # empty, and every magma .cpp then hits the #error "One of ADD_,
   # NOCHANGE, or UPCASE must be defined". Using gcc (matching the
   # All-GNU gfortran already used for the Fortran half) makes the
   # FortranCInterface probe succeed. HIP device .cpp still go through
   # hipcc (CMAKE_CXX_COMPILER).
   GCC_BIN="$(command -v gcc || echo gcc)"
   # GPU arch: magma 2.10.0's own VALID_GFXS list stops at gfx1033 and its
   # add_compile_options(${GPU_ARCH_FLAGS}) line is commented out, so the
   # -DGPU_TARGET path is effectively dead for selecting the offload arch.
   # The real knob is ROCm's hip-config.cmake GPU_TARGETS (plural): when it
   # is unset, hip-config runs amdgpu-arch to autodetect, which FAILS at
   # build time (no GPU visible during the cmake configure step on a
   # login/build node), so NO --offload-arch is emitted and hipcc silently
   # falls back to its built-in default (gfx906). The result is a
   # libmagma.so that cannot run on the target GPU (e.g. gfx942/MI300A).
   # Passing -DGPU_TARGETS makes hip-config attach
   # --offload-arch=${AMDGPU_GFXMODEL} to hip::device, which propagates to
   # the magma target. We keep -DGPU_TARGET too (magma echoes it / uses it
   # in codegen messages).
   cmake \
      -DCMAKE_INSTALL_PREFIX=${MAGMA_PATH} \
      -DCMAKE_BUILD_TYPE=Release \
      -DMAGMA_ENABLE_HIP=ON \
      -DGPU_TARGET="${AMDGPU_GFXMODEL}" \
      -DGPU_TARGETS="${AMDGPU_GFXMODEL}" \
      -DAMDGPU_TARGETS="${AMDGPU_GFXMODEL}" \
      -DCMAKE_HIP_ARCHITECTURES="${AMDGPU_GFXMODEL}" \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_C_COMPILER="${GCC_BIN}" \
      -DCMAKE_CXX_COMPILER=${ROCM_PATH}/bin/hipcc \
      -DCMAKE_Fortran_COMPILER=gfortran \
      -DBLA_VENDOR=OpenBLAS \
      -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATHS}" \
      ..

   make -j
   make install

   # trap handles cleanup of ${MAGMA_BUILD_ROOT}

   export LD_LIBRARY_PATH=${MAGMA_PATH}/lib:${LD_LIBRARY_PATH}

   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find ${MAGMA_PATH} -type f -execdir chown root:root "{}" +
      ${SUDO} find ${MAGMA_PATH} -type d -execdir chown root:root "{}" +
   fi

   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} chmod go-w ${MAGMA_PATH}
   fi

   # Create a module file for magma. Uses MOD_SUDO + MODFLAVOR/MODEXT
   # computed once after preflight (writability-probe sudo; Lua for Lmod,
   # Tcl otherwise).
   ${MOD_SUDO} mkdir -p ${MAGMA_MODULE_DIR}

   # The - option suppresses tabs
   #
   # MAGMA_PATH is the project-internal convention used by the
   # HPCTrainingDock setup scripts. MAGMA_HOME, MAGMA_ROOT, and
   # MAGMA_DIR are aliases for downstream consumers that use
   # different naming conventions:
   #   - MAGMA_HOME : honored by PyTorch's cmake/Modules/FindMAGMA.cmake
   #                  HINTS, and by many other CMake consumers.
   #   - MAGMA_ROOT : the modern CMake convention (find_package looks
   #                  up <Pkg>_ROOT).
   #   - MAGMA_DIR  : Spack's convention, also commonly hand-rolled.
   # Setting all four here makes the magma module the single source
   # of truth for "where is magma installed", so downstream packages
   # (pytorch_setup.sh, future ginkgo, future user code) never have
   # to hardcode the path or re-export under a different name.
   # Toolchain-isolation note (Option B, 2026-05-04):
   # libmagma.so was built with amdclang++ for the HIP device kernels and
   # therefore links libomp.so (LLVM OpenMP) at runtime. We expose ONLY
   # the LLVM lib path -- not the amdclang module itself -- because
   # `load("amdclang")` would also setenv CC=amdclang, CXX=amdclang++,
   # FC=amdflang, OMPI_CC/CXX/FC, F77, F90, STDPAR_CXX (nine vars total;
   # see /shared/apps/modules/.../amdclang/*.lua). That toolchain
   # pollution previously poisoned downstream consumers:
   #   - PyTorch's CMake autodetect picked amdclang++ for libtorch_cpu,
   #     producing long-form std::enable_if NTTP mangling (LLVM #85656)
   #     that did not match HIP TU references, dlopen failed at "import
   #     torch" with the const_data_ptr undefined-symbol error
   #     (slurm 8093, 8096; needed an explicit `unset CC CXX FC ...`
   #     firewall in pytorch_setup.sh that this change makes obsolete).
   #   - magma's own OpenBLAS subbuild inherited FC=amdflang, which
   #     choked on OpenBLAS-0.3.33's OpenMP-5.0 array sections in
   #     `task depend` (slurm 8067, rocm-7.1.1, "not yet implemented:
   #     array sections not supported for task depend").
   # Loading magma is a library dependency; it should not silently
   # rewrite the user's compiler choice. The two prepend_path lines
   # below give libomp.so to ldopen at runtime without touching CC/CXX/FC.
   MAGMA_MODULEFILE="${MAGMA_MODULE_DIR}/${MAGMA_VERSION}${MODEXT}"
   if [ "${MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${MOD_SUDO} tee ${MAGMA_MODULEFILE}
	whatis("Magma version ${MAGMA_VERSION} for AMD hardware")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")
	-- Expose libomp.so (LLVM OpenMP) directly, NOT via load("amdclang"),
	-- which would also export CC/CXX/FC and poison downstream consumers.
	-- See magma_setup.sh comment block above this heredoc for full
	-- rationale (slurm 8067 / 8093 / 8096 references).
	prepend_path("LD_LIBRARY_PATH","${ROCM_PATH}/llvm/lib")
	prepend_path("LD_RUN_PATH",    "${ROCM_PATH}/llvm/lib")
	setenv("MAGMA_PATH","${MAGMA_PATH}")
	setenv("MAGMA_HOME","${MAGMA_PATH}")
	setenv("MAGMA_ROOT","${MAGMA_PATH}")
	setenv("MAGMA_DIR","${MAGMA_PATH}")
	prepend_path("LD_LIBRARY_PATH","${MAGMA_PATH}/lib")
EOF
   else
      cat <<-EOF | ${MOD_SUDO} tee ${MAGMA_MODULEFILE}
	#%Module1.0
	module-whatis "Magma version ${MAGMA_VERSION} for AMD hardware"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_MODULE_NAME}
	# Expose libomp.so (LLVM OpenMP) directly, NOT via 'module load amdclang',
	# which would also export CC/CXX/FC and poison downstream consumers.
	# See magma_setup.sh comment block above this heredoc for full rationale.
	prepend-path LD_LIBRARY_PATH "${ROCM_PATH}/llvm/lib"
	prepend-path LD_RUN_PATH "${ROCM_PATH}/llvm/lib"
	setenv MAGMA_PATH "${MAGMA_PATH}"
	setenv MAGMA_HOME "${MAGMA_PATH}"
	setenv MAGMA_ROOT "${MAGMA_PATH}"
	setenv MAGMA_DIR "${MAGMA_PATH}"
	prepend-path LD_LIBRARY_PATH "${MAGMA_PATH}/lib"
EOF
   fi

   # OpenBLAS env: when we built it (OPENBLAS_BUILD=1) a standalone
   # openblas modulefile already exists, so just load it for a single
   # source of truth. When we reused a system or operator-supplied
   # OpenBLAS, no module exists, so inline the OPENBLAS_PATH/LD_LIBRARY_PATH
   # exports directly in the magma module to keep downstream consumers
   # (pytorch's BLAS=OpenBLAS path, etc.) working.
   if [ "${OPENBLAS_BUILD}" = "1" ]; then
      if [ "${MODFLAVOR}" = "lua" ]; then
         echo "load(\"openblas/${OPENBLAS_VERSION}\")" | ${MOD_SUDO} tee -a ${MAGMA_MODULEFILE}
      else
         echo "if { ![ is-loaded openblas/${OPENBLAS_VERSION} ] } { module load openblas/${OPENBLAS_VERSION} }" | ${MOD_SUDO} tee -a ${MAGMA_MODULEFILE}
      fi
   elif [ -n "${OPENBLAS_PATH}" ]; then
      if [ "${MODFLAVOR}" = "lua" ]; then
         cat <<-EOF | ${MOD_SUDO} tee -a ${MAGMA_MODULEFILE}
	setenv("OPENBLAS_PATH","${OPENBLAS_PATH}")
	prepend_path("LD_LIBRARY_PATH","${OPENBLAS_PATH}/lib")
EOF
      else
         cat <<-EOF | ${MOD_SUDO} tee -a ${MAGMA_MODULEFILE}
	setenv OPENBLAS_PATH "${OPENBLAS_PATH}"
	prepend-path LD_LIBRARY_PATH "${OPENBLAS_PATH}/lib"
EOF
      fi
   fi

fi
