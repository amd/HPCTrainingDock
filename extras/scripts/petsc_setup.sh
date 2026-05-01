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
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus/petsc
BUILD_PETSC=0
ROCM_VERSION=6.2.0
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/petsc
INSTALL_PATH_INPUT=""
PETSC_VERSION="3.24.1"
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
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  WARNING: when selecting the module to supply to --mpi-module, make sure it sets the MPI_PATH environment variable"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [ INSTALL_PATH_INPUT ] default $INSTALL_PATH"
   echo "  --use-amdflang [ USE_AMDFLANG ] set to 1 to build petsc with the AMD next generation Fortran compiler, default $USE_AMDFLANG"
   echo "  --amdflang-release-number [ AMDFLANG_RELEASE_NUMBER ] default $AMDFLANG_RELEASE_NUMBER. Note: this flag is only used if --use-amdflang 1 is specified."
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --petsc-version [ PETSC_VERSION ] default $PETSC_VERSION"
   echo "  --use-spack [ USE_SPACK ] default $USE_SPACK"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --build-petsc [ BUILD_PETSC ] default is 0"
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
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
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
else
   # override path in case ROCM_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/petsc
fi

if [[ "${USE_AMDFLANG}" == 1 ]]; then
   INSTALL_PATH=${INSTALL_PATH}_amdflang
   MODULE_PATH=${MODULE_PATH}_amdflang
fi

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
   if [ -f ${CACHE_FILES}/petsc.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached PETSC"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/petsc.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/petsc.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building PETSC"
      echo "============================"
      echo ""

      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" )
      if [[ ${USE_AMDFLANG} == "1" ]]; then
         # AFAR amdflang-new wraps openmpi compilers; loaded BEFORE the
         # MPI module so the MPI module sees the right Fortran compiler.
         # AFAR releases: https://repo.radeon.com/rocm/misc/flang/
         REQUIRED_MODULES+=( "amdflang-new/rocm-afar-${AMDFLANG_RELEASE_NUMBER}" )
      fi
      REQUIRED_MODULES+=( "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
      if [[ $MPI_PATH == "" ]]; then
         echo "MPI module $MPI_MODULE is not setting the MPI_PATH env variable, aborting..."
         exit 1
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

      if [[ $USE_SPACK == 1 ]]; then

         # ------------ Installing PETSC

         echo " WARNING: installing petsc with spack: the build is a work in progress, fails can happen..."

         if [[ ${SUDO} != "" ]]; then
            ${SUDO} apt-get update
            ${SUDO} apt-get install -y libssl-dev
         else
            echo " WARNING: not using sudo, the spack build might fail if libevent does not find openssl "
         fi

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
         # in the shared HPCTrainingDock checkout. EXIT trap covers
         # the build dir + the two spack user-scope dirs above.
         PETSC_BUILD_DIR=$(mktemp -d -t petsc-build.XXXXXX)
         trap '${SUDO:-sudo} rm -rf "${PETSC_BUILD_DIR:-/nonexistent}" "${SPACK_USER_CONFIG_PATH:-/nonexistent}" "${SPACK_USER_CACHE_PATH:-/nonexistent}"' EXIT
         cd "${PETSC_BUILD_DIR}"

         git clone https://github.com/spack/spack.git

         # load spack environment
         source spack/share/spack/setup-env.sh

         module load hdf5

         # find already installed libs for spack: include --all otherwise ROCm libs will not be found
         spack external find --all

	 spack install rocm-core@${ROCM_VERSION} rocm-cmake@${ROCM_VERSION} hipblas-common@${ROCM_VERSION} rocthrust@${ROCM_VERSION} rocprim@${ROCM_VERSION}

         # change spack install dir for Hypre
         sed -i 's|$spack/opt/spack|'"${PETSC_PATH}"'|g' spack/etc/spack/defaults/base/config.yaml 

         # install petsc with spack, some variants are not specified because true by default
         spack install petsc@$PETSC_VERSION+rocm+fortran+mumps+suite-sparse amdgpu_target=$AMDGPU_GFXMODEL

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

         DOWNLOAD_HDF5=1
         module load hdf5
         if [[ "${HDF5_PATH}" != "" ]]; then
            DOWNLOAD_HDF5=0
         fi

         ./configure --with-debugging=0 --with-x=0 COPTFLAGS="-O3 -march=native -mtune=native" \
                     CXXOPTFLAGS="-O3 -march=native -mtune=native" FOPTFLAGS="-O3 -march=native -mtune=native" \
                     HIPOPTFLAGS="-O3 -march=native -mtune=native" --download-fblaslapack=1 --download-hdf5=$DOWNLOAD_HDF5 --download-metis=1 \
                     --download-parmetis=1 --with-shared-libraries=1 --download-blacs=1 --download-scalapack=1 --download-mumps=1 \
                     --download-suitesparse=1 --with-hip-arch=$AMDGPU_GFXMODEL --with-mpi=1 --with-mpi-dir=$MPI_PATH \
                     --prefix=$PETSC_PATH --with-hip=1 --with-hip-dir=$ROCM_PATH

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
         ${SUDO} make install
         if [ $? -ne 0 ]; then
            echo "ERROR: Eigen install failed"
            exit 1
         fi

         cd ../..
         ${SUDO} rm -rf petsc_to_install slepc_to_install eigen_to_install

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

      module unload rocm/${ROCM_VERSION}
      module unload $MPI_MODULE
      module unload hdf5
      if [[ ${USE_AMDFLANG} == "1" ]]; then
         module unload amdflang-new
      fi

   fi

   # Create a module file for petsc
   if [ -d "$MODULE_PATH" ]; then
      # use sudo if user does not have write access to module path
      if [ ! -w ${MODULE_PATH} ]; then
         SUDO="sudo"
      else
         echo "WARNING: not using sudo since user has write access to module path"
      fi
   else
      # if module path dir does not exist yet, the check on write access will fail
      SUDO="sudo"
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   ROCM_MODULE_LOAD=rocm/${ROCM_VERSION}
   if [[ "${USE_AMDFLANG}" == 1 ]]; then
      # the amdflang-new module also loads rocm
      ROCM_MODULE_LOAD=amdflang-new/rocm-afar-${AMDFLANG_RELEASE_NUMBER}
   fi

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$PETSC_VERSION.lua
	whatis("PETSC Version $PETSC_VERSION - solver package")

	local base = "${PETSC_PATH}"

	prereq("$ROCM_MODULE_LOAD")
	load("$MPI_MODULE")
	setenv("PETSC_PATH", base)
	setenv("PETSC", base)
	setenv("PETSC_DIR", base)
	setenv("SLEPC_PATH", "$SLEPC_PATH")
	setenv("SLEPC_DIR", "$SLEPC_PATH")
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH",pathJoin("${SLEPC_PATH}", "lib"))
	append_path("LD_LIBRARY_PATH","/usr/lib")
EOF

fi
