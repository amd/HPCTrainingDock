#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/parhip
BUILD_PARHIP=1
ROCM_VERSION=6.4.0
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/parhip-v3.14
INSTALL_PATH_INPUT=""
PARHIP_VERSION="3.14"
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
   echo "  --parhip-version [ PARHIP_VERSION ] default $PARHIP_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-parhip [ BUILD_PARHIP ] default is 0"
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
      "--build-parhip")
          shift
          BUILD_PARHIP=${1}
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
      "--parhip-version")
          shift
          PARHIP_VERSION=${1}
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
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/parhip
fi

echo ""
echo "==================================="
echo "Starting PARHIP Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_PARHIP: $BUILD_PARHIP"
echo "Installing PARHIP in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Loading this module for MPI: $MPI_MODULE"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_PARHIP}" = "0" ]; then

   echo "PARHIP will not be built, according to the specified value of BUILD_PARHIP"
   echo "BUILD_PARHIP: $BUILD_PARHIP"
   exit

else
   if [ -f ${CACHE_FILES}/parhip.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached PARHIP"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/parhip.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/parhip.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building PARHIP"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load amdclang

      rm -rf parhip
      ${SUDO} rm -rf $INSTALL_PATH
      # path does not resolve
      git clone --depth 1 --branch v${PARHIP_VERSION} https://github.com/KaHIP/KaHIP.git parhip
      cd parhip
      mkdir build && cd build
      CC=${CC} cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$INSTALL_PATH ..
      make -j 16

      echo "Installing PARHIP in: $INSTALL_PATH"

      ${SUDO} make install

      cd ../..
      rm -rf parhip

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   PARHIP_PATH=${INSTALL_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$PARHIP_VERSION.lua
        whatis("PARHIP package")

        local base = "${PARHIP_PATH}"

        setenv("PARHIP_PATH", base)
        setenv("PARHIP_DIR", base)
        prepend_path("PATH", "${PARHIP_PATH}/bin")
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
EOF

fi
