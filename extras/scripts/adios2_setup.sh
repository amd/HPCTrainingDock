#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/adios2
BUILD_ADIOS2=1
ROCM_VERSION=6.4.0
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/adios2-v2.10.1
INSTALL_PATH_INPUT=""
ADIOS2_VERSION="2.10.1"
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
   echo "  --adios2-version [ ADIOS2_VERSION ] default $ADIOS2_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-adios2 [ BUILD_ADIOS2 ] default is 0"
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
      "--build-adios2")
          shift
          BUILD_ADIOS2=${1}
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
      "--adios2-version")
          shift
          ADIOS2_VERSION=${1}
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
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/adios2
fi

echo ""
echo "==================================="
echo "Starting ADIOS2 Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_ADIOS2: $BUILD_ADIOS2"
echo "Installing ADIOS2 in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Loading this module for MPI: $MPI_MODULE"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_ADIOS2}" = "0" ]; then

   echo "ADIOS2 will not be built, according to the specified value of BUILD_ADIOS2"
   echo "BUILD_ADIOS2: $BUILD_ADIOS2"
   exit

else
   if [ -f ${CACHE_FILES}/adios2.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached ADIOS2"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/adios2.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/adios2.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building ADIOS2"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load amdflang-new
      module load $MPI_MODULE
      module load hdf5
      if [[ $MPI_PATH == "" ]]; then
         echo "MPI module $MPI_MODULE is not setting the MPI_PATH env variable, aborting..."
         exit 1
      fi

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      ${SUDO} rm -rf $INSTALL_PATH
      git clone --depth 1 --branch v$ADIOS2_VERSION https://github.com/ornladios/ADIOS2.git adios2
      cd adios2
      mkdir build && cd build
      cmake -DCMAKE_C_COMPILER=${CC} \
            -DCMAKE_CXX_COMPILER=${CXX} \
            -DCMAKE_Fortran_COMPILER=${FC} \
            -DADIOS2_USE_SST=OFF \
            -DADIOS2_USE_Fortran=ON \
            -DADIOS2_USE_MPI=ON \
            -DADIOS2_USE_HDF5=ON \
            -DHDF5_ROOT=$HDF5_PATH \
            -DADIOS2_USE_Python=OFF \
            -DADIOS2_USE_ZeroMQ=OFF \
            -DBUILD_SHARED_LIBS=ON \
            -DCMAKE_INSTALL_PREFIX=$INSTALL_PATH ..
      make -j 16

      echo "Installing ADIOS2 in: $INSTALL_PATH"

      ${SUDO} make install

      cd ../..
      rm -rf adios2

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi

      module unload amdflang-new
      module unload $MPI_MODULE
      module unload hdf5
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   ADIOS2_PATH=${INSTALL_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$ADIOS2_VERSION.lua
        whatis("ADIOS2 package")

        local base = "${ADIOS2_PATH}"

        load("$MPI_MODULE")
        load("hdf5")
        load("amdflang-new")
        setenv("ADIOS2_PATH", base)
        setenv("ADIOS2_DIR", base)
        prepend_path("PATH", "${ADIOS2_PATH}/bin")
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
EOF

fi
