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
MODULE_PATH=/etc/lmod/modules/ROCmPlus/petsc
BUILD_PETSC=0
ROCM_VERSION=6.2.0
PETSC_VERSION="3.24.1"
# Versioned install root: /opt/rocmplus-X/petsc-v${PETSC_VERSION}.
# The petsc / slepc / eigen subdirs live under this (slepc is also
# checked out at v$PETSC_VERSION, line ~438; eigen tracks 5.0.0).
# Versioning the GROUP root lets multiple petsc releases coexist
# without colliding on /opt/rocmplus-X/petsc.
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/petsc-v${PETSC_VERSION}
INSTALL_PATH_INPUT=""
# --install-path: parent dir; the script appends petsc-v${PETSC_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
# Note: --use-amdflang 1 still appends _amdflang to whichever path wins.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf prior install dir + ${PETSC_VERSION}.lua before build.
# (When --use-amdflang 1, the suffix _amdflang is added to BOTH paths
# so we always clean whatever the resolved INSTALL_PATH/MODULE_PATH is.)
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"
USE_SPACK=0
USE_AMDFLANG=0
AMDFLANG_RELEASE_NUMBER="6.0.0"
MPI_MODULE="openmpi"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

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
   echo "  WARNING: when selecting the module to supply to --mpi-module, make sure it sets the MPI_PATH environment variable"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path-no-version [ INSTALL_PATH_INPUT ] default $INSTALL_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), INSTALL_PATH = ROCMPLUS_PATH/petsc-v\${PETSC_VERSION}"
   echo "  --use-amdflang [ USE_AMDFLANG ] set to 1 to build petsc with the AMD next generation Fortran compiler, default $USE_AMDFLANG"
   echo "  --amdflang-release-number [ AMDFLANG_RELEASE_NUMBER ] default $AMDFLANG_RELEASE_NUMBER. Note: this flag is only used if --use-amdflang 1 is specified."
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --petsc-version [ PETSC_VERSION ] default $PETSC_VERSION"
   echo "  --use-spack [ USE_SPACK ] default $USE_SPACK"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --build-petsc [ BUILD_PETSC ] default is 0"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--build-petsc")
          shift
          BUILD_PETSC=${1}
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
      "--mpi-module")
          shift
          MPI_MODULE=${1}
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
      "--petsc-version")
          shift
          PETSC_VERSION=${1}
          reset-last
          ;;
      "--use-spack")
          shift
          USE_SPACK=${1}
          reset-last
          ;;
      "--use-amdflang")
          shift
          USE_AMDFLANG=${1}
          reset-last
          ;;
      "--amdflang-release-number")
          shift
          AMDFLANG_RELEASE_NUMBER=${1}
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
   INSTALL_PATH=${INSTALL_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends petsc-v${PETSC_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for petsc.
   INSTALL_PATH=${ROCMPLUS_PATH_INPUT}/petsc-v${PETSC_VERSION}
else
   # override path in case ROCM_VERSION or PETSC_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/petsc-v${PETSC_VERSION}
fi

if [[ "${USE_AMDFLANG}" == 1 ]]; then
   INSTALL_PATH=${INSTALL_PATH}_amdflang
   MODULE_PATH=${MODULE_PATH}_amdflang
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${PETSC_VERSION}.lua. Note that when --use-amdflang 1
# both INSTALL_PATH and MODULE_PATH already have _amdflang appended above.
# ── BUILD_PETSC=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_PETSC}" = "0" ]; then
   echo "[petsc BUILD_PETSC=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── Early sudo decision (see hdf5_setup.sh / mpi4py_setup.sh) ────────
# Determine whether privilege escalation is needed BEFORE the --replace
# block and EXIT trap (both rm install/module paths via ${SUDO}). When the
# operator owns a writable install tree (e.g. a user-writable
# /shareddata/opt on a Cray) no sudo is needed -- and forcing it would hit a
# password prompt that fails on a node where the user has no sudo. Probe the
# nearest EXISTING ancestor of INSTALL_PATH (the leaf dir does not exist
# yet). The build branch re-affirms this below.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _probe="${INSTALL_PATH}"
   while [ ! -e "${_probe}" ]; do _probe="$(dirname "${_probe}")"; done
   # Real write test (mktemp), NOT `[ -w ]`: on NFS `-w` is a LYING probe --
   # it reports "writable" on a root:root 0755 tree (e.g. /nfsapps) where the
   # actual write / rm then fails (the netcdf_setup.sh lying-probe failure
   # mode). Mirrors the hdf5/fftw/hypre/kokkos mktemp probe.
   _wtest=$(mktemp --tmpdir="${_probe}" .petsc-write-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_wtest}" ] && [ -f "${_wtest}" ]; then
      rm -f "${_wtest}"
      SUDO=""
      echo "install path ancestor ${_probe} is writable (probe succeeded); not using sudo"
   else
      echo "install path ancestor ${_probe} not user-writable (probe failed); using sudo"
   fi
   unset _probe _wtest
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[petsc --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${PETSC_VERSION}{,.lua}"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   # Remove both flavors (Lmod .lua and Tcl no-extension).
   ${SUDO} rm -f  "${MODULE_PATH}/${PETSC_VERSION}.lua" "${MODULE_PATH}/${PETSC_VERSION}"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
# Note: when --use-amdflang 1 was passed, INSTALL_PATH already had
# _amdflang appended above, so this checks the toolchain-specific dir.
NOOP_RC=43
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[petsc existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                        pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# PETSC_BUILD_DIR + spack user-scope dirs (all set under the source-build
# branch) are cleaned here too, so this single EXIT trap does both jobs. A
# prior separate `trap '... rm PETSC_BUILD_DIR ...' EXIT` further down
# OVERWROTE this handler, silently disabling fail-cleanup of a partial
# install -- folded in here to match hdf5/fftw.
PETSC_BUILD_DIR=""
SPACK_USER_CONFIG_PATH=""
SPACK_USER_CACHE_PATH=""
_petsc_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[petsc fail-cleanup] rc=${rc}: removing partial install + modulefile"
      # ${SUDO} verbatim (NOT ${SUDO:-sudo}): the early-probe may set SUDO=""
      # for an operator-writable tree, and cleanup must then run WITHOUT sudo.
      ${SUDO} rm -rf "${INSTALL_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/${PETSC_VERSION}.lua" "${MODULE_PATH}/${PETSC_VERSION}"
   elif [ ${rc} -ne 0 ]; then
      echo "[petsc fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Scratch build dir + spack user-scope dirs (user-owned /tmp mktemp dirs)
   # -- never need sudo (plain rm; the early-probe may set SUDO="" and
   # ${SUDO:-sudo} would WRONGLY force a sudo password prompt on these).
   # Preserve the build dir on failure when KEEP_FAILED_INSTALLS=1 so the
   # external-package / slepc configure.log files survive for post-mortem.
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" = "1" ]; then
      echo "[petsc fail-cleanup] KEEP_FAILED_INSTALLS=1: leaving build dir ${PETSC_BUILD_DIR} for post-mortem"
   else
      rm -rf "${PETSC_BUILD_DIR:-/nonexistent}" "${SPACK_USER_CONFIG_PATH:-/nonexistent}" "${SPACK_USER_CACHE_PATH:-/nonexistent}"
   fi
   return ${rc}
}
trap _petsc_on_exit EXIT

echo ""
echo "==================================="
echo "Starting PETSC Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_PETSC: $BUILD_PETSC"
echo "Installing PETSc in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "USE_SPACK: $USE_SPACK"
echo "USE_AMDFLANG: $USE_AMDFLANG"
echo "Loading this module for MPI: $MPI_MODULE"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
AMDGPU_GFXMODEL=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/,/g'`

if [ "${BUILD_PETSC}" = "0" ]; then

   echo "PETSC will not be built, according to the specified value of BUILD_PETSC"
   echo "BUILD_PETSC: $BUILD_PETSC"
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
   ROCM_MODULE_NAME=""
   if [[ -n "${LOADEDMODULES:-}" ]]; then
      # Two-pass: prefer a rocm/* whose version matches the REQUESTED
      # ROCM_VERSION (a shell may have several rocm/* loaded, e.g. a Cray
      # default env with both rocm/7.0.3 and rocm/7.2.3 -- picking the first
      # match would wrongly key the build/modulefile on the wrong SDK).
      # Fall back to the first rocm/* if none matches the version exactly.
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

   if [ -f "${CACHE_FILES}/petsc-v${PETSC_VERSION}.tgz" ]; then
      echo ""
      echo "============================"
      echo " Installing Cached PETSC v${PETSC_VERSION}"
      echo "============================"
      echo ""

      # install the cached version. Tarball top-level dir is
      # petsc-v${PETSC_VERSION}/{petsc,slepc,eigen} -- matches the
      # versioned INSTALL_PATH layout used by the from-source branch.
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xpzf ${CACHE_FILES}/petsc-v${PETSC_VERSION}.tgz
      ${SUDO} chown -R root:root ${INSTALL_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/petsc-v${PETSC_VERSION}.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building PETSC"
      echo "============================"
      echo ""

      # ── MPI module auto-correct on a Cray PE (see hdf5/netcdf/fftw) ──
      # The leaf default MPI_MODULE is "openmpi", but a Cray system ships
      # cray-mpich (no openmpi module exists) -- preflight would fail. If
      # cray-mpich is active and the caller did not override the MPI, switch
      # to cray-mpich so the prereq load and the parallel build use the
      # PrgEnv's own MPI. (main_setup.sh also threads --mpi-module
      # mpich-wrappers / cray-mpich when MPICH_DIR is set; this makes the
      # leaf correct standalone too.)
      if [ "${MPI_MODULE}" = "openmpi" ] \
           && { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; }; then
         MPI_MODULE="cray-mpich"
         echo "PETSc: Cray MPICH detected; MPI_MODULE -> cray-mpich"
      fi

      # ── mpich-wrappers resolution (new-flang mpi.mod on a Cray) ──────
      # cray-mpich's amd/rocm-compiler mpi.mod is CLASSIC-Flang V34, which
      # the new LLVM Flang (amdflang / ftn on ROCm 7.x) cannot read. The
      # mpich-wrappers leaf builds a standalone MPICH with FC=amdflang
      # (NEW-flang mpi.mod, MPICH-ABI compatible with cray-mpich) and ships
      # mpicc/mpicxx/mpif90 -- exactly what PETSc --with-mpi-dir wants. When
      # the caller asks for it (main_setup threads --mpi-module
      # mpich-wrappers), resolve the bare name to the concrete,
      # version-matched modulefile token by scanning MODULEPATH. If none is
      # found, fall back to cray-mpich.
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
            echo "PETSc: using mpich-wrappers module '${_mw_tok}' (new-flang mpi.mod)"
         else
            echo "PETSc: WARNING: --mpi-module mpich-wrappers requested but no mpich-wrappers modulefile found on MODULEPATH; falling back to cray-mpich"
            MPI_MODULE="cray-mpich"
         fi
         unset _mw_tok
      fi

      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" )
      if [[ ${USE_AMDFLANG} == "1" ]]; then
         # AFAR amdflang-new wraps openmpi compilers; loaded BEFORE the
         # MPI module so the MPI module sees the right Fortran compiler.
         # AFAR releases: https://repo.radeon.com/rocm/misc/flang/
         REQUIRED_MODULES+=( "amdflang-new/rocm-afar-${AMDFLANG_RELEASE_NUMBER}" )
      fi
      REQUIRED_MODULES+=( "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── MPI_PATH derivation (PrgEnv MPI modules don't set MPI_PATH) ──
      # PETSc's --with-mpi-dir needs a root with bin/mpicc, bin/mpif90,
      # include/mpi.h, lib/libmpi*. The from-source mpich-wrappers module
      # exports MPICH_WRAPPERS_DIR (its install root, which has exactly that
      # layout); cray-mpich exports MPICH_DIR. Neither sets MPI_PATH, so
      # derive it here when an MPI module didn't. Prefer mpich-wrappers
      # (new-flang mpif90) so PETSc's Fortran bindings match what users
      # compile with on ROCm 7.x.
      if [ -z "${MPI_PATH:-}" ]; then
         if [ -n "${MPICH_WRAPPERS_DIR:-}" ]; then
            MPI_PATH="${MPICH_WRAPPERS_DIR}"
            echo "PETSc: MPI_PATH derived from MPICH_WRAPPERS_DIR -> ${MPI_PATH}"
         elif [ -n "${MPICH_DIR:-}" ]; then
            MPI_PATH="${MPICH_DIR}"
            echo "PETSc: MPI_PATH derived from MPICH_DIR (cray-mpich) -> ${MPI_PATH}"
         fi
         export MPI_PATH
      fi
      if [[ $MPI_PATH == "" ]]; then
         echo "MPI module $MPI_MODULE is not setting the MPI_PATH env variable, aborting..."
         exit 1
      fi

      # ---------------------------------------------------------------------
      # Classic-Flang detection (audit_2026_05_07.md / chat 2026-05-07).
      #
      # ROCm 6.x ships amdflang-classic (an LLVM-Flang derivative based on
      # the legacy PGI/F18 frontend). Its kind for `logical(c_bool)` is
      # NOT interoperable with C `_Bool`, so PETSc's BindingsFortran
      # configure check rejects it and the whole configure aborts. Verified
      # failure pattern (sweeps 8492-8498):
      #   6.3.0/8493, 6.3.3/8494, 6.3.4/8492, 6.4.0/8495,
      #   6.4.2/8498, 6.4.3/8497, 6.4.4/8496
      # all bail at the same point during PETSc 3.24.1 configure with
      # "Fortran compiler does not support BIND(C) for type(c_bool)".
      #
      # Probe `mpif90 --version`. amdflang-classic reports
      #   "flang-classic version 18.0.0 ..."   (ROCm 6.3.x)
      #   "flang-classic version 19.0.0 ..."   (ROCm 6.4.x)
      # whereas amdflang-new (ROCm 7.x and afar) reports
      #   "AMD flang version 22.x.x ..."       (no "classic" substring).
      # When classic flang is detected we degrade gracefully:
      #   non-spack: append --with-fortran-bindings=0 to ./configure
      #   spack    : flip +fortran -> -fortran in the spec
      # PETSc still builds; C/C++/HIP users are unaffected; petsc4py and
      # native Fortran callers lose bindings on those rocms only. This is
      # a deliberate trade vs the prior behavior of FAILED-with-no-install.
      # Numbered ROCm 7.x and afar SDKs keep the default (+fortran /
      # --with-fortran-bindings=1), no change for them.
      # ---------------------------------------------------------------------
      PETSC_FORTRAN_FLAG="--with-fortran-bindings=1"
      PETSC_SPACK_FORTRAN_VARIANT="+fortran"
      if [[ -x "${MPI_PATH}/bin/mpif90" ]]; then
         _mpif90_banner=$("${MPI_PATH}/bin/mpif90" --version 2>&1 | head -n 5 || true)
         if echo "${_mpif90_banner}" | grep -qi "flang-classic"; then
            echo ""
            echo "[petsc classic-Flang detected] mpif90 wraps amdflang-classic:"
            echo "${_mpif90_banner}" | sed 's/^/    /'
            echo "[petsc classic-Flang detected] -> Fortran bindings DISABLED"
            echo "[petsc classic-Flang detected]    (configure: --with-fortran-bindings=0;"
            echo "[petsc classic-Flang detected]     spack: -fortran)"
            echo ""
            PETSC_FORTRAN_FLAG="--with-fortran-bindings=0"
            PETSC_SPACK_FORTRAN_VARIANT="-fortran"
         fi
         unset _mpif90_banner
      fi

      # don't use sudo if user has write access to install path
      if [ -d "$INSTALL_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      PETSC_PATH=${INSTALL_PATH}/petsc
      SLEPC_PATH=${INSTALL_PATH}/slepc
      EIGEN_PATH=${INSTALL_PATH}/eigen
      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${PETSC_PATH}
      ${SUDO} mkdir -p ${SLEPC_PATH}
      ${SUDO} mkdir -p ${EIGEN_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      # ---------------------------------------------------------------------
      # Per-job throwaway build dir on local disk for BOTH branches
      # (audit_2026_05_01.md Issue 6).
      #
      # Original layout had the mktemp+trap inside the USE_SPACK==1 branch
      # only.  The non-spack branch then cloned petsc_to_install/,
      # slepc_to_install/, eigen_to_install/ directly into the script's CWD
      # -- which on the build hosts is ${HOME}/repos/HPCTrainingDock (NFS).
      # PETSc's `make install` uses Python `shutil.copy2` to copy ~600
      # headers, and copying NFS-mount-A -> NFS-mount-B trips
      # `[Errno 524] ENOTSUPP` for xattrs/timestamp metadata, aborting
      # the install (verified in
      # logs_05_01_2026/rocm-7.2.1_7959/log_petsc_05_01_2026.txt).
      #
      # Hoisting the build dir to /tmp turns the install copy into
      # local-disk -> NFS, which `shutil.copy2` handles cleanly.
      # The EXIT trap also covers the spack user-scope dirs (set further
      # down in the spack branch), with `:-/nonexistent` guards so the
      # trap is harmless when those vars are unset (non-spack runs).
      # ---------------------------------------------------------------------
      # PETSC_BUILD_DIR (+ the spack user-scope dirs set in the spack branch)
      # are cleaned by the _petsc_on_exit trap installed above; a separate
      # trap here would overwrite that handler and disable fail-cleanup.
      PETSC_BUILD_DIR=$(mktemp -d -t petsc-build.XXXXXX)
      cd "${PETSC_BUILD_DIR}"

      if [[ $USE_SPACK == 1 ]]; then

         # ------------ Installing PETSC

         echo " WARNING: installing petsc with spack: the build is a work in progress, fails can happen..."

         # PKG_SUDO: apt needs root regardless of install-path SUDO.
         # The previous `[[ ${SUDO} != "" ]]` guard skipped libssl-dev
         # whenever the install path was admin-writable, leading to a
         # spack build that silently failed when libevent couldn't
         # find openssl. See openmpi_setup.sh / audit_2026_05_01.md
         # Issue 2.
         PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
         ${PKG_SUDO} apt-get update
         ${PKG_SUDO} apt-get install -y libssl-dev

         # Spack user-scope isolation: see scorep_setup.sh for full
         # rationale. Per-job throwaway dirs keep `spack external
         # find --all` from polluting ~/.spack/packages.yaml across
         # rocm versions and prevent any stale user-scope
         # install_tree.root from over-riding the defaults edit below.
         # The EXIT trap installed above already covers cleanup of
         # these two paths.
         SPACK_USER_CONFIG_PATH=$(mktemp -d -t spack-user-config.XXXXXX)
         SPACK_USER_CACHE_PATH=$(mktemp -d -t spack-user-cache.XXXXXX)
         export SPACK_USER_CONFIG_PATH SPACK_USER_CACHE_PATH

         git clone https://github.com/spack/spack.git

         # load spack environment
         source spack/share/spack/setup-env.sh

         # Tolerate missing hdf5 module under `set -e` (line 12). If the
         # hdf5 sweep failed earlier, an unguarded `module load hdf5` would
         # abort the whole script before spack ever runs. With ||true the
         # script continues; spack will pick up whatever hdf5 it finds via
         # `spack external find` (or build its own as a normal dependency).
         module load hdf5 2>/dev/null || true

         # find already installed libs for spack: include --all otherwise ROCm libs will not be found
         spack external find --all

	 spack install rocm-core@${ROCM_VERSION} rocm-cmake@${ROCM_VERSION} hipblas-common@${ROCM_VERSION} rocthrust@${ROCM_VERSION} rocprim@${ROCM_VERSION}

         # change spack install dir for Hypre
         sed -i 's|$spack/opt/spack|'"${PETSC_PATH}"'|g' spack/etc/spack/defaults/base/config.yaml 

         # install petsc with spack, some variants are not specified because true by default.
         # PETSC_SPACK_FORTRAN_VARIANT is +fortran by default but flips to -fortran when
         # classic-Flang is detected upstream (see classic-Flang block above).
         spack install petsc@$PETSC_VERSION+rocm${PETSC_SPACK_FORTRAN_VARIANT}+mumps+suite-sparse amdgpu_target=$AMDGPU_GFXMODEL

         # get petsc install dir created by spack
         PETSC_PATH_ORIGINAL=$PETSC_PATH
         PETSC_PATH=$(spack location -i petsc)

         # PETSC_BUILD_DIR (under /tmp, contains the spack clone)
         # is removed by the EXIT trap above.

      else

         # petsc install
         git clone --branch v$PETSC_VERSION https://gitlab.com/petsc/petsc.git petsc_to_install
         cd petsc_to_install
         PETSC_REPO=$PWD

         # Patch ScaLAPACK.py: override CDEFS to fix broken Fortran mangling
         # detection with AMD flang (LLVMFlang) in ScaLAPACK's CMake
         python3 -c "
import os
f = os.path.join('config','BuildSystem','config','packages','ScaLAPACK.py')
txt = open(f).read()
old = '''  def formCMakeConfigureArgs(self):
    args = config.package.CMakePackage.formCMakeConfigureArgs(self)
    args.append('-DLAPACK_LIBRARIES=\"'+self.libraries.toString(self.blasLapack.dlib)+'\"')
    args.append('-DSCALAPACK_BUILD_TESTS=OFF')
    return args'''
new = '''  def formCMakeConfigureArgs(self):
    args = config.package.CMakePackage.formCMakeConfigureArgs(self)
    args.append('-DLAPACK_LIBRARIES=\"'+self.libraries.toString(self.blasLapack.dlib)+'\"')
    args.append('-DSCALAPACK_BUILD_TESTS=OFF')
    if self.compilers.fortranManglingDoubleUnderscore:
      args.append('-DCDEFS=Add__')
    elif self.compilers.fortranMangling == \"underscore\":
      args.append('-DCDEFS=Add_')
    elif self.compilers.fortranMangling == \"caps\":
      args.append('-DCDEFS=UPPER')
    elif self.compilers.fortranMangling == \"unchanged\":
      args.append('-DCDEFS=NOCHANGE')
    return args'''
assert old in txt, 'ScaLAPACK.py patch target not found; the file may have changed'
open(f,'w').write(txt.replace(old, new))
print('ScaLAPACK.py patched successfully')
"

         # Patch matdensecupmimpl.h: add <cuda/std/iterator> include for
         # CCCL 3.0+ rocms (rocm-therock-23.2.0 today; presumably rocm 7.3+
         # later). PETSc 3.24.1 line 310 uses cuda::std::iter_difference_t<T>
         # under #if CCCL_VERSION >= 3000000 but never includes the header
         # that actually defines it -- it relies on thrust transitively
         # pulling in cuda::std symbols, which works on CCCL 2.x but not 3.x.
         # Result on therock-23.2.0 (CCCL 3000002): 13 cascading compile
         # errors in matmpidensehip.cpp / matseqdensehip.cpp -- iter_difference_t
         # undeclared at line 310, then base_type / difference_type / iterator
         # undeclared in MatrixIteratorBase / DiagonalIterator / SubMatrixIterator
         # (slurm 8225, 2026-05-05).
         #
         # Shell-guarded on the CCCL header presence so the patch only runs
         # on rocms that actually ship libcudacxx. Numbered 7.0.0 ... 7.2.1
         # have no <cuda/std/...> headers (verified by inspection), so the
         # source tree on those builds remains byte-identical to upstream
         # PETSc 3.24.1. Easy to tell at a glance which build flavor a given
         # install came from: grep cuda/std/iterator
         # ${PETSC_PATH}/include/petsc/private/matdensecupmimpl.h.
         if [ -n "${ROCM_PATH:-}" ] && [ -f "${ROCM_PATH}/include/cuda/std/__cccl/version.h" ]; then
            echo "petsc: detected libcudacxx (CCCL) under ${ROCM_PATH}/include/cuda/std/ -- applying matdensecupmimpl.h cuda/std/iterator patch"
            python3 -c "
import os
f = os.path.join('include','petsc','private','matdensecupmimpl.h')
txt = open(f).read()
old = '#include <thrust/copy.h>'
new = '''#include <thrust/copy.h>
  #if __has_include(<cuda/std/iterator>)
    #include <cuda/std/iterator>
  #endif'''
assert old in txt, 'matdensecupmimpl.h thrust/copy.h anchor not found; the file may have changed'
assert new not in txt, 'matdensecupmimpl.h cuda/std/iterator patch already applied'
open(f,'w').write(txt.replace(old, new))
print('matdensecupmimpl.h patched: added <cuda/std/iterator> for CCCL 3.0+')
"
         else
            echo "petsc: no libcudacxx detected (no ${ROCM_PATH:-<unset>}/include/cuda/std/__cccl/version.h) -- skipping matdensecupmimpl.h cuda/std/iterator patch"
         fi

         # System hdf5 is OPTIONAL: if its module loads cleanly we use it
         # (DOWNLOAD_HDF5=0 -> --download-hdf5=0); otherwise we fall back
         # to PETSc's own internal hdf5 build (DOWNLOAD_HDF5=1 ->
         # --download-hdf5=1). The 2>/dev/null||true is essential under
         # `set -e` (line 12): without it, a missing hdf5 module (e.g.
         # because hdf5_setup.sh itself failed earlier in the same sweep)
         # would abort the script with rc=1 BEFORE the if-test below ever
         # runs, defeating the fallback design. Verified failure pattern:
         # 6.4.0/8391, 6.4.3/8388, 6.3.0/8440, 6.3.4/8436, 7.0.0/8185,
         # 7.13.0/8186 -- 30-line petsc logs that all bail at this exact
         # line in lockstep with the parent sweep's hdf5(rc=1) failure.
         DOWNLOAD_HDF5=1
         module load hdf5 2>/dev/null || true
         if [[ -n "${HDF5_PATH:-}" ]]; then
            DOWNLOAD_HDF5=0
         fi

         # ── Operator escape-hatch: pre-staged external-package tarballs ──
         # PETSc --download-<pkg>=1 fetches each external package over the
         # network. Several (fblaslapack, metis, parmetis) are hosted ONLY on
         # bitbucket.org, and the per-package fallback mirror is
         # web.cels.anl.gov. On clusters whose proxy blocks BOTH (this Cray
         # closes bitbucket.org with SSL_ERROR_ZERO_RETURN and the ANL mirror
         # is unreachable too, on login AND compute nodes), configure dies at
         # "Unable to download package FBLASLAPACK". When PETSC_PACKAGES_DOWNLOAD_DIR
         # is set to a directory pre-populated (from a host with access) with
         # the package tarballs PETSc lists, pass it as
         # --with-packages-download-dir: configure then reads tarballs from
         # there (no network) and, if any are missing, prints the exact URLs
         # to stage. main_setup.sh auto-detects /shareddata/src/petsc-pkgs.
         # NOTE: with --with-packages-download-dir, ALL --download-* packages
         # must be present in the dir (configure will not fall back to the
         # network for any of them).
         PETSC_PKG_DOWNLOAD_OPT=""
         if [ -n "${PETSC_PACKAGES_DOWNLOAD_DIR:-}" ] && [ -d "${PETSC_PACKAGES_DOWNLOAD_DIR}" ]; then
            PETSC_PKG_DOWNLOAD_OPT="--with-packages-download-dir=${PETSC_PACKAGES_DOWNLOAD_DIR}"
            echo "petsc: using operator-staged package dir ${PETSC_PACKAGES_DOWNLOAD_DIR} (--with-packages-download-dir; no network)"
         fi

         # ── gcc-toolset C++ runtime mismatch fix (see netcdf/PnetCDF) ───
         # On this Cray the toolchains used to build PETSc disagree on their
         # GCC backend: mpicc/mpicxx (mpich-wrappers) drive gcc-toolset-14's
         # gcc/g++, but ROCm's amdclang++ (HIP/device sources) selects
         # gcc-toolset-12. The C++ TUs compiled via mpicxx (gcc-14 headers)
         # reference libstdc++ symbols that exist only in GCC >= 13/14
         # (std::ios_base_library_init(), __cxa_call_terminate,
         # std::__cxx11::...::_M_replace_cold), which gcc-toolset ships in a
         # STATIC libstdc++_nonshared.a. libpetsc.so is linked by the C
         # linker (mpicc = gcc-14 gcc), which adds a bare `-lstdc++` -- but
         # PETSc's own link line lists the gcc-toolset-12 lib dir FIRST (from
         # amdclang's auto-detected paths), so `-lstdc++` resolves to
         # gcc-toolset-12's libstdc++ whose nonshared.a LACKS those symbols.
         # libpetsc.so then has them UNDEFINED (shared libs allow that) and
         # the next consumer link -- SLEPc's configure "checklink" -- fails:
         #   libpetsc.so: undefined reference to `std::ios_base_library_init()'
         # (verified rocm-7.2.3 / mpich-wrappers, RHEL 9). Fix: prepend the
         # gcc-toolset dir that DOES define the symbol (the one mpicxx uses)
         # via LDFLAGS, so `-lstdc++` resolves to that toolset's libstdc++ ld
         # script -- which pulls in its nonshared.a -- and libpetsc.so embeds
         # the symbols, becoming self-contained for SLEPc, Eigen, and
         # end-user links. LDFLAGS is just a search path, so PETSc's trivial
         # compiler/MPI sanity checks are unaffected (a bare LIBS archive or
         # --whole-archive breaks those checks; a -L does not).
         PETSC_LDFLAGS_OPT=""
         _ns_dir=""
         for _d in $(ls -d /opt/rh/gcc-toolset-*/root/usr/lib/gcc/x86_64-redhat-linux/* 2>/dev/null | sort -Vr); do
            _cand="${_d}/libstdc++_nonshared.a"
            # grep -c (not -q): under `set -eo pipefail` grep -q closes the
            # pipe on first match -> nm gets SIGPIPE -> archive silently never
            # selected. grep -c reads the whole stream (no early close).
            [ -f "${_cand}" ] || continue
            _ns_cnt=$(nm -C "${_cand}" 2>/dev/null | grep -c "ios_base_library_init" || true)
            if [ "${_ns_cnt:-0}" -gt 0 ]; then
               _ns_dir="${_d}"; break
            fi
         done
         unset _ns_cnt _cand _d
         if [ -n "${_ns_dir}" ]; then
            PETSC_LDFLAGS_OPT="LDFLAGS=-L${_ns_dir}"
            echo "petsc: prepending ${_ns_dir} via LDFLAGS so -lstdc++ resolves the gcc-toolset libstdc++ that defines std::ios_base_library_init (for the gcc-14/clang-12 mismatch)"
         fi
         unset _ns_dir

         # PETSC_FORTRAN_FLAG is --with-fortran-bindings=1 by default but flips to
         # --with-fortran-bindings=0 when classic-Flang is detected upstream
         # (see classic-Flang block above). Built as an array so args that
         # contain spaces (COPTFLAGS, and the LDFLAGS="-L<dir>" from the
         # gcc-toolset compat block) are passed as single tokens.
         CONFIG_ARGS=(
            --with-debugging=0 --with-x=0
            COPTFLAGS="-O3 -march=native -mtune=native"
            CXXOPTFLAGS="-O3 -march=native -mtune=native"
            FOPTFLAGS="-O3 -march=native -mtune=native"
            HIPOPTFLAGS="-O3 -march=native -mtune=native"
            --download-fblaslapack=1 --download-hdf5=$DOWNLOAD_HDF5 --download-metis=1
            --download-parmetis=1 --with-shared-libraries=1 --download-blacs=1
            --download-scalapack=1 --download-mumps=1 --download-suitesparse=1
            --with-hip-arch=$AMDGPU_GFXMODEL --with-mpi=1 --with-mpi-dir=$MPI_PATH
            --prefix=$PETSC_PATH --with-hip=1 --with-hip-dir=$ROCM_PATH
            ${PETSC_FORTRAN_FLAG}
         )
         [ -n "${PETSC_PKG_DOWNLOAD_OPT}" ] && CONFIG_ARGS+=( "${PETSC_PKG_DOWNLOAD_OPT}" )
         [ -n "${PETSC_LDFLAGS_OPT}" ] && CONFIG_ARGS+=( "${PETSC_LDFLAGS_OPT}" )
         ./configure "${CONFIG_ARGS[@]}"

         make PETSC_DIR=$PETSC_REPO PETSC_ARCH=arch-linux-c-opt all
         if [ $? -ne 0 ]; then
            echo "ERROR: PETSc build failed"
            exit 1
         fi
         ${SUDO} make PETSC_DIR=$PETSC_REPO PETSC_ARCH=arch-linux-c-opt install
         if [ $? -ne 0 ]; then
            echo "ERROR: PETSc install failed"
            exit 1
         fi

         cd ../

         # slepc install
         git clone --branch v$PETSC_VERSION https://gitlab.com/slepc/slepc.git slepc_to_install
         cd slepc_to_install
         SLEPC_REPO=$PWD

         export PETSC_DIR=$PETSC_PATH

         ./configure --prefix=$SLEPC_PATH
         if [ $? -ne 0 ]; then
            echo "ERROR: SLEPc configure failed"
            exit 1
         fi

         make SLEPC_DIR=$SLEPC_REPO PETSC_DIR=$PETSC_PATH
         if [ $? -ne 0 ]; then
            echo "ERROR: SLEPc build failed"
            exit 1
         fi
         ${SUDO} make SLEPC_DIR=$SLEPC_REPO PETSC_DIR=$PETSC_PATH install-lib
         if [ $? -ne 0 ]; then
            echo "ERROR: SLEPc install failed"
            exit 1
         fi

         cd ../

         # eigen install

         git clone --branch 5.0.0 https://gitlab.com/libeigen/eigen.git eigen_to_install
         cd eigen_to_install
         mkdir build && cd build

	 # removing -DEIGEN_TEST_HIP=ON because it has a hard-coded path to /opt/rocm
         #-- Could NOT find GoogleHash (missing: GOOGLEHASH_INCLUDES GOOGLEHASH_COMPILE)
         #-- Could NOT find Adolc (missing: ADOLC_INCLUDES ADOLC_LIBRARIES)
         #-- Could NOT find MPFR (missing: MPFR_INCLUDES MPFR_LIBRARIES MPFR_VERSION_OK) (Required is at least version "1.0.0")
         #-- Found PkgConfig: /usr/bin/pkg-config (found version "0.29.2")
         #-- Could NOT find FFTW (missing: FFTW_INCLUDES FFTW_LIBRARIES)
         #
         # EIGEN_BUILD_TESTING=OFF is required to avoid a bug in Eigen 5.x's
         # cmake/EigenTesting.cmake (line 78): separate_arguments() is called with
         # ${ARGV2} unquoted, so CMake list variables like FFTW_LIBRARIES expand to
         # multiple arguments, causing "separate_arguments given unexpected argument(s)".
         # Eigen defines a safe wrapper (ei_maybe_separate_arguments) but EigenTesting.cmake
         # does not use it. Disabling tests skips the entire EigenTesting.cmake code path.
         #
         cmake -DCMAKE_INSTALL_PREFIX=$EIGEN_PATH -DCHOLMOD_LIBRARIES=$PETSC_PATH/lib -DCHOLMOD_INCLUDES=$PETSC_PATH/include \
               -DKLU_LIBRARIES=$PETSC_PATH/lib -DKLU_INCLUDES=$PETSC_PATH/include \
               -DCMAKE_PREFIX_PATH=${ROCM_PATH} -DCMAKE_MODULE_PATH=${ROCM_PATH}/hip/cmake \
               -DEIGEN_BUILD_TESTING=OFF ..
         if [ $? -ne 0 ]; then
            echo "ERROR: Eigen cmake configuration failed"
            exit 1
         fi
         # Build as user; sudo only the install (file copies).  Eigen is
         # mostly headers but the CMake-generated install target may
         # trigger codegen / build steps -- if those run under sudo
         # they leave root-owned files in ${PETSC_BUILD_DIR}/eigen_to_install/build/
         # that would race the EXIT trap on cleanup.
         make -j $(nproc)
         if [ $? -ne 0 ]; then
            echo "ERROR: Eigen build failed"
            exit 1
         fi
         ${SUDO} make install
         if [ $? -ne 0 ]; then
            echo "ERROR: Eigen install failed"
            exit 1
         fi

         cd ../..
         # petsc_to_install/, slepc_to_install/, eigen_to_install/ all
         # live under ${PETSC_BUILD_DIR} (under /tmp) and are removed by
         # the EXIT trap installed before the USE_SPACK fork. No
         # explicit rm needed (and the explicit rm here would race with
         # the trap on `set -e` aborts).

      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${PETSC_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${SLEPC_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${EIGEN_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
         ${SUDO} chmod go-w ${PETSC_PATH}
         ${SUDO} chmod go-w ${SLEPC_PATH}
         ${SUDO} chmod go-w ${EIGEN_PATH}
      fi

      # Unload the dependent (MPI) BEFORE its dependency (rocm): the openmpi
      # modulefile prereqs rocm/<ver>, so unloading rocm while openmpi is
      # still loaded trips Lmod ("Cannot load module openmpi without
      # rocm/<ver>") and aborts under set -e. `|| true` tolerates either
      # module being already-absent (mirrors hypre_setup.sh).
      module unload $MPI_MODULE || true
      module unload ${ROCM_MODULE_NAME} || true
      # `module unload hdf5` may fail if we took the DOWNLOAD_HDF5=1
      # path above and never loaded it (or if the load itself silently
      # no-op'd via ||true). Tolerate either case under `set -e`.
      module unload hdf5 2>/dev/null || true
      if [[ ${USE_AMDFLANG} == "1" ]]; then
         module unload amdflang-new
      fi

   fi

   # Create a module file for petsc
   #
   # Modulefile-write sudo: root needs none; otherwise touch-probe the
   # nearest EXISTING ancestor of MODULE_PATH (a real mktemp, not a -w test
   # that can "lie" on some NFS mounts). A user-writable /shareddata/modules
   # tree on a Cray then needs no sudo, and forcing it would hit a password
   # prompt that fails where the user has no sudo. Mirrors netcdf_setup.sh.
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      PKG_SUDO_MOD=""
   else
      _mprobe="${MODULE_PATH}"
      while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
      _mtest=$(mktemp --tmpdir="${_mprobe}" .petsc-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         PKG_SUDO_MOD=""
         echo "petsc: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         PKG_SUDO_MOD="sudo"
         echo "petsc: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
      fi
      unset _mprobe _mtest
   fi
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   ROCM_MODULE_LOAD=${ROCM_MODULE_NAME}
   if [[ "${USE_AMDFLANG}" == 1 ]]; then
      # the amdflang-new module also loads rocm
      ROCM_MODULE_LOAD=amdflang-new/rocm-afar-${AMDFLANG_RELEASE_NUMBER}
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

   # A consumer satisfies the ROCm dependency with either the local TheRock
   # real module (rocm-new/<ver>) or its alias (rocm/<ver>): PrgEnv-amd-new
   # loads rocm-new directly, while a bare `module load rocm/<ver>` pulls it
   # in under the alias name. Tcl `prereq` with several names is satisfied if
   # ANY is loaded; Lmod's equivalent is prereq_any(). Non-rocm names (e.g.
   # the amdflang-new module used for the amdflang build) are emitted as-is.
   # AAC7 gate: the rocm-new/<ver> alias is only meaningful on a TheRock /
   # PrgEnv-amd-new site (AAC7), where rocm-new is a real modulefile. On a
   # stock site (e.g. AAC6) only rocm/<ver> exists, so widening the prereq
   # to rocm-new would reference a phantom module name -- gate it on whether
   # a rocm-new modulefile is actually discoverable on MODULEPATH. When it is
   # not, emit the original plain prereq("rocm/<ver>"). Mirrors hdf5/hipifly.
   rocm_new_available() {
      local _d _OIFS="${IFS}"; IFS=":"
      for _d in ${MODULEPATH:-}; do
         if [ -d "${_d}/rocm-new" ]; then IFS="${_OIFS}"; return 0; fi
      done
      IFS="${_OIFS}"; return 1
   }
   _RPV="${ROCM_MODULE_LOAD##*/}"
   case "${ROCM_MODULE_LOAD}" in
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
         ROCM_PREREQ_TCL="${ROCM_MODULE_LOAD}"
         ROCM_PREREQ_LUA="prereq(\"${ROCM_MODULE_LOAD}\")"
         ;;
   esac
   unset _RPV

   # ── Modulefile flavor: Lua (Lmod) vs Tcl (classic Environment Modules) ─
   # Lmod consumes <name>.lua; classic Tcl `environment-modules` consumes an
   # extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
   # when Lmod is absent (this site runs Tcl Environment Modules). Without
   # this, the .lua file is invisible to a Tcl `module` and `module load
   # petsc` fails on a Cray. Mirrors hdf5/netcdf/fftw.
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      _MODFILE="${MODULE_PATH}/${PETSC_VERSION}.lua"
      _MODFLAVOR="lua"
   else
      _MODFILE="${MODULE_PATH}/${PETSC_VERSION}"
      _MODFLAVOR="tcl"
   fi

   # The - option suppresses leading tabs in the heredoc body.
   if [ "${_MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	whatis("PETSC Version $PETSC_VERSION - solver package")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${PETSC_PATH}"

	${ROCM_PREREQ_LUA}
	load("$MPI_MODULE")
	setenv("PETSC_PATH", base)
	setenv("PETSC", base)
	setenv("PETSC_DIR", base)
	setenv("SLEPC_PATH", "$SLEPC_PATH")
	setenv("SLEPC_DIR", "$SLEPC_PATH")
	setenv("PETSC_MPI_MODULE", "$MPI_MODULE")
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH",pathJoin("${SLEPC_PATH}", "lib"))
EOF
   else
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	#%Module1.0
	module-whatis "PETSC Version $PETSC_VERSION - solver package"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${PETSC_PATH}"

	prereq ${ROCM_PREREQ_TCL}
	if { ![ is-loaded $MPI_MODULE ] } { module load $MPI_MODULE }
	setenv PETSC_PATH \$base
	setenv PETSC \$base
	setenv PETSC_DIR \$base
	setenv SLEPC_PATH "$SLEPC_PATH"
	setenv SLEPC_DIR "$SLEPC_PATH"
	setenv PETSC_MPI_MODULE "$MPI_MODULE"
	prepend-path LD_LIBRARY_PATH \$base/lib
	prepend-path LD_LIBRARY_PATH "${SLEPC_PATH}/lib"
EOF
   fi
   unset _MODFILE _MODFLAVOR ROCM_PREREQ_TCL ROCM_PREREQ_LUA

fi
