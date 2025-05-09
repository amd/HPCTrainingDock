#!/bin/bash

# Variables controlling setup process
export AOMP_VERSION_NUMBER=19.0-3
export AOMP_VERSION_SHORT=19.0
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/aomp

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  --build-aomp-latest"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-LatestCompilers/aomp"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --help: this usage information"
   exit 1
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--build-aomp-latest")
          shift
          BUILD_AOMP_LATEST=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
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
echo "Starting AOMP Latest Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_AOMP_LATEST: $BUILD_AOMP_LATEST"
echo "AOMP_VERSION_NUMBER: $AOMP_VERSION_NUMBER"
echo "==================================="
echo ""

if [ "${BUILD_AOMP_LATEST}" = "1" ]; then
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/aomp_${AOMP_VERSION_NUMBER}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached AOMP Latest"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xpzf ${CACHE_FILES}/aomp_${AOMP_VERSION_NUMBER}.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/aomp_${AOMP_VERSION_NUMBER}.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building AOMP Latest"
      echo "============================"
      echo ""

      echo "What directory for AOMP build?"
      pwd
      echo "====================================="
      export AOMP=/opt/rocmplus-${ROCM_VERSION}/aomp
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+rwX /opt
      fi

# Installs aomp from .deb package but then we can't specify where to install it
#     wget -q https://github.com/ROCm/aomp/releases/download/rel_19.0-0/aomp_Ubuntu2204_19.0-0_amd64.deb
#     apt-get install ./aomp_Ubuntu2204_19.0-0_amd64.deb

      ${SUDO} apt-get update
      ${SUDO} ${DEB_FRONTEND} apt-get install -y gawk ninja-build generate-ninja ccache libssl-dev \
	      libgmp-dev libmpfr-dev libbabeltrace-dev liblzma-dev libdrm-dev libelf-dev
      pip3 install CppHeaderParser

      wget -q https://github.com/ROCm-Developer-Tools/aomp/releases/download/rel_${AOMP_VERSION_NUMBER}/aomp-${AOMP_VERSION_NUMBER}.tar.gz
      tar -xzf aomp-${AOMP_VERSION_NUMBER}.tar.gz
      cd aomp${AOMP_VERSION_SHORT}
      echo "What directory for AOMP make?"
      pwd
      echo "====================================="
      make
      echo "====================================="

      cd ..
      rm -rf aomp-${AOMP_VERSION_NUMBER}.tar.gz aomp${AOMP_VERSION_SHORT}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find /opt -type f -execdir chown root:root "{}" +
         ${SUDO} chmod go-w /opt
      fi

   fi

   # In either case, create a module file for AOMP compiler
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/amdclang-${AOMP_VERSION_SHORT}.lua
	whatis("AMD OpenMP Compiler version 19.0-3 based on LLVM")

	local base = "/opt/rocmplus-${ROCM_VERSION}/aomp_19.0-3"

	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("CC", pathJoin(base, "bin/amdclang"))
	setenv("CXX", pathJoin(base, "bin/amdclang++"))
	setenv("FC", pathJoin(base, "bin/flang"))
	setenv("OMPI_CC", pathJoin(base, "bin/amdclang"))
	setenv("OMPI_CXX", pathJoin(base, "bin/amdclang++"))
	setenv("OMPI_FC", pathJoin(base, "bin/flang"))
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
