#!/bin/bash

ROCM_VERSION=6.0
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_PYTORCH=0
ZSTD_VERSION=1.5.6
PYTORCH_VERSION=2.7.0
PYTHON_VERSION=10
TORCHVISION_VERSION=0.21.0
TORCHVISION_HASH="7af6987"
TORCHAUDIO_VERSION=2.6.0
TORCHAUDIO_HASH="d883142"
PILLOW_VERSION=11.2.1
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
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "--amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is autodetected"
   echo "--build-pytorch [ BUILD_PYTORCH ] set to 1 to build jax default is 0"
   echo "--pytorch-version [ PYTORCH_VERSION ] version of PyTorch, default is $PYTORCH_VERSION"
   echo "--python-version [ PYTHON_VERSION ] version of Python, default is $PYTHON_VERSION"
   echo "--install-path [ INSTALL_PATH ] directory where PyTorch, Torchaudio and Torchvision will be installed, default is $INSTALL_PATH"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "--use-wheel [ USE_WHEEL ] build with a wheel instead of from source, default is $USE_WHEEL"
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
      "--help")
         usage
         ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
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

ZSTD_PATH=$INSTALL_PATH/zstd
TRANSFORMERS_PATH=$INSTALL_PATH/transformers
TRITON_PATH=$INSTALL_PATH/triton
SAGEATTENTION_PATH=$INSTALL_PATH/sageattention
FLASHATTENTION_PATH=$INSTALL_PATH/flashattention
AOTRITON_PATH=$INSTALL_PATH/aotriton
PYTORCH_PATH=$INSTALL_PATH/pytorch
TORCHVISION_PATH=$INSTALL_PATH/vision
TORCHAUDIO_PATH=$INSTALL_PATH/audio

if [ "${BUILD_PYTORCH}" = "0" ]; then

   echo "pytorch will not be built, according to the specified value of BUILD_PYTORCH"
   echo "BUILD_PYTORCH: $BUILD_PYTORCH"
   exit

else

   PYTORCH_SHORT_VERSION=`echo ${PYTORCH_VERSION} | cut -f1-2 -d'.'`
   if [ "${PYTORCH_SHORT_VERSION}" == "2.7" ]; then
      AOTRITON_VERSION="0.9.2b"
      ${SUDO} ${DEB_FRONTEND} apt-get install -y liblzma-dev
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.6" ]; then
      AOTRITON_VERSION="0.8b"
      ${SUDO} ${DEB_FRONTEND} apt-get install -y liblzma-dev
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.5" ]; then
      AOTRITON_VERSION="0.7b"
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.4" ]; then
      AOTRITON_VERSION="0.6b"
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.3" ]; then
      AOTRITON_VERSION="0.4b"
   else
      echo " No AOTriton support for requested PyTorch version: https://github.com/ROCm/aotriton "
      echo " Build aborted, please select a PyTorch version >= 2.3 "
      exit 1
   fi

   echo ""
   echo "======================================"
   echo "Starting Pytorch Install with"
   echo "PyTorch Version: $PYTORCH_VERSION"
   echo "PyTorch Install Directory: $PYTORCH_PATH"
   echo "Torchvision Version: $TORCHVISION_VERSION"
   echo "Torchvision Install Directory: $TORCHVISION_PATH"
   echo "Torchaudio Version: $TORCHAUDIO_VERSION"
   echo "Torchaudio Install Directory: $TORCHAUDIO_PATH"
   echo "AOTriton Version: $AOTRITON_VERSION"
   echo "AOTriton Install Directory: $AOTRITON_PATH"
   echo "ROCm Version: $ROCM_VERSION"
   echo "Module Directory: $MODULE_PATH"
   echo "Use Wheel to Build?: $USE_WHEEL"
   echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
   echo "======================================"
   echo ""

   ${SUDO} apt-get update
   ${SUDO} ${DEB_FRONTEND} apt-get install -y python-is-python3
   ${SUDO} ${DEB_FRONTEND} apt-get install -y libopenmpi-dev

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/pytorch.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Pytorch"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/pytorch.tgz
      if [ "${USER}" != "sysadmin" ]; then
         rm ${CACHE_FILES}/pytorch.tgz
      fi

   elif [ "${USE_WHEEL}" == "1" ]; then

      # don't use sudo if user has write access to install path
      if [ -d "$INSTALL_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${TRANSFORMERS_PATH}
      ${SUDO} mkdir -p ${TRITON_PATH}
      ${SUDO} mkdir -p ${SAGEATTENTION_PATH}
      ${SUDO} mkdir -p ${FLASHATTENTION_PATH}
      ${SUDO} mkdir -p ${PYTORCH_PATH}
      ${SUDO} mkdir -p ${TORCHAUDIO_PATH}
      ${SUDO} mkdir -p ${TORCHVISION_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      # install of pre-built pytorch using a wheel
      echo "Installing PyTorch, Torchaudio and Torchvision with wheel"
      ROCM_VERSION_WHEEL=${ROCM_VERSION}
      echo ${ROCM_VERSION_WHEEL}
      if [[ `echo ${ROCM_VERSION} | cut -f3-3 -d'.'` == 0 ]]; then
         ROCM_VERSION_WHEEL=`echo ${ROCM_VERSION} | cut -f1-2 -d'.'`
      fi
      pip3 install torch==${PYTORCH_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${PYTORCH_PATH}
      pip3 install torchaudio==${TORCHAUDIO_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TORCHAUDIO_PATH}
      pip3 install torchvision==${TORCHVISION_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TORCHVISION_PATH}
      pip3 install --target=${TRANSFORMERS_PATH} transformers
      pip3 install --target=${TRITON_PATH} triton
      pip3 install --target=${SAGEATTENTION_PATH} sageattention
      pip3 install --target=${FLASHATTENTION_PATH} flashattention

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi

   else

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm

      # don't use sudo if user has write access to install path
      if [ -d "$INSTALL_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      if [[ ${SUDO} != "" ]]; then
         ${SUDO} apt-get update
         ${SUDO} ${DEB_FRONTEND} apt-get install -y python-is-python3
         ${SUDO} ${DEB_FRONTEND} apt-get install -y libopenmpi-dev
         wget -q https://registrationcenter-download.intel.com/akdlm/IRC_NAS/79153e0f-74d7-45af-b8c2-258941adf58a/intel-onemkl-2025.0.0.940.sh
         ${SUDO} sh ./intel-onemkl-2025.0.0.940.sh -a -s --eula accept
         export PATH=/opt/intel/oneapi:$PATH
      else
         ln -s $(which python3) ~/bin/python
         export PATH="$HOME/bin:$PATH"
         source $HOME/.bashrc
         mkdir -p ${INSTALL_PATH}/mkl
         pip3 install mkl --target=${INSTALL_PATH}/mkl
         export PYTHONPATH=$PYTHONPATH:${INSTALL_PATH}/mkl
      fi

      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${TRANSFORMERS_PATH}
      ${SUDO} mkdir -p ${TRITON_PATH}
      ${SUDO} mkdir -p ${SAGEATTENTION_PATH}
      ${SUDO} mkdir -p ${FLASHATTENTION_PATH}
      ${SUDO} mkdir -p ${ZSTD_PATH}
      ${SUDO} mkdir -p ${AOTRITON_PATH}
      ${SUDO} mkdir -p ${PYTORCH_PATH}
      ${SUDO} mkdir -p ${TORCHAUDIO_PATH}
      ${SUDO} mkdir -p ${TORCHVISION_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      echo ""
      echo "=================================="
      echo " Installing AOTriton from source "
      echo "=================================="
      echo ""

      export GPU_TARGETS=${AMDGPU_GFXMODEL}
      export AMDGPU_TARGETS=${AMDGPU_GFXMODEL}

      git clone --branch v${ZSTD_VERSION} https://github.com/facebook/zstd.git
      cd zstd/build/cmake
      cmake -DCMAKE_INSTALL_PREFIX=${ZSTD_PATH}
      make install
      export PATH=${ZSTD_PATH}:${ZSTD_PATH}/bin:$PATH
      cd ../../../

      git clone --branch ${AOTRITON_VERSION}  https://github.com/ROCm/aotriton.git

      cd aotriton
      git submodule update --init --recursive
      mkdir build && cd build

      if [[ "${AMDGPU_GFXMODEL}" == "gfx90a" ]]; then
         TARGET_GPUS="MI200"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx942" ]]; then
	 TARGET_GPUS="MI300X"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx942;gfx90a" ]]; then
	 TARGET_GPUS="MI300X;MI200"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx90a;gfx942" ]]; then
	 TARGET_GPUS="MI200;MI300X"
      else
         echo "Please select gfx90a, gfx942, or both separated with a ; as AMDGPU_GFXMODEL"
	 exit 1
      fi

      cmake -DAOTRITON_HIPCC_PATH=${ROCM_PATH}/bin -DTARGET_GPUS=${TARGET_GPUS} -DCMAKE_INSTALL_PREFIX=${AOTRITON_PATH} -DCMAKE_BUILD_TYPE=Release -DAOTRITON_GPU_BUILD_TIMEOUT=0 -G Ninja ..

      ninja install

      cd ../..
      rm -rf aotriton zstd

      echo ""
      echo "============================"
      echo " Installing Pytorch, "
      echo " Torchaudio and Torchivision"
      echo " from source"
      echo "============================"
      echo ""

      # Build with GPU aware MPI not working yet
      # Need to use the update-alternatives in openmpi setup to get
      # GPU aware MPI
      #module load openmpi

      export PYTHONPATH=${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages:$PYTHONPATH
      export _GLIBCXX_USE_CXX11_ABI=1
      export ROCM_HOME=${ROCM_PATH}
      export ROCM_SOURCE_DIR=${ROCM_PATH}
      export USE_ROCM=1
      export USE_CUDA=0
      export MAX_JOBS=20
      export USE_MPI=1
      export PYTORCH_ROCM_ARCH=${AMDGPU_GFXMODEL}
      export PYTORCH_INSTALL_DIR=${PYTORCH_PATH}
      export AOTRITON_INSTALLED_PREFIX=${AOTRITON_PATH}

      # this block of code is to retry if git clone fails.
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
	 # we will add the environment variables above the line that says "# set up appropriate env variable" in setup.py
	 LINE=`sed -n '/# set up appropriate env variable/=' setup.py | grep -n ""`
	 LINE=`echo ${LINE} | cut -c 3-`

         sed -i ''"${LINE}"'i os.environ["ROCM_HOME"] = '"${ROCM_HOME}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["ROCM_SOURCE_DIR"] = '"${ROCM_SOURCE_DIR}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["PYTORCH_ROCM_ARCH"] = '"${PYTORCH_ROCM_ARCH}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["AOTRITON_INSTALLED_PREFIX"] = '"${AOTRITON_INSTALLED_PREFIX}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["CMAKE_INCLUDE_PATH"] = '"${CMAKE_INCLUDE_PATH}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["LIBS"] = '"${LIBS}"'' setup.py
      fi

      if [ "${PYTORCH_SHORT_VERSION}" == "2.4" ]; then
         # the USE_ROCM define is not passed to the CAFFE2 build
         # https://github.com/pytorch/pytorch/issues/103312
         # We comment out the lines within the USE_ROCM block in the torch/csrc/jit/ir/ir.cpp file
         sed -i -e 's/case cuda/\/\/case cuda/' torch/csrc/jit/ir/ir.cpp
         # prevent Caffe2 from writing into /usr/local/
         sed -i '/install(DIRECTORY ${CMAKE_BINARY_DIR}\/caffe2 DESTINATION ${PYTHON_LIB_REL_PATH}/s/^/#/g' caffe2/CMakeLists.txt
         sed -i '/FILES_MATCHING PATTERN \"\*\.py")/s/^/#/g' caffe2/CMakeLists.txt
      fi

      pip3 install -r requirements.txt
      #pip3 install -r requirements.txt --target=$INSTALL_PATH
      #PYTHONPATH="PYTHONPATH:$INSTALL_PATH"
      python3 tools/amd_build/build_amd.py >& /dev/null

      echo ""
      echo "===================="
      echo "Starting setup.py install"
      echo "===================="
      echo ""
      python3 setup.py install --prefix=${PYTORCH_PATH}
      echo ""
      echo "===================="
      echo "Finished setup.py install"
      echo "===================="
      echo ""

      cd ..
      rm -rf pytorch
      cd /tmp

      export PYTHONPATH=${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchvision-${TORCHVISION_VERSION}a0+${TORCHVISION_HASH}-py3.${PYTHON_VERSION}-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-${PILLOW_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchaudio-${TORCHAUDIO_VERSION}a0+${TORCHAUDIO_HASH}-py3.${PYTHON_VERSION}-linux-x86_64.egg:$PYTHONPATH
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages:$PYTHONPATH
      export PYTHONPATH=${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages:$PYTHONPATH

      git clone --recursive --depth 1 --branch v${TORCHVISION_VERSION} https://github.com/pytorch/vision
      cd vision
      python3 setup.py install --prefix=${TORCHVISION_PATH}
      cd ..

      git clone --recursive --depth 1 --branch v${TORCHAUDIO_VERSION} https://github.com/pytorch/audio
      cd audio
      python3 setup.py install --prefix=${TORCHAUDIO_PATH}

      pip3 install --target=${TRANSFORMERS_PATH} transformers
      pip3 install --target=${TRITON_PATH} triton
      pip3 install --target=${SAGEATTENTION_PATH} sageattention
      pip3 install --target=${FLASHATTENTION_PATH} sageattention

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi

      # cleanup
      cd ..
      rm -rf vision audio
      rm -f intel-onemkl-2025.0.0.940.sh
      ${SUDO} rm -rf /tmp/amd_triton_kernel* /tmp/can*

   fi
fi

# create a module file for pytorch
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

# the - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${PYTORCH_VERSION}.lua
	whatis("PyTorch version ${PYTORCH_VERSION} with ROCm Support")

	load("rocm/${ROCM_VERSION}")
	conflict("miniconda3")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchvision-${TORCHVISION_VERSION}+${TORCHVISION_HASH}-py3.${PYTHON_VERSION}-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-${PILLOW_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchaudio-${TORCHAUDIO_VERSION}a0+${TORCHAUDIO_HASH}-py3.${PYTHON_VERSION}-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${TRANSFORMERS_PATH}")
	prepend_path("PYTHONPATH","${TRITON_PATH}")
	prepend_path("PYTHONPATH","${SAGEATTENTION_PATH}")
	prepend_path("PYTHONPATH","${FLASHATTENTION_PATH}")
	prepend_path("PYTHONPATH","${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages")
	prepend_path("PYTHONPATH","${PYTORCH_PATH}")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}")
	prepend_path("PYTHONPATH","${TORCHAUDIO_PATH}")
	prepend_path("PATH","${PYTORCH_PATH}/pytorch/bin")
EOF
#        cmd1="mkdir -p $$HOME/miopen_tmpdir; export TMPDIR=$$HOME/miopen_tmpdir"
#        cmd2="rm -rf $$HOME/miopen_tmpdir; unset TMPDIR"
#        execute{cmd=cmd1, modeA={"load"}}
#        execute{cmd=cmd2, modeA={"unload"}}

#pip download --only-binary :all: --dest /opt/wheel_files_6.0/pytorch-rocm --no-cache --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/rocm6.0
#cat > /opt/wheel_files_6.0/README_pytorch <<-EOF
#        To install the pytorch package for ROCM 6.0
#           pip3 install /opt/wheel_files-6.0/pytorch-rocm/torch-2.3.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torchvision-0.18.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#EOF

