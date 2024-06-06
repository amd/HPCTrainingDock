#/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

ROCM_VERSION=6.0
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_CUPY=0

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
      "--build-cupy")
          shift
          BUILD_CUPY=${1}
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
echo "Starting cuPY Install with"
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL" 
echo "BUILD_CUPY: $BUILD_CUPY" 
echo "==================================="
echo ""

if [ "${BUILD_CUPY}" = "0" ]; then

   echo "cupy will not be build, according to the specified value of BUILD_CUPY"
   echo "BUILD_CUPY: $BUILD_CUPY"
   exit 1

else 
   if [ -f /opt/rocmplus-${ROCM_VERSION}/cupy.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached cuPY"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf cupy.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/cupy
      sudo rm /opt/rocmplus-${ROCM_VERSION}/cupy.tgz
   else
      echo ""
      echo "============================"
      echo " Building cuPY"
      echo "============================"
      echo ""


      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}
      
      export CUPY_INSTALL_USE_HIP=1
      export ROCM_HOME=${ROCM_PATH}
      export HCC_AMDGPU_ARCH=${AMDGPU_GFXMODEL}
      
      git clone -q --depth 1 --recursive https://github.com/ROCm/cupy.git
      cd cupy
      
      sudo sed -i -e '/numpy/s/1.27/1.25/' setup.py
      python3 setup.py -q bdist_wheel
      
      sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/cupy
      sudo pip3 install -v --target=/opt/rocmplus-${ROCM_VERSION}/cupy dist/cupy-13.0.0b1-cp310-cp310-linux_x86_64.whl
      
      cd ..
      sudo rm -rf cupy
      module unload rocm/${ROCM_VERSION}
   fi
      
   # Create a module file for cupy
   export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/cupy
   
   sudo mkdir -p ${MODULE_PATH}
   
   # The - option suppresses tabs
   cat <<-EOF | sudo tee ${MODULE_PATH}/13.0.0b1.lua
	whatis("HIP version of cuPY or hipPY")

	load("rocm/${ROCM_VERSION}")
	prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/cupy")
EOF

fi
