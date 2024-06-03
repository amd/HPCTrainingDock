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
      "--build-og-latest")
          shift
          BUILD_OG_LATEST=${1}
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
echo "Starting OG Latest Install with"
echo "BUILD_OG_LATEST: $BUILD_OG_LATEST" 
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "==================================="
echo ""


if [ "${BUILD_OG_LATEST}" = "1" ] ; then
   if [ -f /opt/rocmplus-${ROCM_VERSION}/og13.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached OG Latest"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf og13.tgz 
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/og13-*
      rm /opt/rocmplus-${ROCM_VERSION}/og13.tgz

      cd /etc/lmod/modules/ROCmPlus-LatestCompilers
      tar -xzf /opt/rocmplus-${ROCM_VERSION}/og13module.tgz
      chown -R root:root /etc/lmod/modules/ROCmPlus-LatestCompilers/og*
      rm /opt/rocmplus-${ROCM_VERSION}/og13module.tgz
   else
      echo ""
      echo "============================"
      echo " Building OG Latest"
      echo "============================"
      echo ""


      # Install the OpenMP GCC compiler latest drop
      export OG_INSTALL_DIR=/opt/rocmplus-${ROCM_VERSION}/og13-SCRIPT_OG_BUILD_DATE
      export OGDIR=/opt/rocmplus-${ROCM_VERSION}/og_build
      cd /opt/rocmplus-${ROCM_VERSION}
      git clone --depth 1 https://github.com/ROCm-Developer-Tools/og
      cd og
      bin/build_og13.sh
      cd /opt/rocmplus-${ROCM_VERSION}
      rm -rf og og_build

      # Only install module when building OG gcc development compiler
      #  For cached version, use a cached module file
      export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/og

      sudo mkdir -p ${MODULE_PATH}

      # The - option suppresses tabs
      cat <<-EOF | sudo tee ${MODULE_PATH}/gcc-develop-SCRIPT_OG_BUILD_DATE.lua
	whatis("GCC Development Version SCRIPT_OG_BUILD_DATE compiler")

	local base = "/opt/rocmplus-${ROCM_VERSION}/og13-SCRIPT_OG_BUILD_DATE"

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
fi
