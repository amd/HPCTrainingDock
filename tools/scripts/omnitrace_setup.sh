#!/bin/bash

# Variables controlling setup process
OMNITRACE_BUILD_FROM_SOURCE=0
INSTALL_OMNITRACE_RESEARCH=0

# Autodetect defaults
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"
ROCM_VERSION=6.0
PYTHON_VERSION=12
OMNITRACE_VERSION=1.11.3
TOOL_REPO="https://github.com/ROCm/omnitrace"
TOOL_NAME="omnitrace"
TOOL_CONFIG="OMNITRACE"
MPI_MODULE="openmpi"
MODULE_PATH="/etc/lmod/modules/ROCmPlus-AMDResearchTools/${TOOL_NAME}"
MODULE_PATH_INPUT=""
INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/${TOOL_NAME}"
INSTALL_PATH_INPUT=""
GITHUB_BRANCH="amd-staging"


if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi


usage()
{
   echo "Usage:"
   echo "  --module-path [ MODULE_PATH ] default is $MODULE_PATH "
   echo "  --github-branch [GITHUB_BRANCH] default is $GITHUB_BRANCH "
   echo "  --mpi-module [ MPI_MODULE ] default is $MPI_MODULE "
   echo "  --omnitrace-build-from-source [OMNITRACE_BUILD_FROM_SOURCE] default is $OMNITRACE_BUILD_FROM_SOURCE "
   echo "  --install-path [INSTALL_PATH ] default is $INSTALL_PATH "
   echo "  --python-version [PYTHON_VERSION ] minor version of Python3, default is $PYTHON_VERSION "
   echo "  --install-omnitrace-research [INSTALL_OMNITRACE_RESEARCH] default is $INSTALL_OMNITRACE_RESEARCH "
   echo "  --rocm-version [ ROCM_VERSION ] default is $ROCM_VERSION "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL "
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--help")
          usage
	  ;;
      "--install-omnitrace-research")
          shift
          INSTALL_OMNITRACE_RESEARCH=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH_INPUT=${1}
          reset-last
          ;;
      "--github-branch")
          shift
          GITHUB_BRANCH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
	  ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
	  ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
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

result=`echo ${ROCM_VERSION} | awk '$1>6.2.9'` && echo $result
if [[ "${result}" ]]; then
   TOOL_NAME="rocprofiler-systems"
   TOOL_REPO="https://github.com/ROCm/rocprofiler-systems.git"
   TOOL_CONFIG="ROCPROFSYS"
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/${TOOL_NAME}"
fi

if [ "${MODULE_PATH_INPUT}" != "" ]; then
   MODULE_PATH=${MODULE_PATH_INPUT}
else
   # override path with right ${TOOL_NAME}
   MODULE_PATH="/etc/lmod/modules/ROCmPlus-AMDResearchTools/${TOOL_NAME}"
fi

# don't use sudo if user has write access to install path
if [ -w ${INSTALL_PATH} ]; then
   SUDO=""
   export TEXINFO_PATH=${INSTALL_PATH}/texinfo
   wget https://ftp.gnu.org/gnu/texinfo/texinfo-7.0.2.tar.gz
   tar -xzvf texinfo-7.0.2.tar.gz
   cd texinfo-7.0.2
   ./configure --prefix=$TEXINFO_PATH && make && make install
   export PATH=$TEXINFO_PATH/bin:$PATH
   rm -rf texinfo-7.0.2*
else
   if [ ! -x /usr/bin/gettext ]; then
      ${SUDO} apt-get update
      ${SUDO} apt-get install -y gettext autopoint
   fi
fi

# omnitrace (omnitrace-avail) will throw this message using default values, so change default to 2
# [omnitrace][116] /proc/sys/kernel/perf_event_paranoid has a value of 3. Disabling PAPI (requires a value <= 2)...
# [omnitrace][116] In order to enable PAPI support, run 'echo N | ${SUDO} tee /proc/sys/kernel/perf_event_paranoid' where                   N is <= 2
if (( `cat /proc/sys/kernel/perf_event_paranoid` > 0 )); then echo "Please do:  echo 0  | ${SUDO} tee /proc/sys/kernel/perf_event_paranoid"; fi

PYTHON_VERSION="3.${PYTHON_VERSION}"

echo ""
echo "============================"
echo " Installing ${TOOL_NAME} with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "AMDGPU_GFXMODEL is $AMDGPU_GFXMODEL"
echo "OMNITRACE_BUILD_FROM_SOURCE is $OMNITRACE_BUILD_FROM_SOURCE"
echo "INSTALL_PATH is $INSTALL_PATH"
echo "MODULE_PATH is $MODULE_PATH"
echo "PYTHON_VERSION is 3.$PYTHON_VERSION"
echo "============================"
echo ""

if [[ "$INSTALL_OMNITRACE_RESEARCH" == "0" ]];then
   echo " Exiting due to value of INSTALL_OMNITRACE_RESEARCH being: $INSTALL_OMNITRACE_RESEARCH "
   echo " Use --install-omnitrace-research 1 as input to enable this installation"
   exit
fi

if [ "${OMNITRACE_BUILD_FROM_SOURCE}" = "0" ] ; then
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/${TOOL_NAME}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached ${TOOL_NAME}"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -pxzf ${CACHE_FILES}/${TOOL_NAME}.tgz
      #${SUDO} chown -R root:root /opt/rocmplus-${ROCM_VERSION}/${TOOL_NAME}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/${TOOL_NAME}.tgz
      fi
   else
      result=`echo ${ROCM_VERSION} | awk '$1>6.2.9'` && echo $result
      if [[ "${result}" ]]; then
	 echo " ---------------- ERROR ---------------- "
         echo " You are checking for a pre-build omnitrace but ROCm version is above 6.2.4 "
	 echo " You should either install rocprofiler-systems with sudo apt-get roprofiler-systems "
	 echo " Or from source with this script specifying --omnitrace-build-from-source 1 "
	 exit 1
      else
         if  wget -q https://github.com/AMDResearch/omnitrace/releases/download/v${OMNITRACE_VERSION}/omnitrace-install.py && \
         python3.${PYTHON_VERSION} ./omnitrace-install.py --prefix /opt/rocmplus-${ROCM_VERSION}/omnitrace --rocm "${ROCM_VERSION}" -d ubuntu -v "${DISTRO_VERSION}"; then
            OMNITRACE_PREBUILT_DOWNLOADED=1
         else
            OMNITRACE_PREBUILT_DOWNLOADED=0
            OMNITRACE_BUILD_FROM_SOURCE=1
         fi
      fi
   fi
fi

if [ "${OMNITRACE_BUILD_FROM_SOURCE}" = "1" ] ; then
   # Load the ROCm version for this build
   source /etc/profile.d/lmod.sh
   source /etc/profile.d/z01_lmod.sh
   module load rocm/${ROCM_VERSION}
   module load ${MPI_MODULE}
   TOOL_VERSION="amd-staging"

   CPU_TYPE=zen3
   if [ "${AMDGFX_GFXMODEL}" = "gfx1030" ]; then
      CPU_TYPE=zen2
   fi
   if [ "${AMDGFX_GFXMODEL}" = "gfx90a" ]; then
      CPU_TYPE=zen3
   fi
   if [ "${AMDGFX_GFXMODEL}" = "gfx942" ]; then
      CPU_TYPE=zen4
   fi

   ${SUDO} mkdir -p ${INSTALL_PATH}

   git clone --depth 1 --branch ${GITHUB_BRANCH} ${TOOL_REPO} tool-source --recurse-submodules && \
       cmake                                         \
          -B tool-build                      \
          -D CMAKE_INSTALL_PREFIX=${INSTALL_PATH}  \
          -D ${TOOL_CONFIG}_USE_HIP=ON                 \
          -D ${TOOL_CONFIG}_USE_ROCM_SMI=ON            \
          -D ${TOOL_CONFIG}_USE_ROCTRACER=ON           \
          -D ${TOOL_CONFIG}_USE_PYTHON=ON              \
          -D ${TOOL_CONFIG}_USE_OMPT=ON                \
          -D ${TOOL_CONFIG}_USE_MPI_HEADERS=ON         \
          -D ${TOOL_CONFIG}_USE_MPI=ON                 \
          -D ${TOOL_CONFIG}_BUILD_PAPI=ON              \
          -D ${TOOL_CONFIG}_BUILD_LIBUNWIND=ON         \
          -D ${TOOL_CONFIG}_BUILD_DYNINST=ON           \
          -D DYNINST_BUILD_TBB=ON                 \
          -D DYNINST_BUILD_BOOST=ON               \
          -D DYNINST_BUILD_ELFUTILS=ON            \
          -D DYNINST_BUILD_LIBIBERTY=ON           \
          -D AMDGPU_TARGETS="${AMDGPU_GFXMODEL}"  \
          -D CpuArch_TARGET=${CPU_TYPE} \
          -D ${TOOL_CONFIG}_DEFAULT_ROCM_PATH=${ROCM_PATH} \
          -D ${TOOL_CONFIG}_USE_COMPILE_TIMING=ON \
          tool-source

   cmake --build tool-build --target all --parallel 16
   ${SUDO} cmake --build tool-build --target install
   rm -rf tool-source tool-build
fi

# Create a module file for ${TOOL_NAME}
if [ ! -w ${MODULE_PATH} ]; then
   SUDO="sudo"
fi

${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${TOOL_VERSION}.lua
	whatis("Name: ${TOOL_NAME}")
	whatis("Version: ${TOOL_VERSION}")
	whatis("Category: AMD")
	whatis("${TOOL_NAME}")

	local base = "${INSTALL_PATH}"

	load("rocm/${ROCM_VERSION}")
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
        prepend_path("PYTHONPATH",pathJoin(base,"lib/${PYTHON_VERSION}/site-packages"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	setenv("${TOOL_CONFIG}_PATH", base)
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
EOF


