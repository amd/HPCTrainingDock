#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/rcm
BUILD_RCM=1
ROCM_VERSION=6.4.0
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/rcm-v3.14
INSTALL_PATH_INPUT=""
RCM_VERSION="3.14"
SUDO="sudo"
MPI_MODULE="openmpi"
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
   echo "  WARNING: when selecting the module to supply to --mpi-module, make sure it sets the MPI_PATH environment variable"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [ INSTALL_PATH_INPUT ] default $INSTALL_PATH"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --rcm-version [ RCM_VERSION ] default $RCM_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-rcm [ BUILD_RCM ] default is 0"
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
      "--build-rcm")
          shift
          BUILD_RCM=${1}
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
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--rcm-version")
          shift
          RCM_VERSION=${1}
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
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/rcm
fi

echo ""
echo "==================================="
echo "Starting RCM Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_RCM: $BUILD_RCM"
echo "Installing RCM in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Loading this module for MPI: $MPI_MODULE"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_RCM}" = "0" ]; then

   echo "RCM will not be built, according to the specified value of BUILD_RCM"
   echo "BUILD_RCM: $BUILD_RCM"
   exit

else
   if [ -f ${CACHE_FILES}/rcm.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached RCM"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/rcm.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/rcm.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building RCM"
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

      echo "Installing RCM in: $INSTALL_PATH"

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

   ${SUDO} mkdir -p ${MODULE_PATH}

   RCM_PATH=${INSTALL_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$RCM_VERSION.lua
        whatis("RCM package")

        local base = "${RCM_PATH}"

        setenv("RCM_PATH", base)
        setenv("RCM_DIR", base)
        prepend_path("PATH", "${RCM_PATH}/bin")
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
EOF

fi
