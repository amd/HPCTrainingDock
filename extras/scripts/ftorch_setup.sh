#!/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.2.0
BUILD_FTORCH=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/ftorch
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
FTORCH_PATH=/opt/rocmplus-${ROCM_VERSION}/ftorch
FTORCH_PATH_INPUT=""
PYTORCH_MODULE=pytorch

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
   echo "  --build-ftorch [ BUILD_FTORCH ] default $BUILD_FTORCH "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --pytorch-module [ PYTORCH_MODULE ] default $PYTORCH_MODULE"
   echo "  --install-path [ FTORCH_PATH ] default $FTORCH_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
      "--build-ftorch")
          shift
          BUILD_FTORCH=${1}
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
          FTORCH_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--pytorch-module")
          shift
          PYTORCH_MODULE=${1}
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

if [ "${FTORCH_PATH_INPUT}" != "" ]; then
   FTORCH_PATH=${FTORCH_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   FTORCH_PATH=/opt/rocmplus-${ROCM_VERSION}/ftorch
fi

echo ""
echo "==================================="
echo "Starting FTorch Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_FTORCH: $BUILD_FTORCH"
echo "FTORCH_PATH: $FTORCH_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_FTORCH}" = "0" ]; then

   echo "FTorch will not be built, according to the specified value of BUILD_FTORCH"
   echo "BUILD_FTORCH: $BUILD_FTORCH"
   exit

else
   cd /tmp

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/ftorch.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached FTorch"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/ftorch
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/ftorch.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/ftorch.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building FTorch"
      echo "============================"
      echo ""

      # Load the ROCm version for this FTorch build
      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z00_lmod.sh
      if [[ "${ROCM_VERSION}" == *"afar"* ]]; then
         ROCM_AFAR_VERSION=`echo rocm${ROCM_VERSION} | sed -e 's!afar-!afar/!'`
         module load $ROCM_AFAR_VERSION
      else
         module load rocm/${ROCM_VERSION}
      fi
      module load ${PYTORCH_MODULE}

      if [ -d "$FTORCH_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${FTORCH_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $FTORCH_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $FTORCH_PATH
      fi

      git clone https://github.com/Cambridge-ICCS/FTorch.git 
      cd FTorch

      mkdir build && cd build
      cmake -DCMAKE_INSTALL_PREFIX=$FTORCH_PATH  -DGPU_DEVICE=HIP ..
      make -j
      ${SUDO} make install

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $FTORCH_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $FTORCH_PATH -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w $FTORCH_PATH
      fi

      # cleanup
      cd ../..
      rm -rf FTorch
      module unload rocm/${ROCM_VERSION}
      module unload ${PYTORCH_MODULE}
   fi

   # Create a module file for cupy
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/dev.lua
	whatis("FTorch: a library for directly calling PyTorch ML models from Fortran")

	load("rocm/${ROCM_VERSION}")
	load("${PYTORCH_MODULE}")
	prepend_path("LD_LIBRARY_PATH", pathJoin("${FTORCH_PATH}", "lib"))
	setenv("FTORCH_HOME","${FTORCH_PATH}")
	setenv("FTorch_DIR","${FTORCH_PATH}")

EOF

fi
