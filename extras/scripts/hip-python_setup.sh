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
ROCM_VERSION=6.4.3
BUILD_HIP_PYTHON=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/hip-python
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
HIP_PYTHON_PATH=/opt/rocmplus-${ROCM_VERSION}/hip-python
HIP_PYTHON_PATH_INPUT=""
HIP_PYTHON_VERSION=""    # empty -> use "${ROCM_VERSION}.*" pip wildcard (legacy default)
# --replace 1: rm -rf prior install dir + ${ROCM_VERSION}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

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
   echo "  --build-hip-python [ BUILD_HIP_PYTHON ] default $BUILD_HIP_PYTHON "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ HIP_PYTHON_PATH ] default $HIP_PYTHON_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hip-python-version [ HIP_PYTHON_VERSION ] PyPI version specifier (default: \${ROCM_VERSION}.*)"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
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
      "--build-hip-python")
          shift
          BUILD_HIP_PYTHON=${1}
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
          HIP_PYTHON_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--hip-python-version")
          shift
          HIP_PYTHON_VERSION=${1}
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

if [ "${HIP_PYTHON_PATH_INPUT}" != "" ]; then
   HIP_PYTHON_PATH=${HIP_PYTHON_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   HIP_PYTHON_PATH=/opt/rocmplus-${ROCM_VERSION}/hip-python
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${ROCM_VERSION}.lua to match the
# `tee ${MODULE_PATH}/${ROCM_VERSION}.lua` write below.
# ── BUILD_HIP_PYTHON=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_HIP_PYTHON}" = "0" ]; then
   echo "[hip-python BUILD_HIP_PYTHON=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[hip-python --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HIP_PYTHON_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${ROCM_VERSION}.lua"
   ${SUDO} rm -rf "${HIP_PYTHON_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${ROCM_VERSION}.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${HIP_PYTHON_PATH}" ]; then
   echo ""
   echo "[hip-python existence-check] ${HIP_PYTHON_PATH} already installed; skipping."
   echo "                             pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (HIP_PYTHON_BUILD_DIR, set
# under BUILD_HIP_PYTHON=1) + fail-cleanup. Replaces inline build-dir
# `trap '... rm HIP_PYTHON_BUILD_DIR ...' EXIT` later in the script.
_hip_python_on_exit() {
   local rc=$?
   [ -n "${HIP_PYTHON_BUILD_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${HIP_PYTHON_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hip-python fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HIP_PYTHON_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${ROCM_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[hip-python fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _hip_python_on_exit EXIT

echo ""
echo "==================================="
echo "Starting HIP-Python Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_HIP_PYTHON: $BUILD_HIP_PYTHON"
echo "HIP_PYTHON_PATH: $HIP_PYTHON_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_HIP_PYTHON}" = "0" ]; then

   echo "HIP-Python will not be built, according to the specified value of BUILD_HIP_PYTHON"
   echo "BUILD_HIP_PYTHON: $BUILD_HIP_PYTHON"
   exit

else
   # Per-job throwaway scratch dir under /tmp (or $TMPDIR if Slurm
   # set one). Replaces a bare `cd /tmp` followed by a fixed
   # `hip-python-build` venv path — concurrent rocm-version jobs
   # would race on /tmp/hip-python-build (deactivate of one and
   # `rm -rf hip-python-build` of the other could nuke an in-flight
   # pip install). Only `pip install --target=$HIP_PYTHON_PATH`
   # writes hit NFS. EXIT trap handles cleanup of the build venv.
   HIP_PYTHON_BUILD_DIR=$(mktemp -d -t hip-python-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into _hip_python_on_exit
   # installed above (so the same EXIT handler also does fail-cleanup
   # of any partial install / modulefile).
   cd "${HIP_PYTHON_BUILD_DIR}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/hip-python.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HIP-Python"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/hip-python
      cd /opt/rocmplus-${ROCM_VERSION}
      #${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/hip-python.tgz
      #chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hip-python
      #${SUDO} chmod og-w /opt/rocmplus-${ROCM_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/hip-python.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building HIP-Python"
      echo "============================"
      echo " HIP_PYTHON_PATH is $HIP_PYTHON_PATH"
      echo ""


      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
      export HIP_PYTHON_INSTALL_USE_HIP=1
      export ROCM_HOME=${ROCM_PATH}
      export HIPCC=${ROCM_HOME}/bin/hipcc
      export HCC_AMDGPU_ARCH=${AMDGPU_GFXMODEL}

      if [ -d "$HIP_PYTHON_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${HIP_PYTHON_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $HIP_PYTHON_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $HIP_PYTHON_PATH
      fi
      python3 -m venv hip-python-build
      source hip-python-build/bin/activate
      python3 -m pip install pip --upgrade
      HIP_PYTHON_PIP_SPEC="${HIP_PYTHON_VERSION:-${ROCM_VERSION}.*}"
      echo "Installing hip-python with PyPI spec: ${HIP_PYTHON_PIP_SPEC}"
      python3 -m pip install --target=$HIP_PYTHON_PATH/hip-python -i https://test.pypi.org/simple "hip-python==${HIP_PYTHON_PIP_SPEC}" --force-reinstall --no-cache
      python3 -m pip install --target=$HIP_PYTHON_PATH/hip-python -i https://test.pypi.org/simple "hip-python-as-cuda==${HIP_PYTHON_PIP_SPEC}" --force-reinstall --no-cache
      python3 -m pip config set global.extra-index-url https://test.pypi.org/simple
      python3 -m pip install --target=$HIP_PYTHON_PATH/numba-hip "numba-hip[rocm-${ROCM_VERSION}] @ git+https://github.com/ROCm/numba-hip.git" --force-reinstall --no-cache
      deactivate
      # hip-python-build venv lives under HIP_PYTHON_BUILD_DIR
      # (under /tmp) and is removed by the EXIT trap above.
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $HIP_PYTHON_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $HIP_PYTHON_PATH -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $HIP_PYTHON_PATH
      fi
   fi

   # Create a module file for hip-python
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
        whatis("HIP-Python with ROCm support")

        prereq("rocm/${ROCM_VERSION}")
        prepend_path("PYTHONPATH","$HIP_PYTHON_PATH/hip-python")
        prepend_path("PYTHONPATH","$HIP_PYTHON_PATH/numba-hip")
	setenv("NUMBA_HIP_USE_DEVICE_LIB_CACHE","0")
EOF

fi
