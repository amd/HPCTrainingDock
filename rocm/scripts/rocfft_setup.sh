#!/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.4.3
BUILD_ROCFFT=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus/rocfft
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
ROCFFT_PATH=/opt/rocmplus-${ROCM_VERSION}/rocfft
ROCFFT_PATH_INPUT=""
ROCFFT_VERSION="develop"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-rocfft [ BUILD_ROCFFT ] default $BUILD_ROCFFT "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ ROCFFT_PATH ] default $ROCFFT_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocfft-version [ ROCFFT_VERSION ] specify the version of HIP-Python, default is $ROCFFT_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--build-rocfft")
          shift
          BUILD_ROCFFT=${1}
          reset-last
          ;;
      "--rocfft-version")
          shift
          ROCFFT_VERSION=${1}
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
          ROCFFT_PATH_INPUT=${1}
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

if [ "${ROCFFT_PATH_INPUT}" != "" ]; then
   ROCFFT_PATH=${ROCFFT_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   ROCFFT_PATH=/opt/rocmplus-${ROCM_VERSION}/rocfft
fi

echo ""
echo "==================================="
echo "Starting rocFFT Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_ROCFFT: $BUILD_ROCFFT"
echo "ROCFFT_PATH: $ROCFFT_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "ROCFFT_VERSION: $ROCFFT_VERSION"
echo "==================================="
echo ""

if [ "${BUILD_ROCFFT}" = "0" ]; then

   echo "rocFFT will not be built, according to the specified value of BUILD_ROCFFT"
   echo "BUILD_ROCFFT: $BUILD_ROCFFT"
   exit

else
   cd /tmp

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/rocfft.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached rocFFT"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/rocfft
      cd /opt/rocmplus-${ROCM_VERSION}
      #${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/rocfft.tgz
      #chown -R root:root /opt/rocmplus-${ROCM_VERSION}/rocfft
      #${SUDO} chmod og-w /opt/rocmplus-${ROCM_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/rocfft.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building ROCFFT"
      echo "============================"
      echo " ROCFFT_PATH is $ROCFFT_PATH"
      echo ""


      # Load the ROCm version for this HIP-Python build -- use hip compiler, path to ROCm and the GPU model
      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z00_lmod.sh
      module load rocm/${ROCM_VERSION} amdclang

#     if [ -d "$ROCFFT_PATH" ]; then
#        # don't use sudo if user has write access to install path
#        if [ -w ${ROCFFT_PATH} ]; then
#           SUDO=""
#        else
#           echo "WARNING: using an install path that requires sudo"
#        fi
#     else
#        # if install path does not exist yet, the check on write access will fail
#        echo "WARNING: using sudo, make sure you have sudo privileges"
#     fi

      ${SUDO} mkdir -p $ROCFFT_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $ROCFFT_PATH
      fi

      git clone --no-checkout https://github.com/rocm/rocm-libraries
      cd rocm-libraries
      git sparse-checkout init
      git sparse-checkout set projects/rocfft
      git checkout
      cd projects/rocfft
      mkdir build && cd build
      cmake -DGPU_TARGETS="${AMDGPU_GFXMODEL}" -DCMAKE_INSTALL_PREFIX=${ROCFFT_PATH} ..
      make
      make install
      cd ../../..
      rm -rf rocm-libraries

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $ROCFFT_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $ROCFFT_PATH -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w $ROCFFT_PATH
      fi
   fi

   # Create a module file for rocfft
#   if [ -d "$MODULE_PATH" ]; then
#      # use sudo if user does not have write access to module path
#      if [ ! -w ${MODULE_PATH} ]; then
#         SUDO="sudo"
#      else
#         echo "WARNING: not using sudo since user has write access to module path"
#      fi
#   else
#      # if module path dir does not exist yet, the check on write access will fail
#      SUDO="sudo"
#      echo "WARNING: using sudo, make sure you have sudo privileges"
#   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCFFT_VERSION}.lua
	whatis("rocFFT with ROCm support")

	local base = "${ROCFFT_PATH}"

        prereq("rocm/${ROCM_VERSION}")

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
EOF

fi
