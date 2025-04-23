#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/petsc
BUILD_PETSC=0
ROCM_VERSION=6.0
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/petsc
INSTALL_PATH_INPUT=""
PETSC_VERSION="3.23.0"
SUDO="sudo"
USE_SPACK=0
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
   echo "  --petsc-version [ PETSC_VERSION ] default $PETSC_VERSION"
   echo "  --use-spack [ USE_SPACK ] default $USE_SPACK"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-petsc [ BUILD_PETSC ] default is 0"
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
      "--build-petsc")
          shift
          BUILD_PETSC=${1}
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
      "--petsc-version")
          shift
          PETSC_VERSION=${1}
          reset-last
          ;;
      "--use-spack")
          shift
          USE_SPACK=${1}
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
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/petsc
fi

echo ""
echo "==================================="
echo "Starting PETSC Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_PETSC: $BUILD_PETSC"
echo "Installing PETSc in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "USE_SPACK: $USE_SPACK"
echo "Loading this module for MPI: $MPI_MODULE"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_PETSC}" = "0" ]; then

   echo "PETSC will not be built, according to the specified value of BUILD_PETSC"
   echo "BUILD_PETSC: $BUILD_PETSC"
   exit

else
   if [ -f ${CACHE_FILES}/petsc.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached PETSC"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/petsc.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/petsc.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building PETSC"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm/${ROCM_VERSION}
      module load $MPI_MODULE
      if [[ $MPI_PATH == "" ]]; then
         echo "MPI module $MPI_MODULE is not setting the MPI_PATH env variable, aborting..."
         exit 1
      fi

      cd /tmp

      # don't use sudo if user has write access to install path
      if [ -d "$INSTALL_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      PETSC_PATH=${INSTALL_PATH}/petsc
      SLEPC_PATH=${INSTALL_PATH}/slepc
      EIGEN_PATH=${INSTALL_PATH}/eigen
      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${PETSC_PATH}
      ${SUDO} mkdir -p ${SLEPC_PATH}
      ${SUDO} mkdir -p ${EIGEN_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      if [[ $USE_SPACK == 1 ]]; then

         # ------------ Installing PETSC

         git clone https://github.com/spack/spack.git

         # load spack environment
         source spack/share/spack/setup-env.sh

         # find already installed libs for spack
         spack external find

         # change spack install dir for Hypre
         sed -i 's|$spack/opt/spack|'"${PETSC_PATH}"'|g' spack/etc/spack/defaults/config.yaml

         # install petsc with spack, some variants are not specified because true by default
         spack install petsc@$PETSC_VERSION+rocm+fortran+mumps+suite-sparse amdgpu_target=$AMDGPU_GFXMODEL

         # get petsc install dir created by spack
         PETSC_PATH_ORIGINAL=$PETSC_PATH
         PETSC_PATH=`spack find -p petsc | awk '{print $2}' | grep opt`

         rm -rf spack

      else

         # petsc install
         git clone --branch v$PETSC_VERSION https://gitlab.com/petsc/petsc.git
         cd petsc
         PETSC_REPO=$PWD
         DOWNLOAD_HDF5=1
         module load hdf5
         if [[ "HDF5_PATH" != "" ]]; then
            DOWNLOAD_HDF5=0
         fi

         ./configure --with-debugging=0 --with-x=0 COPTFLAGS="-O3 -march=native -mtune=native" \
                     CXXOPTFLAGS="-O3 -march=native -mtune=native" FOPTFLAGS="-O3 -march=native -mtune=native" \
                     HIPOPTFLAGS="-O3 -march=native -mtune=native" --download-fblaslapack=1 --download-hdf5=$DOWNLOAD_HDF5 --download-metis=1 \
                     --download-parmetis=1 --with-shared-libraries=1 --download-blacs=1 --download-scalapack=1 --download-mumps=1 \
                     --download-suitesparse=1 --with-hip-arch=$AMDGPU_GFXMODEL --with-mpi=1 --with-mpi-dir=$MPI_PATH \
                     --prefix=$PETSC_PATH --with-hip=1 --with-hip-dir=$ROCM_PATH 

         ${SUDO} make PETSC_DIR=$PETSC_REPO PETSC_ARCH=arch-linux-c-opt all
         ${SUDO} make PETSC_DIR=$PETSC_REPO PETSC_ARCH=arch-linux-c-opt install

         # slepc install
         git clone --branch v$PETSC_VERSION https://gitlab.com/slepc/slepc.git
         cd slepc
         SLEPC_REPO=$PWD

         export PETSC_DIR=$PETSC_PATH

         ./configure --prefix=$SLEPC_PATH

         ${SUDO} make SLEPC_DIR=$SLEPC_REPO PETSC_DIR=$PETSC_PATH
         ${SUDO} make SLEPC_DIR=$SLEPC_REPO PETSC_DIR=$PETSC_PATH install

         # eigen install

         git clone --branch nightly https://gitlab.com/libeigen/eigen.git
         cd eigen
         mkdir build && cd build

         cmake -DCMAKE_INSTALL_PREFIX=$EIGEN_PATH -DCHOLMOD_LIBRARIES=$PETSC_PATH/lib -DCHOLMOD_INCLUDES=$PETSC_PATH/include \
               -DKLU_LIBRARIES=$PETSC_PATH/lib -DKLU_INCLUDES=$PETSC_PATH/include -DEIGEN_TEST_HIP=ON ..
         ${SUDO} make install

      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${PETSC_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${SLEPC_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${EIGEN_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
         ${SUDO} chmod go-w ${PETSC_PATH}
         ${SUDO} chmod go-w ${SLEPC_PATH}
         ${SUDO} chmod go-w ${EIGEN_PATH}
      fi

      module unload rocm/${ROCM_VERSION}
      module unload $MPI_MODULE

   fi

   # Create a module file for petsc
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$PETSC_VERSION.lua
	whatis("PETSC - solver package")

	local base = "${PETSC_PATH}"

	load("rocm/${ROCM_VERSION}")
	load("$MPI_MODULE")
	setenv("PETSC_PATH", base)
	prepend_path("PATH",pathJoin(base, "bin"))
	prepend_path("PATH","${PETSC_PATH}/bin")
	prepend_path("PATH","${SLEPC_PATH}/bin")
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH","/usr/lib")
EOF

fi
