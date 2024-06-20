#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

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
   exit 1

else 
   if [ -f /opt/rocmplus-${ROCM_VERSION}/pytorch.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Pytorch"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf pytorch.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/pytorch
      rm /opt/rocmplus-${ROCM_VERSION}/pytorch.tgz
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
      
      export PYTHONPATH=/opt/rocmplus-${ROCM_VERSION}/pytorch/lib/python3.10/site-packages:$PYTHONPATH
      
      # Install of pre-built pytorch for reference
      #pip3 install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/rocm6.0
      
      export _GLIBCXX_USE_CXX11_ABI=1
      export ROCM_HOME=${ROCM_PATH}
      export USE_ROCM=1
      export USE_CUDA=0
      export MAX_JOBS=20
      export USE_MPI=0
      export PYTORCH_ROCM_ARCH="${AMDGPU_GFXMODEL}"
      
      git clone -q --recursive -b release/2.2 https://github.com/ROCm/pytorch
      cd pytorch
      sudo pip3 install -r requirements.txt
      sudo pip3 install intel::mkl-static intel::mkl-include
      
      #export CMAKE_PREFIX_PATH=/opt/rocmplus-${ROCM_VERSION}/pytorch
      sudo mkdir /opt/rocmplus-${ROCM_VERSION}/pytorch
      sudo python3 tools/amd_build/build_amd.py >& /dev/null
      
      sudo python3 setup.py develop --prefix=/opt/rocmplus-${ROCM_VERSION}/pytorch
      echo ""
      echo ""
      echo ""
      echo "===================="
      echo "Finished setup.py develop"
      echo "===================="
      echo ""
      echo ""
      echo ""
      echo "===================="
      echo "Starting setup.py install"
      echo "===================="
      echo ""
      python3 setup.py install -v --prefix=/opt/rocmplus-${ROCM_VERSION}/pytorch
      echo ""
      echo ""
      echo ""
      echo "===================="
      echo "Finished setup.py install"
      echo "===================="
      echo ""
      echo ""
      
      pip uninstall torchvision
      git clone --recursive -b release/0.17 https://github.com/pytorch/vision torchvision
      python3 setup.py install --prefix=/opt/rocmplus-${ROCM_VERSION}/pytorch
      
      rm -rf /app/pytorch
      
   fi
fi

# Create a module file for Pytorch
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/pytorch

sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | sudo tee ${MODULE_PATH}/2.2.lua
        whatis("HIP version of pytorch")

        load("rocm/${ROCM_VERSION}")
        conflict("miniconda3")
        prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/pytorch/lib/python3.10/site-packages")
EOF

#pip download --only-binary :all: --dest /opt/wheel_files_6.0/pytorch-rocm --no-cache --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/rocm6.0
#cat > /opt/wheel_files_6.0/README_pytorch <<-EOF
#        To install the pytorch package for ROCM 6.0
#           pip3 install /opt/wheel_files-6.0/pytorch-rocm/torch-2.3.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torchvision-0.18.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#EOF

