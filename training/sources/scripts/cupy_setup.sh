#/bin/bash

module load rocm/SCRIPT_ROCM_VERSION

export CUPY_INSTALL_USE_HIP=1
export ROCM_HOME=${ROCM_PATH}
export HCC_AMDGPU_ARCH=AMDGPU_GFXMODEL

git clone -q --depth 1 --recursive https://github.com/ROCm/cupy.git
cd cupy

sed -i -e '/numpy/s/1.27/1.25/' setup.py
python3 setup.py -q bdist_wheel

mkdir -p /opt/rocmplus-SCRIPT_ROCM_VERSION/cupy
pip3 install -v --target=/opt/rocmplus-SCRIPT_ROCM_VERSION/cupy dist/cupy-13.0.0b1-cp310-cp310-linux_x86_64.whl

rm -rf cupy
module unload rocm/SCRIPT_ROCM_VERSION

# Create a module file for cupy
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/cupy

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/13.0.0b1.lua <<-EOF
	whatis("HIP version of cuPY or hipPY")
	 
        load("rocm/SCRIPT_ROCM_VERSION")
        prepend_path("PYTHONPATH","/opt/rocmplus-SCRIPT_ROCM_VERSION/cupy")
EOF
