#!/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/LinuxPlus/rcmf90
BUILD_RCMF90=1
ROCM_VERSION=6.4.0
RCMF90_VERSION="3.14"
INSTALL_PATH=/opt/rcmf90-v${RCMF90_VERSION}
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
   echo "  --rcmf90-version [ RCMF90_VERSION ] default $RCMF90_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-rcmf90 [ BUILD_RCMF90 ] default is 0"
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
      "--build-rcmf90")
          shift
          BUILD_RCMF90=${1}
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
      "--rcmf90-version")
          shift
          RCMF90_VERSION=${1}
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
   # override path in case RCMF90_VERSION has been supplied as input
   INSTALL_PATH=/opt/rcmf90-v${RCMF90_VERSION}
fi

echo ""
echo "==================================="
echo "Starting RCMF90 Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_RCMF90: $BUILD_RCMF90"
echo "RCMF90_VERSION: $RCMF90_VERSION"
echo "Installing RCMF90 in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_RCMF90}" = "0" ]; then

   echo "RCMF90 will not be built, according to the specified value of BUILD_RCMF90"
   echo "BUILD_RCMF90: $BUILD_RCMF90"
   exit

else
   if [ -f ${CACHE_FILES}/rcm.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached RCMF90"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xpzf ${CACHE_FILES}/rcmf90.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/rcmf90.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building RCMF90"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load amdclang

      rm -rf rcm
      ${SUDO} rm -rf $INSTALL_PATH
      # path does not resolve
      git clone --depth 1 https://github.com/asimovpp/RCM-f90.git rcm-f90
      cd rcm-f90
      make

      echo "Installing RCMF90 in: $INSTALL_PATH"

      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} cp -r lib ${INSTALL_PATH}/
      ${SUDO} cp -r include ${INSTALL_PATH}/

      cd ..
      rm -rf rcm-f90

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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$RCMF90_VERSION.lua
        whatis("RCMF90 package")

        local base = "${INSTALL_PATH}"

        setenv("RCMF90", base)
        setenv("RCMF90_PATH", base)
        setenv("RCMF90_DIR", base)
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
EOF

fi
