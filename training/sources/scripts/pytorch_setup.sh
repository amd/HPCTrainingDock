#!/bin/bash
if [ "BUILD_PYTORCH_LATEST" = "1" ]; then
   if [ -f /opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch.tgz ]; then
      #install the cached version
      cd /opt/rocmplus-SCRIPT_ROCM_VERSION
      tar -xzf pytorch.tgz
      chown -R root:root /opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch
      rm /opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch.tgz
   else
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
      
      export PYTHONPATH=/opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch/lib/python3.10/site-packages:$PYTHONPATH
      
      # Install of pre-built pytorch for reference
      #pip3 install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/rocm6.0
      
      export _GLIBCXX_USE_CXX11_ABI=1
      export ROCM_HOME=${ROCM_PATH}
      export USE_ROCM=1
      export USE_CUDA=0
      export MAX_JOBS=20
      export USE_MPI=0
      export PYTORCH_ROCM_ARCH="AMDGPU_GFXMODEL"
      
      git clone -q --recursive -b release/2.2 https://github.com/ROCm/pytorch
      cd pytorch
      pip3 install -r requirements.txt
      pip3 install intel::mkl-static intel::mkl-include
      
      #export CMAKE_PREFIX_PATH=/opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch
      mkdir /opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch
      python3 tools/amd_build/build_amd.py >& /dev/null
      
      python3 setup.py develop --prefix=/opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch
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
      python3 setup.py install -v --prefix=/opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch
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
      python3 setup.py install --prefix=/opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch
      
      rm -rf /app/pytorch
      
   fi
fi

# Create a module file for Pytorch
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/pytorch

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/2.2.lua <<-EOF
        whatis("HIP version of pytorch")

        load("rocm/SCRIPT_ROCM_VERSION")
        prepend_path("PYTHONPATH","/opt/rocmplus-SCRIPT_ROCM_VERSION/pytorch/lib/python3.10/site-packages")
EOF

#pip download --only-binary :all: --dest /opt/wheel_files_6.0/pytorch-rocm --no-cache --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/rocm6.0
#cat > /opt/wheel_files_6.0/README_pytorch <<-EOF
#        To install the pytorch package for ROCM 6.0
#           pip3 install /opt/wheel_files-6.0/pytorch-rocm/torch-2.3.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torchvision-0.18.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#EOF

