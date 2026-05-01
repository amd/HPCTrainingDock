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

# Variables controlling setup process
ROCM_VERSION=6.2.0
BUILD_CUPY=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/cupy
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
CUPY_PATH=/opt/rocmplus-${ROCM_VERSION}/cupy
CUPY_PATH_INPUT=""
CUPY_VERSION="13.6.0"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-cupy [ BUILD_CUPY ] default $BUILD_CUPY "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ CUPY_PATH ] default $CUPY_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --cupy-version [ CUPY_VERSION ] specify the version of CuPy, default is $CUPY_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
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
      "--build-cupy")
          shift
          BUILD_CUPY=${1}
	  reset-last
          ;;
      "--cupy-version")
          shift
          CUPY_VERSION=${1}
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
      "--install-path")
          shift
          CUPY_PATH_INPUT=${1}
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

if [ "${CUPY_PATH_INPUT}" != "" ]; then
   CUPY_PATH=${CUPY_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   CUPY_PATH=/opt/rocmplus-${ROCM_VERSION}/cupy
fi

REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" )
preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
ROCM_HOME=${ROCM_PATH}

echo ""
echo "==================================="
echo "Starting CuPy Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_CUPY: $BUILD_CUPY"
echo "CUPY_PATH: $CUPY_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "CUPY_VERSION: $CUPY_VERSION"
echo "==================================="
echo ""

if [ "${BUILD_CUPY}" = "0" ]; then

   echo "CuPy will not be built, according to the specified value of BUILD_CUPY"
   echo "BUILD_CUPY: $BUILD_CUPY"
   exit

else
   # Per-job throwaway build dir; replaces a fixed `cd /tmp` (with a
   # later `rm -rf cupy cupy_build`) that would race with any other
   # concurrent cupy build on the same node.
   CUPY_BUILD_ROOT=$(mktemp -d -t cupy-build.XXXXXX)
   trap '[ -n "${CUPY_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${CUPY_BUILD_ROOT}"' EXIT
   cd "${CUPY_BUILD_ROOT}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/cupy.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached CuPy"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/cupy
      cd /opt/rocmplus-${ROCM_VERSION}
      #${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/cupy.tgz
      #chown -R root:root /opt/rocmplus-${ROCM_VERSION}/cupy
      #${SUDO} chmod og-w /opt/rocmplus-${ROCM_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/cupy.tgz
      fi
      SAVED_ROCM_HOME=${ROCM_HOME}
   else
      echo ""
      echo "============================"
      echo " Building CuPy"
      echo "============================"
      echo ""


      # Load the ROCm version for this CuPy build -- use hip compiler, path to ROCm and the GPU model
      export CUPY_INSTALL_USE_HIP=1
      export ROCM_HOME=${ROCM_PATH}
      export HIPCC=${ROCM_HOME}/bin/hipcc
      export HCC_AMDGPU_ARCH=$(echo ${AMDGPU_GFXMODEL} | cut -d';' -f1)
      OFFLOAD_ARCH_FLAGS=""
      for arch in $(echo ${AMDGPU_GFXMODEL} | tr ';' ' '); do
          OFFLOAD_ARCH_FLAGS+=" --offload-arch=${arch}"
      done
      export HIPCC_COMPILE_FLAGS_APPEND="${OFFLOAD_ARCH_FLAGS} ${HIPCC_COMPILE_FLAGS_APPEND}"
      # Detect a system `uv` if present, but make the lookup non-fatal
      # under set -eo pipefail (line 5).  The previous form
      #   UV_LOC=`which uv`
      # silently aborted the entire script whenever `uv` was not
      # installed (Debian `which` exits 1 with no diagnostic on either
      # stream), so the `if [ "x$UV_LOC" == "x" ]` fallback below was
      # dead code -- the script terminated before reaching it. Audit
      # ref: 7973 cupy rc=1 with log truncated at the "Building CuPy"
      # banner. `command -v` is a POSIX builtin (no external `which`
      # dep); `2>/dev/null || true` keeps set -e quiet on a miss.
      UV_LOC=$(command -v uv 2>/dev/null || true)
      python3 -m venv cupy_build
      source cupy_build/bin/activate
      if [ "x$UV_LOC" == "x" ]; then
         pip3 install uv
         PATH="${PATH}:~/.local/bin"
      fi

      if [ -d "$CUPY_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${CUPY_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $CUPY_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $CUPY_PATH
      fi
      uv pip install -v --target=$CUPY_PATH pytest mock xarray[complete] build numpy-allocator --no-cache
      export PYTHONPATH=$PYTHONPATH:$CUPY_PATH
      if [ "$(printf '%s\n' "$ROCM_VERSION" "6.4.4" | sort -V | head -n1)" = "$ROCM_VERSION" ]; then
         # Get source from the upstream repository of CuPy.
         git clone -q --depth 1 -b v$CUPY_VERSION --recursive https://github.com/cupy/cupy.git
         cd cupy
      else
	 git clone -q --depth 1 -b release/rocmds-25.10 https://github.com/ROCm/cupy.git     
         cd cupy
	 git submodule update --init --recursive
      fi	      
      uv build --wheel
      uv pip install -v --upgrade --target=$CUPY_PATH dist/*.whl
      uv pip install -v --target=$CUPY_PATH cupy-xarray --no-deps
      deactivate
      cd /
      # clean-up: trap handles ${CUPY_BUILD_ROOT}/{cupy,cupy_build}
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $CUPY_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $CUPY_PATH -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $CUPY_PATH
      fi

      SAVED_ROCM_HOME=${ROCM_HOME}
      module unload rocm/${ROCM_VERSION}
   fi

   # Create a module file for cupy
   if [ -d "$MODULE_PATH" ]; then
      # use sudo if user does not have write access to module path
      if [ ! -w ${MODULE_PATH} ]; then
         SUDO="sudo"
      else
         echo "WARNING: not using sudo since user has write access to module path"
      fi
   else
      # if module path dir does not exist yet, the check on write access will fail
      SUDO="sudo"
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${CUPY_VERSION}.lua
	whatis("CuPy with ROCm support")

	prereq("rocm/${ROCM_VERSION}")
	prepend_path("PYTHONPATH","$CUPY_PATH")
	prepend_path("CPATH","/usr/lib/gcc/x86_64-linux-gnu/12/include")
        setenv("ROCM_HOME","$SAVED_ROCM_HOME")
EOF

fi
