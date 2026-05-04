#!/bin/bash

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
ROCM_VERSION=6.2.0
GITHUB_BRANCH="develop"
# --replace 1: rm -rf prior install dir + ${GITHUB_BRANCH}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
# (Pre-existing REPLACE=0 was a stub never read by the script body.)
REPLACE=0
KEEP_FAILED_INSTALLS=0
# BUILD_ROCPROF_COMPUTE is the master "do this script's work at all" gate.
# Set to 0 to short-circuit early (after arg parsing, before --replace and
# the existence check) with NOOP_RC=43, matching the prior wrapper
# `if [[ "${BUILD_ROCPROF_COMPUTE}" == "1" ]]; then ...; fi` that used
# to live in bare_system/main_setup.sh. Distinct from
# INSTALL_ROCPROF_COMPUTE_FROM_SOURCE: see rocprof-sys_setup.sh comment.
BUILD_ROCPROF_COMPUTE=1
INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=0
SUDO_PACKAGE_INSTALL="sudo"
SUDO_MODULE_INSTALL="sudo"
TOOL_NAME="rocprofiler-compute"
TOOL_CONFIG="ROCPROF_COMPUTE"
TOOL_REPO="https://github.com/ROCm/${TOOL_NAME}"
MODULE_PATH="/etc/lmod/modules/ROCmPlus-AMDResearchTools/${TOOL_NAME}"
MODULE_PATH_INPUT=""
INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/${TOOL_NAME}-${GITHUB_BRANCH}"
INSTALL_PATH_INPUT=""

if [ -f /.singularity.d/Singularity ]; then
   SUDO_PACKAGE_INSTALL=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-rocprof-compute [ BUILD_ROCPROF_COMPUTE ] master gate; 0 = exit NOOP_RC, default $BUILD_ROCPROF_COMPUTE"
   echo "  --help: print this usage information"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL "
   echo "  --install-path: default is: $INSTALL_PATH"
   echo "  --python-version: minor version of Python3, default not set"
   echo "  --module-path: default is: $MODULE_PATH"
   echo "  --install-rocprof-compute-from-source: default is $INSTALL_ROCPROF_COMPUTE_FROM_SOURCE"
   echo "  --rocm-version: default is $ROCM_VERSION"
   echo "  --github-branch: default is $GITHUB_BRANCH"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
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
      "--help")
          shift
          usage
	  ;;
      "--build-rocprof-compute")
          shift
          BUILD_ROCPROF_COMPUTE=${1}
          reset-last
          ;;
      "--install-rocprof-compute-from-source")
          shift
          INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
	  reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH_INPUT=${1}
	  reset-last
          ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
	  reset-last
          ;;
      "--github-branch")
          shift
          GITHUB_BRANCH=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--keep-failed-installs")
          shift
          KEEP_FAILED_INSTALLS=${1}
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/${TOOL_NAME}-${GITHUB_BRANCH}"
fi

if [ "${MODULE_PATH_INPUT}" != "" ]; then
   MODULE_PATH=${MODULE_PATH_INPUT}
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${GITHUB_BRANCH}.lua to match the
# `tee ${MODULE_PATH}/${GITHUB_BRANCH}.lua` write below.
# ── BUILD_ROCPROF_COMPUTE=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_ROCPROF_COMPUTE}" = "0" ]; then
   echo "[rocprof-compute BUILD_ROCPROF_COMPUTE=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[rocprof-compute --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${GITHUB_BRANCH}.lua"
   ${SUDO_PACKAGE_INSTALL} rm -rf "${INSTALL_PATH}"
   ${SUDO_MODULE_INSTALL}  rm -f  "${MODULE_PATH}/${GITHUB_BRANCH}.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[rocprof-compute existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                                  pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

_rocprof_compute_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[rocprof-compute fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO_PACKAGE_INSTALL:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO_MODULE_INSTALL:-sudo}  rm -f  "${MODULE_PATH}/${GITHUB_BRANCH}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[rocprof-compute fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _rocprof_compute_on_exit EXIT

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

echo ""
echo "====================================="
echo "Installing ${TOOL_NAME}:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "INSTALL_PATH is $INSTALL_PATH"
echo "MODULE_PATH is $MODULE_PATH"
echo "GITHUB_BRANCH is $GITHUB_BRANCH"
echo "PYTHON_VERSION is 3.$PYTHON_VERSION"
echo "====================================="
echo ""

if [[ "$INSTALL_ROCPROF_COMPUTE_FROM_SOURCE" == "0" ]];then
   echo " The script is aborting due to the value of the INSTALL_ROCPROF_COMPUTE_FROM_SOURCE flag: $INSTALL_ROCPROF_COMPUTE_FROM_SOURCE	"
   echo " Please supply this option when running the script: '--install-rocprof-compute-from-source 1'"
   # Sentinel rc=43 (NOOP_RC) tells main_setup.sh's run_and_log to
   # classify this as SKIPPED(no-op), not OK. The SDK already ships
   # rocprofiler-compute; this script only adds value when building
   # from source. Kept in sync by convention with main_setup.sh.
   exit 43
fi

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ -f ${CACHE_FILES}/${TOOL_NAME}-${GITHUB_BRANCH}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached ${TOOL_NAME}-${GITHUB_BRANCH}"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/${TOOL_NAME}-${GITHUB_BRANCH}.tgz
      chown -R root:root ${TOOL_NAME}-${GITHUB_BRANCH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO_PACKAGE_INSTALL} rm ${CACHE_FILES}/${TOOL_NAME}-${GITHUB_BRANCH}.tgz
      fi
else

   git clone -b ${GITHUB_BRANCH} https://github.com/ROCm/rocm-systems.git rocm-systems-source
   cd rocm-systems-source/projects/rocprofiler-compute

   ${SUDO_PACKAGE_INSTALL} mkdir -p ${INSTALL_PATH}
   if [[ "${USER}" != "root" ]]; then
      ${SUDO_PACKAGE_INSTALL} chmod -R a+w ${INSTALL_PATH}
   fi

   PYTHON=python3
   if [ "${PYTHON_VERSION}" != "" ]; then
      PYTHON=python3.${PYTHON_VERSION}
   fi

   ${PYTHON} -m pip install -t ${INSTALL_PATH}/python-libs -r requirements.txt --upgrade
   ${PYTHON} -m pip install -t ${INSTALL_PATH}/python-libs pytest --upgrade
   mkdir build && cd build
   cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH}/ \
         -DCMAKE_BUILD_TYPE=Release \
         -DPYTHON_DEPS=${INSTALL_PATH}/python-libs \
         -DMOD_INSTALL_PATH=${INSTALL_PATH}/modulefiles ..
         make install
   cd ../..
   cd ../../..
   rm -rf rocm-systems-source

   if [[ "${USER}" != "root" ]]; then
      ${SUDO_PACKAGE_INSTALL} chmod go-w ${INSTALL_PATH}
   fi
fi

${SUDO_MODULE_INSTALL} mkdir -p ${MODULE_PATH}

cat <<-EOF | ${SUDO_MODULE_INSTALL} tee ${MODULE_PATH}/${GITHUB_BRANCH}.lua
	local help_message = [[

	${TOOL_NAME} is an open-source performance analysis tool for profiling
	machine learning/HPC workloads running on AMD MI GPUs.

	Source cloned from branch ${GITHUB_BRANCH}
	]]

	help(help_message,"\n")

	whatis("Name: ${TOOL_NAME}")
	whatis("Github Branch: ${GITHUB_BRANCH}")
	whatis("Keywords: Profiling, Performance, GPU")
	whatis("Description: tool for GPU performance profiling")
	whatis("URL: https://github.com/ROCm/rocprofiler-compute")

	-- Export environmental variables
	local topDir="${INSTALL_PATH}"
	local binDir="${INSTALL_PATH}/bin"
	local shareDir="${INSTALL_PATH}/share"
	local pythonDeps="${INSTALL_PATH}/python-libs"
	-- no need to set: local roofline="${ROOFLINE_BIN}"

	setenv("${TOOL_CONFIG}_DIR",topDir)
	setenv("${TOOL_CONFIG}_BIN",binDir)
	setenv("${TOOL_CONFIG}_SHARE",shareDir)
	-- no need to set: setenv("ROOFLINE_BIN",roofline)

	-- Update relevant PATH variables
	prepend_path("PATH",binDir)
	if ( pythonDeps  ~= "" ) then
   	prepend_path("PYTHONPATH",pythonDeps)
	end

	-- Site-specific additions
	-- depends_on "python"
	-- depends_on "rocm"
	prereq(atleast("rocm","${ROCM_VERSION}"))
	--  prereq("mongodb-tools")
	local home = os.getenv("HOME")
	setenv("MPLCONFIGDIR",pathJoin(home,".matplotlib"))
EOF
