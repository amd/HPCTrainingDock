#!/bin/bash

# Variables controlling setup process
MODULE_PATH==/etc/lmod/modules/ROCmPlus-AMDResearchTools/omnitrace
OMNITRACE_BUILD_FROM_SOURCE=0

# Autodetect defaults
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-MPI/openmpi"
   echo "--omnitrace-build-from-source [OMNITRACE_BUILD_FROM_SOURCE]"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
      "--omnitrace-build-from-source")
          shift
          OMNITRACE_BUILD_FROM_SOURCE=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

echo ""
echo "============================"
echo " Installing Omnitrace with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "AMDGPU_GFXMODEL is $AMDGPU_GFXMODEL"
echo "OMNITRACE_BUILD_FROM_SOURCE is $OMNITRACE_BUILD_FROM_SOURCE"
echo "============================"
echo ""

if [ "${OMNITRACE_BUILD_FROM_SOURCE}" = "0" ] ; then
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}
   if [ -f ${CACHE_FILES}/omnitrace.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Omnitrace"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      sudo tar -xzf ${CACHE_FILES}/omnitrace.tgz
      sudo chown -R root:root /opt/rocmplus-${ROCM_VERSION}/omnitrace
      if [ "${USER}" != "sysadmin" ]; then
         sudo rm ${CACHE_FILES}/omnitrace.tgz
      fi
   else
      if  wget -q https://github.com/AMDResearch/omnitrace/releases/download/v1.11.1/omnitrace-install.py && \
          python3 ./omnitrace-install.py --prefix /opt/rocmplus-${ROCM_VERSION}/omnitrace --rocm "${ROCM_VERSION}" -d ubuntu -v "${DISTRO_VERSION}"; then
         OMNITRACE_PREBUILT_DOWNLOADED=1
      else
         OMNITRACE_PREBUILT_DOWNLOADED=0
         OMNITRACE_BUILD_FROM_SOURCE=1
      fi
   fi
fi

if [ "${OMNITRACE_BUILD_FROM_SOURCE}" = "1" ] ; then
   # Load the ROCm version for this build
   source /etc/profile.d/lmod.sh
   module load rocm/${ROCM_VERSION} openmpi

   CPU_TYPE=zen3
   if [ "${AMDGFX_GFXMODE}L" = "gfx1030" ]; then
      CPU_TYPE=zen2
   fi
   if [ "${AMDGFX_GFXMODE}L" = "gfx90a" ]; then
      CPU_TYPE=zen3
   fi
   if [ "${AMDGFX_GFXMODE}L" = "gfx942" ]; then
      CPU_TYPE=zen4
   fi

   # Fixing error "mv: cannot stat 't-es.gmo': No such file or directory: (language support) due to missing gettext
   if [ ! -x /usr/bin/gettext ]; then
      sudo apt-get update
      sudo apt-get install -y gettext autopoint
   fi

   git clone --depth 1 https://github.com/AMDResearch/omnitrace.git omnitrace-source --recurse-submodules && \
       cmake                                         \
          -B omnitrace-build                      \
          -D CMAKE_INSTALL_PREFIX=/opt/rocmplus-${ROCM_VERSION}/omnitrace  \
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
          -D AMDGPU_TARGETS="${AMDGPU_GFXMODE}L"  \
          -D CpuArch_TARGET=${CPU_TYPE} \
          -D OMNITRACE_DEFAULT_ROCM_PATH=/opt/rocm-${ROCM_VERSION} \
          -D OMNITRACE_USE_COMPILE_TIMING=ON \
          omnitrace-source

   cmake --build omnitrace-build --target all --parallel 16
   sudo cmake --build omnitrace-build --target install
   rm -rf omnitrace-source
fi

# In either case, create a module file for Omnitrace
sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | sudo tee ${MODULE_PATH}/1.11.2.lua
	whatis("Name: omnitrace")
	whatis("Version: 1.11.2")
	whatis("Category: AMD")
	whatis("omnitrace")

	local base = "/opt/rocmplus-${ROCM_VERSION}/omnitrace/"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	setenv("OMNITRACE_PATH", base)
	load("rocm/${ROCM_VERSION}")
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
EOF


