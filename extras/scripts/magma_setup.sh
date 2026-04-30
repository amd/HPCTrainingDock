#!/bin/bash

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# Shared module-prerequisite checker (exits 42 = SKIPPED if a module is
# unavailable). See bare_system/lib/preflight.sh.
# shellcheck source=../../bare_system/lib/preflight.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../bare_system/lib/preflight.sh"

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_MAGMA=0
ROCM_VERSION=6.2.0
MAGMA_VERSION=master
OPENBLAS_VERSION=0.3.22
MODULE_PATH=/etc/lmod/modules/ROCmPlus/magma
MAGMA_PATH=/opt/rocmplus-${ROCM_VERSION}/magma
MAGMA_PATH_INPUT=""
OPENBLAS_PATH=""

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
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ MAGMA_PATH ] default $MAGMA_PATH"
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
          MAGMA_VERSION=${1}
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
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          MAGMA_PATH_INPUT=${1}
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

if [ "${MAGMA_PATH_INPUT}" != "" ]; then
   MAGMA_PATH=${MAGMA_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   MAGMA_PATH=/opt/rocmplus-${ROCM_VERSION}/magma
fi

echo ""
echo "==================================="
echo "Starting Magma Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_MAGMA: $BUILD_MAGMA"
echo "MAGMA_VERSION: $MAGMA_VERSION"
echo "OPENBLAS_VERSION: $OPENBLAS_VERSION"
echo "MAGMA_PATH: $MAGMA_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

if [ "${BUILD_MAGMA}" = "0" ]; then

   echo "Magma will not be built, according to the specified value of BUILD_MAGMA"
   echo "BUILD_MAGMA: $BUILD_MAGMA"
   exit

else

   # don't use sudo if user has write access to install path
   if [ -d "$MAGMA_PATH" ]; then
      if [ -w ${MAGMA_PATH} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" "amdclang" )
   preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

   ## Check whether OpenBLAS already exists on the system
   BUILD_OPENBLAS=1

   if [ -n "${OPENBLAS_PATH}" ]; then
      if ls ${OPENBLAS_PATH}/lib/libopenblas.* 1>/dev/null 2>&1; then
         echo "Using OpenBLAS at ${OPENBLAS_PATH}"
         BUILD_OPENBLAS=0
      else
         echo "WARNING: OpenBLAS not found at specified path ${OPENBLAS_PATH}, will build from source"
      fi
   fi

   if [ "${BUILD_OPENBLAS}" = "1" ]; then
      for libdir in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/local/lib /usr/local/lib64; do
         if [ -f "${libdir}/libopenblas.so" ]; then
            echo "Found system OpenBLAS at ${libdir}"
            BUILD_OPENBLAS=0
            break
         fi
      done
   fi

   if [ "${BUILD_OPENBLAS}" = "1" ] && ldconfig -p 2>/dev/null | grep -q libopenblas; then
      echo "Found system OpenBLAS via ldconfig"
      BUILD_OPENBLAS=0
   fi

   if [ "${BUILD_OPENBLAS}" = "1" ]; then
      echo ""
      echo "============================"
      echo " Building OpenBLAS ${OPENBLAS_VERSION}"
      echo "============================"
      echo ""

      if [ -z "${OPENBLAS_PATH}" ]; then
         OPENBLAS_PATH=/opt/rocmplus-${ROCM_VERSION}/openblas
      fi

      ${SUDO} mkdir -p ${OPENBLAS_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${OPENBLAS_PATH}
      fi

      cd /tmp
      rm -rf openblas_build
      mkdir openblas_build && cd openblas_build
      curl -LO https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v${OPENBLAS_VERSION}.tar.gz
      tar xf v${OPENBLAS_VERSION}.tar.gz
      cd OpenBLAS-${OPENBLAS_VERSION}/
      make -j MAKE_NB_JOBS=0 ARCH=x86_64 TARGET=ZEN USE_LOCKING=1 USE_OPENMP=1 USE_THREAD=1 RANLIB=ranlib libs netlib shared
      make -j install PREFIX=${OPENBLAS_PATH} MAKE_NB_JOBS=0 ARCH=x86_64 TARGET=ZEN USE_LOCKING=1 USE_OPENMP=1 USE_THREAD=1 RANLIB=ranlib

      cd /tmp
      rm -rf openblas_build

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${OPENBLAS_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${OPENBLAS_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${OPENBLAS_PATH}
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

   cd /tmp
   rm -rf magma_build
   mkdir magma_build && cd magma_build
   git clone https://github.com/icl-utk-edu/magma.git -b ${MAGMA_VERSION}
   cd magma
   echo -e "BACKEND = hip\nFORT = true\nGPU_TARGET = ${AMDGPU_GFXMODEL}" > make.inc
   make -f make.gen.hipMAGMA -j
   make generate
   mkdir build && cd build

   cmake \
      -DCMAKE_INSTALL_PREFIX=${MAGMA_PATH} \
      -DCMAKE_BUILD_TYPE=Release \
      -DMAGMA_ENABLE_HIP=ON \
      -DGPU_TARGET=${AMDGPU_GFXMODEL} \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_CXX_COMPILER=${ROCM_PATH}/bin/hipcc \
      -DCMAKE_Fortran_COMPILER=gfortran \
      -DBLA_VENDOR=OpenBLAS \
      -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATHS}" \
      ..

   make -j
   make install

   cd /tmp
   rm -rf magma_build

   export LD_LIBRARY_PATH=${MAGMA_PATH}/lib:${LD_LIBRARY_PATH}

   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find ${MAGMA_PATH} -type f -execdir chown root:root "{}" +
      ${SUDO} find ${MAGMA_PATH} -type d -execdir chown root:root "{}" +
   fi

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod go-w ${MAGMA_PATH}
   fi

   # Create a module file for magma
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

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${MAGMA_VERSION}.lua
	whatis("Magma version ${MAGMA_VERSION} for AMD hardware")

	prereq("rocm/${ROCM_VERSION}")
	load("amdclang")
	setenv("MAGMA_PATH","${MAGMA_PATH}")
	prepend_path("LD_LIBRARY_PATH","${MAGMA_PATH}/lib")
EOF

   if [ -n "${OPENBLAS_PATH}" ]; then
      cat <<-EOF | ${SUDO} tee -a ${MODULE_PATH}/${MAGMA_VERSION}.lua
	setenv("OPENBLAS_PATH","${OPENBLAS_PATH}")
	prepend_path("LD_LIBRARY_PATH","${OPENBLAS_PATH}/lib")
EOF
   fi

fi
