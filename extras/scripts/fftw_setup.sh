#!/bin/bash

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
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocm-module [ ROCM_MODULE ] default $ROCM_MODULE"
   echo "  --fftw-version [ FFTW_VERSION ] default $FFTW_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --enable-mpi [ ENABLE_MPI ], set to 1 to enable, enabled by default if MPI is installed"
   echo "  --install-path [ FFTW_PATH ] default $FFTW_PATH"
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
      "--install-path")
          shift
          FFTW_PATH_INPUT=${1}
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

if [ "${REPLACE}" = "1" ]; then
   echo "[fftw --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${FFTW_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${FFTW_VERSION}.lua"
   ${SUDO} rm -rf "${FFTW_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${FFTW_VERSION}.lua"
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

_fftw_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[fftw fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${FFTW_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${FFTW_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[fftw fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
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

      # default build is without mpi
      ENABLE_MPI=""
      REQUIRED_MODULES=( "${ROCM_MODULE}/${ROCM_VERSION}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
      if [[ `which mpicc | wc -l` -eq 1 ]]; then
	 # if mpi is found in the path, build fftw parallel
         ENABLE_MPI="--enable-mpi"
      fi

      # override flags with user defined values if present
      if [ "${ENABLE_MPI_INPUT}" == "1" ]; then
         ENABLE_MPI="--enable-mpi"
      fi

      # Build under /tmp (compute-node local disk) so the three
      # full builds (double, single, long-double) don't round-trip
      # through NFS for every .o, .a, .so. Only `make install`
      # writes hit NFS via the absolute --prefix=${FFTW_PATH}.
      # EXIT trap guarantees cleanup even on build failure (we have
      # set -e). Audit basis: 7950 fftw took ~7m14s with build under
      # /home/admin/repos/HPCTrainingDock/fftw-3.3.10/...
      FFTW_BUILD_DIR=$(mktemp -d -t fftw-build.XXXXXX)
      trap '[ -n "${FFTW_BUILD_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${FFTW_BUILD_DIR}"' EXIT
      cd "${FFTW_BUILD_DIR}"

      wget -q https://www.fftw.org/fftw-${FFTW_VERSION}.tar.gz
      tar zxf fftw-${FFTW_VERSION}.tar.gz
      cd fftw-${FFTW_VERSION}

      USE_MPICC=""
      if [ "${ENABLE_MPI}" == "1" ]; then
         USE_MPICC="MPICC=mpicc"
	 C_COMPILER="mpicc"
      fi	      

      # Use all available cores for the three precision variants. Without
      # `-j` each of these three full builds runs serially on one core,
      # which dominated the rocmplus install wallclock at ~23min on the
      # sh5 nodes (96 cores). With `-j$(nproc)` it drops to a few minutes.
      MAKE_JOBS=$(nproc 2>/dev/null || echo 16)

      # configure for double precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-sse2 --enable-avx --enable-avx2 \
		  CC=${C_COMPILER} ${USE_MPICC}
      make -j ${MAKE_JOBS}
      make install

      # configure for single precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-sse2 --enable-avx --enable-avx2 --enable-float \
		  CC=${C_COMPILER} ${USE_MPICC}
      make -j ${MAKE_JOBS}
      make install

      # configure for long double precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-long-double \
		  CC=${C_COMPILER} ${USE_MPICC}
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
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${FFTW_VERSION}.lua
	whatis("FFTW: Fastest Fourier Transform in the West")

	local base = "${FFTW_PATH}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	setenv("FFTW_PATH", base)
	prepend_path("PATH", pathJoin(base, "bin"))
EOF

fi

