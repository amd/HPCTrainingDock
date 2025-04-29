#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/fyamlc
BUILD_FYAMLC=1
ROCM_VERSION=6.4.0
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/fyamlc-v0.2.6
INSTALL_PATH_INPUT=""
FYAMLC_VERSION="0.2.6"
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
   # override path in case ROCM_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/fyamlc-v${FYAMLC_VERSION}
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
      cd /opt/rocmplus-${ROCM_VERSION}
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
      rm -rf fyaml-v${FYAMLC_VERSION}.tar.gz
      rm -rf fortran-yaml-c-${FYAMLC_VERSION}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   FYAMLC_PATH=${INSTALL_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$FYAMLC_VERSION.lua
        whatis("FYAMLC package")

        local base = "${FYAMLC_PATH}"

        setenv("FYAMLC", base)
        setenv("FYAMLC_PATH", base)
        setenv("FYAMLC_DIR", base)
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
EOF

fi
