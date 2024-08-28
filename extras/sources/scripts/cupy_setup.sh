#/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.0
BUILD_CUPY=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/cupy
AMDGPU_GFXMODEL_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults

usage()
{
   echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "--build-cupy"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-AI/cupy" 
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
      "--build-cupy")
          shift
          BUILD_CUPY=${1}
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

# Load the ROCm version for this CuPy build
source /etc/profile.d/lmod.sh
source /etc/profile.d/z01_lmod.sh
module load rocm/${ROCM_VERSION}
if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

echo ""
echo "==================================="
echo "Starting Cupy Install with"
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL" 
echo "BUILD_CUPY: $BUILD_CUPY" 
echo "==================================="
echo ""

if [ "${BUILD_CUPY}" = "0" ]; then

   echo "CuPy will not be built, according to the specified value of BUILD_CUPY"
   echo "BUILD_CUPY: $BUILD_CUPY"
   exit

else 
   cd /tmp

   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}
   if [ -f ${CACHE_FILES}/cupy.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached CuPy"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/cupy
      cd /opt/rocmplus-${ROCM_VERSION}
      #${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/cupy.tgz
      #chown -R root:root /opt/rocmplus-${ROCM_VERSION}/cupy
      #${SUDO} chmod og-w /opt/rocmplus-${ROCM_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/cupy.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building CuPy"
      echo "============================"
      echo ""

      
      # Load the ROCm version for this CuPy build -- use hip compiler, path to ROCm and the GPU model
      export CUPY_INSTALL_USE_HIP=1
      export ROCM_HOME=${ROCM_PATH}
      export HCC_AMDGPU_ARCH=${AMDGPU_GFXMODEL}
      
      # Get source from the ROCm repository of CuPy.
      git clone -q --depth 1 --recursive https://github.com/ROCm/cupy.git
      cd cupy
      
      # use version 1.25 of numpy – need to test with later numpy version
      sed -i -e '/numpy/s/1.27/1.25/' setup.py
      # set python path to installation directory
      PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/cupy
      # build basic cupy package
      python3 setup.py -q bdist_wheel
      
      # install necessary packages in installation directory
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/cupy
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}/cupy
      fi
      pip3 install -v --target=/opt/rocmplus-${ROCM_VERSION}/cupy pytest mock
      pip3 install -v --target=/opt/rocmplus-${ROCM_VERSION}/cupy dist/cupy-13.0.0b1-cp310-cp310-linux_x86_64.whl
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/cupy -type f -execdir chown root:root "{}" +
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/cupy -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w /opt/rocmplus-${ROCM_VERSION}/cupy
      fi
      
      # cleanup
      cd ..
      rm -rf cupy
      module unload rocm/${ROCM_VERSION}
   fi
      
   # Create a module file for cupy
   
   ${SUDO} mkdir -p ${MODULE_PATH}
   
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/13.0.0b1.lua
	whatis("HIP version of CuPy")

	load("rocm/${ROCM_VERSION}")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/cupy")
EOF

fi
