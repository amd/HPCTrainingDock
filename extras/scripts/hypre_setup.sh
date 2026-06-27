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
MODULE_PATH=/etc/lmod/modules/ROCmPlus/hypre
BUILD_HYPRE=0
ROCM_VERSION=6.2.0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
AMDGPU_GFXMODEL_INPUT=""
USE_SPACK=0
HYPRE_VERSION="3.1.0"
MPI_MODULE="openmpi"
HYPRE_PATH=/opt/rocmplus-${ROCM_VERSION}/hypre-v${HYPRE_VERSION}
HYPRE_PATH_INPUT=""
# --install-path: parent dir; the script appends hypre-v${HYPRE_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf the prior hypre-v${HYPRE_VERSION} install dir and
# its modulefile BEFORE building. Idempotent if nothing to remove.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so the
# partial install + modulefile are left on disk for post-mortem.
# Together these replace the legacy main_setup.sh `replace_pkg` /
# `PKG_CLEAN_DIRS`/`PKG_CLEAN_MODS` arrays -- which had drifted out
# of sync with the actual install paths during the versioning pass --
# so the install-layout knowledge lives in exactly one place: this
# script. main_setup.sh just threads through `--replace
# ${REPLACE_EXISTING}` and `--keep-failed-installs ${KEEP_FAILED_INSTALLS}`.
REPLACE=0
KEEP_FAILED_INSTALLS=0

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default is $MODULE_PATH "
   echo "  --install-path-no-version [ HYPRE_PATH_INPUT ] default is $HYPRE_PATH "
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), HYPRE_PATH = ROCMPLUS_PATH/hypre-v\${HYPRE_VERSION}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL_INPUT ] default autodetected "
   echo "  --hypre-version [ HYPRE_VERSION ] default is $HYPRE_VERSION "
   echo "  --use-spack [ USE_SPACK ] default is $USE_SPACK "
   echo "  --build-hypre [ BUILD_HYPRE ] default is 0 "
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information "
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--build-hypre")
          shift
          BUILD_HYPRE=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--hypre-version")
          shift
          HYPRE_VERSION=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path-no-version")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--use-spack")
          shift
          USE_SPACK=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   HYPRE_PATH=${INSTALL_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends hypre-v${HYPRE_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for hypre.
   HYPRE_PATH=${ROCMPLUS_PATH_INPUT}/hypre-v${HYPRE_VERSION}
else
   # override path in case ROCM_VERSION or HYPRE_VERSION has been supplied as input
   HYPRE_PATH=/opt/rocmplus-${ROCM_VERSION}/hypre-v${HYPRE_VERSION}
fi

# ── Install-path sudo (computed EARLY, before afar-skip/--replace) ────
# The afar-skip and --replace blocks below rm -rf the install dir +
# modulefile with ${SUDO}. The leaf default is SUDO=sudo, which on a
# cluster with no passwordless sudo and a user-owned install tree (this
# Cray) makes --replace / afar-skip die on a password prompt before the
# build even starts. Probe the nearest existing ancestor of the install
# dir for user-writability and drop sudo when we own it. Mirrors the
# magma/kokkos/petsc/rocshmem writability probe. The same SUDO then
# governs the build-branch install dir + chowns below. EUID 0 never
# needs sudo.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :  # already cleared (e.g. Singularity)
else
   _iprobe="$(dirname "${HYPRE_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .hypre-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "hypre: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "hypre: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── BUILD_HYPRE=0 short-circuit: operator opt-out ────────────────────
# Replaces the `if [[ "${BUILD_HYPRE}" == "1" ]]; then run_and_log
# hypre ...; fi` wrapper that previously gated this script's entire
# invocation in bare_system/main_setup.sh. Moving the gate inside has
# two effects:
#   * BUILD_HYPRE is now interpreted in exactly one place (here),
#     beside its only consumer; main_setup.sh just threads the value
#     through unconditionally and lets each script decide its own fate.
#   * the per-package summary records a SKIPPED(no-op) line for every
#     opted-out package (vs. the prior silent omission), which makes
#     it obvious from a single log grep what was actually built vs.
#     what the operator turned off.
# Placement: AFTER arg parsing + path resolution (so BUILD_HYPRE has
# its final value and any echo references resolve correctly) and
# BEFORE the --replace block (so --replace 1 + BUILD_HYPRE=0 does NOT
# wipe an existing install -- "don't install" must not be confused
# with "wipe what is there"). Also before the existence-check guard
# and the EXIT-trap install for the same reason. Exits ${NOOP_RC}=43
# so run_and_log classifies this as SKIPPED, not OK.
NOOP_RC=43
if [ "${BUILD_HYPRE}" = "0" ]; then
   echo "[hypre BUILD_HYPRE=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── afar SDK incompatibility detection ───────────────────────────────
# AMD's pre-release "AFAR" ROCm drops (rocm-afar-22.x, rocm-afar-7.0.5)
# are runtime-only / partial SDKs. Verified empirically on this cluster
# (audit_2026_05_06, job 8490, log_hypre_05_06_2026.txt:69):
#
#   afar-22.1.0  $ find <ROCM_PATH> -name 'rocblas-config.cmake'
#                -> 0 matches  (.so present at <ROCM_PATH>/lib/librocblas.so*
#                               but no cmake metadata)
#   afar-22.2.0  $ same probe -> 1 match (cmake config present)
#   rocm-7.2.1   $ same probe -> 1 match
#
# hypre's config/cmake/HYPRE_SetupHIPToolkit.cmake:223 calls
# find_package(rocblas) which fails with "Could not find a package
# configuration file provided by 'rocblas'". Skipping here turns
# 8490-style FAILED hypre(rc=1) into the correct SKIPPED(no-op)
# bucket on afar-22.1.0 (afar-22.2.0 ships the cmake config; the
# probe correctly lets that case through).
#
# Probe shape: gated on `${ROCM_PATH}` matching `*afar*` AND no
# rocblas-config.cmake. Self-corrects if AMD ships the cmake metadata
# in a future afar drop (matches the rocm-bundled hipfort policy in
# extras/scripts/hipfort_setup.sh).
if [[ "${ROCM_PATH:-}" == *afar* ]]; then
   if [[ -z "${ROCM_PATH:-}" ]] && type module >/dev/null 2>&1; then
      module load "rocm/${ROCM_VERSION}" 2>/dev/null || true
   fi
   if [ ! -f "${ROCM_PATH}/lib/cmake/rocblas/rocblas-config.cmake" ]; then
      echo ""
      echo "[hypre afar-skip] ROCM_PATH=${ROCM_PATH} is an AMD AFAR partial SDK"
      echo "                  missing : <ROCM_PATH>/lib/cmake/rocblas/rocblas-config.cmake"
      echo "                  hypre requires find_package(rocblas); cannot build on afar SDK."
      echo "                  Skipping (no source build, no cache restore)."
      echo ""
      if [ -d "${HYPRE_PATH}" ]; then
         echo "[hypre afar-skip] removing stale from-source install: ${HYPRE_PATH}"
         ${SUDO} rm -rf "${HYPRE_PATH}"
      fi
      if [ -f "${MODULE_PATH}/${HYPRE_VERSION}.lua" ] || [ -f "${MODULE_PATH}/${HYPRE_VERSION}" ]; then
         echo "[hypre afar-skip] removing stale modulefile: ${MODULE_PATH}/${HYPRE_VERSION}{.lua,}"
         ${SUDO} rm -f "${MODULE_PATH}/${HYPRE_VERSION}.lua" "${MODULE_PATH}/${HYPRE_VERSION}"
      fi
      # ── Drop a SKIPPED marker so the inventory tool can distinguish ──
      # "skipped on this SDK" from "absent / failed". See
      # bare_system/inventory_packages.py ('N' symbol -- Not possible to build on this SDK).
      _SKIP_MARKER_DIR="$(dirname "${HYPRE_PATH}")"
      ${SUDO} mkdir -p "${_SKIP_MARKER_DIR}" 2>/dev/null || true
      if [ -d "${_SKIP_MARKER_DIR}" ]; then
         ${SUDO} tee "${_SKIP_MARKER_DIR}/hypre.SKIPPED" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: hypre
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    hypre_setup.sh (afar-skip guard)
Reason:          AFAR SDK is missing
                 <ROCM_PATH>/lib/cmake/rocblas/rocblas-config.cmake.
                 hypre requires find_package(rocblas); cannot build
                 on this SDK.
                 Self-corrects on the next sweep if AMD ships a more
                 complete AFAR drop.
MARKER_EOF
      fi
      unset _SKIP_MARKER_DIR
      exit ${NOOP_RC}
   fi
fi

# ── --replace: remove prior install + modulefile BEFORE building ─────
# Invoked when the operator (or main_setup.sh's --replace-existing 1
# pass-through) wants this version's install dir + ${HYPRE_VERSION}.lua
# wiped before a fresh install. Safe if nothing is there to remove.
# Other versions' installs are NOT touched (multi-version coexistence).
if [ "${REPLACE}" = "1" ]; then
   echo "[hypre --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HYPRE_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${HYPRE_VERSION}{.lua,}"
   ${SUDO} rm -rf "${HYPRE_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${HYPRE_VERSION}.lua" "${MODULE_PATH}/${HYPRE_VERSION}"
fi

# ── Existence guard: skip if this version is already installed ───────
# Replaces the `[[ ! -d ${ROCMPLUS}/hypre-v${HYPRE_VERSION} ]]` clause
# that previously gated this script's invocation in
# bare_system/main_setup.sh. Moving the check into the script keeps the
# install-path knowledge in exactly one place (the same HYPRE_PATH /
# HYPRE_VERSION resolved above), which matters because:
#   * --hypre-version on the CLI overrides what main_setup.sh passed,
#     and only the script sees the final value;
#   * multi-component scripts (magma+openblas, netcdf-c/f/pnetcdf,
#     openmpi+xpmem+ucx+ucc, etc.) check ALL of their components here,
#     not just the first one main_setup.sh happened to know about.
# Placement: AFTER the --replace block (so --replace 1 wipes first and
# this check passes through to a real rebuild) and BEFORE the EXIT trap
# install (so the NOOP_RC exit below is not interpreted as a partial
# install and does not trigger fail-cleanup of the install we just
# confirmed is intact). Exits with NOOP_RC=43 (set in the BUILD_HYPRE=0
# block above); main_setup.sh's run_and_log records this as
# SKIPPED(no-op) in the per-package summary.
if [ -d "${HYPRE_PATH}" ]; then
   echo ""
   echo "[hypre existence-check] ${HYPRE_PATH} already installed; skipping."
   echo "                        pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ──────────
# On a non-zero exit (configure error, build error, install error,
# preflight miss, etc.) remove any partial artifacts this script left
# behind so the next sweep starts from a clean state. Skipped when
# --keep-failed-installs 1 (operator wants to inspect the partial
# install for post-mortem). This replaces the `cleanup_pkg` helper +
# PKG_CLEAN_DIRS/PKG_CLEAN_MODS arrays that used to live in
# bare_system/main_setup.sh and that had to be kept in sync with the
# script's install layout by hand. Now the cleanup paths are derived
# from the same HYPRE_PATH / MODULE_PATH / HYPRE_VERSION variables the
# install side uses, so they cannot drift.
_hypre_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hypre fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HYPRE_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${HYPRE_VERSION}.lua" "${MODULE_PATH}/${HYPRE_VERSION}"
   elif [ ${rc} -ne 0 ]; then
      echo "[hypre fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # 2026-05-05: also clean the local build dir if set (regular non-spack
   # branch puts the source extraction under /tmp via mktemp; see
   # comment-block above the HYPRE_BUILD_DIR=mktemp call). The spack
   # branch installs its own EXIT trap that handles SPACK_USER_*
   # dirs as well as its own HYPRE_BUILD_DIR; that trap REPLACES this
   # one so this block does not run on the spack code path.
   if [ -n "${HYPRE_BUILD_DIR:-}" ] && [ -d "${HYPRE_BUILD_DIR}" ]; then
      ${SUDO:-sudo} rm -rf "${HYPRE_BUILD_DIR}"
   fi
   return ${rc}
}
trap _hypre_on_exit EXIT

echo ""
echo "==================================="
echo "Starting HYPRE Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HYPRE: $BUILD_HYPRE"
echo "HYPRE_VERSION: $HYPRE_VERSION"
echo "HYPRE_PATH: $HYPRE_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   # Stderr-silenced + `|| true`: rocminfo can fail when the SDK is built
   # against a newer glibc than the host (ROCm 7.2.3 binaries need
   # GLIBC_2.38; jammy has 2.35) and under pipefail would kill the script.
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi


AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_HYPRE}" = "0" ]; then

   echo "HYPRE will not be built, according to the specified value of BUILD_HYPRE"
   echo "BUILD_HYPRE: $BUILD_HYPRE"
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

   if [ -f ${CACHE_FILES}/hypre-v${HYPRE_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HYPRE"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # hypre-v${HYPRE_VERSION}.tgz and contain a top-level directory
      # hypre-v${HYPRE_VERSION}/ so it lands directly at ${HYPRE_PATH}
      # when extracted under /opt/rocmplus-X.
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/hypre-v${HYPRE_VERSION}.tgz
      chown -R root:root ${HYPRE_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/hypre-v${HYPRE_VERSION}.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building HYPRE"
      echo "============================"
      echo ""

      # ── MPI module auto-correct on a Cray PE (see hdf5/netcdf/petsc) ──
      # hypre's cmake needs an MPI for find_package(MPI) (and, with Fortran
      # enabled below, find_package(MPI COMPONENTS Fortran) -> mpifort). The
      # leaf default MPI_MODULE is "openmpi", but a Cray system ships
      # cray-mpich (no openmpi module exists) -- preflight would SKIP the
      # whole build. If cray-mpich is active and the caller did not override
      # the MPI, switch to cray-mpich. main_setup.sh also threads
      # --mpi-module mpich-wrappers / cray-mpich; this makes the leaf
      # correct standalone too.
      if [ "${MPI_MODULE}" = "openmpi" ] \
           && { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; }; then
         MPI_MODULE="cray-mpich"
         echo "hypre: Cray MPICH detected; MPI_MODULE -> cray-mpich"
      fi

      # ── mpich-wrappers resolution (PrgEnv MPI + new-flang mpi.mod) ─────
      # cray-mpich drives the build through cc/CC/ftn wrappers and does not
      # put mpicc/mpicxx/mpifort on PATH, so cmake's find_package(MPI)
      # cannot locate it. The from-source mpich-wrappers leaf ships
      # mpicc/mpicxx/mpifort (MPICH-ABI compatible with cray-mpich, built
      # with the new LLVM Flang amdflang -> amdflang-format mpi.mod) --
      # exactly what hypre's Fortran drivers need on ROCm 7.x. When the
      # caller asks for it (main_setup threads --mpi-module mpich-wrappers),
      # resolve the bare name to the concrete, version-matched modulefile
      # token by scanning MODULEPATH. If none is found, fall back to
      # cray-mpich.
      if [ "${MPI_MODULE}" = "mpich-wrappers" ]; then
         _mw_tok=""
         _OLD_IFS="${IFS}"; IFS=":"
         for _d in ${MODULEPATH:-}; do
            for _cand in "mpich-wrappers/${ROCM_VERSION}" "mpich-wrappers"; do
               if [ -e "${_d}/${_cand}" ] || [ -e "${_d}/${_cand}.lua" ]; then
                  _mw_tok="${_cand}"; break 2
               fi
            done
         done
         IFS="${_OLD_IFS}"; unset _OLD_IFS _d _cand
         if [ -n "${_mw_tok}" ]; then
            MPI_MODULE="${_mw_tok}"
            echo "hypre: using mpich-wrappers module '${_mw_tok}' (PrgEnv MPI; ships mpicc/mpicxx/mpifort, new-flang mpi.mod)"
         else
            echo "hypre: WARNING: --mpi-module mpich-wrappers requested but no mpich-wrappers modulefile found on MODULEPATH; falling back to cray-mpich"
            MPI_MODULE="cray-mpich"
         fi
         unset _mw_tok
      fi

      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── Compiler + MPI selection for cmake ───────────────────────────
      # On a Cray PrgEnv-amd-new the system Fortran (amdflang / Cray ftn)
      # is the NEW LLVM Flang, whose mpi.mod format the old crayftn cannot
      # read and vice versa. Resolve concrete compilers so the build is
      # consistent and find_package(MPI) succeeds:
      #   * mpich-wrappers: mpicc (gcc) / mpicxx (g++) / mpifort (amdflang),
      #     standalone MPICH built with FC=amdflang -> new-flang mpi.mod.
      #     This is the PrgEnv MPI + amdflang the operator asked for.
      #   * else: leave compilers unset (cmake defaults; non-Cray openmpi
      #     path), and let find_package(MPI) discover the wrappers on PATH.
      # HIP device code is compiled by CMAKE_HIP_COMPILER
      # (${ROCM_PATH}/llvm/bin/clang++, set by HYPRE's own
      # HYPRE_SetupHIPToolkit.cmake from ROCM_PATH), independent of these
      # host C/C++ compilers, so using mpicc/mpicxx for host is safe.
      HYPRE_C_COMPILER=""
      HYPRE_CXX_COMPILER=""
      HYPRE_F_COMPILER=""
      if [ "${MPI_MODULE#mpich-wrappers}" != "${MPI_MODULE}" ] \
           && command -v mpicc   >/dev/null 2>&1 \
           && command -v mpicxx  >/dev/null 2>&1 \
           && command -v mpifort >/dev/null 2>&1; then
         HYPRE_C_COMPILER=$(command -v mpicc)
         HYPRE_CXX_COMPILER=$(command -v mpicxx)
         HYPRE_F_COMPILER=$(command -v mpifort)
         echo "hypre: mpich-wrappers MPI -> mpicc/mpicxx/mpifort (PrgEnv MPI, new-flang mpi.mod)."
         echo "hypre: Fortran wrapper mpifort -> $(${HYPRE_F_COMPILER} --version 2>/dev/null | head -1)"
      fi

      # ── MPI hint for cmake's find_package(MPI) ───────────────────────
      # The PrgEnv MPI modules don't export the variables find_package(MPI)
      # keys on. mpich-wrappers exports MPICH_WRAPPERS_DIR (root has
      # bin/mpicc + include + lib); cray-mpich exports MPICH_DIR. Set
      # MPI_HOME so cmake can locate the MPI even when the wrappers aren't
      # on PATH (harmless when they are).
      if [ -z "${MPI_HOME:-}" ]; then
         if [ -n "${MPICH_WRAPPERS_DIR:-}" ]; then
            export MPI_HOME="${MPICH_WRAPPERS_DIR}"
            echo "hypre: MPI_HOME set from MPICH_WRAPPERS_DIR -> ${MPI_HOME}"
         elif [ -n "${MPICH_DIR:-}" ]; then
            export MPI_HOME="${MPICH_DIR}"
            echo "hypre: MPI_HOME set from MPICH_DIR (cray-mpich) -> ${MPI_HOME}"
         fi
      fi

      ${SUDO} mkdir -p ${HYPRE_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${HYPRE_PATH}
      fi

      HYPRE_PATH_ORIGINAL=$HYPRE_PATH
      # ------------ Installing HYPRE

      if [[ $USE_SPACK == 1 ]]; then

         echo " WARNING: installing hypre with spack: the build is a work in progress, fails can happen..."

         # PKG_SUDO: apt needs root regardless of install-path SUDO.
         # The previous `[[ ${SUDO} != "" ]]` guard skipped libssl-dev
         # whenever the install path was admin-writable, leading to a
         # spack build that silently failed when libevent couldn't
         # find openssl. See openmpi_setup.sh / audit_2026_05_01.md
         # Issue 2.
         PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
         ${PKG_SUDO} apt-get update
         ${PKG_SUDO} apt-get install -y libssl-dev unzip

         # Spack user-scope isolation: see scorep_setup.sh for full
         # rationale. Per-job throwaway dirs keep `spack external
         # find --all` from polluting ~/.spack/packages.yaml across
         # rocm versions and prevent any stale user-scope
         # install_tree.root from over-riding the defaults edit below.
         SPACK_USER_CONFIG_PATH=$(mktemp -d -t spack-user-config.XXXXXX)
         SPACK_USER_CACHE_PATH=$(mktemp -d -t spack-user-cache.XXXXXX)
         export SPACK_USER_CONFIG_PATH SPACK_USER_CACHE_PATH

         # Spack clone goes under /tmp (compute-node local disk) so
         # concurrent rocm-version builds don't race on ${PWD}/spack
         # in the shared HPCTrainingDock checkout (observed
         # 2026-04-30: 7952's scorep_setup.sh hit "destination path
         # 'spack' already exists" because 7954 created it earlier).
         # EXIT trap covers the build dir + the two spack user-scope
         # dirs above.
         HYPRE_BUILD_DIR=$(mktemp -d -t hypre-build.XXXXXX)
         trap '${SUDO:-sudo} rm -rf "${HYPRE_BUILD_DIR:-/nonexistent}" "${SPACK_USER_CONFIG_PATH:-/nonexistent}" "${SPACK_USER_CACHE_PATH:-/nonexistent}"' EXIT
         cd "${HYPRE_BUILD_DIR}"

         git clone https://github.com/spack/spack.git

         # load spack environment
         source spack/share/spack/setup-env.sh

         # find already installed libs for spack
         spack external find --all

         spack install rocm-core@${ROCM_VERSION} rocm-cmake@${ROCM_VERSION} hipblas-common@${ROCM_VERSION} rocthrust@${ROCM_VERSION} rocprim@${ROCM_VERSION}

         # change spack install dir for Hypre
         sed -i 's|$spack/opt/spack|'"${HYPRE_PATH}"'|g' spack/etc/spack/defaults/base/config.yaml 

         # install hypre with spack
         #spack install hypre+rocm+rocblas+unified-memory
         spack install hypre@$HYPRE_VERSION+rocm+unified-memory+gpu-aware-mpi amdgpu_target=$AMDGPU_GFXMODEL

         # get hypre install dir created by spack
         HYPRE_PATH=$(spack location -i hypre)

         # HYPRE_BUILD_DIR (under /tmp, contains the spack clone) is
         # removed by the EXIT trap above.

      else

         # 2026-05-05: isolate the regular (non-spack) hypre build under
         # /tmp (compute-node local disk) instead of PWD (the shared NFS
         # HPCTrainingDock checkout). Without this, three concurrent
         # rocm-version sweeps that hit the hypre step at the same time
         # collide on a single ~/HPCTrainingDock/hypre-${HYPRE_VERSION}/
         # directory and corrupt each other's source trees. Observed in
         # the overnight 8221/8222/8223 sweep (2026-05-05 ~05:52 UTC):
         #   - 8221 (sh5-pl1-s12-09): `rm -rf hypre-3.1.0` failed with
         #     "Directory not empty" because 8222 was concurrently
         #     extracting into the same directory; rc=1.
         #   - 8222 (sh5-pl1-s12-12): later `sed -i IJ_mv/IJMatrix_parcsr_device.c`
         #     hit ENOENT because 8221's partial rm had unlinked the file
         #     after 8222's tar wrote it; rc=2.
         #   - 8223 (sh5-pl1-s12-33): hit hypre 7 min later (after the
         #     other two failed and their fail-cleanup traps fired);
         #     PWD was clean by then; succeeded.
         # Per-job /tmp dir gives each sweep its own scratch tree, so
         # rm/wget/tar/cd/sed never see another job's intermediate state.
         # The spack branch above (line ~412) already used this pattern;
         # extending to the regular branch closes the gap. Cleanup
         # consolidated into _hypre_on_exit (which also handles install
         # rollback), see the trap registration earlier in this script.
         HYPRE_BUILD_DIR=$(mktemp -d -t hypre-build.XXXXXX)
         cd "${HYPRE_BUILD_DIR}"

         ${SUDO} rm -rf v${HYPRE_VERSION}.tar.gz hypre-${HYPRE_VERSION}
         wget -q https://github.com/hypre-space/hypre/archive/refs/tags/v${HYPRE_VERSION}.tar.gz
         tar -xzf v${HYPRE_VERSION}.tar.gz
         cd hypre-${HYPRE_VERSION}/src

         # ROCm-build patches. Two classes:
         #   (a) HYPRE_THRUST_IDENTITY -> thrust::identity<T>() inlining.
         #       Verified the macro definition is byte-identical in 3.0.0
         #       and 3.1.0 (utilities/_hypre_utilities.hpp:451-453,
         #       utilities/device_utils.h:233-235), so these 9 string
         #       substitutions remain valid across both versions.
         #   (b) Commenting out the user-defined __syncwarp() shim that
         #       collides with ROCm's own. In 3.0.0 the shim sits at
         #       _hypre_utilities.hpp:1481-1484; in 3.1.0 the file was
         #       refactored (now 2869 lines vs 3704; line numbers shifted)
         #       and the patch needs to be re-validated. v3.1.0 was
         #       advertised with "rocm 7.0 support" added upstream
         #       (https://github.com/hypre-space/hypre/releases/tag/v3.1.0),
         #       which suggests the conflict may have been resolved
         #       upstream. Apply the line-range patch only for 3.0.0;
         #       for 3.1.0 (and beyond) we skip it and let the build
         #       fail loudly if the conflict is back -- at which point
         #       we'll patch the new line range with a fresh diagnosis
         #       rather than blindly comment out random lines.
         if [ "${HYPRE_VERSION}" = "3.0.0" ]; then
            sed -i -e '1481,1484s!^!//!' utilities/_hypre_utilities.hpp
         else
            echo "hypre: skipping legacy 1481-1484 __syncwarp comment-out patch for HYPRE_VERSION=${HYPRE_VERSION}"
            echo "hypre: (line numbers shifted upstream; if build fails on __syncwarp redefinition, re-add a version-correct patch here)"
         fi

         sed -i -e 's/HYPRE_THRUST_IDENTITY(char)/thrust::identity<char>()/' seq_mv/csr_spgemm_device_symbl.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(char)/thrust::identity<char>()/' IJ_mv/IJMatrix_parcsr_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(char)/thrust::identity<char>()/' IJ_mv/IJVector_parcsr_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Int)/thrust::identity<HYPRE_Int>()/' parcsr_mv/par_csr_fffc_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Int)/thrust::identity<HYPRE_Int>()/' parcsr_ls/ame.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Int)/thrust::identity<HYPRE_Int>()/' parcsr_ls/par_coarsen_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Int)/thrust::identity<HYPRE_Int>()/' parcsr_ls/par_mod_multi_interp_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Complex)/thrust::identity<HYPRE_Complex>()/' IJ_mv/IJMatrix_parcsr_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Complex)/thrust::identity<HYPRE_Complex>()/' IJ_mv/IJVector_parcsr_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Complex)/thrust::identity<HYPRE_Complex>()/' parcsr_ls/ams.c

         mkdir build && cd build

         # Assemble cmake args. Host C/C++ compilers come from the MPI
         # wrappers (mpicc/mpicxx) when mpich-wrappers resolved, so the
         # build links the PrgEnv MPI consistently; HIP device code uses
         # HYPRE's own CMAKE_HIP_COMPILER (${ROCM_PATH}/llvm/bin/clang++).
         # ROCM_PATH is passed explicitly so HYPRE_SetupHIPToolkit.cmake
         # finds rocblas/the HIP compiler. MPI_HOME / CMAKE_PREFIX_PATH let
         # find_package(MPI) resolve the PrgEnv MPI when its wrappers are
         # not the cmake compilers (cray-mpich path).
         HYPRE_CMAKE_ARGS=(
            -DCMAKE_INSTALL_PREFIX="$HYPRE_PATH"
            -DHYPRE_ENABLE_MIXEDINT=ON
            -DHYPRE_ENABLE_MPI=ON
            -DHYPRE_ENABLE_OPENMP=ON
            -DHYPRE_BUILD_TESTS=ON
            -DHYPRE_ENABLE_HIP=ON
            -DCMAKE_HIP_ARCHITECTURES="$AMDGPU_GFXMODEL"
            -DHYPRE_ENABLE_UMPIRE=OFF
            -DHYPRE_ENABLE_GPU_PROFILING=ON
            -DHYPRE_ENABLE_GPU_AWARE_MPI=ON
            -DBUILD_SHARED_LIBS=ON
            -DHYPRE_ENABLE_UNIFIED_MEMORY=ON
         )
         [ -n "${ROCM_PATH:-}" ] && HYPRE_CMAKE_ARGS+=( -DROCM_PATH="${ROCM_PATH}" )
         [ -n "${HYPRE_C_COMPILER}" ]   && HYPRE_CMAKE_ARGS+=( -DCMAKE_C_COMPILER="${HYPRE_C_COMPILER}" )
         [ -n "${HYPRE_CXX_COMPILER}" ] && HYPRE_CMAKE_ARGS+=( -DCMAKE_CXX_COMPILER="${HYPRE_CXX_COMPILER}" )
         # Build the Fortran drivers with the new amdflang (via mpifort)
         # so the operator-requested compiler is actually exercised and
         # the Fortran interface is compiled against the new-flang mpi.mod.
         if [ -n "${HYPRE_F_COMPILER}" ]; then
            HYPRE_CMAKE_ARGS+=(
               -DHYPRE_ENABLE_FORTRAN=ON
               -DCMAKE_Fortran_COMPILER="${HYPRE_F_COMPILER}"
            )
            echo "hypre: HYPRE_ENABLE_FORTRAN=ON with CMAKE_Fortran_COMPILER=${HYPRE_F_COMPILER} (amdflang)"
         fi
         if [ -n "${MPI_HOME:-}" ]; then
            HYPRE_CMAKE_ARGS+=( -DMPI_HOME="${MPI_HOME}" -DCMAKE_PREFIX_PATH="${MPI_HOME}" )
         fi

         cmake "${HYPRE_CMAKE_ARGS[@]}" ..

         make -j
         ${SUDO} make install
         cd ../../..
         rm -rf hypre-${HYPRE_VERSION} v${HYPRE_VERSION}.tar.gz

      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
            ${SUDO} find ${HYPRE_PATH_ORIGINAL} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${HYPRE_PATH_ORIGINAL}
      fi

      module unload ${ROCM_MODULE_NAME} || true
      module unload ${MPI_MODULE} || true

   fi

   # Create a module file for hypre
   #
   # Module-tree sudo + flavor: pick Lua (.lua) for Lmod, classic Tcl
   # (no ext) otherwise, and probe the module tree for user-writability
   # so a user-owned modulepath (this Cray) does not trigger a sudo
   # password prompt. Mirrors the magma/kokkos modulefile probe.
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      MODFLAVOR="lua"; MODEXT=".lua"
   else
      MODFLAVOR="tcl"; MODEXT=""
   fi
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      MOD_SUDO=""
   else
      _mprobe="${MODULE_PATH}"
      while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
      _mtest=$(mktemp --tmpdir="${_mprobe}" .hypre-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         MOD_SUDO=""
         echo "hypre: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         MOD_SUDO="sudo"
         echo "hypre: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
      fi
      unset _mprobe _mtest
   fi
   ${MOD_SUDO} mkdir -p ${MODULE_PATH}

   # Detect the actual libdir: RHEL9/cmake GNUInstallDirs installs shared
   # libs to lib64, Debian/Ubuntu to lib. Point the modulefile at whichever
   # exists so LD_LIBRARY_PATH resolves libHYPRE.so.
   if [ -d "${HYPRE_PATH}/lib64" ]; then
      HYPRE_LIBDIR="lib64"
   else
      HYPRE_LIBDIR="lib"
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

   # The - option suppresses tabs. Dual flavor: Lua for Lmod, classic Tcl
   # otherwise. Both prereq the rocm SDK module and load the (resolved)
   # MPI module so downstream linking against libHYPRE picks up the same
   # PrgEnv MPI the library was built against.
   # ROCm prereq: accept rocm-new/<ver> OR rocm/<ver>. Under PrgEnv-amd-new
   # the loaded ROCm module is rocm-new/<ver>, not rocm/<ver>, so a plain
   # `prereq rocm/<ver>` fails there. Widen only when a rocm-new modulefile
   # is discoverable on MODULEPATH (AAC7 / TheRock site); stock sites (AAC6)
   # keep the plain rocm/<ver> prereq. Mirrors hipifly/hdf5/petsc.
   rocm_new_available() {
      local _d _OIFS="${IFS}"; IFS=":"
      for _d in ${MODULEPATH:-}; do
         if [ -d "${_d}/rocm-new" ]; then IFS="${_OIFS}"; return 0; fi
      done
      IFS="${_OIFS}"; return 1
   }
   _RPV="${ROCM_MODULE_NAME##*/}"
   case "${ROCM_MODULE_NAME}" in
      rocm/*|rocm-new/*)
         if rocm_new_available; then
            ROCM_PREREQ_TCL="rocm-new/${_RPV} rocm/${_RPV}"
            ROCM_PREREQ_LUA="prereq_any(\"rocm-new/${_RPV}\", \"rocm/${_RPV}\")"
         else
            ROCM_PREREQ_TCL="rocm/${_RPV}"
            ROCM_PREREQ_LUA="prereq(\"rocm/${_RPV}\")"
         fi
         ;;
      *)
         ROCM_PREREQ_TCL="${ROCM_MODULE_NAME}"
         ROCM_PREREQ_LUA="prereq(\"${ROCM_MODULE_NAME}\")"
         ;;
   esac
   unset _RPV

   HYPRE_MODULEFILE="${MODULE_PATH}/${HYPRE_VERSION}${MODEXT}"
   if [ "${MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${MOD_SUDO} tee ${HYPRE_MODULEFILE}
	whatis("HYPRE - solver package")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${HYPRE_PATH}"

	${ROCM_PREREQ_LUA}
	load("${MPI_MODULE}")
	setenv("HYPRE_PATH", base)
	prepend_path("PATH",pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "${HYPRE_LIBDIR}"))
EOF
   else
      cat <<-EOF | ${MOD_SUDO} tee ${HYPRE_MODULEFILE}
	#%Module1.0
	module-whatis "HYPRE - solver package"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${HYPRE_PATH}"

	prereq ${ROCM_PREREQ_TCL}
	if { ![ is-loaded ${MPI_MODULE} ] } { module load ${MPI_MODULE} }
	setenv HYPRE_PATH \$base
	prepend-path PATH \$base/bin
	prepend-path LD_LIBRARY_PATH \$base/${HYPRE_LIBDIR}
EOF
   fi

fi
