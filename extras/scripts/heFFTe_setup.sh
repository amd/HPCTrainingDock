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
MODULE_PATH=/etc/lmod/modules/ROCmPlus/heffte
BUILD_HEFFTE=1
ROCM_VERSION=6.2.0
SUDO="sudo"
AMDGPU_GFXMODEL_INPUT=""
# HEFFTE_VERSION holds the BARE numeric version (no leading 'v'); the
# script prepends 'v' where the upstream needs it (git tag) and uses the
# bare form everywhere else (install dir 'heffte-v${VERSION}', modulefile
# '${VERSION}.lua') so we match the fftw / hypre / hdf5 / petsc convention.
# 2.4.1 is what a --depth 1 clone of the upstream default branch yields;
# we pin the matching git tag v${HEFFTE_VERSION} for reproducibility.
HEFFTE_VERSION="2.4.1"
MPI_MODULE="openmpi"
HEFFTE_PATH=/opt/rocmplus-${ROCM_VERSION}/heffte-v${HEFFTE_VERSION}
INSTALL_PATH_INPUT=""
# --install-path: parent dir; the script appends heffte-v${HEFFTE_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf the prior heffte-v${HEFFTE_VERSION} install dir and
# its modulefile BEFORE building. Idempotent if nothing to remove.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so the
# partial install + modulefile are left on disk for post-mortem.
# Canonical template: extras/scripts/hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default is $MODULE_PATH "
   echo "  --install-path-no-version [ HEFFTE_PATH ] default is $HEFFTE_PATH "
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), HEFFTE_PATH = ROCMPLUS_PATH/heffte-v\${HEFFTE_VERSION}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL_INPUT ] default autodetected "
   echo "  --heffte-version [ HEFFTE_VERSION ] default is $HEFFTE_VERSION "
   echo "  --build-heffte [ BUILD_HEFFTE ] default is $BUILD_HEFFTE "
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
      "--build-heffte")
          shift
          BUILD_HEFFTE=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--heffte-version")
          shift
          # Strip optional leading 'v' so callers that pass either
          # 'v2.4.1' or '2.4.1' both land in the same canonical form.
          HEFFTE_VERSION=${1#v}
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
   HEFFTE_PATH=${INSTALL_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends heffte-v${HEFFTE_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for heffte.
   HEFFTE_PATH=${ROCMPLUS_PATH_INPUT}/heffte-v${HEFFTE_VERSION}
else
   # override path in case ROCM_VERSION or HEFFTE_VERSION has been supplied as input
   HEFFTE_PATH=/opt/rocmplus-${ROCM_VERSION}/heffte-v${HEFFTE_VERSION}
fi

# ── Install-path sudo (computed EARLY, before afar-skip/--replace) ────
# The afar-skip and --replace blocks below rm -rf the install dir +
# modulefile with ${SUDO}. The leaf default is SUDO=sudo, which on a
# cluster with no passwordless sudo and a user-owned install tree (this
# Cray) makes --replace / afar-skip die on a password prompt before the
# build even starts. Probe the nearest existing ancestor of the install
# dir for user-writability and drop sudo when we own it. Mirrors the
# hypre/magma/kokkos/petsc writability probe. The same SUDO then governs
# the build-branch install dir + chowns below. EUID 0 never needs sudo.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :  # already cleared (e.g. Singularity)
else
   _iprobe="$(dirname "${HEFFTE_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .heffte-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "heffte: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "heffte: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── BUILD_HEFFTE=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
# Placement: AFTER arg parsing + path resolution and BEFORE the --replace
# block (so --replace 1 + BUILD_HEFFTE=0 does NOT wipe an existing
# install -- "don't install" must not be confused with "wipe what is
# there"). Exits ${NOOP_RC}=43 so run_and_log classifies this as
# SKIPPED, not OK.
NOOP_RC=43
if [ "${BUILD_HEFFTE}" = "0" ]; then
   echo "[heffte BUILD_HEFFTE=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── afar SDK incompatibility detection ───────────────────────────────
# AMD's pre-release "AFAR" ROCm drops (rocm-afar-22.x, rocm-afar-7.0.5)
# are runtime-only / partial SDKs. heFFTe with Heffte_ENABLE_ROCM=ON
# calls find_package(rocfft) (and find_package(hip)); without the rocFFT
# CMake package config the configure step fails with "Could not find a
# package configuration file provided by 'rocfft'". Skip here so an AFAR
# SDK produces the correct SKIPPED(no-op) bucket rather than a FAILED
# build. Probe shape: gated on `${ROCM_PATH}` matching `*afar*` AND no
# rocfft-config.cmake present. Self-corrects if AMD ships rocFFT's cmake
# metadata in a future afar drop (matches the rocm-bundled hipfort policy
# in extras/scripts/hipfort_setup.sh, and the rocblas/rocthrust probes in
# hypre/kokkos).
if [[ "${ROCM_PATH:-}" == *afar* ]]; then
   if [[ -z "${ROCM_PATH:-}" ]] && type module >/dev/null 2>&1; then
      module load "rocm/${ROCM_VERSION}" 2>/dev/null || true
   fi
   if [ ! -f "${ROCM_PATH}/lib/cmake/rocfft/rocfft-config.cmake" ]; then
      echo ""
      echo "[heffte afar-skip] ROCM_PATH=${ROCM_PATH} is an AMD AFAR partial SDK"
      echo "                   missing : <ROCM_PATH>/lib/cmake/rocfft/rocfft-config.cmake"
      echo "                   heFFTe requires find_package(rocfft); cannot build on afar SDK."
      echo "                   Skipping (no source build, no cache restore)."
      echo ""
      if [ -d "${HEFFTE_PATH}" ]; then
         echo "[heffte afar-skip] removing stale from-source install: ${HEFFTE_PATH}"
         ${SUDO} rm -rf "${HEFFTE_PATH}"
      fi
      if [ -f "${MODULE_PATH}/${HEFFTE_VERSION}.lua" ] || [ -f "${MODULE_PATH}/${HEFFTE_VERSION}" ]; then
         echo "[heffte afar-skip] removing stale modulefile: ${MODULE_PATH}/${HEFFTE_VERSION}{.lua,}"
         ${SUDO} rm -f "${MODULE_PATH}/${HEFFTE_VERSION}.lua" "${MODULE_PATH}/${HEFFTE_VERSION}"
      fi
      # ── Drop a SKIPPED marker so the inventory tool can distinguish ──
      # "skipped on this SDK" from "absent / failed". See
      # bare_system/inventory_packages.py ('N' symbol -- Not possible to build on this SDK).
      _SKIP_MARKER_DIR="$(dirname "${HEFFTE_PATH}")"
      ${SUDO} mkdir -p "${_SKIP_MARKER_DIR}" 2>/dev/null || true
      if [ -d "${_SKIP_MARKER_DIR}" ]; then
         ${SUDO} tee "${_SKIP_MARKER_DIR}/heffte.SKIPPED" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: heffte
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    heFFTe_setup.sh (afar-skip guard)
Reason:          AFAR SDK is missing
                 <ROCM_PATH>/lib/cmake/rocfft/rocfft-config.cmake.
                 heFFTe requires find_package(rocfft); cannot build
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
# pass-through) wants this version's install dir + ${HEFFTE_VERSION}.lua
# wiped before a fresh install. Safe if nothing is there to remove.
# Other versions' installs are NOT touched (multi-version coexistence).
if [ "${REPLACE}" = "1" ]; then
   echo "[heffte --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HEFFTE_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${HEFFTE_VERSION}{.lua,}"
   ${SUDO} rm -rf "${HEFFTE_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${HEFFTE_VERSION}.lua" "${MODULE_PATH}/${HEFFTE_VERSION}"
fi

# ── Existence guard: skip if this version is already installed ───────
# Placement: AFTER the --replace block (so --replace 1 wipes first and
# this check passes through to a real rebuild) and BEFORE the EXIT trap
# install (so the NOOP_RC exit below is not interpreted as a partial
# install and does not trigger fail-cleanup of the install we just
# confirmed is intact). Exits with NOOP_RC=43; main_setup.sh's
# run_and_log records this as SKIPPED(no-op) in the per-package summary.
if [ -d "${HEFFTE_PATH}" ]; then
   echo ""
   echo "[heffte existence-check] ${HEFFTE_PATH} already installed; skipping."
   echo "                         pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ──────────
# On a non-zero exit (configure error, build error, install error,
# preflight miss, etc.) remove any partial artifacts this script left
# behind so the next sweep starts from a clean state. Skipped when
# --keep-failed-installs 1 (operator wants to inspect the partial
# install for post-mortem). Canonical template: hypre_setup.sh.
_heffte_on_exit() {
   local rc=$?
   # ── attempted-but-failed marker (inventory 'F' glyph) ─────────────
   # On failure, drop a persistent <pkg>.FAILED sibling of the install
   # dir so inventory_packages.py can tell "build attempted but failed"
   # (F) apart from "never attempted" (-). It survives the rm -rf below
   # because it lives in the rocmplus root, not inside HEFFTE_PATH. On a
   # clean exit we remove any stale marker from a prior failed run.
   local _fail_marker="$(dirname "${HEFFTE_PATH}")/heffte.FAILED"
   if [ ${rc} -ne 0 ]; then
      ${SUDO:-sudo} mkdir -p "$(dirname "${HEFFTE_PATH}")" 2>/dev/null || true
      ${SUDO:-sudo} tee "${_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: heffte
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    heFFTe_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_heffte_*.txt).
MARKER_EOF
   else
      ${SUDO:-sudo} rm -f "${_fail_marker}"
   fi
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[heffte fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HEFFTE_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${HEFFTE_VERSION}.lua" "${MODULE_PATH}/${HEFFTE_VERSION}"
   elif [ ${rc} -ne 0 ]; then
      echo "[heffte fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Clean the local build dir if set (source clone + build tree live
   # under /tmp via mktemp; see the HEFFTE_BUILD_DIR=mktemp call below).
   if [ -n "${HEFFTE_BUILD_DIR:-}" ] && [ -d "${HEFFTE_BUILD_DIR}" ]; then
      rm -rf "${HEFFTE_BUILD_DIR}"
   fi
   return ${rc}
}
trap _heffte_on_exit EXIT

echo ""
echo "==================================="
echo "Starting heFFTe Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HEFFTE: $BUILD_HEFFTE"
echo "HEFFTE_VERSION: $HEFFTE_VERSION"
echo "HEFFTE_PATH: $HEFFTE_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "MPI_MODULE: $MPI_MODULE"
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

if [ "${BUILD_HEFFTE}" = "0" ]; then

   echo "heFFTe will not be built, according to the specified value of BUILD_HEFFTE"
   echo "BUILD_HEFFTE: $BUILD_HEFFTE"
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

   if [ -f ${CACHE_FILES}/heffte-v${HEFFTE_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached heFFTe"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # heffte-v${HEFFTE_VERSION}.tgz and contain a top-level directory
      # heffte-v${HEFFTE_VERSION}/ so it lands directly at ${HEFFTE_PATH}
      # when extracted under /opt/rocmplus-X.
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/heffte-v${HEFFTE_VERSION}.tgz
      chown -R root:root ${HEFFTE_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/heffte-v${HEFFTE_VERSION}.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building heFFTe"
      echo "============================"
      echo ""

      # ── MPI module auto-correct on a Cray PE (see hypre/hdf5/netcdf) ──
      # heFFTe's cmake needs an MPI for find_package(MPI) -> mpicxx. The
      # leaf default MPI_MODULE is "openmpi", but a Cray system ships
      # cray-mpich (no openmpi module exists) -- preflight would SKIP the
      # whole build. If cray-mpich is active and the caller did not
      # override the MPI, switch to cray-mpich. main_setup.sh also threads
      # --mpi-module mpich-wrappers / cray-mpich; this makes the leaf
      # correct standalone too.
      if [ "${MPI_MODULE}" = "openmpi" ] \
           && { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; }; then
         MPI_MODULE="cray-mpich"
         echo "heffte: Cray MPICH detected; MPI_MODULE -> cray-mpich"
      fi

      # ── mpich-wrappers resolution (PrgEnv MPI) ────────────────────────
      # cray-mpich drives the build through cc/CC/ftn wrappers and does not
      # put mpicc/mpicxx on PATH, so cmake's find_package(MPI) cannot
      # locate it. The from-source mpich-wrappers leaf ships mpicc/mpicxx
      # (MPICH-ABI compatible with cray-mpich). When the caller asks for it
      # (main_setup threads --mpi-module mpich-wrappers), resolve the bare
      # name to the concrete, version-matched modulefile token by scanning
      # MODULEPATH. If none is found, fall back to cray-mpich.
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
            echo "heffte: using mpich-wrappers module '${_mw_tok}' (PrgEnv MPI; ships mpicc/mpicxx)"
         else
            echo "heffte: WARNING: --mpi-module mpich-wrappers requested but no mpich-wrappers modulefile found on MODULEPATH; falling back to cray-mpich"
            MPI_MODULE="cray-mpich"
         fi
         unset _mw_tok
      fi

      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── MPI hint for cmake's find_package(MPI) ───────────────────────
      # The stock openmpi module puts mpicxx on PATH, so find_package(MPI)
      # discovers the ROCm-aware OpenMPI wrappers directly (this is the
      # tested AAC6 path). The PrgEnv MPI modules don't export the
      # variables find_package(MPI) keys on: mpich-wrappers exports
      # MPICH_WRAPPERS_DIR (root has bin/mpicc + include + lib); cray-mpich
      # exports MPICH_DIR. Set MPI_HOME so cmake can locate the MPI even
      # when the wrappers aren't on PATH (harmless when they are).
      if [ -z "${MPI_HOME:-}" ]; then
         if [ -n "${MPICH_WRAPPERS_DIR:-}" ]; then
            export MPI_HOME="${MPICH_WRAPPERS_DIR}"
            echo "heffte: MPI_HOME set from MPICH_WRAPPERS_DIR -> ${MPI_HOME}"
         elif [ -n "${MPICH_DIR:-}" ]; then
            export MPI_HOME="${MPICH_DIR}"
            echo "heffte: MPI_HOME set from MPICH_DIR (cray-mpich) -> ${MPI_HOME}"
         fi
      fi

      ${SUDO} mkdir -p ${HEFFTE_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${HEFFTE_PATH}
      fi

      # Isolate the build under /tmp (compute-node local disk) instead of
      # PWD (the shared NFS HPCTrainingDock checkout). Without this,
      # concurrent rocm-version sweeps that hit the heffte step at the same
      # time collide on a single source tree and corrupt each other's
      # checkouts. Per-job /tmp dir gives each sweep its own scratch tree.
      # Cleanup is consolidated into _heffte_on_exit (which also handles
      # install rollback), see the trap registration earlier in this script.
      HEFFTE_BUILD_DIR=$(mktemp -d -t heffte-build.XXXXXX)
      cd "${HEFFTE_BUILD_DIR}"

      # heFFTe upstream tags are 'v<MAJ>.<MIN>.<MIC>' (e.g. v2.4.1); we
      # store HEFFTE_VERSION as the bare numeric form, so prepend 'v' here.
      # --depth 1 shallow clone of the pinned tag (matches the documented
      # build recipe, minimizes network/disk).
      git clone --depth 1 --branch v${HEFFTE_VERSION} https://github.com/icl-utk-edu/heffte.git
      cd heffte
      mkdir build && cd build

      # ── cmake configure ──────────────────────────────────────────────
      # Build heFFTe against rocFFT (Heffte_ENABLE_ROCM=ON) with the FFTW
      # CPU backend OFF, matching the documented recipe. HIP device code is
      # compiled by hipcc (CMAKE_CXX_COMPILER); find_package(MPI) discovers
      # the ROCm-aware MPI wrappers. AMDGPU_TARGETS / CMAKE_HIP_ARCHITECTURES
      # select the offload arch (semicolon-separated multi-arch is honored,
      # e.g. "gfx90a;gfx942"). GPU-aware MPI is enabled (on by default for
      # this configuration) so device buffers pass straight to MPI. Shared
      # libs (libheffte.so). CMAKE_INSTALL_LIBDIR pinned to lib/ so the
      # layout is identical across distros (GNUInstallDirs otherwise emits
      # lib64/ on RHEL-family; the lib64 probe below is a defensive fallback).
      HEFFTE_CMAKE_ARGS=(
         -DCMAKE_INSTALL_PREFIX="${HEFFTE_PATH}"
         -DCMAKE_INSTALL_LIBDIR=lib
         -DCMAKE_BUILD_TYPE=Release
         -DCMAKE_CXX_COMPILER="${ROCM_PATH}/bin/hipcc"
         -DBUILD_SHARED_LIBS=ON
         -DHeffte_ENABLE_ROCM=ON
         -DHeffte_ENABLE_FFTW=OFF
         -DHeffte_ENABLE_GPU_AWARE_MPI=ON
         -DAMDGPU_TARGETS="${AMDGPU_GFXMODEL}"
         -DCMAKE_HIP_ARCHITECTURES="${AMDGPU_GFXMODEL}"
      )
      [ -n "${ROCM_PATH:-}" ] && HEFFTE_CMAKE_ARGS+=( -DCMAKE_PREFIX_PATH="${ROCM_PATH}" )
      if [ -n "${MPI_HOME:-}" ]; then
         HEFFTE_CMAKE_ARGS+=( -DMPI_HOME="${MPI_HOME}" )
      fi

      cmake "${HEFFTE_CMAKE_ARGS[@]}" ..

      make -j
      ${SUDO} make install

      # Cleanup of ${HEFFTE_BUILD_DIR} (source clone + build tree) is
      # handled by the EXIT trap registered above. cd to / so subsequent
      # module-file generation isn't running from a dir about to be removed.
      cd /

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${HEFFTE_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${HEFFTE_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} chmod go-w ${HEFFTE_PATH}
      fi

      module unload ${MPI_MODULE} || true
      module unload ${ROCM_MODULE_NAME} || true

   fi

   # Create a module file for heffte
   #
   # Module-tree sudo + flavor: pick Lua (.lua) for Lmod, classic Tcl
   # (no ext) otherwise, and probe the module tree for user-writability
   # so a user-owned modulepath (this Cray) does not trigger a sudo
   # password prompt. Mirrors the hypre/magma/kokkos modulefile probe.
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
      _mtest=$(mktemp --tmpdir="${_mprobe}" .heffte-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         MOD_SUDO=""
         echo "heffte: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         MOD_SUDO="sudo"
         echo "heffte: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
      fi
      unset _mprobe _mtest
   fi
   ${MOD_SUDO} mkdir -p ${MODULE_PATH}

   # Detect the actual libdir: RHEL9/cmake GNUInstallDirs installs shared
   # libs to lib64, Debian/Ubuntu to lib. We pinned CMAKE_INSTALL_LIBDIR=lib
   # above, but probe defensively (covers the cached-tar branch too) so
   # LD_LIBRARY_PATH resolves libheffte.so and Heffte_DIR finds the config.
   if [ -d "${HEFFTE_PATH}/lib64/cmake/Heffte" ]; then
      HEFFTE_LIBDIR="lib64"
   else
      HEFFTE_LIBDIR="lib"
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
   # MPI module so downstream linking against libheffte picks up the same
   # MPI the library was built against.
   # HEFFTE_ROOT is the documented user-facing env var (see the build
   # recipe: `export HEFFTE_ROOT=$HOME/heffte-rocm`); Heffte_ROOT / Heffte_DIR
   # are the CMake find_package(Heffte) conventions so downstream cmake
   # consumers resolve the package without hardcoding paths.
   # ROCm prereq: accept rocm-new/<ver> OR rocm/<ver>. Under PrgEnv-amd-new
   # the loaded ROCm module is rocm-new/<ver>, not rocm/<ver>, so a plain
   # `prereq rocm/<ver>` fails there. Mirrors hypre/hdf5/petsc.
   _RPV="${ROCM_MODULE_NAME##*/}"
   case "${ROCM_MODULE_NAME}" in
      rocm/*|rocm-new/*)
         ROCM_PREREQ_TCL="rocm-new/${_RPV} rocm/${_RPV}"
         ROCM_PREREQ_LUA="prereq_any(\"rocm-new/${_RPV}\", \"rocm/${_RPV}\")"
         ;;
      *)
         ROCM_PREREQ_TCL="${ROCM_MODULE_NAME}"
         ROCM_PREREQ_LUA="prereq(\"${ROCM_MODULE_NAME}\")"
         ;;
   esac
   unset _RPV

   HEFFTE_MODULEFILE="${MODULE_PATH}/${HEFFTE_VERSION}${MODEXT}"
   if [ "${MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${MOD_SUDO} tee ${HEFFTE_MODULEFILE}
	whatis("heFFTe ${HEFFTE_VERSION} - Highly Efficient FFT for Exascale (ROCm/rocFFT backend)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${HEFFTE_PATH}"

	${ROCM_PREREQ_LUA}
	load("${MPI_MODULE}")
	setenv("HEFFTE_ROOT", base)
	setenv("HEFFTE_PATH", base)
	setenv("Heffte_ROOT", base)
	setenv("Heffte_DIR", pathJoin(base, "${HEFFTE_LIBDIR}/cmake/Heffte"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "${HEFFTE_LIBDIR}"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("CMAKE_PREFIX_PATH", base)
EOF
   else
      cat <<-EOF | ${MOD_SUDO} tee ${HEFFTE_MODULEFILE}
	#%Module1.0
	module-whatis "heFFTe ${HEFFTE_VERSION} - Highly Efficient FFT for Exascale (ROCm/rocFFT backend)"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${HEFFTE_PATH}"

	prereq ${ROCM_PREREQ_TCL}
	if { ![ is-loaded ${MPI_MODULE} ] } { module load ${MPI_MODULE} }
	setenv HEFFTE_ROOT \$base
	setenv HEFFTE_PATH \$base
	setenv Heffte_ROOT \$base
	setenv Heffte_DIR \$base/${HEFFTE_LIBDIR}/cmake/Heffte
	prepend-path PATH \$base/bin
	prepend-path LD_LIBRARY_PATH \$base/${HEFFTE_LIBDIR}
	prepend-path CPATH \$base/include
	prepend-path CMAKE_PREFIX_PATH \$base
EOF
   fi

fi
