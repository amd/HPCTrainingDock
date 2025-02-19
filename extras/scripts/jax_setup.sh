#/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.0
BUILD_JAX=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/jax
AMDGPU_GFXMODEL_INPUT=""
JAX_VERSION=4.35
JAX_PATH=/opt/rocmplus-${ROCM_VERSION}/jax
JAX_PATH_INPUT=""
JAXLIB_PATH=/opt/rocmplus-${ROCM_VERSION}/jaxlib
JAXLIB_PATH_INPUT=""

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

usage()
{
   echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected, specify as a comma separated list"
   echo "--build-jax [ BUILD_JAX ] set to 1 to build jax default is 0"
   echo "--jax-version [ JAX_VERSION ] version of JAX, XLA, and JAXLIB, default is $JAX_VERSION"
   echo "--jax-install-path [ JAX_PATH ] directory where JAX will be installed, default is $JAX_PATH"
   echo "--jaxlib-install-path [ JAXLIB_PATH ] directory where JAX will be installed, default is $JAXLIB_PATH"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default $MODULE_PATH"
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
      "--jax-version")
          shift
          JAX_VERSION=${1}
	  reset-last
          ;;
      "--jax-install-path")
          shift
          JAX_PATH_INPUT=${1}
	  reset-last
          ;;
      "--jaxlib-install-path")
          shift
          JAXLIB_PATH_INPUT=${1}
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

if [ "${JAX_PATH_INPUT}" != "" ]; then
   JAX_PATH=${JAX_PATH_INPUT}
else
   # override jax path in case ROCM_VERSION has been supplied as input
   JAX_PATH=/opt/rocmplus-${ROCM_VERSION}/jax
fi

if [ "${JAXLIB_PATH_INPUT}" != "" ]; then
   JAXLIB_PATH=${JAXLIB_PATH_INPUT}
else
   # override jaxlib path in case ROCM_VERSION has been supplied as input
   JAXLIB_PATH=/opt/rocmplus-${ROCM_VERSION}/jaxlib
fi


# don't use sudo if user has write access to install path
if [ -w ${JAX_PATH} ]; then
   if [ -w ${JAXLIB_PATH} ]; then
   SUDO=""
   fi
fi


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
echo "====================================="
echo " Installing JAXLIB and JAX"
echo " JAX Install directory: $JAX_PATH"
echo " JAXLIB Install directory: $JAXLIB_PATH"
echo " JAX Module directory: $MODULE_PATH"
echo " ROCm Version: $ROCM_VERSION"
echo "====================================="
echo ""

if [ "${BUILD_JAX}" = "0" ]; then

   echo "JAX will not be built, according to the specified value of BUILD_JAX"
   echo "BUILD_JAX: $BUILD_JAX"
   exit

else 
   cd /tmp

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/jax.tgz ] && [ -f ${CACHE_FILES}/jaxlib.tgz ]; then
      echo ""
      echo "==================================="
      echo " Installing Cached JAXLIB and JAX"
      echo "==================================="
      echo ""

      #install the cached version
      ${SUDO} mkdir -p ${JAX_PATH}
      cd /opt/rocmplus-${ROCM_VERSION}

      ${SUDO} tar -xzpf ${CACHE_FILES}/jax.tgz

      ${SUDO} mkdir -p ${JAXLIB_PATH}
      ${SUDO} tar -xzpf ${CACHE_FILES}/jaxlib.tgz

      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm  ${CACHE_FILES}/jax.tgz ${CACHE_FILES}/jaxlib.tgz
      fi
   else
      echo ""
      echo "======================================="
      echo " Installing JAXLIB and JAX from source"
      echo "======================================="
      echo ""

      if [[ `which python | wc -l` -eq 0 ]]; then
         echo "============================"
	 echo "WARNING: python needs to be linked to python3 for the build to work"
	 echo ".....Installing python-is-python3......"
         echo "============================"
	 ${SUDO} apt-get update
         ${SUDO} ${DEB_FRONTEND} apt-get install -y python-is-python3
      fi

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm/${ROCM_VERSION}

      export JAX_PLATFORMS="rocm,cpu"

      git clone --depth 1 --branch rocm-jaxlib-v0.${JAX_VERSION} https://github.com/ROCm/xla.git
      cd xla
      export XLA_PATH=$PWD
      cd ..
      git clone --depth 1 --branch rocm-jaxlib-v0.${JAX_VERSION} https://github.com/ROCm/jax.git
      cd jax
      
      # install necessary packages in installation directory
      ${SUDO} mkdir -p ${JAXLIB_PATH}
      ${SUDO} mkdir -p ${JAX_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${JAX_PATH}
         ${SUDO} chmod a+w ${JAXLIB_PATH}
      fi

      # build the wheel for jaxlib
      python3 build/build.py --enable_rocm --rocm_path=$ROCM_PATH \
	                     --bazel_options=--override_repository=xla=$XLA_PATH \
			     --rocm_amdgpu_targets=$AMDGPU_GFXMODEL \
			     --bazel_options=--action_env=CC=/usr/bin/gcc --nouse_clang \
			     --build_gpu_plugin --gpu_plugin_rocm_version=60 --build_gpu_kernel_plugin=rocm \
			     --bazel_options=--jobs=128 \
			     --bazel_startup_options=--host_jvm_args=-Xmx512m

      # install the wheel for jaxlib
      pip3 install -v --target=${JAXLIB_PATH} dist/jax*.whl

      # next we need to install the jax python module
      pip3 install --target=${JAX_PATH} .

      # cleanup
      cd ..
      rm -rf /tmp/jax
      rm -rf /tmp/xla

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${JAXLIB_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${JAXLIB_PATH} -type d -execdir chown root:root "{}" +
         ${SUDO} find ${JAX_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${JAX_PATH} -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w ${JAXLIB_PATH}
         ${SUDO} chmod go-w ${JAX_PATH}
      fi

      module unload rocm/${ROCM_VERSION}
   fi
      
   # Create a module file for jax
   
   ${SUDO} mkdir -p ${MODULE_PATH}
   
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/0.${JAX_VERSION}.lua
	whatis("JAX version ${JAX_VERSION} with ROCm support")

	load("rocm/${ROCM_VERSION}")
        setenv("XLA_FLAGS","--xla_gpu_enable_triton_gemm=False --xla_gpu_autotune_level=3")
	prepend_path("PYTHONPATH","${JAX_PATH}")
	prepend_path("PYTHONPATH","${JAXLIB_PATH}")
EOF

fi
