#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

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
      "--build-clacc-latest")
          shift
          BUILD_CLACC_LATEST=${1}
          ;;
      *)  
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

if [ "$(printf '%s\n' "6.1.0" "${ROCM_VERSION}" | sort --version-sort | head -n1)" = "6.1.0" ]; then 
   # C++ Standard Parallel is included in the released compiler
   exit;
fi

echo ""
echo "==================================="
echo "Starting CLACC Install with"
echo "BUILD_CLACC_LATEST: $BUILD_CLACC_LATEST" 
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL" 
echo "==================================="
echo ""

if [ "${BUILD_CLACC_LATEST}" = "1" ]; then
   if [ -f /opt/rocmplus-${ROCM_VERSION}/clacc_clang.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached CLACC"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf clacc_clang.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/clacc_clang
      rm clacc_clang.tgz
   else
      echo ""
      echo "============================"
      echo " Building CLACC"
      echo "============================"
      echo ""

      git clone -b clacc/main https://github.com/llvm-doe-org/llvm-project.git clacc-clang

      cd clacc-clang

      mkdir llvm-build
      cd llvm-build
      cmake -G Ninja -DCMAKE_INSTALL_PREFIX=/opt/rocmplus-${ROCM_VERSION}/clacc_clang \
        -DCMAKE_BUILD_TYPE=Release               \
        -DLLVM_ENABLE_PROJECTS="clang;flang;lld" \
        -DLLVM_ENABLE_RUNTIMES=openmp            \
        -DLLVM_TARGETS_TO_BUILD="host;AMDGPU"    \
        -DLIBOMPTARGET_AMDGCN_GFXLIST="${AMDGPU_GFXMODEL}" \
        -DLLVM_PARALLEL_COMPILE_JOBS=20          \
        -DLLVM_PARALLEL_LINK_JOBS=10             \
         ../llvm
       ninja -j20 -l10
       ninja install

       rm -rf /app/clacc-clang
   fi

   # In either case, create a module file for CLACC compiler
   export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/clacc

   mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat > ${MODULE_PATH}/clang-17.0.0.lua <<-EOF
	whatis("Clang OpenMP Compiler with CLACC version 17.0-0 based on LLVM")

	local base = "/opt/rocmplus-${ROCM_VERSION}/clacc_clang"

	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("CC", pathJoin(base, "bin/clang"))
	setenv("CXX", pathJoin(base, "bin/clang++"))
	setenv("FC", pathJoin(base, "bin/flang-new"))
	setenv("F77", pathJoin(base, "bin/flang-new"))
	setenv("F90", pathJoin(base, "bin/flang-new"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "libexec"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("MANPATH", pathJoin(base, "man"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	load("rocm/${ROCM_VERSION}")
	family("compiler")
EOF
fi
