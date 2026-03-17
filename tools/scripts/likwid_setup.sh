#!/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/ROCmPlus/likwid
BUILD_LIKWID=0
ROCM_VERSION=6.2.0
LIKWID_VERSION="5.5.1"
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/likwid
INSTALL_PATH_INPUT=""
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
   echo "  --build-likwid [ BUILD_LIKWID ] default is $BUILD_LIKWID"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --likwid-version [ LIKWID_VERSION ] default $LIKWID_VERSION"
   echo "  --install-path [ INSTALL_PATH ] default $INSTALL_PATH"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
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
      "--build-likwid")
          shift
          BUILD_LIKWID=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/likwid
fi

echo ""
echo "==================================="
echo "Starting LIKWID Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_LIKWID: $BUILD_LIKWID"
echo "LIKWID_VERSION: $LIKWID_VERSION"
echo "INSTALL_PATH: $INSTALL_PATH"
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

      module load rocm/${ROCM_VERSION}

      cd /tmp
      rm -rf likwid*
      wget -q https://github.com/RRZE-HPC/likwid/archive/refs/tags/v${LIKWID_VERSION}.tar.gz
      tar -xzf v${LIKWID_VERSION}.tar.gz
      cd likwid-${LIKWID_VERSION}
      sed -i -e '/^ROCM_INTERFACE/s/false/true/' \
             -e '/^PREFIX/s!/usr/local!'"${INSTALL_PATH}"'!' \
             config.mk

      export ROCM_HOME=${ROCM_PATH}
      make -j
      ${SUDO} make install

      cd /tmp
      rm -rf likwid* v${LIKWID_VERSION}.tar.gz

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

	local base = "${INSTALL_PATH}"

	prereq("rocm/${ROCM_VERSION}")
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
EOF

fi
