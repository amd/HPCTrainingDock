#!/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus/kokkos
BUILD_KOKKOS=0
ROCM_VERSION=6.2.0
KOKKOS_ARCH_AMD_GFX942="OFF"
KOKKOS_ARCH_AMD_GFX90A="OFF"
KOKKOS_ARCH_VEGA90A="OFF"
KOKKOS_VERSION="4.7.01"
KOKKOS_PATH=/opt/rocmplus-${ROCM_VERSION}/kokkos
KOKKOS_PATH_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ KOKKOS_PATH ] default $KOKKOS_PATH"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL_INPUT ] default is autodetected "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --build-kokkos [ BUILD_KOKKOS ], set to 1 to build Kokkos, default is 0"
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
      "--build-kokkos")
          shift
          BUILD_KOKKOS=${1}
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
          KOKKOS_PATH_INPUT=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL_INPUT=${1}
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

if [ "${KOKKOS_PATH_INPUT}" != "" ]; then
   KOKKOS_PATH=${KOKKOS_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   KOKKOS_PATH=/opt/rocmplus-${ROCM_VERSION}/kokkos
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

echo ""
echo "==================================="
echo "Starting Kokkos Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_KOKKOS: $BUILD_KOKKOS"
echo "KOKKOS_PATH:  $KOKKOS_PATH"
echo "MODULE_PATH:  $MODULE_PATH"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

if [ "${BUILD_KOKKOS}" = "0" ]; then

   echo "Kokkos will not be built, according to the specified value of BUILD_KOKKOS"
   echo "BUILD_KOKKOS: $BUILD_KOKKOS"
   exit

else
   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Kokkos"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/kokkos.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/kokkos
      ${SUDO} rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos.tgz

   else
      echo ""
      echo "============================"
      echo " Building Kokkos"
      echo "============================"
      echo ""

      # don't use sudo if user has write access to install path
      if [ -d "$KOKKOS_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${KOKKOS_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${KOKKOS_PATH}

      if [ "${AMDGPU_GFXMODEL}" = "gfx90a" ]; then
         KOKKOS_ARCH_AMD_GFX90A="ON"
      elif [ "${AMDGPU_GFXMODEL}" = "gfx942" ]; then
	 KOKKOS_ARCH_AMD_GFX942_APU="ON"
      elif [ "${AMDGPU_GFXMODEL}" = "gfx900" ]; then
         KOKKOS_ARCH_VEGA90A="ON"
      fi

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z00_lmod.sh
      module load rocm/${ROCM_VERSION}

      git clone --branch ${KOKKOS_VERSION} https://github.com/kokkos/kokkos
      cd kokkos

      ${SUDO} mkdir build
      cd build

      ${SUDO} cmake -DCMAKE_INSTALL_PREFIX=${KOKKOS_PATH} \
	         -DCMAKE_PREFIX_PATH=${ROCM_PATH} \
                 -DKokkos_ENABLE_SERIAL=ON \
                 -DKokkos_ENABLE_HIP=ON \
		 -DKokkos_ENABLE_OPENMP=ON \
                 -DKokkos_ARCH_AMD_GFX942_APU=${KOKKOS_ARCH_AMD_GFX942_APU} \
                 -DKokkos_ARCH_ZEN4=ON \
                 -DCMAKE_CXX_COMPILER=${ROCM_PATH}/bin/hipcc ..

      ${SUDO} make -j
      ${SUDO} make install

      cd ../..
      ${SUDO} rm -rf kokkos

      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for kokkos
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${KOKKOS_VERSION}.lua
	whatis("Kokkos version ${KOKKOS_VERSION} - Performance Portability Language")

	prereq("rocm/${ROCM_VERSION}")
	prepend_path("PATH","${KOKKOS_PATH}")
	setenv("Kokkos_DIR","${KOKKOS_PATH}")
	setenv("HSA_XNACK","1")
EOF

fi

