#!/bin/bash

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_PYTORCH=0
PYTORCH_VERSION=2.4.0
TORCHVISION_VERSION=0.19.0
TORCHVISION_HASH="48b1edf"
TORCHAUDIO_VERSION=2.4.0
TORCHAUDIO_HASH="69d4077"
PILLOW_VERSION=11.0.0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/pytorch
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/pytorch
INSTALL_PATH_INPUT=""
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
USE_WHEEL=0

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

usage()
{
   echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default is $AMDGPU_GFXMODEL"
   echo "--build-pytorch [ BUILD_PYTORCH ] set to 1 to build jax default is 0"
   echo "--pytorch-version [ PYTORCH_VERSION ] version of PyTorch, default is $PYTORCH_VERSION"
   echo "--install-path [ INSTALL_PATH ] directory where PyTorch, Torchaudio and Torchvision will be installed, default is $INSTALL_PATH"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "--use-wheel [ USE_WHEEL ] build with a wheel instead of from source, default is $USE_WHEEL"
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
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
	  reset-last
          ;;
      "--build-pytorch")
          shift
          BUILD_PYTORCH=${1}
	  reset-last
          ;;
      "--pytorch-version")
          shift
          PYTORCH_VERSION=${1}
	  reset-last
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
      "--use-wheel")
          shift
          USE_WHEEL=${1}
	  reset-last
          ;;
      *)  
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/pytorch
fi

PYTORCH_PATH=$INSTALL_PATH/pytorch
TORCHVISION_PATH=$INSTALL_PATH/vision
TORCHAUDIO_PATH=$INSTALL_PATH/audio

if [ "${BUILD_PYTORCH}" = "0" ]; then

   echo "pytorch will not be built, according to the specified value of BUILD_PYTORCH"
   echo "BUILD_PYTORCH: $BUILD_PYTORCH"
   exit

else

   echo ""
   echo "======================================"
   echo "Starting Pytorch Install with"
   echo "PyTorch Version: $PYTORCH_VERSION"
   echo "PyTorch Install Directory: $PYTORCH_PATH"
   echo "Torchvision Version: $TORCHVISION_VERSION"
   echo "Torchvision Install Directory: $TORCHVISION_PATH"
   echo "Torchaudio Version: $TORCHAUDIO_VERSION"
   echo "Torchaudio Install Directory: $TORCHAUDIO_PATH"
   echo "ROCm Version: $ROCM_VERSION"
   echo "Module Directory: $MODULE_PATH"
   echo "Use Wheel to Build?: $USE_WHEEL"
   echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
   echo "======================================"
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/pytorch.tgz ] && [ -f ${CACHE_FILES}/audio.tgz ] && [ -f ${CACHE_FILES}/vision.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Pytorch"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/pytorch.tgz
      tar -xzf ${CACHE_FILES}/audio.tgz
      tar -xzf ${CACHE_FILES}/vision.tgz
      if [ "${USER}" != "sysadmin" ]; then
         rm ${CACHE_FILES}/pytorch.tgz ${CACHE_FILES}/audio.tgz ${CACHE_FILES}/vision.tgz
      fi

   elif [ "${USE_WHEEL}" == "1" ]; then

      echo " Build with wheel coming soon, for now please build from source by setting --use-wheel 0"

   else
      echo ""
      echo "============================"
      echo " Installing Pytorch, "
      echo " Torchaudio and Torchivision"
      echo " from source"
      echo "============================"
      echo ""


      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm
      # Build with GPU aware MPI not working yet
      # Need to use the update-alternatives in openmpi setup to get
      # GPU aware MPI
      #module load openmpi

      ${SUDO} apt-get update
      ${SUDO} ${DEB_FRONTEND} apt-get install -y python-is-python3
      ${SUDO} ${DEB_FRONTEND} apt-get install -y libopenmpi-dev
      
      # unset environment variables that are not needed for pytorch
      unset BUILD_AOMP_LATEST
      unset BUILD_CLACC_LATEST
      unset BUILD_GCC_LATEST
      unset BUILD_LLVM_LATEST
      unset BUILD_OG_LATEST
      unset USE_CACHED_APPS
      unset BUILD_CUPY
      unset BUILD_PYTORCH
      unset BUILD_KOKKOS
      
      export PYTHONPATH=${PYTORCH_PATH}/lib/python3.10/site-packages:$PYTHONPATH
      
      # Install of pre-built pytorch for reference
      #${SUDO} pip3 install --target=/opt/rocmplus-${ROCM_VERSION}/pytorch torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0
      
      export _GLIBCXX_USE_CXX11_ABI=1
      export ROCM_HOME=${ROCM_PATH}
      export ROCM_SOURCE_DIR=${ROCM_PATH}
      export USE_ROCM=1
      export USE_CUDA=0
      export MAX_JOBS=20
      export USE_MPI=1
      export PYTORCH_ROCM_ARCH=${AMDGPU_GFXMODEL}
      
      export PYTORCH_INSTALL_DIR=${PYTORCH_PATH}

      # don't use sudo if user has write access to install path
      if [ -w ${INSTALL_PATH} ]; then
         SUDO=""
      fi

      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${PYTORCH_PATH}
      ${SUDO} mkdir -p ${TORCHAUDIO_PATH}
      ${SUDO} mkdir -p ${TORCHVISION_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      # This block of code is to retry if git clone fails.
      RETRIES=6
      DELAY=30
      COUNT=1
      while [ $COUNT -lt $RETRIES ]; do
        git clone --recursive --depth 1 --branch v${PYTORCH_VERSION} https://github.com/pytorch/pytorch
        if [ $? -eq 0 ]; then
          RETRIES=0
          break
        fi
        let COUNT=$COUNT+1
        sleep $DELAY
      done

      cd pytorch
      if [[ "${USER}" == "root" ]]; then
         sed -i '266i os.environ["ROCM_HOME"] = '"${ROCM_HOME}"'' setup.py
         sed -i '266i os.environ["ROCM_SOURCE_DIR"] = '"${ROCM_SOURCE_DIR}"'' setup.py
         sed -i '266i os.environ["PYTORCH_ROCM_ARCH"] = '"${PYTORCH_ROCM_ARCH}"'' setup.py
      fi
      # Pytorch 2.4 needs some patches to build for ROCm
      # NOT NEEDED ANYMORE:Fix triton build failure due to tritonlang.blob.core.windows.net not available
      # The download from https://tritonlang.blob.core.windows.net/llvm-builds/ has been
      # blocked and made private. We substitute https://oaitriton.blob.core.windows.net/public/llvm-builds/
      # The pytorch head already has this change, but the pytorch 2.4 does not
      # Patch documentation is at https://github.com/pytorch/pytorch/pull/133694/files
      # patch .github/scripts/build_triton_wheel.py < /tmp/pytorch_build_triton_wheel_py.patch
      # The next fix is a ROCm fix. The USE_ROCM define is not passed to the CAFFE2 build
      # https://github.com/pytorch/pytorch/issues/103312
      # We comment out the lines within the USE_ROCM block in the torch/csrc/jit/ir/ir.cpp file
      sed -i -e 's/case cuda/\/\/case cuda/' torch/csrc/jit/ir/ir.cpp
      # With the next fix we are preventing Caffe2 from writing into /usr/local/
      sed -i '/install(DIRECTORY ${CMAKE_BINARY_DIR}\/caffe2 DESTINATION ${PYTHON_LIB_REL_PATH}/s/^/#/g' caffe2/CMakeLists.txt 
      sed -i '/FILES_MATCHING PATTERN \"\*\.py")/s/^/#/g' caffe2/CMakeLists.txt

      pip3 install mkl-static mkl-include 
      pip3 install -r requirements.txt
      
      python3 tools/amd_build/build_amd.py >& /dev/null
      
      echo ""
      echo "===================="
      echo "Starting setup.py install"
      echo "===================="
      echo ""
      python setup.py install --prefix=${PYTORCH_PATH}
      echo ""
      echo "===================="
      echo "Finished setup.py install"
      echo "===================="
      echo ""

      export PYTHONPATH=${PYTORCH_PATH}/lib/python3.10/site-packages
      echo "PYTHONPATH is ${PYTHONPATH}"
      python3 -c 'import torch' 2> /dev/null && echo 'Success' || echo 'Failure'

      cd ..
      ${SUDO} rm -rf pytorch
      cd /tmp

      export PYTHONPATH=${PYTORCH_PATH}/lib/python3.10/site-packages
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.10/site-packages/torchvision-${TORCHVISION_VERSION}a0+${TORCHVISION_HASH}-py3.10-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.10/site-packages/pillow-${PILLOW_VERSION}-py3.10-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=${TORCHAUDIO_PATH}/lib/python3.10/site-packages/torchaudio-${TORCHAUDIO_VERSION}a0+${TORCHAUDIO_HASH}-py3.10-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.10/site-packages:$PYTHONPATH
      export PYTHONPATH=${TORCHAUDIO_PATH}/lib/python3.10/site-packages:$PYTHONPATH

      git clone --recursive --depth 1 --branch v${TORCHVISION_VERSION} https://github.com/pytorch/vision
      cd vision
      python3 setup.py install --prefix=${TORCHVISION_PATH}
      cd ..

      git clone --recursive --depth 1 --branch v${TORCHAUDIO_VERSION} https://github.com/pytorch/audio
      cd audio
      python3 setup.py install --prefix=${TORCHAUDIO_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
         ${SUDO} find ${PYTORCH_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${PYTORCH_PATH} -type d -execdir chown root:root "{}" +
         ${SUDO} find ${TORCHVISION_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${TORCHVISION_PATH} -type d -execdir chown root:root "{}" +
         ${SUDO} find ${TORCHAUDIO_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${TORCHAUDIO_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
         ${SUDO} chmod go-w ${PYTORCH_PATH}
         ${SUDO} chmod go-w ${TORCHVISION_PATH}
         ${SUDO} chmod go-w ${TORCHAUDIO_PATH}
      fi

      # cleanup
      cd ..
      rm -rf vision audio
      ${SUDO} rm -rf /tmp/amd_triton_kernel* /tmp/can*

   fi
fi

# Create a module file for pytorch
if [ ! -w ${MODULE_PATH} ]; then
   SUDO="sudo"
fi
${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${PYTORCH_VERSION}.lua
        whatis("PyTorch version ${PYTORCH_VERSION} with ROCm Support")

        load("rocm/${ROCM_VERSION}")
        conflict("miniconda3")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}/lib/python3.10/site-packages/torchvision-${TORCHVISION_VERSION}a0+${TORCHVISION_HASH}-py3.10-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}/lib/python3.10/site-packages/pillow-${PILLOW_VERSION}-py3.10-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${TORCHAUDIO_PATH}/lib/python3.10/site-packages/torchaudio-${TORCHAUDIO_VERSION}a0+${TORCHAUDIO_HASH}-py3.10-linux-x86_64.egg")
        prepend_path("PYTHONPATH","${PYTORCH_PATH}/lib/python3.10/site-packages")
EOF

#pip download --only-binary :all: --dest /opt/wheel_files_6.0/pytorch-rocm --no-cache --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/rocm6.0
#cat > /opt/wheel_files_6.0/README_pytorch <<-EOF
#        To install the pytorch package for ROCM 6.0
#           pip3 install /opt/wheel_files-6.0/pytorch-rocm/torch-2.3.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torchvision-0.18.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#EOF

