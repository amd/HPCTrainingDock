#!/bin/sh

if [ "OMNITRACE_BUILD_FROM_SOURCE" = "0" ] ; then
   wget -q https://github.com/AMDResearch/omnitrace/releases/download/v1.11.1/omnitrace-install.py && \
       python3 ./omnitrace-install.py --prefix /opt/rocmplus-SCRIPT_ROCM_VERSION/omnitrace --rocm "SCRIPT_ROCM_VERSION" -d ubuntu -v "DISTRO_VERSION"
else
   SAVE_PATH=${PATH}
   export PATH=$PATH:/opt/rocmplus-SCRIPT_ROCM_VERSION/openmpi:/opt/rocmplus-SCRIPT_ROCM_VERSION/ucx
   CPU_TYPE=zen3
   if [ "AMDGCN_GFXMODEL" = "gfx1030" ]; then
      CPU_TYPE=zen2
   fi
   if [ "AMDGCN_GFXMODEL" = "gfx90a" ]; then
      CPU_TYPE=zen3
   fi
   if [ "AMDGCN_GFXMODEL" = "gfx942" ]; then
      CPU_TYPE=zen4
   fi

   git clone --depth 1 https://github.com/AMDResearch/omnitrace.git omnitrace-source --recurse-submodules && \
       cmake                                         \
          -B omnitrace-build                      \
          -D CMAKE_INSTALL_PREFIX=/opt/rocmplus-SCRIPT_ROCM_VERSION/omnitrace  \
          -D OMNITRACE_USE_HIP=ON                 \
          -D OMNITRACE_USE_ROCM_SMI=ON            \
          -D OMNITRACE_USE_ROCTRACER=ON           \
          -D OMNITRACE_USE_PYTHON=ON              \
          -D OMNITRACE_USE_OMPT=ON                \
          -D OMNITRACE_USE_MPI_HEADERS=ON         \
          -D OMNITRACE_USE_MPI=ON                 \
          -D OMNITRACE_BUILD_PAPI=ON              \
          -D OMNITRACE_BUILD_LIBUNWIND=ON         \
          -D OMNITRACE_BUILD_DYNINST=ON           \
          -D DYNINST_BUILD_TBB=ON                 \
          -D DYNINST_BUILD_BOOST=ON               \
          -D DYNINST_BUILD_ELFUTILS=ON            \
          -D DYNINST_BUILD_LIBIBERTY=ON           \
          -D AMDGPU_TARGETS="AMDGPU_GFXMODEL"     \
          -D CpuArch_TARGET=${CPU_TYPE} \
          -D OMNITRACE_DEFAULT_ROCM_PATH=/opt/rocm-SCRIPT_ROCM_VERSION \
          -D OMNITRACE_USE_COMPILE_TIMING=ON \
          omnitrace-source

   cmake --build omnitrace-build --target all --parallel 16
   cmake --build omnitrace-build --target install
   PATH=${SAVE_PATH}
fi

# In either case, create a module file for Omnitrace
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AMDResearchTools/omnitrace

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/1.11.2.lua <<-EOF
	whatis("Name: omnitrace")
	whatis("Version: 1.11.2")
	whatis("Category: AMD")
	whatis("omnitrace")

	local base = "/opt/rocmplus-SCRIPT_ROCM_VERSION/omnitrace/"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	setenv("OMNITRACE_PATH", base)
	load("rocm/SCRIPT_ROCM_VERSION")
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
EOF


