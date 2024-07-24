#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

ROCM_VERSION=6.1.0
BUILD_GCC_LATEST=0

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          ;;
      "--build-gcc-latest")
          shift
          BUILD_GCC_LATEST=${1}
          ;;
      *)  
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

export GCC_VERSION_NUMBER=13.2.0
export GCC_VERSION=gcc-${GCC_VERSION_NUMBER}

echo ""
echo "==================================="
echo "Starting AMD GCC Latest Install with"
echo "BUILD_GCC_LATEST: $BUILD_GCC_LATEST" 
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "GCC_VERSION: $GCC_VERSION" 
echo "==================================="
echo ""

if [ "${BUILD_GCC_LATEST}" = "1" ] ; then
   if  [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/${GCC_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached AMD GCC Latest"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/${GCC_VERSION}.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/CacheFiles/${GCC_VERSION}
      rm ${GCC_VERSION}.tgz
   else
      echo ""
      echo "============================"
      echo " Building AMD GCC Latest"
      echo "============================"
      echo ""

      export LLVM_DIR=llvm-project-llvmorg-13.0.1
      export LLVM_DIR_SHORT=llvmorg-13.0.1

      # Set install directory
      export DEST=/opt/rocmplus-${ROCM_VERSION}/${GCC_VERSION}
      chmod a+w /opt
      sudo mkdir $DEST

      # modules
      module load rocm

      wget -q https://github.com/llvm/llvm-project/archive/refs/tags/${LLVM_DIR_SHORT}.tar.gz
      tar xf ${LLVM_DIR_SHORT}.tar.gz
      mkdir builds && cd builds
      cmake -D 'LLVM_TARGETS_TO_BUILD=X86;AMDGPU' -D LLVM_ENABLE_PROJECTS=lld ../${LLVM_DIR}/llvm && \
      make -j 12 || exit 1

      #On n'installe pas mais on déplace en les renommant certains binaires.
      mkdir -p $DEST/amdgcn-amdhsa/bin
      cp -a ./bin/llvm-ar $DEST/amdgcn-amdhsa/bin/ar
      cp -a ./bin/llvm-ar $DEST/amdgcn-amdhsa/bin/ranlib
      cp -a ./bin/llvm-mc $DEST/amdgcn-amdhsa/bin/as
      cp -a ./bin/llvm-nm $DEST/amdgcn-amdhsa/bin/nm
      cp -a ./bin/lld $DEST/amdgcn-amdhsa/bin/ld
      cd ..

      rm -rf builds
      rm -rf ${LLVM_DIR} ${LLVM_DIR_SHORT}

      git clone https://sourceware.org/git/newlib-cygwin.git newlib
      git clone https://gcc.gnu.org/git/gcc.git gcc 
      cd gcc 
      git checkout releases/${GCC_VERSION}
      ./contrib/download_prerequisites

      target=$(./config.guess)
      echo "Target ",$target

      ln -s ../newlib/newlib ./newlib
      mkdir build && cd build
      ../configure --prefix=$DEST --target=amdgcn-amdhsa --enable-languages=c,c++,lto,fortran --disable-sjlj-exceptions --with-newlib \
                   --enable-as-accelerator-for=$target --with-build-time-tools=$DEST/amdgcn-amdhsa/bin --disable-libquadmath \
                   --disable-bootstrap
      make -j 16
      make install
      cd ..
      rm newlib

      mkdir buildhost && cd buildhost && \
      ../configure --prefix=$DEST --build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu --target=x86_64-pc-linux-gnu --disable-multilib \
      --enable-offload-targets=amdgcn-amdhsa=$DEST/amdgcn-amdhsa --disable-bootstrap

      make -j 16
      sudo make install
      cd ..

      rm -rf build buildhost
      rm -rf gcc newlib

      chmod a-w /opt
   fi

   # In either case, create a module file for AMD-GCC compiler
   export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/amd-gcc

   mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | sudo tee ${MODULE_PATH}/13.2.0.lua
	whatis("Custom built GCC Version 13.2.0 compiler")
	whatis("This version enables offloading to AMD GPUs")

	local base = "/opt/rocmplus-${ROCM_VERSION}/gcc-13.2.0"

	setenv("CC", pathJoin(base, "bin/gcc"))
	setenv("CXX", pathJoin(base, "bin/g++"))
	setenv("F77", pathJoin(base, "bin/gfortran"))
	setenv("F90", pathJoin(base, "bin/gfortran"))
	setenv("FC", pathJoin(base,"bin/gfortran"))
	append_path("INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
	load("rocm/${ROCM_VERSION}")
	family("compiler")
EOF
fi
