#!/bin/bash

# Autodetect defaults
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO_PACKAGE_INSTALL="sudo"
SUDO_MODULE_INSTALL="sudo"
ROCM_VERSION=6.2.0
PYTHON_VERSION=10
TOOL_REPO="https://github.com/ROCm/omnitrace"
TOOL_NAME="omnitrace"
TOOL_CONFIG="OMNITRACE"
TOOL_NAME_UC=$TOOL_CONFIG
TOOL_CMAKE_DIR="tool-source"
MPI_MODULE="openmpi"
MODULE_PATH="/etc/lmod/modules/ROCmPlus-AMDResearchTools/${TOOL_NAME}"
MODULE_PATH_INPUT=""
INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/${TOOL_NAME}"
INSTALL_PATH_INPUT=""
GITHUB_BRANCH="develop"
INSTALL_ROCPROF_SYS_FROM_SOURCE=0


if [ -f /.singularity.d/Singularity ]; then
   SUDO_PACKAGE_INSTALL=""
fi


usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default is $MODULE_PATH "
   echo "  --github-branch [ GITHUB_BRANCH] default is $GITHUB_BRANCH "
   echo "  --mpi-module [ MPI_MODULE ] default is $MPI_MODULE "
   echo "  --install-path [ INSTALL_PATH ] default is $INSTALL_PATH "
   echo "  --python-version [ PYTHON_VERSION ] minor version of Python3, default is $PYTHON_VERSION "
   echo "  --install-rocprof-sys-from-source [ INSTALL_ROCPROF_SYS_FROM_SOURCE ] default is $INSTALL_ROCPROF_SYS_FROM_SOURCE "
   echo "  --rocm-version [ ROCM_VERSION ] default is $ROCM_VERSION "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL "
   echo "  --help: print this usage information"
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
      "--install-rocprof-sys-from-source")
          shift
          INSTALL_ROCPROF_SYS_FROM_SOURCE=${1}
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
   TOOL_REPO="https://github.com/ROCm/rocm-systems.git"
   TOOL_CONFIG="ROCPROFSYS"
   TOOL_NAME_UC="ROCPROFILER_SYSTEMS"
   TOOL_CMAKE_DIR="tool-source/projects/rocprofiler-systems"
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
if [ -d "$INSTALL_PATH" ]; then
   if [ -w ${INSTALL_PATH} ]; then
      SUDO_PACKAGE_INSTALL=""
   fi
fi

# don't use sudo if user has write access to module path
if [ -d "$MODULE_PATH" ]; then
   if [ -w ${MODULE_PATH} ]; then
      SUDO_MODULE_INSTALL=""
   fi
fi


# install dependencies
if [ "${DISTRO}" == "ubuntu" ]; then
   if [ "${SUDO_PACKAGE_INSTALL}" == "" ]; then
      export TEXINFO_PATH=${INSTALL_PATH}/texinfo
      wget https://ftp.gnu.org/gnu/texinfo/texinfo-7.0.2.tar.gz
      tar -xzvf texinfo-7.0.2.tar.gz
      cd texinfo-7.0.2
      ./configure --prefix=$TEXINFO_PATH && make && make install
      export PATH=$TEXINFO_PATH/bin:$PATH
      cd ../
      rm -rf texinfo-7.0.2*
   else
      if [ ! -x /usr/bin/gettext ]; then
         ${SUDO_PACKAGE_INSTALL} apt-get update
         ${SUDO_PACKAGE_INSTALL} apt-get install -y gettext autopoint liblzma-dev libzstd-dev
      fi
   fi
fi

# omnitrace (omnitrace-avail) will throw this message using default values, so change default to 2
# [omnitrace][116] /proc/sys/kernel/perf_event_paranoid has a value of 3. Disabling PAPI (requires a value <= 2)...
# [omnitrace][116] In order to enable PAPI support, run 'echo N | ${SUDO} tee /proc/sys/kernel/perf_event_paranoid' where                   N is <= 2
if (( `cat /proc/sys/kernel/perf_event_paranoid` > 0 )); then echo "Please do:  echo 0  | ${SUDO_PACKAGE_INSTALL} tee /proc/sys/kernel/perf_event_paranoid"; fi

echo ""
echo "============================"
echo " Installing ${TOOL_NAME} with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "AMDGPU_GFXMODEL is $AMDGPU_GFXMODEL"
echo "INSTALL_ROCPROF_SYS_FROM_SOURCE is $INSTALL_ROCPROF_SYS_FROM_SOURCE"
echo "INSTALL_PATH is $INSTALL_PATH"
echo "MODULE_PATH is $MODULE_PATH"
echo "PYTHON_VERSION is 3.$PYTHON_VERSION"
echo "============================"
echo ""

if [[ "$INSTALL_ROCPROF_SYS_FROM_SOURCE" == "0" ]];then
   echo " Exiting due to value of INSTALL_ROCPROF_SYS_FROM_SOURCE being: $INSTALL_ROCPROF_SYS_FROM_SOURCE "
   echo " Use '--install-rocprof-sys-from source 1' as input to enable this installation"
   exit
fi

if [ "${INSTALL_ROCPROF_SYS_FROM_SOURCE}" = "1" ] ; then
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
      tar -xzf ${CACHE_FILES}/${TOOL_NAME}.tgz
      chown -R root:root ${TOOL_NAME}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO_PACKAGE_INSTALL} rm ${CACHE_FILES}/${TOOL_NAME}.tgz
      fi

   else
      # Load the ROCm version for this build
      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm/${ROCM_VERSION}
      module load ${MPI_MODULE}

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

      ${SUDO_PACKAGE_INSTALL} mkdir -p ${INSTALL_PATH}

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
             -D GPU_TARGETS="${AMDGPU_GFXMODEL}"  \
             -D CpuArch_TARGET=${CPU_TYPE} \
             -D ${TOOL_CONFIG}_DEFAULT_ROCM_PATH=${ROCM_PATH} \
             -D ${TOOL_CONFIG}_USE_COMPILE_TIMING=ON \
             ${TOOL_CMAKE_DIR}

      cmake --build tool-build --target all --parallel 16
      ${SUDO_PACKAGE_INSTALL} cmake --build tool-build --target install
      rm -rf tool-source tool-build
   fi
fi

${SUDO_MODULE_INSTALL} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO_MODULE_INSTALL} tee ${MODULE_PATH}/${GITHUB_BRANCH}.lua
	whatis("Name: ${TOOL_NAME}")
	whatis("Installed from Github branch: ${GITHUB_BRANCH}")
	whatis("Category: AMD")
	whatis("${TOOL_NAME}")

	local topDir = "${INSTALL_PATH}"
	local binDir = "${INSTALL_PATH}/bin"
	local shareDir = "${INSTALL_PATH}/share/${TOOL_NAME}"

	setenv("${TOOL_NAME_UC}_DIR",topDir)
	setenv("${TOOL_NAME_UC}_BIN",binDir)
	setenv("${TOOL_NAME_UC}_SHARE",shareDir)
	prepend_path("PATH", pathJoin(shareDir, "bin"))

	load("rocm/${ROCM_VERSION}")
	prepend_path("LD_LIBRARY_PATH", pathJoin(topDir, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(topDir, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(topDir, "include"))
	prepend_path("CPATH", pathJoin(topDir, "include"))
	prepend_path("PATH", pathJoin(topDir, "bin"))
	prepend_path("PYTHONPATH",pathJoin(topDir,"lib/python3.${PYTHON_VERSION}/site-packages"))
	prepend_path("INCLUDE", pathJoin(topDir, "include"))
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
	set_shell_function("omnitrace-avail",'${INSTALL_PATH}/bin/rocprof-sys-avail "$@"',"${INSTALL_PATH}/bin/rocprof-sys-avail $*")
	set_shell_function("omnitrace-instrument",'${INSTALL_PATH}/bin/rocprof-sys-instrument "$@"',"${INSTALL_PATH}/bin/rocprof-sys-instrument $*")
	set_shell_function("omnitrace-run",'${INSTALL_PATH}/bin/rocprof-sys-run "$@"',"${INSTALL_PATH}/bin/rocprof-sys-run $*")
EOF


