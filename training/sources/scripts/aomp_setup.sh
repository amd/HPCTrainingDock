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
      "--build-aomp-latest")
          shift
          BUILD_AOMP_LATEST=${1}
          ;;
      *)  
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

export AOMP_VERSION_NUMBER=19.0-0
export AOMP_VERSION_SHORT=19.0

echo ""
echo "==================================="
echo "Starting AOMP Latest Install with"
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "BUILD_AOMP_LATEST: $BUILD_AOMP_LATEST" 
echo "AOMP_VERSION_NUMBER: $AOMP_VERSION_NUMBER" 
echo "==================================="
echo ""

if [ "${BUILD_AOMP_LATEST}" = "1" ]; then
   if [ -f /opt/rocmplus-${ROCM_VERSION}/aomp_${AOMP_VERSION_NUMBER}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached AOMP Latest"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf aomp_${AOMP_VERSION_NUMBER}.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/aomp_${AOMP_VERSION_NUMBER}
      rm /opt/rocmplus-${ROCM_VERSION}/aomp_${AOMP_VERSION_NUMBER}.tgz
   else
      echo ""
      echo "============================"
      echo " Building AOMP Latest"
      echo "============================"
      echo ""

      export AOMP=/opt/rocmplus-${ROCM_VERSION}/aomp
      chmod a+w /opt

# Installs aomp from .deb package but then we can't specify where to install it
#     wget -q https://github.com/ROCm/aomp/releases/download/rel_19.0-0/aomp_Ubuntu2204_19.0-0_amd64.deb
#     apt-get install ./aomp_Ubuntu2204_19.0-0_amd64.deb
      
      wget -q https://github.com/ROCm-Developer-Tools/aomp/releases/download/rel_${AOMP_VERSION_NUMBER}/aomp-${AOMP_VERSION_NUMBER}.tar.gz
      tar -xzf aomp-${AOMP_VERSION_NUMBER}.tar.gz
      cd aomp${AOMP_VERSION_SHORT}
      make

      cd ..
      rm -rf aomp-${AOMP_VERSION_NUMBER}.tar.gz aomp${AOMP_VERSION_SHORT}

      chmod a-w /opt
   fi

   # In either case, create a module file for AOMP compiler
   export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/aomp

   mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat > ${MODULE_PATH}/amdclang-${AOMP_VERSION_SHORT}.lua <<-EOF
	whatis("AMD OpenMP Compiler version 19.0-0 based on LLVM")
	
	local base = "/opt/rocmplus-${ROCM_VERSION}/aomp_19.0-0"

	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("CC", pathJoin(base, "bin/amdclang"))
	setenv("CXX", pathJoin(base, "bin/amdclang++"))
	setenv("FC", pathJoin(base, "bin/flang"))
	setenv("F77", pathJoin(base, "bin/flang"))
	setenv("F90", pathJoin(base, "bin/flang"))
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
