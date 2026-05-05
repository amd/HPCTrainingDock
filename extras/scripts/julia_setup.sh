#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/LinuxPlus/julia
BUILD_JULIA=0
JULIA_VERSION="1.12"
JULIA_PARENT_DIR=/opt
JULIA_PARENT_DIR_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --parent-dir [ JULIA_PARENT_DIR ] Julia will be installed in ${JULIA_PARENT_DIR}/julia-v${JULIA_VERSION}"
   echo "  --build-julia [ BUILD_JULIA ], set to 1 to build Julia, default is 0"
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
      "--build-julia")
          shift
          BUILD_JULIA=${1}
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
      "--parent-dir")
          shift
          JULIA_PARENT_DIR_INPUT=${1}
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

if [ "${JULIA_PARENT_DIR_INPUT}" != "" ]; then
   JULIA_PARENT_DIR=${JULIA_PARENT_DIR_INPUT}
fi

echo ""
echo "==================================="
echo "Starting Julia Install with"
echo "JULIA_VERSION: $JULIA_VERSION"
echo "BUILD_JULIA: $BUILD_JULIA"
echo "JULIA_PARENT_DIR:  $JULIA_PARENT_DIR"
echo "MODULE_PATH:  $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_JULIA}" = "0" ]; then

   echo "Julia will not be built, according to the specified value of BUILD_JULIA"
   echo "BUILD_JULIA: $BUILD_JULIA"
   exit

else
   echo ""
   echo "============================"
   echo " Building Julia"
   echo "============================"
   echo ""

   # don't use sudo if user has write access to the julia parent dir
   if [ -d "${JULIA_PARENT_DIR}" ]; then
      # don't use sudo if user has write access to the julia parent dir
      if [ -w ${JULIA_PARENT_DIR} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      # if install path does not exist yet, the check on write access will fail
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod -R a+w $JULIA_PARENT_DIR
   fi

   # the julia install wants to create the directory to install so it has not exist already
   JULIA_PATH=${JULIA_PARENT_DIR}/julia-v${JULIA_VERSION}
   export JULIA_DEPOT_PATH=$JULIA_PATH
   curl -fsSL https://install.julialang.org | sh -s -- --yes --add-to-path=no -p=${JULIA_PATH}
   export PATH=$PATH:"$JULIA_PATH/bin"
   juliaup add 1.12
   juliaup default 1.12
   julia -e 'using Pkg; Pkg.add("AMDGPU")'
   ${SUDO} mv ~/.julia $JULIA_PATH
   cd ${JULIA_PATH}/.julia
   ${SUDO} mv ../* .
   cd ..
   ${SUDO} mv .julia/bin .
   ${SUDO} mv .julia/juliaupself.json .
   ${SUDO} chmod -R 755 .julia/*

   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find $JULIA_PARENT_DIR -type f -execdir chown root:root "{}" +
      ${SUDO} find $JULIA_PARENT_DIR -type d -execdir chown root:root "{}" +
   fi

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod -R go-w $JULIA_PARENT_DIR
   fi

   # Create a module file for julia
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # Provenance: capture this leaf script's git state for the modulefile
   # whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured
   # at the top of this script before any cd) so this works even after
   # the script has cd'd into a temp build dir. Self-contained: falls
   # back to "unknown" when run from a stripped-of-.git context (Docker
   # layer, release tarball, or git binary missing).
   LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
   LEAF_SCRIPT_COMMIT=unknown
   LEAF_SCRIPT_DIRTY=unknown
   _leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
   if [ -d "${_leaf_dir}" ] && command -v git >/dev/null 2>&1 \
      && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
      [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
      unset _commit
      if [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
         LEAF_SCRIPT_DIRTY=dirty
      else
         LEAF_SCRIPT_DIRTY=clean
      fi
   fi
   unset _leaf_dir

	#setenv("JULIA_DEPOT_PATH","${JULIA_PATH}")
   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${JULIA_VERSION}.lua
	whatis("Julia programming language, version ${JULIA_VERSION}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prepend_path("PATH","${JULIA_PATH}/bin")
	setenv("JULIA_PATH","${JULIA_PATH}")
	setenv("JULIA_VERSION","${JULIA_VERSION}")
	cmd1="cp -r ${JULIA_PATH}/.julia $HOME"
	execute{cmd=cmd1, modeA={"load"}}


EOF

fi

