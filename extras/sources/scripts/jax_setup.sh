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

# Load the ROCm version for this JAX build
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
      echo " Building JAXLIB and JAX"
      echo "============================"
      echo ""

      export JAX_PLATFORMS="rocm,cpu"

      git clone https://github.com/ROCm/xla.git
      cd xla
      git reset --hard 8d53a6c61429310b561f17e08a35d90486055d64
      export XLA_PATH=$PWD
      cd ..
      git clone https://github.com/ROCm/jax.git
      cd jax
      git reset --hard 644ac10c92c38bfbeb87ba5698084757a80408a5 
      
      # install necessary packages in installation directory
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/jaxlib
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}/jaxlib
      fi

      if [[ `which python | wc -l` -eq 0 ]]; then
         echo "============================"
	 echo "WARNING: pyhton needs to be linked to python3 for the build to work"
	 echo ".....Installing python-is-python3......"
         echo "============================"
	 ${SUDO} apt-get update
         ${SUDO} apt-get install -y python-is-python3
      fi

      # build the wheel for jaxlib
      python3 build/build.py --enable_rocm --rocm_path=$ROCM_PATH \
	                     --bazel_options=--override_repository=xla=$XLA_PATH \
			     --rocm_amdgpu_target=$AMDGPU_GFXMODEL \
			     --bazel_options=--action_env=CC=/usr/bin/gcc --nouse_clang \
			     --build_gpu_plugin --gpu_plugin_rocm_version=60 --build_gpu_kernel_plugin=rocm \
			     --bazel_options=--jobs=128 \
			     --bazel_startup_options=--host_jvm_args=-Xmx512m

      # install the wheel for jaxlib
      pip3 install -v --target=/opt/rocmplus-${ROCM_VERSION}/jaxlib dist/jax*.whl

      # next we need to install the jax python module
      sudo pip3 install --target=/opt/rocmplus-${ROCM_VERSION}/jax .

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/jaxlib -type f -execdir chown root:root "{}" +
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/jaxlib -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w /opt/rocmplus-${ROCM_VERSION}/jaxlib
      fi

      # cleanup
      cd ..
      ${SUDO} rm -rf /tmp/jax
      ${SUDO} rm -rf /tmp/xla
      module unload rocm/${ROCM_VERSION}
   fi
      
   # Create a module file for jax
   
   ${SUDO} mkdir -p ${MODULE_PATH}
   
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/0.4.30.dev.lua
	whatis("JAX with ROCm support")

	load("rocm/${ROCM_VERSION}")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/jax")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/jaxlib")
EOF

fi
