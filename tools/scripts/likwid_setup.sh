#!/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus/likwid
BUILD_LIKWID=0
ROCM_VERSION=6.2.0
LIKWID_VERSION="5.5.1"
LIKWID_PATH=/opt/rocmplus-${ROCM_VERSION}/likwid
LIKWID_PATH_INPUT=""
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --likwid-install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-likwid: default $BUILD_LIKWID"
   echo "  --likwid-version [ LIKWID_VERSION ] default $LIKWID_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --likwid-install-path [ LIKWID_PATH_INPUT ] default $LIKWID_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--build-likwid")
          shift
          BUILD_LIKWID=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--likwid-install-path")
          shift
          LIKWID_PATH_INPUT=${1}
          reset-last
          ;;
      "--likwid-version")
          shift
          LIKWID_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
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

LIKWID_PATH=/opt/rocmplus-${ROCM_VERSION}/likwid
if [ "${LIKWID_PATH_INPUT}" != "" ]; then
   LIKWID_PATH=${LIKWID_PATH_INPUT}
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

echo ""
echo "==================================="
echo "Starting LIKWID Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_LIKWID: $BUILD_LIKWID"
echo "LIKWID_VERSION: $LIKWID_VERSION"
echo "LIKWID_PATH: $LIKWID_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_LIKWID}" = "0" ]; then

   echo "LIKWID will not be built, according to the specified value of BUILD_LIKWID"
   echo "BUILD_LIKWID: $BUILD_LIKWID"
   exit

else
   if [ -f ${CACHE_FILES}/likwid.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached LIKWID"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xpzf ${CACHE_FILES}/likwid.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/likwid.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building LIKWID"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}

      # don't use sudo if user has write access to install path
      if [ -d "$LIKWID_PATH" ]; then
         if [ -w ${LIKWID_PATH} ]; then
            SUDO=""
            echo "WARNING: not using sudo since user has write access to install path"
         else
            echo "WARNING: using install paths that require sudo"
         fi
      else
         # if install path does not exist yet
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${LIKWID_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+rwX ${LIKWID_PATH}
      fi

      # Per-job throwaway build dir; replaces a fixed `cd /tmp; rm -rf
      # likwid*` pattern that would race with -- and clobber -- any
      # other concurrent likwid build on the same node (different
      # ROCm versions, sweeps, etc.).
      LIKWID_BUILD_ROOT=$(mktemp -d -t likwid-build.XXXXXX)
      trap '[ -n "${LIKWID_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${LIKWID_BUILD_ROOT}"' EXIT
      cd "${LIKWID_BUILD_ROOT}"
      wget -q https://github.com/RRZE-HPC/likwid/archive/refs/tags/v${LIKWID_VERSION}.tar.gz
      tar -xzf v${LIKWID_VERSION}.tar.gz
      cd likwid-${LIKWID_VERSION}
      sed -i -e '/^ROCM_INTERFACE/s/false/true/' \
             -e '/^PREFIX/s!/usr/local!'"${LIKWID_PATH}"'!' \
             config.mk

      export ROCM_HOME=${ROCM_PATH}
      make -j
      ${SUDO} make install

      # trap handles cleanup of ${LIKWID_BUILD_ROOT}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${LIKWID_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${LIKWID_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${LIKWID_PATH}
      fi

      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for likwid
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${LIKWID_VERSION}.lua
	whatis("LIKWID - Lightweight performance tools")

	local base = "${LIKWID_PATH}"

	prereq("rocm/${ROCM_VERSION}")
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
EOF

fi
