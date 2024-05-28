#/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`

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
echo "==================================="
echo ""


module load rocm/${ROCM_VERSION}

export CUPY_INSTALL_USE_HIP=1
export ROCM_HOME=${ROCM_PATH}
export HCC_AMDGPU_ARCH=${AMDGPU_GFXMODEL}

git clone -q --depth 1 --recursive https://github.com/ROCm/cupy.git
cd cupy

sed -i -e '/numpy/s/1.27/1.25/' setup.py
python3 setup.py -q bdist_wheel

mkdir -p /opt/rocmplus-${ROCM_VERSION}/cupy
pip3 install -v --target=/opt/rocmplus-${ROCM_VERSION}/cupy dist/cupy-13.0.0b1-cp310-cp310-linux_x86_64.whl

rm -rf cupy
module unload rocm/${ROCM_VERSION}

# Create a module file for cupy
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/cupy

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/13.0.0b1.lua <<-EOF
	whatis("HIP version of cuPY or hipPY")
	 
        load("rocm/${ROCM_VERSION}")
        prepend_path("PYTHONPATH","/opt/rocmplus-${ROCM_VERSION}/cupy")
EOF
