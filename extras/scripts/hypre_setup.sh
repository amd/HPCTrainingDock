#!/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus/hypre
BUILD_HYPRE=0
ROCM_VERSION=6.2.0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
AMDGPU_GFXMODEL_INPUT=""
USE_SPACK=0
HYPRE_VERSION="2.33.0"
MPI_MODULE="openmpi"
HYPRE_PATH=/opt/rocmplus-${ROCM_VERSION}/hypre
HYPRE_PATH_INPUT=""

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
   echo "  --module-path [ MODULE_PATH ] default is $MODULE_PATH "
   echo "  --install-path [ HYPRE_PATH_INPUT ] default is $HYPRE_PATH "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL_INPUT ] default autodetected "
   echo "  --hypre-version [ HYPRE_VERSION ] default is $HYPRE_VERSION "
   echo "  --use-spack [ USE_SPACK ] default is $USE_SPACK "
   echo "  --build-hypre [ BUILD_HYPRE ] default is 0 "
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
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
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
else
   # override path in case ROCM_VERSION has been supplied as input
   HYPRE_PATH=/opt/rocmplus-${ROCM_VERSION}/hypre
fi

echo ""
echo "==================================="
echo "Starting HYPRE Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HYPRE: $BUILD_HYPRE"
echo "HYPRE_VERSION: $HYPRE_VERSION"
echo "HYPRE_PATH: $HYPRE_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi


AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_HYPRE}" = "0" ]; then

   echo "HYPRE will not be built, according to the specified value of BUILD_HYPRE"
   echo "BUILD_HYPRE: $BUILD_HYPRE"
   exit

else
   if [ -f ${CACHE_FILES}/hypre.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HYPRE"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/hypre.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/hypre.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building HYPRE"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm/${ROCM_VERSION}
      module load ${MPI_MODULE}

      # don't use sudo if user has write access to install path
      if [ -d "$HYPRE_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${HYPRE_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${HYPRE_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${HYPRE_PATH}
      fi

      HYPRE_PATH_ORIGINAL=$HYPRE_PATH
      # ------------ Installing HYPRE

      if [[ $USE_SPACK == 1 ]]; then

         echo " WARNING: installing hypre with spack: the build is a work in progress, fails can happen..."

         if [[ ${SUDO} != "" ]]; then
            ${SUDO} apt-get update
            ${SUDO} apt-get install -y libssl-dev unzip
         else
            echo " WARNING: not using sudo, the spack build might fail if libevent does not find openssl "
         fi

         git clone https://github.com/spack/spack.git

         # load spack environment
         source spack/share/spack/setup-env.sh

         # find already installed libs for spack
         spack external find --all

         spack install rocm-core@${ROCM_VERSION} rocm-cmake@${ROCM_VERSION} hipblas-common@${ROCM_VERSION} rocthrust@${ROCM_VERSION} rocprim@${ROCM_VERSION}

         # change spack install dir for Hypre
         sed -i 's|$spack/opt/spack|'"${HYPRE_PATH}"'|g' spack/etc/spack/defaults/config.yaml

         # install hypre with spack
         #spack install hypre+rocm+rocblas+unified-memory
         spack install hypre@$HYPRE_VERSION+rocm+unified-memory+gpu-aware-mpi amdgpu_target=$AMDGPU_GFXMODEL

         # get hypre install dir created by spack
         HYPRE_PATH=`spack find -p hypre | awk '{print $2}' | grep opt`

         ${SUDO} rm -rf spack

      else

         git clone --branch v$HYPRE_VERSION https://github.com/hypre-space/hypre.git
         cd hypre/src
         mkdir build && cd build

         cmake -DCMAKE_INSTALL_PREFIX=$HYPRE_PATH -DHYPRE_ENABLE_MIXEDINT=ON -DHYPRE_ENABLE_MPI=ON \
               -DHYPRE_ENABLE_OPENMP=ON -DHYPRE_BUILD_TESTS=ON -DHYPRE_ENABLE_HIP=ON -DCMAKE_HIP_ARCHITECTURES=$AMDGPU_GFXMODEL \
                -DHYPRE_ENABLE_GPU_PROFILING=ON -DHYPRE_ENABLE_GPU_AWARE_MPI=ON -DBUILD_SHARED_LIBS=ON -DHYPRE_ENABLE_UNIFIED_MEMORY=ON ..

         make -j
         ${SUDO} make install
         cd ../../..
         rm -rf hypre

      fi

      if [[ "${USER}" != "root" ]]; then
            ${SUDO} find ${HYPRE_PATH_ORIGINAL} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${HYPRE_PATH_ORIGINAL}
      fi

      module unload rocm/${ROCM_VERSION}
      module unload ${MPI_MODULE}

   fi

   # Create a module file for hypre
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$HYPRE_VERSION.lua
	whatis("HYPRE - solver package")

	local base = "${HYPRE_PATH}"

	load("rocm/${ROCM_VERSION}")
	load("${MPI_MODULE}")
	setenv("HYPRE_PATH", base)
	prepend_path("PATH",pathJoin(base, "bin"))
	prepend_path("PATH","${HYPRE_PATH}/bin")
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH","/usr/lib")
EOF

fi
