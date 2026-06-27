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
MODULE_PATH=/etc/lmod/modules/ROCmPlus/fftw
BUILD_FFTW=0
ROCM_VERSION=6.2.0
ROCM_MODULE="rocm"
C_COMPILER=`which gcc`
C_COMPILER_INPUT=""
FC_COMPILER=`which gfortran`
FC_COMPILER_INPUT=""
ENABLE_MPI_INPUT=""
FFTW_VERSION=3.3.10
MPI_MODULE="openmpi"
FFTW_PATH=/opt/rocmplus-${ROCM_VERSION}/fftw-v$FFTW_VERSION
FFTW_PATH_INPUT=""
# --install-path: parent dir; the script appends fftw-v${FFTW_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf prior install dir + ${FFTW_VERSION}.lua before building.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocm-module [ ROCM_MODULE ] default $ROCM_MODULE"
   echo "  --fftw-version [ FFTW_VERSION ] default $FFTW_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --enable-mpi [ ENABLE_MPI ], set to 1 to enable, enabled by default if MPI is installed"
   echo "  --install-path-no-version [ FFTW_PATH ] default $FFTW_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), FFTW_PATH = ROCMPLUS_PATH/fftw-v\${FFTW_VERSION}"
   echo "  --c-compiler [ C_COMPILER ] default ${C_COMPILER}"
   echo "  --fc-compiler [ FC_COMPILER ] default ${FC_COMPILER}"
   echo "  --build-fftw [ BUILD_FFTW ], set to 1 to build FFTW, default is 0"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information"
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
      "--build-fftw")
          shift
          BUILD_FFTW=${1}
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
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path-no-version")
          shift
          FFTW_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--enable-mpi")
          shift
          ENABLE_MPI_INPUT=${1}
          reset-last
          ;;
      "--c-compiler")
          shift
          C_COMPILER=${1}
          reset-last
          ;;
      "--fc-compiler")
          shift
          FC_COMPILER=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--rocm-module")
          shift
          ROCM_MODULE=${1}
          reset-last
          ;;
      "--fftw-version")
          shift
          FFTW_VERSION=${1}
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

if [ "${FFTW_PATH_INPUT}" != "" ]; then
   FFTW_PATH=${FFTW_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends fftw-v${FFTW_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for fftw.
   FFTW_PATH=${ROCMPLUS_PATH_INPUT}/fftw-v${FFTW_VERSION}
else
   # override path in case FFTW_VERSION has been supplied as input
   FFTW_PATH=/opt/rocmplus-${ROCM_VERSION}/fftw-v${FFTW_VERSION}
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# ── BUILD_FFTW=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_FFTW}" = "0" ]; then
   echo "[fftw BUILD_FFTW=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── Early sudo decision (see hdf5_setup.sh / mpi4py_setup.sh) ────────
# Determine whether privilege escalation is needed BEFORE the --replace
# block and EXIT trap (both rm install/module paths via ${SUDO}). When the
# operator owns a writable install tree (e.g. a user-writable
# /shareddata/opt on a Cray) no sudo is needed -- and forcing it would hit a
# password prompt that fails on a node where the user has no sudo. Probe the
# nearest EXISTING ancestor of FFTW_PATH (the leaf dir does not exist yet).
# The build branch re-affirms this below.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _probe="${FFTW_PATH}"
   while [ ! -e "${_probe}" ]; do _probe="$(dirname "${_probe}")"; done
   # Real write test (mktemp), NOT `[ -w ]`: on NFS `-w` is a LYING probe --
   # it reports "writable" on a root:root 0755 tree (e.g. /nfsapps) where the
   # actual write / rm then fails (the netcdf_setup.sh lying-probe failure
   # mode). Mirrors the hdf5/hipifly/kokkos mktemp probe.
   _wtest=$(mktemp --tmpdir="${_probe}" .fftw-write-probe.XXXXXX 2>/dev/null || true)
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
   echo "[fftw --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${FFTW_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${FFTW_VERSION}{,.lua}"
   ${SUDO} rm -rf "${FFTW_PATH}"
   # Remove both flavors (Lmod .lua and Tcl no-extension).
   ${SUDO} rm -f  "${MODULE_PATH}/${FFTW_VERSION}.lua" "${MODULE_PATH}/${FFTW_VERSION}"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${FFTW_PATH}" ]; then
   echo ""
   echo "[fftw existence-check] ${FFTW_PATH} already installed; skipping."
   echo "                       pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# FFTW_BUILD_DIR (a /tmp scratch dir, set under the source-build branch)
# is cleaned here too, so this single EXIT trap does both jobs. A prior
# separate `trap '... rm FFTW_BUILD_DIR' EXIT` further down OVERWROTE this
# handler, silently disabling fail-cleanup of a partial install -- folded
# in here to match hdf5_setup.sh.
FFTW_BUILD_DIR=""
_fftw_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[fftw fail-cleanup] rc=${rc}: removing partial install + modulefile"
      # ${SUDO} verbatim (NOT ${SUDO:-sudo}): the early-probe may set SUDO=""
      # for an operator-writable tree, and cleanup must then run WITHOUT sudo.
      ${SUDO} rm -rf "${FFTW_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/${FFTW_VERSION}.lua" "${MODULE_PATH}/${FFTW_VERSION}"
   elif [ ${rc} -ne 0 ]; then
      echo "[fftw fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Scratch build dir under /tmp (user-owned via mktemp) -- never needs sudo.
   [ -n "${FFTW_BUILD_DIR:-}" ] && rm -rf "${FFTW_BUILD_DIR}"
   return ${rc}
}
trap _fftw_on_exit EXIT


if [ "${BUILD_FFTW}" = "0" ]; then

   echo "FFTW will not be built, according to the specified value of BUILD_FFTW"
   echo "BUILD_FFTW: $BUILD_FFTW"
   echo "Make sure to set '--build-fftw 1' when running this install script"
   exit

else

   echo ""
   echo "==============================="
   echo " Installing FFTW"
   echo " Install directory: $FFTW_PATH"
   echo " Module directory: $MODULE_PATH"
   echo " FFTW Version: $FFTW_VERSION"
   echo " ROCm Version: $ROCM_VERSION"
   echo "==============================="
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

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
   #   3. ${ROCM_MODULE}/${ROCM_VERSION}: standalone-invocation fallback when
   #      neither LOADEDMODULES nor ROCM_PATH is populated.
   ROCM_MODULE_NAME=""
   if [[ -n "${LOADEDMODULES:-}" ]]; then
      _OLD_IFS="${IFS}"; IFS=":"
      for _m in ${LOADEDMODULES}; do
         case "${_m}" in
            ${ROCM_MODULE:-rocm}/*) ROCM_MODULE_NAME="${_m}"; break ;;
         esac
      done
      IFS="${_OLD_IFS}"; unset _OLD_IFS _m
   fi
   if [[ -z "${ROCM_MODULE_NAME}" ]]; then
      if [[ -n "${ROCM_PATH:-}" ]]; then
         _rp_bn="${ROCM_PATH##*/}"
         ROCM_MODULE_NAME="${ROCM_MODULE}/${_rp_bn#rocm-}"
         unset _rp_bn
      else
         ROCM_MODULE_NAME="${ROCM_MODULE}/${ROCM_VERSION}"
      fi
   fi

   if [ -f ${CACHE_FILES}/fftw-v${FFTW_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached FFTW"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # fftw-v${FFTW_VERSION}.tgz and contain a top-level directory
      # fftw-v${FFTW_VERSION}/ so it lands directly at ${FFTW_PATH}
      # when extracted under /opt/rocmplus-X. (Previous code cd'd
      # into /opt and chown'd /opt/fftw-v..., which left the install
      # in the wrong place; corrected here as part of the multi-version
      # pass.)
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/fftw-v${FFTW_VERSION}.tgz
      chown -R root:root ${FFTW_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/fftw-v${FFTW_VERSION}.tgz
      fi

   else
      echo ""
      echo "==============================="
      echo " Installing FFTW from source"
      echo "==============================="
      echo ""

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh

      if [ -d "$FFTW_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${FFTW_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${FFTW_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${FFTW_PATH}
      fi

      # ── MPI module auto-correct on a Cray PE (see hdf5_setup.sh) ──────
      # The leaf default MPI_MODULE is "openmpi", but a Cray system ships
      # cray-mpich (no openmpi module exists) -- preflight would fail. If
      # cray-mpich is active and the caller did not override the MPI, switch
      # to cray-mpich so the prereq load and the parallel build use the
      # PrgEnv's own MPI. (main_setup.sh also threads --mpi-module cray-mpich
      # / mpich-wrappers when MPICH_DIR is set; this makes the leaf correct
      # standalone too.)
      if [ "${MPI_MODULE}" = "openmpi" ] \
           && { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; }; then
         MPI_MODULE="cray-mpich"
         echo "FFTW: Cray MPICH detected; MPI_MODULE -> cray-mpich"
      fi

      # ── mpich-wrappers resolution (PrgEnv MPI on a Cray) ─────────────
      # mpich-wrappers is a standalone MPICH (MPICH-ABI compatible with
      # cray-mpich) front-loading mpicc/mpicxx/mpifort. When the caller asks
      # for it (main_setup threads --mpi-module mpich-wrappers), resolve the
      # bare name to the concrete, version-matched modulefile token by
      # scanning MODULEPATH (mpich-wrappers/${ROCM_VERSION} first, then a
      # bare mpich-wrappers). If none is found, fall back to cray-mpich so
      # the build still works with the Cray PE wrappers.
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
            echo "FFTW: using mpich-wrappers module '${_mw_tok}' (PrgEnv MPI)"
         else
            echo "FFTW: WARNING: --mpi-module mpich-wrappers requested but no mpich-wrappers modulefile found on MODULEPATH; falling back to cray-mpich"
            MPI_MODULE="cray-mpich"
         fi
         unset _mw_tok
      fi

      # default build is without mpi
      ENABLE_MPI=""
      MPICC_BIN=""
      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── MPI C-compiler (MPICC) selection ─────────────────────────────
      # FFTW's --enable-mpi builds libfftw3*_mpi using MPICC. Pick the MPI C
      # wrapper that matches the loaded MPI module so the MPI variant links
      # the SAME MPI as the rest of the PrgEnv stack:
      #   1. mpich-wrappers / OpenMPI / MVAPICH -> mpicc (front-loaded by the
      #      module just preflight-loaded above).
      #   2. cray-mpich (no mpich-wrappers) -> Cray PE `cc` wrapper.
      # The serial (non-MPI) FFTW libs still build with the plain C_COMPILER.
      if [ "${MPI_MODULE#mpich-wrappers}" != "${MPI_MODULE}" ] \
           && command -v mpicc >/dev/null 2>&1; then
         ENABLE_MPI="--enable-mpi"
         MPICC_BIN="$(command -v mpicc)"
         echo "FFTW: mpich-wrappers MPI -> MPICC=${MPICC_BIN}"
      elif { [ "${MPI_MODULE}" = "cray-mpich" ] || [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; } \
           && command -v cc >/dev/null 2>&1; then
         ENABLE_MPI="--enable-mpi"
         MPICC_BIN="$(command -v cc)"
         echo "FFTW: Cray PE detected -> MPICC=${MPICC_BIN} (cray-mpich)"
      elif command -v mpicc >/dev/null 2>&1; then
         # OpenMPI / MVAPICH path
         ENABLE_MPI="--enable-mpi"
         MPICC_BIN="$(command -v mpicc)"
         echo "FFTW: MPI -> MPICC=${MPICC_BIN}"
      else
         echo "FFTW: no MPI C wrapper found; building serial FFTW only"
      fi

      # operator opt-out / opt-in override
      if [ "${ENABLE_MPI_INPUT}" == "1" ]; then
         ENABLE_MPI="--enable-mpi"
      elif [ "${ENABLE_MPI_INPUT}" == "0" ]; then
         ENABLE_MPI=""
         MPICC_BIN=""
         echo "FFTW: --enable-mpi 0 requested; building serial FFTW only"
      fi

      # ── -fPIC for ALL objects (HPE/Cray PE only) ─────────────────────
      # On an HPE/Cray PE the mpich-wrappers mpicc (and the craype cc) drive
      # the ROCm clang, whose ld.lld links executables as -pie by default.
      # FFTW's non-libtool helper archive libbench2.a (built with the serial
      # CC) and the mpi-bench objects are otherwise compiled without -fPIC,
      # so the PIE link of mpi/mpi-bench fails with "relocation R_X86_64_32
      # ... recompile with -fPIC". Bake -fPIC into CC (and MPICC) so every
      # object -- including the static archives and the final libfftw3.a --
      # is position-independent. Gate on Cray markers so a stock
      # OpenMPI/gcc build (GNU ld, non-strict) is left byte-for-byte as is.
      # The vars are passed as a quoted array because they embed a space; the
      # unquoted ${...} form would word-split -fPIC into a stray configure arg.
      PIC_FLAG=""
      if [ -n "${CRAYPE_VERSION:-}" ] || [ -n "${PE_ENV:-}" ] \
         || [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ] \
         || [ -d /opt/cray/pe ]; then
         PIC_FLAG=" -fPIC"
         echo "FFTW: HPE/Cray PE detected -> adding -fPIC (PIE-default ROCm clang/ld.lld)"
      fi
      COMPILER_ARGS=( "CC=${C_COMPILER}${PIC_FLAG}" )
      [ -n "${ENABLE_MPI}" ] && [ -n "${MPICC_BIN}" ] \
         && COMPILER_ARGS+=( "MPICC=${MPICC_BIN}${PIC_FLAG}" )

      # Build under /tmp (compute-node local disk) so the three
      # full builds (double, single, long-double) don't round-trip
      # through NFS for every .o, .a, .so. Only `make install`
      # writes hit NFS via the absolute --prefix=${FFTW_PATH}.
      # EXIT trap guarantees cleanup even on build failure (we have
      # set -e). Audit basis: 7950 fftw took ~7m14s with build under
      # /home/admin/repos/HPCTrainingDock/fftw-3.3.10/...
      # FFTW_BUILD_DIR is cleaned by the _fftw_on_exit trap installed above
      # (folding build-dir + fail-cleanup into one handler; a separate trap
      # here would overwrite that handler and disable fail-cleanup).
      FFTW_BUILD_DIR=$(mktemp -d -t fftw-build.XXXXXX)
      cd "${FFTW_BUILD_DIR}"

      wget -q https://www.fftw.org/fftw-${FFTW_VERSION}.tar.gz
      tar zxf fftw-${FFTW_VERSION}.tar.gz
      cd fftw-${FFTW_VERSION}

      # Use all available cores for the three precision variants. Without
      # `-j` each of these three full builds runs serially on one core,
      # which dominated the rocmplus install wallclock at ~23min on the
      # sh5 nodes (96 cores). With `-j$(nproc)` it drops to a few minutes.
      MAKE_JOBS=$(nproc 2>/dev/null || echo 16)

      # configure for double precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-sse2 --enable-avx --enable-avx2 \
		  "${COMPILER_ARGS[@]}"
      make -j ${MAKE_JOBS}
      make install

      # configure for single precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-sse2 --enable-avx --enable-avx2 --enable-float \
		  "${COMPILER_ARGS[@]}"
      make -j ${MAKE_JOBS}
      make install

      # configure for long double precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-long-double \
		  "${COMPILER_ARGS[@]}"
      make -j ${MAKE_JOBS}
      make install

      # FFTW_BUILD_DIR (under /tmp) is removed by the EXIT trap
      # above; no need to rm the tarball or extracted source dir.

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${FFTW_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${FFTW_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${FFTW_PATH}
      fi

   fi

   # Create a module file for fftw
   #
   # Modulefile-write sudo: root needs none; otherwise probe the nearest
   # EXISTING ancestor of MODULE_PATH for writability (a user-writable
   # /shareddata/modules tree on a Cray needs no sudo, and forcing it would
   # hit a password prompt that fails where the user has no sudo). Mirrors
   # hdf5_setup.sh.
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      PKG_SUDO_MOD=""
   else
      _mprobe="${MODULE_PATH}"
      while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
      # Real write test (mktemp), NOT `[ -w ]` (NFS lying-probe; see above).
      _mwtest=$(mktemp --tmpdir="${_mprobe}" .fftw-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mwtest}" ] && [ -f "${_mwtest}" ]; then
         rm -f "${_mwtest}"
         PKG_SUDO_MOD=""
      else
         PKG_SUDO_MOD="sudo"
      fi
      unset _mprobe _mwtest
   fi
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

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

   # ── Modulefile flavor: Lua (Lmod) vs Tcl (classic Environment Modules) ─
   # Lmod consumes <name>.lua; classic Tcl `environment-modules` consumes an
   # extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
   # when Lmod is absent (this site runs Tcl Environment Modules).
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      _MODFILE="${MODULE_PATH}/${FFTW_VERSION}.lua"
      _MODFLAVOR="lua"
   else
      _MODFILE="${MODULE_PATH}/${FFTW_VERSION}"
      _MODFLAVOR="tcl"
   fi

   # For an MPI build, libfftw3*_mpi links a specific MPI; require that MPI
   # module so a consumer cannot load a mismatched (or no) MPI. Only emitted
   # when MPI was enabled and an MPI module name is known.
   _EMIT_MPI_PREREQ=0
   if [ -n "${ENABLE_MPI}" ] && [ -n "${MPI_MODULE}" ]; then
      _EMIT_MPI_PREREQ=1
   fi

   # The - option suppresses leading tabs in the heredoc body.
   if [ "${_MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	whatis("FFTW: Fastest Fourier Transform in the West")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")
	local base = "${FFTW_PATH}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	setenv("FFTW_PATH", base)
	setenv("FFTW_ROOT", base)
	setenv("FFTW_MPI_MODULE", "${MPI_MODULE}")
	prepend_path("PATH", pathJoin(base, "bin"))
EOF
      if [ "${_EMIT_MPI_PREREQ}" = "1" ]; then
         echo "prereq(\"${MPI_MODULE}\")" | ${PKG_SUDO_MOD} tee -a "${_MODFILE}" >/dev/null
      fi
   else
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	#%Module1.0
	module-whatis "FFTW: Fastest Fourier Transform in the West"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_MODULE_NAME}
	set base "${FFTW_PATH}"
	prepend-path LD_LIBRARY_PATH \$base/lib
	prepend-path C_INCLUDE_PATH \$base/include
	prepend-path CPLUS_INCLUDE_PATH \$base/include
	setenv FFTW_PATH \$base
	setenv FFTW_ROOT \$base
	setenv FFTW_MPI_MODULE "${MPI_MODULE}"
	prepend-path PATH \$base/bin
EOF
      if [ "${_EMIT_MPI_PREREQ}" = "1" ]; then
         echo "prereq ${MPI_MODULE}" | ${PKG_SUDO_MOD} tee -a "${_MODFILE}" >/dev/null
      fi
   fi
   unset _MODFILE _MODFLAVOR _EMIT_MPI_PREREQ

fi

