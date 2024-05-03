#!/bin/bash

set -v

if [ "BUILD_LLVM_LATEST" = "1" ]; then
   if [ -f /opt/rocmplus-SCRIPT_ROCM_VERSION/llvm-latest.tgz ]; then
      #install the cached version
      cd /opt/rocmplus-SCRIPT_ROCM_VERSION
      tar -xzf llvm-latest.tgz
      chown -R root:root /opt/rocmplus-SCRIPT_ROCM_VERSION/llvm-latest
      rm /opt/rocmplus-SCRIPT_ROCM_VERSION/llvm-latest.tgz
   else
      INSTALL_DIR=/opt/rocmplus-SCRIPT_ROCM_VERSION/llvm-latest
      git clone https://github.com/llvm/llvm-project.git
      cd llvm-project

      GITSHA=a40bada91aeda276a772acfbcae6e8de26755a11
      git checkout $GITSHA
      wget -q https://raw.githubusercontent.com/ROCm/roc-stdpar/main/data/patches/LLVM/CLANG_LLVM.patch
      patch -p1 < CLANG_LLVM.patch

      mkdir llvm-build
      cd llvm-build
      cmake -G Ninja -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang;lld;flang" \
        -DLLVM_ENABLE_RUNTIMES="libcxxabi;libcxx;openmp" \
        -DLLVM_TARGETS_TO_BUILD="host;AMDGPU"    \
        -DLIBOMPTARGET_AMDGCN_GFXLIST="${AMDGPU_GFX}" \
        -DLLVM_PARALLEL_COMPILE_JOBS=20          \
        -DLLVM_PARALLEL_LINK_JOBS=10             \
         ../llvm

      ninja -j20 -l10
      ninja install

      cd ${INSTALL_DIR}/include
      wget -q https://raw.githubusercontent.com/ROCm/roc-stdpar/main/include/hipstdpar_lib.hpp

      rm -rf /app/llvm-project
   fi

   # In either case, create a module file for llvm-latest compiler
   export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/llvm-latest

   mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat > ${MODULE_PATH}/gcc11_hipstdpar.lua <<-EOF
	whatis("LLVM latest compiler version with stdpar patch applied")

	local base = "/opt/rocmplus-SCRIPT_ROCM_VERSION/llvm-latest"

	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("CC", pathJoin(base, "bin/clang"))
	setenv("CXX", pathJoin(base, "bin/clang++"))
	setenv("FC", pathJoin(base, "bin/flang"))
	setenv("F77", pathJoin(base, "bin/flang"))
	setenv("F90", pathJoin(base, "bin/flang"))
	setenv("STDPAR_PATH", pathJoin(base, "include"))
	setenv("STDPAR_CXX", pathJoin(base, "bin/clang++"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "libexec"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("MANPATH", pathJoin(base, "man"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	load("rocm/SCRIPT_ROCM_VERSION")
	family("compiler")
EOF
fi
