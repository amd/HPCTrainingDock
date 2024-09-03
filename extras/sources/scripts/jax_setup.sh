#/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.0
BUILD_JAX=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/jax
AMDGPU_GFXMODEL_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults

usage()
{
   echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "--build-jax"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-AI/jax" 
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
      "--build-jax")
          shift
          BUILD_JAX=${1}
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
echo "Starting JAX Install with"
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL" 
echo "BUILD_JAX: $BUILD_JAX" 
echo "==================================="
echo ""

if [ "${BUILD_JAX}" = "0" ]; then

   echo "JAX will not be built, according to the specified value of BUILD_JAX"
   echo "BUILD_JAX: $BUILD_JAX"
   exit

else 
   cd /tmp

   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}
   if [ -f ${CACHE_FILES}/jax.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached JAX"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/jax
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/jax.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/jax.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building JAX"
      echo "============================"
      echo ""

      export JAX_ROCM_VERSION=$ROCM_VERSION
      
      git clone --recursive --depth 1 --branch rocm-xla-stable-2024_08_07 https://github.com/ROCmSoftwarePlatform/xla.git
      cd xla
      export XLA_PATH=$PWD
      cd ..
      git clone --recursive --depth 1 --branch rocm-jax-stable-2024_08_07 https://github.com/ROCm/jax.git  
      cd jax
      
      # install necessary packages in installation directory
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/jax
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}/jax
      fi
      pip3 install -v --target=/opt/rocmplus-${ROCM_VERSION}/jax dist/jaxlib-0.4.32.dev20240903+rocm620-cp310-cp310-manylinux2014_x86_64.whl 
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/jax -type f -execdir chown root:root "{}" +
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/jax -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w /opt/rocmplus-${ROCM_VERSION}/jax
      fi
      
      # cleanup
      cd ..
      rm -rf jax
      module unload rocm/${ROCM_VERSION}
   fi
      
   # Create a module file for jax
   
   ${SUDO} mkdir -p ${MODULE_PATH}
   
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/0.4.32.dev.lua
	whatis("JAX with ROCm support")

	load("rocm/${ROCM_VERSION}")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/jax")
EOF

fi
