#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/LinuxPlus/fyamlc
BUILD_FYAMLC=1
ROCM_VERSION=6.4.0
FYAMLC_VERSION="0.2.6"
INSTALL_PATH=/opt/fyamlc-v${FYAMLC_VERSION}
INSTALL_PATH_INPUT=""
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [ INSTALL_PATH_INPUT ] default $INSTALL_PATH"
   echo "  --fyamlc-version [ FYAMLC_VERSION ] default $FYAMLC_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-fyamlc [ BUILD_FYAMLC ] default is 0"
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
      "--build-fyamlc")
          shift
          BUILD_FYAMLC=${1}
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
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--fyamlc-version")
          shift
          FYAMLC_VERSION=${1}
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case FYAMLC_VERSION has been supplied as input
   INSTALL_PATH=/opt/fyamlc-v${FYAMLC_VERSION}
fi

echo ""
echo "==================================="
echo "Starting FYAMLC Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_FYAMLC: $BUILD_FYAMLC"
echo "Installing FYAMLC in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Loading this module for MPI: $MPI_MODULE"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_FYAMLC}" = "0" ]; then

   echo "FYAMLC will not be built, according to the specified value of BUILD_FYAMLC"
   echo "BUILD_FYAMLC: $BUILD_FYAMLC"
   exit

else
   if [ -f ${CACHE_FILES}/fyamlc-v${FYAMLC_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached FYAMLC"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xpzf ${CACHE_FILES}/fyamlc-v${FYAMLC_VERSION}.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/fyamlc-v${FYAMLC_VERSION}.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building FYAMLC"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      wget https://github.com/Nicholaswogan/fortran-yaml-c/archive/refs/tags/v${FYAMLC_VERSION}.tar.gz -O fyamlc-v${FYAMLC_VERSION}.tar.gz
      tar -xzf fyamlc-v${FYAMLC_VERSION}.tar.gz
      cd fortran-yaml-c-${FYAMLC_VERSION}
      mkdir build && cd build
      cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH} -DBUILD_SHARED_LIBS=Yes ..
      cmake --build .

      echo "Installing FYAMLC in: $INSTALL_PATH"

      ${SUDO} mkdir -p ${INSTALL_PATH}/{include,lib}
      ${SUDO} cp -r modules ${INSTALL_PATH}
      ${SUDO} cp src/*so ${INSTALL_PATH}/lib/
      ${SUDO} cp _deps/libyaml-build/libyaml.so ${INSTALL_PATH}/lib

      cd ../..
      rm -rf fyamlc-v${FYAMLC_VERSION}.tar.gz
      rm -rf fortran-yaml-c-${FYAMLC_VERSION}

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi
   fi

   # Create a module file for fftw
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

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/$FYAMLC_VERSION.lua
        whatis("FYAMLC package")
        whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

        local base = "${INSTALL_PATH}"

        setenv("FYAMLC", base)
        setenv("FYAMLC_PATH", base)
        setenv("FYAMLC_DIR", base)
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
EOF

fi
