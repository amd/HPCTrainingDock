#!/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/makedepf90
BUILD_MAKEDEPF90=1
ROCM_VERSION=6.4.0
MAKEDEPF90_VERSION="2.10.1"
INSTALL_PATH=/opt/makedepf90-v${MAKEDEPF90_VERSION}
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
   echo "  --makedepf90-version [ MAKEDEPF90_VERSION ] default $MAKEDEPF90_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-makedepf90 [ BUILD_MAKEDEPF90 ] default is 0"
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
      "--build-makedepf90")
          shift
          BUILD_MAKEDEPF90=${1}
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
      "--makedepf90-version")
          shift
          MAKEDEPF90_VERSION=${1}
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
   # override path in case MAKEDEPF90_VERSION has been supplied as input
   INSTALL_PATH=/opt/makedepf90-v${MAKEDEPF90_VERSION}
fi

echo ""
echo "==================================="
echo "Starting MAKEDEPF90 Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_MAKEDEPF90: $BUILD_MAKEDEPF90"
echo "Installing MAKEDEPF90 in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_MAKEDEPF90}" = "0" ]; then

   echo "MAKEDEPF90 will not be built, according to the specified value of BUILD_MAKEDEPF90"
   echo "BUILD_MAKEDEPF90: $BUILD_MAKEDEPF90"
   exit

else
   if [ -f ${CACHE_FILES}/makedepf90.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached MAKEDEPF90"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xpzf ${CACHE_FILES}/makedepf90.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/makedepf90.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building MAKEDEPF90"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      ${SUDO} rm -rf $INSTALL_PATH
      # path does not resolve
      #git clone https://salsa.debian.org/science-team/makedepf90.git
      tar -xzf ../sources/makedepf90-debian-latest.tar.gz
      cd makedepf90-debian-latest
      ./configure --prefix=${INSTALL_PATH}

      make

      echo "Installing MAKEDEPF90 in: $INSTALL_PATH"

      ${SUDO} mkdir -p ${INSTALL_PATH}/bin
      ${SUDO} cp makedepf90 ${INSTALL_PATH}/bin

      cd ..
      rm -rf makedepf90-debian-latest

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi
   fi

   # Create a module file for fftw
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$MAKEDEPF90_VERSION.lua
        whatis("MAKEDEPF90 package")

        local base = "${INSTALL_PATH}"

        setenv("MAKEDEPF90", base)
        setenv("MAKEDEPF90_PATH", base)
        setenv("MAKEDEPF90_DIR", base)
        prepend_path("PATH", "${INSTALL_PATH}/bin")
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
EOF

fi
