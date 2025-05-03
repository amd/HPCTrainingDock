#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/pyyaml_lit
BUILD_PYYAML_LIT=1
ROCM_VERSION=6.4.0
PYYAML_LIT_VERSION="3.14"
INSTALL_PATH=/opt/pyyaml_lit-v${PYYAML_LIT_VERSION}
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
   echo "  --pyyaml-lit-version [ PYYAML_LIT_VERSION ] default $PYYAML_LIT_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-pyyaml_lit [ BUILD_PYYAML_LIT ] default is 0"
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
      "--build-pyyaml_lit")
          shift
          BUILD_PYYAML_LIT=${1}
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
      "--pyyaml-lit-version")
          shift
          PYYAML_LIT_VERSION=${1}
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
   # override path in case PYYAML_LIT_VERSION has been supplied as input
   INSTALL_PATH=/opt/pyyaml_lit-v${PYYAML_LIT_VERSION}
fi

echo ""
echo "==================================="
echo "Starting PYYAML_LIT Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_PYYAML_LIT: $BUILD_PYYAML_LIT"
echo "Installing PYYAML_LIT in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "PYYAML_LIT_VERSION: $PYYAML_LIT_VERSION"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_PYYAML_LIT}" = "0" ]; then

   echo "PYYAML_LIT will not be built, according to the specified value of BUILD_PYYAML_LIT"
   echo "BUILD_PYYAML_LIT: $BUILD_PYYAML_LIT"
   exit

else
   if [ -f ${CACHE_FILES}/pyyaml_lit.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached PYYAML_LIT"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xpzf ${CACHE_FILES}/pyyaml_lit.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/pyyaml_lit.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building PYYAML_LIT"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      pip3 install pyyaml lit --target=${INSTALL_PATH}

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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${PYYAML_LIT_VERSION}.lua
        whatis("PYYAML_LIT package")

        setenv("PYTHONUSERBASE", "${INSTALL_PATH}")
        append_path("PATH", "${INSTALL_PATH}/bin")
        prepend_path("PYTHONPATH", "${INSTALL_PATH}")
EOF

fi
