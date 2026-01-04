#!/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.4.3
BUILD_HIP_PYTHON=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/hip-python
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
HIP_PYTHON_PATH=/opt/rocmplus-${ROCM_VERSION}/hip-python
HIP_PYTHON_PATH_INPUT=""
HIP_PYTHON_VERSION="13.6.0"

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
   echo "  --build-hip-python [ BUILD_HIP_PYTHON ] default $BUILD_HIP_PYTHON "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ HIP_PYTHON_PATH ] default $HIP_PYTHON_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hip-python-version [ HIP_PYTHON_VERSION ] specify the version of HIP-Python, default is $HIP_PYTHON_VERSION"
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
      "--build-hip-python")
          shift
          BUILD_HIP_PYTHON=${1}
          reset-last
          ;;
      "--hip-python-version")
          shift
          HIP_PYTHON_VERSION=${1}
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
          HIP_PYTHON_PATH_INPUT=${1}
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

if [ "${HIP_PYTHON_PATH_INPUT}" != "" ]; then
   HIP_PYTHON_PATH=${HIP_PYTHON_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   HIP_PYTHON_PATH=/opt/rocmplus-${ROCM_VERSION}/hip-python
fi

echo ""
echo "==================================="
echo "Starting HIP-Python Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_HIP_PYTHON: $BUILD_HIP_PYTHON"
echo "HIP_PYTHON_PATH: $HIP_PYTHON_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "HIP_PYTHON_VERSION: $HIP_PYTHON_VERSION"
echo "==================================="
echo ""

if [ "${BUILD_HIP_PYTHON}" = "0" ]; then

   echo "HIP-Python will not be built, according to the specified value of BUILD_HIP_PYTHON"
   echo "BUILD_HIP_PYTHON: $BUILD_HIP_PYTHON"
   exit

else
   cd /tmp

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/hip-python.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HIP-Python"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/hip-python
      cd /opt/rocmplus-${ROCM_VERSION}
      #${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/hip-python.tgz
      #chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hip-python
      #${SUDO} chmod og-w /opt/rocmplus-${ROCM_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/hip-python.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building HIP-Python"
      echo "============================"
      echo " HIP_PYTHON_PATH is $HIP_PYTHON_PATH"
      echo ""


      # Load the ROCm version for this HIP-Python build -- use hip compiler, path to ROCm and the GPU model
      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z00_lmod.sh
      if [[ "${ROCM_VERSION}" == *"afar"* ]]; then
         ROCM_AFAR_VERSION=`echo rocm${ROCM_VERSION} | sed -e 's!afar!afar/!'`
         module load $ROCM_AFAR_VERSION
      else
         module load rocm/${ROCM_VERSION}
      fi
      export HIP_PYTHON_INSTALL_USE_HIP=1
      export ROCM_HOME=${ROCM_PATH}
      export HIPCC=${ROCM_HOME}/bin/hipcc
      export HCC_AMDGPU_ARCH=${AMDGPU_GFXMODEL}

      if [ -d "$HIP_PYTHON_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${HIP_PYTHON_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $HIP_PYTHON_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $HIP_PYTHON_PATH
      fi
      python3 -m venv hip-python-build
      source hip-python-build/bin/activate
      python3 -m pip install pip
      # remove the last digit from the version and replace with 0
      ROCM_VERSION_MODIFIED="${ROCM_VERSION::-1}0"
      # will be installed as a dependency of numba-hip and avoid an extra subdirectory
      #python3 -m pip install --target=$HIP_PYTHON_PATH -i https://test.pypi.org/simple hip-python~=${ROCM_VERSION_MODIFIED}
      python3 -m pip config set global.extra-index-url https://test.pypi.org/simple
      python3 -m pip install --target=$HIP_PYTHON_PATH/hip-python "numba-hip[rocm-6-4-0] @ git+https://github.com/ROCm/numba-hip.git"
      deactivate
      rm -rf hip-python-build
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $HIP_PYTHON_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $HIP_PYTHON_PATH -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w $HIP_PYTHON_PATH
      fi
   fi

   # Create a module file for hip-python
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${HIP_PYTHON_VERSION}.lua
        whatis("HIP-Python with ROCm support")

        prereq("rocm/${ROCM_VERSION}")
        prepend_path("PYTHONPATH","$HIP_PYTHON_PATH/hip-python")
EOF

fi
