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
      
      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/pytorch/lib/python3.10/site-packages
      
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
      git submodule sync
      git submodule update --init --recursive
      sudo pip3 install mkl-static mkl-include
      sudo pip3 install -r requirements.txt
      
      sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/pytorch
      sudo chmod a+w /opt/rocmplus-${ROCM_VERSION}/pytorch
      python3 tools/amd_build/build_amd.py >& /dev/null
      
      echo ""
      echo "===================="
      echo "Starting setup.py install"
      echo "===================="
      echo ""
      python3 setup.py install --prefix=/opt/rocmplus-${ROCM_VERSION}/pytorch
      echo ""
      echo "===================="
      echo "Finished setup.py install"
      echo "===================="
      echo ""
    
      #echo 'Defaults:%sudo env_keep += "PYTHONPATH"' | sudo EDITOR='tee -a' visudo

      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages:$PYTHONPATH
      pip3 uninstall torchvision
      sudo mkdir /opt/rocmplus-${ROCM_VERSION}/vision
      sudo chmod a+w /opt/rocmplus-${ROCM_VERSION}/vision
      cd ..
      git clone --recursive https://github.com/pytorch/vision
      cd vision
      git reset --hard bf01bab
      python3 setup.py install --prefix=/opt/rocmplus-${ROCM_VERSION}/vision

      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/audio/lib/python3.10/site-packages:$PYTHONPATH
      pip3 uninstall torchaudio
      sudo mkdir /opt/rocmplus-${ROCM_VERSION}/audio
      sudo chmod a+w /opt/rocmplus-${ROCM_VERSION}/audio
      cd ..
      git clone --recursive https://github.com/pytorch/audio
      cd audio
      git reset --hard 7f6209b
      python3 setup.py install --prefix=/opt/rocmplus-${ROCM_VERSION}/audio
      
      cd ..
      sudo chown root:root /opt/rocmplus-${ROCM_VERSION}/pytorch
      sudo chmod og-w /opt/rocmplus-${ROCM_VERSION}/pytorch
      sudo chown root:root /opt/rocmplus-${ROCM_VERSION}/vision
      sudo chmod og-w /opt/rocmplus-${ROCM_VERSION}/vision
      sudo chown root:root /opt/rocmplus-${ROCM_VERSION}/audio
      sudo chmod og-w /opt/rocmplus-${ROCM_VERSION}/audio

      rm -rf pytorch vision audio
   fi
fi

# Create a module file for Pytorch
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/pytorch

sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | sudo tee ${MODULE_PATH}/2.3.1.lua
	whatis("HIP version of PyTorch")

	load("rocm/${ROCM_VERSION}")
	conflict("miniconda3")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/audio/lib/python3.10/site-packages")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/pytorch/lib/python3.10/site-packages")
EOF
	#prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages/torchvision-0.20.0a0+bf01bab-py3.10-linux-x86_64.egg")
	#prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/vision/lib/python3.10/site-packages/pillow-10.4.0-py3.10-linux-x86_64.egg")
	#prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/audio/lib/python3.10/site-packages/torchaudio-2.4.0a0+7f6209b-py3.10-linux-x86_64.egg")
        #prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/pytorch/lib/python3.10/site-packages")

#pip download --only-binary :all: --dest /opt/wheel_files_6.0/pytorch-rocm --no-cache --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/rocm6.0
#cat > /opt/wheel_files_6.0/README_pytorch <<-EOF
#        To install the pytorch package for ROCM 6.0
#           pip3 install /opt/wheel_files-6.0/pytorch-rocm/torch-2.3.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torchvision-0.18.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#EOF

