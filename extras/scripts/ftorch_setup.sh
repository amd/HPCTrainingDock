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
BUILD_FTORCH=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/ftorch
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
FTORCH_PATH=/opt/rocmplus-${ROCM_VERSION}/ftorch
FTORCH_PATH_INPUT=""
PYTORCH_MODULE=pytorch
FTORCH_VERSION=""    # empty -> default branch (main); else passed to git checkout after clone
# --replace 1: rm -rf prior install dir + dev.lua before build.
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
   echo "  --build-ftorch [ BUILD_FTORCH ] default $BUILD_FTORCH "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --pytorch-module [ PYTORCH_MODULE ] default $PYTORCH_MODULE"
   echo "  --install-path [ FTORCH_PATH ] default $FTORCH_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --ftorch-version [ FTORCH_VERSION ] git tag/branch/commit to check out after clone (default: repo HEAD)"
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
      "--build-ftorch")
          shift
          BUILD_FTORCH=${1}
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
          FTORCH_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--pytorch-module")
          shift
          PYTORCH_MODULE=${1}
	  reset-last
          ;;
      "--ftorch-version")
          shift
          FTORCH_VERSION=${1}
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

if [ "${FTORCH_PATH_INPUT}" != "" ]; then
   FTORCH_PATH=${FTORCH_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   FTORCH_PATH=/opt/rocmplus-${ROCM_VERSION}/ftorch
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is dev.lua (no version baked in).
# ── BUILD_FTORCH=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_FTORCH}" = "0" ]; then
   echo "[ftorch BUILD_FTORCH=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[ftorch --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${FTORCH_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/dev.lua"
   ${SUDO} rm -rf "${FTORCH_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/dev.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${FTORCH_PATH}" ]; then
   echo ""
   echo "[ftorch existence-check] ${FTORCH_PATH} already installed; skipping."
   echo "                         pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (FTORCH_BUILD_ROOT, set
# under BUILD_FTORCH=1) PLUS fail-cleanup of partial install +
# modulefile. Replaces inline `trap '... rm FTORCH_BUILD_ROOT ...' EXIT`.
_ftorch_on_exit() {
   local rc=$?
   [ -n "${FTORCH_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${FTORCH_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[ftorch fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${FTORCH_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/dev.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[ftorch fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _ftorch_on_exit EXIT

echo ""
echo "==================================="
echo "Starting FTorch Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_FTORCH: $BUILD_FTORCH"
echo "FTORCH_PATH: $FTORCH_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_FTORCH}" = "0" ]; then

   echo "FTorch will not be built, according to the specified value of BUILD_FTORCH"
   echo "BUILD_FTORCH: $BUILD_FTORCH"
   exit

else
   # Per-job throwaway build dir; replaces a fixed `cd /tmp` (with a
   # later `rm -rf FTorch`) that would race with any other concurrent
   # ftorch build on the same node.
   FTORCH_BUILD_ROOT=$(mktemp -d -t ftorch-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into _ftorch_on_exit
   # installed above (so the same EXIT handler also does fail-cleanup
   # of any partial install / modulefile).
   cd "${FTORCH_BUILD_ROOT}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/ftorch.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached FTorch"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/ftorch
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/ftorch.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/ftorch.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building FTorch"
      echo "============================"
      echo ""

      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" "${PYTORCH_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      if [ -d "$FTORCH_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${FTORCH_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $FTORCH_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $FTORCH_PATH
      fi

      git clone https://github.com/Cambridge-ICCS/FTorch.git
      if [ -n "${FTORCH_VERSION}" ]; then
         echo "Checking out FTorch ref: ${FTORCH_VERSION}"
         (cd FTorch && git checkout "${FTORCH_VERSION}")
      fi
      cd FTorch

      mkdir build && cd build

      # PyTorch bundles its own cmake/ctest/cpack/etc. under
      # ${PYTORCH_PATH}/bin whose shebangs point at the build venv
      # (#!/home/admin/pytorch_build/bin/python3). That venv is deleted
      # at the end of pytorch_setup.sh, so execve returns ENOENT on
      # the interpreter ("bad interpreter" -> exit 126). The pytorch
      # module load above prepends ${PYTORCH_PATH}/bin to PATH, so a
      # bare `cmake` would resolve to that broken script. Resolve a
      # system cmake explicitly by stripping any pytorch bin dir from
      # PATH for this lookup. Tracks audit_2026_05_01.md Issue 5; the
      # root cause is the unconditional shebang rewrite that should be
      # applied in pytorch_setup.sh (deferred fix).
      #
      # 8063 audit: the prior regex `/pytorch/.*/bin$` required at
      # least one path component between `/pytorch/` and `/bin`, but
      # pytorch_setup.sh installs to ${ROCMPLUS}/pytorch-v${VERSION}/
      # pytorch/bin (no intermediate component) so the regex never
      # matched and the broken cmake stayed first on PATH. Switch to
      # filtering by the install-root naming convention `pytorch-v`
      # (set in pytorch_setup.sh:61, INSTALL_PATH=...pytorch-v${VER})
      # which uniquely identifies our install across versions and
      # cannot be defeated by adding/removing intermediate path
      # components in a future module layout. (Option B from the
      # 8063 audit; PYTORCH_PATH isn't exported by the pytorch
      # modulefile so we can't filter by absolute path here.)
      CMAKE_BIN=$(PATH=$(echo "$PATH" | tr ':' '\n' | grep -v '/pytorch-v[^/]*/' | paste -sd:) command -v cmake)
      if [ ! -x "${CMAKE_BIN}" ]; then
         CMAKE_BIN=/usr/bin/cmake
      fi
      echo "ftorch: using cmake at ${CMAKE_BIN} (head -1: $(head -1 "${CMAKE_BIN}" 2>/dev/null))"

      "${CMAKE_BIN}" -DCMAKE_INSTALL_PREFIX=$FTORCH_PATH  -DGPU_DEVICE=HIP ..
      make -j
      ${SUDO} make install

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $FTORCH_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $FTORCH_PATH -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $FTORCH_PATH
      fi

      # cleanup: trap handles ${FTORCH_BUILD_ROOT}/FTorch
      cd /
      module unload rocm/${ROCM_VERSION}
      module unload ${PYTORCH_MODULE}
   fi

   # Create a module file for cupy
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/dev.lua
	whatis("FTorch: a library for directly calling PyTorch ML models from Fortran")

	prereq("rocm/${ROCM_VERSION}")
	load("${PYTORCH_MODULE}")
	prepend_path("LD_LIBRARY_PATH", pathJoin("${FTORCH_PATH}", "lib"))
	setenv("FTORCH_HOME","${FTORCH_PATH}")
	setenv("FTorch_DIR","${FTORCH_PATH}")

EOF

fi
