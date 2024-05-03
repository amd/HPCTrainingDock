#!/bin/bash

wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | apt-key add -
apt-get update
wget -q https://repo.radeon.com/amdgpu-install/AMDGPU_ROCM_VERSION/ubuntu/ROCM_REPO_DIST/amdgpu-install_AMDGPU_INSTALL_VERSION_all.deb
apt-get install -y ./amdgpu-install_AMDGPU_INSTALL_VERSION_all.deb
amdgpu-install -y  --usecase=hiplibsdk,rocm --no-dkms

# Required by DeepSpeed
ln -s /opt/rocm-SCRIPT_ROCM_VERSION/.info/version /opt/rocm-SCRIPT_ROCM_VERSION/.info/version-dev

# rocm-validation-suite is optional
#apt-get install -qy rocm-validation-suite

# Uncomment the appropriate one for your system if you want
# to hardwire the code generation
#RUN echo "gfx90a" > /opt/rocm/bin/target.lst
#RUN echo "gfx908" >>/opt/rocm/bin/target.lst
#RUN echo "gfx906" >>/opt/rocm/bin/target.lst
#RUN echo "gfx1030" >>/opt/rocm/bin/target.lst

#ENV ROCM_TARGET_LST=/opt/rocm/bin/target.lst 

#RUN mkdir -p rocinfo \
#    && cd rocinfo \
#    && git clone  https://github.com/RadeonOpenCompute/rocminfo.git \
#    && cd rocminfo  \
#    && ls -lsa  \
#    && mkdir -p build \
#    && cd build  \
#    && cmake -DCMAKE_PREFIX_PATH=/opt/rocm .. \
#    && make install  

# set up up module files

# Create a module file for rocm sdk
export MODULE_PATH=/etc/lmod/modules/ROCm/rocm

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/SCRIPT_ROCM_VERSION.lua <<-EOF
	whatis("Name: ROCm")
	whatis("Version: SCRIPT_ROCM_VERSION")
	whatis("Category: AMD")
	whatis("ROCm")

	local base = "/opt/rocm-SCRIPT_ROCM_VERSION/"
	local mbase = " /etc/lmod/modules/ROCm/rocm"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	setenv("ROCM_PATH", base)
	family("GPUSDK")
EOF

# Create a module file for amdclang compiler
export MODULE_PATH=/etc/lmod/modules/ROCm/amdclang

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/17.0-SCRIPT_ROCM_VERSION.lua <<-EOF
	whatis("Name: AMDCLANG")
	whatis("Version: SCRIPT_ROCM_VERSION")
	whatis("Category: AMD")
	whatis("AMDCLANG")

	local base = "/opt/rocm-SCRIPT_ROCM_VERSION/llvm"
	local mbase = "/etc/lmod/modules/ROCm/amdclang"

	setenv("CC", pathJoin(base, "bin/amdclang"))
	setenv("CXX", pathJoin(base, "bin/amdclang++"))
	setenv("FC", pathJoin(base, "bin/amdflang"))
	setenv("F77", pathJoin(base, "bin/amdflang"))
	setenv("F90", pathJoin(base, "bin/amdflang"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_RUN_PATH", pathJoin(base, "lib"))
	prepend_path("CPATH", pathJoin(base, "include"))
	load("rocm/SCRIPT_ROCM_VERSION")
	family("compiler")
EOF

# Create a module file for hipfort package
export MODULE_PATH=/etc/lmod/modules/ROCm/hipfort

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/SCRIPT_ROCM_VERSION.lua <<-EOF
	whatis("Name: ROCm HIPFort")
	whatis("Version: SCRIPT_ROCM_VERSION")

	setenv("HIPFORT_HOME", "/opt/rocm-SCRIPT_ROCM_VERSION")
	append_path("LD_LIBRARY_PATH", "/opt/rocm-SCRIPT_ROCM_VERSION/lib")
	setenv("LIBS", "-L/opt/rocm-SCRIPT_ROCM_VERSION/lib -lhipfort-amdgcn.a")
	load("rocm/SCRIPT_ROCM_VERSION")
EOF

# Create a module file for opencl compiler
export MODULE_PATH=/etc/lmod/modules/ROCm/opencl

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/SCRIPT_ROCM_VERSION.lua <<-EOF
	whatis("Name: ROCm OpenCL")
	whatis("Version: SCRIPT_ROCM_VERSION")
	whatis("Category: AMD")
	whatis("ROCm OpenCL")

	local base = "/opt/rocm-SCRIPT_ROCM_VERSION/opencl"
	local mbase = " /etc/lmod/modules/ROCm/opencl"

	prepend_path("PATH", pathJoin(base, "bin"))
	family("OpenCL")
EOF
