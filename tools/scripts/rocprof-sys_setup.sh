#!/bin/bash

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# ── Preflight: declare and load required Lmod modules ─────────────────
# Inlined (formerly bare_system/lib/preflight.sh) so this script is
# self-contained and can be copied/run standalone. preflight_modules
# loads each module in order; on the first failure it prints the Lmod
# diagnostic and returns MISSING_PREREQ_RC=42, which the parent
# main_setup.sh re-classifies as SKIPPED rather than FAILED.
MISSING_PREREQ_RC=42
if ! type module >/dev/null 2>&1; then
   [ -r /etc/profile.d/lmod.sh ]            && . /etc/profile.d/lmod.sh
   [ -r /usr/share/lmod/lmod/init/bash ]    && . /usr/share/lmod/lmod/init/bash
fi
preflight_modules() {
   [ "$#" -eq 0 ] && return 0
   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command not available; needed:$(printf ' %s' "$@")" >&2
      return ${MISSING_PREREQ_RC}
   fi
   echo "preflight: required modules:$(printf ' %s' "$@")"
   local m err
   err=$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)
   for m in "$@"; do
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         [ -s "${err}" ] && sed 's/^/  module> /' "${err}" >&2
         rm -f "${err}"
         return ${MISSING_PREREQ_RC}
      fi
   done
   rm -f "${err}"
   echo "preflight: all required modules loaded."
}

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
# BUILD_ROCPROF_SYS is the master "do this script's work at all" gate.
# Set to 0 to short-circuit early (after arg parsing, before --replace
# and the existence check) with NOOP_RC=43, matching the prior wrapper
# `if [[ "${BUILD_ROCPROF_SYS}" == "1" ]]; then run_and_log ...; fi`
# that used to live in bare_system/main_setup.sh. Distinct from
# INSTALL_ROCPROF_SYS_FROM_SOURCE: the latter is a *what* knob (build
# vs. use the SDK's prebuilt binary, default = use prebuilt) whereas
# BUILD_ROCPROF_SYS is the *whether* gate.
BUILD_ROCPROF_SYS=1
INSTALL_ROCPROF_SYS_FROM_SOURCE=0
# --replace 1: rm -rf prior install dir + ${GITHUB_BRANCH}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0


if [ -f /.singularity.d/Singularity ]; then
   SUDO_PACKAGE_INSTALL=""
fi


usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-rocprof-sys [ BUILD_ROCPROF_SYS ] master gate; 0 = exit NOOP_RC, default $BUILD_ROCPROF_SYS"
   echo "  --module-path [ MODULE_PATH ] default is $MODULE_PATH "
   echo "  --github-branch [ GITHUB_BRANCH] default is $GITHUB_BRANCH "
   echo "  --mpi-module [ MPI_MODULE ] default is $MPI_MODULE "
   echo "  --install-path [ INSTALL_PATH ] default is $INSTALL_PATH "
   echo "  --python-version [ PYTHON_VERSION ] minor version of Python3, default is $PYTHON_VERSION "
   echo "  --install-rocprof-sys-from-source [ INSTALL_ROCPROF_SYS_FROM_SOURCE ] default is $INSTALL_ROCPROF_SYS_FROM_SOURCE "
   echo "  --rocm-version [ ROCM_VERSION ] default is $ROCM_VERSION "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL "
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
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
      "--build-rocprof-sys")
          shift
          BUILD_ROCPROF_SYS=${1}
          reset-last
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

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name here is ${GITHUB_BRANCH}.lua (e.g. develop.lua),
# matching the `tee ${MODULE_PATH}/${GITHUB_BRANCH}.lua` write below.
# ── BUILD_ROCPROF_SYS=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_ROCPROF_SYS}" = "0" ]; then
   echo "[rocprof-sys BUILD_ROCPROF_SYS=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[rocprof-sys --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${GITHUB_BRANCH}.lua"
   ${SUDO_PACKAGE_INSTALL} rm -rf "${INSTALL_PATH}"
   ${SUDO_MODULE_INSTALL}  rm -f  "${MODULE_PATH}/${GITHUB_BRANCH}.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[rocprof-sys existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                              pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

_rocprof_sys_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[rocprof-sys fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO_PACKAGE_INSTALL:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO_MODULE_INSTALL:-sudo}  rm -f  "${MODULE_PATH}/${GITHUB_BRANCH}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[rocprof-sys fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _rocprof_sys_on_exit EXIT

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
   echo " Use '--install-rocprof-sys-from-source 1' as input to enable this installation"
   # Sentinel rc=43 (NOOP_RC) tells main_setup.sh's run_and_log to
   # classify this as SKIPPED(no-op), not OK. The SDK already ships
   # rocprofiler-systems; this script only adds value when building
   # from source. Kept in sync by convention with main_setup.sh.
   exit 43
fi

if [ "${INSTALL_ROCPROF_SYS_FROM_SOURCE}" = "1" ] ; then
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f "${CACHE_FILES}/${TOOL_NAME}.tgz" ]; then
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
      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      CPU_TYPE=zen3
      if [ "${AMDGPU_GFXMODEL}" = "gfx1030" ]; then
         CPU_TYPE=zen2
      fi
      if [ "${AMDGPU_GFXMODEL}" = "gfx90a" ]; then
         CPU_TYPE=zen3
      fi
      if [ "${AMDGPU_GFXMODEL}" = "gfx942" ]; then
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

	prereq("rocm/${ROCM_VERSION}")
	prepend_path("LD_LIBRARY_PATH", pathJoin(topDir, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(topDir, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(topDir, "include"))
	prepend_path("CPATH", pathJoin(topDir, "include"))
	prepend_path("PATH", pathJoin(topDir, "bin"))
	prepend_path("PYTHONPATH",pathJoin(topDir,"lib/python3.${PYTHON_VERSION}/site-packages"))
	prepend_path("INCLUDE", pathJoin(topDir, "include"))
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
EOF


