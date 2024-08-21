#!/bin/bash

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_PYTORCH=0

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          ;;
      "--build-pytorch")
          shift
          BUILD_PYTORCH=${1}
          ;;
      *)  
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

echo ""
echo "==================================="
echo "Starting Pytorch Install with"
echo "BUILD_PYTORCH: $BUILD_PYTORCH" 
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL" 
echo "==================================="
echo ""

if [ "${BUILD_PYTORCH}" = "0" ]; then

   echo "pytorch will not be build, according to the specified value of BUILD_PYTORCH"
   echo "BUILD_PYTORCH: $BUILD_PYTORCH"
   exit

else
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}
   if [ -f ${CACHE_FILES}/pytorch.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Pytorch"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/pytorch.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/pytorch
      if [ "${USER}" != "sysadmin" ]; then
         rm ${CACHE_FILES}/pytorch.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building Pytorch"
      echo "============================"
      echo ""


      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm
      # Build with GPU aware MPI not working yet
      #module load openmpi
      
      # unset environment variables that are not needed for pytorch
      unset BUILD_AOMP_LATEST
      unset BUILD_CLACC_LATEST
      unset BUILD_GCC_LATEST
      unset BUILD_LLVM_LATEST
      unset BUILD_OG_LATEST
      unset USE_CACHED_APPS
      
      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/pytorch/lib/python3.10/site-packages:$PYTHONPATH
      
      # Install of pre-built pytorch for reference
      #sudo pip3 install --target=/opt/rocmplus-${ROCM_VERSION}/pytorch torch torchvision torchaudio --index-url https://download.pytorch.org/whl/rocm6.0
      
      export _GLIBCXX_USE_CXX11_ABI=1
      export ROCM_HOME=${ROCM_PATH}
      export USE_ROCM=1
      export USE_CUDA=0
      export MAX_JOBS=20
      export USE_MPI=0
      export PYTORCH_ROCM_ARCH="${AMDGPU_GFXMODEL}"
      
      git clone --recursive https://github.com/pytorch/pytorch
      cd pytorch
      git reset --hard d990dad # PyTorch 2.4, Python 3.12
      git submodule sync
      git submodule update --init --recursive
      sudo pip3 install mkl-static mkl-include
      sudo pip3 install -r requirements.txt
      
      sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/pytorch
      sudo python3 tools/amd_build/build_amd.py >& /dev/null
      
      echo ""
      echo "===================="
      echo "Starting setup.py install"
      echo "===================="
      echo ""
      sudo python3 setup.py install --prefix=/opt/rocmplus-${ROCM_VERSION}/pytorch
      echo ""
      echo "===================="
      echo "Finished setup.py install"
      echo "===================="
      echo ""
    
      cd /tmp

      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/pytorch/lib/python3.10/site-packages
      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages/torchvision-0.19.0a0+48b1edf-py3.10-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages/pillow-10.4.0-py3.10-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/audio/lib/python3.10/site-packages/torchaudio-2.4.0a0+69d4077-py3.10-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages:$PYTHONPATH
      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/audio/lib/python3.10/site-packages:$PYTHONPATH

      # install necessary packages in installation directory
      sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/vision
      sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/audio

      if [[ "${USER}" != "root" ]]; then
         sudo chmod a+w /opt/rocmplus-${ROCM_VERSION}/vision
         sudo chmod a+w /opt/rocmplus-${ROCM_VERSION}/audio
      fi

      git clone --recursive https://github.com/pytorch/vision
      cd vision
      git reset --hard 48b1edf # Torchvision 0.19
      python3 setup.py install --prefix=/opt/rocmplus-${ROCM_VERSION}/vision
      cd ..

      git clone --recursive https://github.com/pytorch/audio
      cd audio
      git reset --hard 69d4077 # TorhcAudio 2.4.0
      python3 setup.py install --prefix=/opt/rocmplus-${ROCM_VERSION}/audio

      if [[ "${USER}" != "root" ]]; then
         sudo find /opt/rocmplus-${ROCM_VERSION}/vision -type f -execdir chown root:root "{}" +
         sudo find /opt/rocmplus-${ROCM_VERSION}/vision -type d -execdir chown root:root "{}" +
         sudo find /opt/rocmplus-${ROCM_VERSION}/audio -type f -execdir chown root:root "{}" +
         sudo find /opt/rocmplus-${ROCM_VERSION}/audio -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         sudo chmod go-w /opt/rocmplus-${ROCM_VERSION}/vision
         sudo chmod go-w /opt/rocmplus-${ROCM_VERSION}/audio
      fi

      # cleanup
      cd ..
      rm -rf vision audio
      sudo rm -rf /app/pytorch
      sudo rm -rf /tmp/amd_triton_kernel* /tmp/can*

   fi
fi

# Create a module file for Pytorch
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/pytorch

sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | sudo tee ${MODULE_PATH}/2.4.lua
        whatis("HIP version of PyTorch")

        load("rocm/${ROCM_VERSION}")
        conflict("miniconda3")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages/torchvision-0.19.0a0+48b1edf-py3.10-linux-x86_64.egg")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages/pillow-10.4.0-py3.10-linux-x86_64.egg")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/audio/lib/python3.10/site-packages/torchaudio-2.4.0a0+69d4077-py3.10-linux-x86_64.egg")
        prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/pytorch/lib/python3.10/site-packages")
EOF

#pip download --only-binary :all: --dest /opt/wheel_files_6.0/pytorch-rocm --no-cache --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/rocm6.0
#cat > /opt/wheel_files_6.0/README_pytorch <<-EOF
#        To install the pytorch package for ROCM 6.0
#           pip3 install /opt/wheel_files-6.0/pytorch-rocm/torch-2.3.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torchvision-0.18.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#EOF

