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
MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/hipfort_from_source
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_HIPFORT=0
ROCM_VERSION=6.2.0
HIPFORT_PATH="/opt/rocmplus-${ROCM_VERSION}/hipfort"
HIPFORT_PATH_INPUT=""
FC_COMPILER=gfortran
HIPFORT_VERSION=""    # empty -> use rocm-${ROCM_VERSION} branch (legacy default)

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hipfort-version [ HIPFORT_VERSION ] git branch/tag to clone (default: rocm-\${ROCM_VERSION})"
   echo "  --build-hipfort [ BUILD_HIPFORT ], set to 1 to build hipfort, default is $BUILD_HIPFORT"
   echo "  --fc-compiler [FC_COMPILER: gfortran|amdflang-new|cray-ftn], default is $FC_COMPILER"
   echo "  --install-path [ HIPFORT_PATH ], default is $HIPFORT_PATH"
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
      "--build-hipfort")
          shift
          BUILD_HIPFORT=${1}
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
      "--install-path")
          shift
          HIPFORT_PATH_INPUT=${1}
          reset-last
          ;;
      "--fc-compiler")
          shift
          FC_COMPILER=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--hipfort-version")
          shift
          HIPFORT_VERSION=${1}
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

if [ "${HIPFORT_PATH_INPUT}" != "" ]; then
   HIPFORT_PATH=${HIPFORT_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   HIPFORT_PATH=/opt/rocmplus-${ROCM_VERSION}/hipfort
fi

echo ""
echo "==================================="
echo "Starting Hipfort Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HIPFORT: $BUILD_HIPFORT"
echo "MODULE_PATH: $MODULE_PATH"
echo "HIPFORT_PATH: $HIPFORT_PATH"
echo "FC_COMPILER: $FC_COMPILER"
echo "==================================="
echo ""

if [ "${BUILD_HIPFORT}" = "0" ]; then

   echo "Hipfort will not be built, according to the specified value of BUILD_HIPFORT"
   echo "BUILD_HIPFORT: $BUILD_HIPFORT"
   exit

else
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

   if [ -f ${CACHE_FILES}/hipfort.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Hipfort"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/hipfort.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hipfort
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/hipfort.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building Hipfort"
      echo "============================"
      echo ""

      # don't use sudo if user has write access to install path
      if [ -w ${HIPFORT_PATH} ]; then
         SUDO=""
      fi

      if  [ "${BUILD_HIPFORT}" = "1" ]; then

         REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" )
         # Conditional dep: amdflang-new is needed only when building
         # against that compiler (added below if FC_COMPILER selects it).
         if [ "${FC_COMPILER:-}" = "amdflang-new" ]; then
            REQUIRED_MODULES+=( "amdflang-new" )
         fi
         preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

         if [ -d "$HIPFORT_PATH" ]; then
            # don't use sudo if user has write access to install path
            if [ -w ${HIPFORT_PATH} ]; then
               SUDO=""
            else
               echo "WARNING: using an install path that requires sudo"
            fi
         else
            # if install path does not exist yet, the check on write access will fail
            echo "WARNING: using sudo, make sure you have sudo privileges"
         fi

         ${SUDO} mkdir -p ${HIPFORT_PATH}

         # Per-job throwaway build dir under /tmp (or $TMPDIR if
         # Slurm set one). Replaces a clone into ${PWD}/hipfort
         # which is the shared NFS HPCTrainingDock checkout —
         # concurrent rocm-version jobs would race on that path.
         # Only `make install` writes hit NFS via -DHIPFORT_INSTALL_DIR.
         HIPFORT_BUILD_DIR=$(mktemp -d -t hipfort-build.XXXXXX)
         trap '[ -n "${HIPFORT_BUILD_DIR:-}" ] && rm -rf "${HIPFORT_BUILD_DIR}"' EXIT
         cd "${HIPFORT_BUILD_DIR}"

         HIPFORT_BRANCH="${HIPFORT_VERSION:-rocm-${ROCM_VERSION}}"
         echo "Cloning hipfort branch/tag: ${HIPFORT_BRANCH}"
         git clone --branch "${HIPFORT_BRANCH}" https://github.com/ROCm/hipfort.git
         cd hipfort

         mkdir build && cd build

         if [ "${FC_COMPILER}" = "gfortran" ]; then
            cmake -DHIPFORT_INSTALL_DIR=${HIPFORT_PATH} ..
         elif [ "${FC_COMPILER}" = "amdflang-new" ]; then
            # amdflang-new was already loaded by preflight above.
            cmake -DHIPFORT_INSTALL_DIR=${HIPFORT_PATH} -DHIPFORT_COMPILER=$FC -DHIPFORT_COMPILER_FLAGS="-ffree-form -cpp" ..
         elif [ "${FC_COMPILER}" = "cray-ftn" ]; then
            cmake -DHIPFORT_INSTALL_DIR=$HIPFORT_PATH -DHIPFORT_BUILD_TYPE=RELEASE -DHIPFORT_COMPILER=$(which ftn) -DHIPFORT_COMPILER_FLAGS="-ffree -eT" -DHIPFORT_AR=$(which ar) -DHIPFORT_RANLIB=$(which ranlib) ..
         else
            echo " ERROR: requested compiler is not currently among the available options "
            echo " Please choose one among: gfortran (default), amdflang-new, cray-ftn "
            exit 1
         fi

         # Parallel build then install. `make install` alone re-runs the
         # serial build dependency graph; splitting it lets cmake fan
         # out across cores. (S6 audit follow-up: hipfort was building
         # one Fortran source at a time, ~4 minutes wall, when nproc
         # cores were idle.)
         MAKE_JOBS=$(nproc)
         ${SUDO} make -j ${MAKE_JOBS}
         ${SUDO} make install

         # HIPFORT_BUILD_DIR (under /tmp, contains the hipfort
         # source clone) is removed by the EXIT trap above.

      fi

   fi

   # Create a module file for hipfort
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis(" hipfort module ")
	whatis(" this hipfort build has been compiled with: $FC_COMPILER. ")
	prereq("rocm/${ROCM_VERSION}")
	local fc_compiler = "${FC_COMPILER}"
	if fc_compiler == "amdflang-new" then
		load("amdflang-new")
	end
	append_path("LD_LIBRARY_PATH","${HIPFORT_PATH}/lib")
	setenv("LIBS","-L${HIPFORT_PATH}/lib -lhipfort-amdgcn.a")
	setenv("HIPFORT_PATH","${HIPFORT_PATH}")
	setenv("HIPFORT_LIB","${HIPFORT_PATH}/lib")
	setenv("HIPFORT_INC","${HIPFORT_PATH}/include/hipfort")
	prepend_path("PATH","${HIPFORT_PATH}/bin")
EOF

fi

