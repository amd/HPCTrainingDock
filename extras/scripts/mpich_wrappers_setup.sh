#!/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/ROCmPlus/mpich_wrappers
BUILD_MPICH_WRAPPERS=0
ROCM_AFAR_VERSION=22.3.0
CRAY_MPICH_VERSION=8.1.33
AMDGPU_GFXMODEL=gfx942
CPU_TYPE=genoa
MPICH_VERSION=4.3.0
LIBFABRIC_PATH=/opt/cray/libfabric/2.2.0rc1
INSTALL_PATH_INPUT=""
INSTALL_PATH=/shared/apps/rhel9/rocm-afar-${ROCM_AFAR_VERSION}/mpich-wrappers

SUDO="sudo"

if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --rocm-afar-version [ ROCM_AFAR_VERSION ] default $ROCM_AFAR_VERSION"
   echo "  --cray-mpich-version [ CRAY_MPICH_VERSION ] default $CRAY_MPICH_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default $AMDGPU_GFXMODEL"
   echo "  --cpu-type [ CPU_TYPE ] default $CPU_TYPE"
   echo "  --mpich-version [ MPICH_VERSION ] default $MPICH_VERSION"
   echo "  --libfabric-path [ LIBFABRIC_PATH ] default $LIBFABRIC_PATH"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ INSTALL_PATH ] default $INSTALL_PATH"
   echo "  --build-mpich-wrappers [ BUILD_MPICH_WRAPPERS ], set to 1 to build, default is 0"
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
      "--build-mpich-wrappers")
          shift
          BUILD_MPICH_WRAPPERS=${1}
          reset-last
          ;;
      "--rocm-afar-version")
          shift
          ROCM_AFAR_VERSION=${1}
          reset-last
          ;;
      "--cray-mpich-version")
          shift
          CRAY_MPICH_VERSION=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--cpu-type")
          shift
          CPU_TYPE=${1}
          reset-last
          ;;
      "--mpich-version")
          shift
          MPICH_VERSION=${1}
          reset-last
          ;;
      "--libfabric-path")
          shift
          LIBFABRIC_PATH=${1}
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
   INSTALL_PATH=/shared/apps/rhel9/rocm-afar-${ROCM_AFAR_VERSION}/mpich-wrappers
fi

if [ "${BUILD_MPICH_WRAPPERS}" = "0" ]; then

   echo "MPICH wrappers will not be built, according to the specified value of BUILD_MPICH_WRAPPERS"
   echo "BUILD_MPICH_WRAPPERS: $BUILD_MPICH_WRAPPERS"
   echo "Make sure to set '--build-mpich-wrappers 1' when running this install script"
   exit

else

   echo ""
   echo "==================================="
   echo " Installing MPICH Wrappers"
   echo " Install directory: $INSTALL_PATH"
   echo " Module directory: $MODULE_PATH"
   echo " MPICH Version: $MPICH_VERSION"
   echo " ROCm AFAR Version: $ROCM_AFAR_VERSION"
   echo " Cray MPICH Version: $CRAY_MPICH_VERSION"
   echo " AMDGPU GFX Model: $AMDGPU_GFXMODEL"
   echo " CPU Type: $CPU_TYPE"
   echo " Libfabric Path: $LIBFABRIC_PATH"
   echo "==================================="
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-afar-${ROCM_AFAR_VERSION}-${AMDGPU_GFXMODEL_STRING}

   if [ -f ${CACHE_FILES}/mpich-v${MPICH_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached MPICH Wrappers"
      echo "============================"
      echo ""

      cd /opt
      tar -xzf ${CACHE_FILES}/mpich-v${MPICH_VERSION}.tgz
      chown -R root:root ${INSTALL_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/mpich-v${MPICH_VERSION}.tgz
      fi

   else
      echo ""
      echo "==================================="
      echo " Building MPICH Wrappers from source"
      echo "==================================="
      echo ""

      module purge
      module load PrgEnv-gnu
      module load craype-x86-${CPU_TYPE}
      module load craype-accel-amd-${AMDGPU_GFXMODEL}
      module load cray-python
      module load cray-mpich/${CRAY_MPICH_VERSION}
      module load rocm-afar/${ROCM_AFAR_VERSION}

      if [ -d "$INSTALL_PATH" ]; then
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${INSTALL_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      WORK_DIR=$(mktemp -d)
      cd ${WORK_DIR}

      wget -q https://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz
      tar -xzf mpich-${MPICH_VERSION}.tar.gz
      rm mpich-${MPICH_VERSION}.tar.gz
      cd mpich-${MPICH_VERSION}

      CC=$(which amdclang) \
      CXX=$(which amdclang++) \
      FC=$(which amdflang) \
      F77=$(which amdflang) \
      ./configure \
          --prefix=${INSTALL_PATH} \
          --enable-fortran=all \
          --enable-cxx \
          --with-device=ch4:ofi \
          --with-libfabric=${LIBFABRIC_PATH} \
          > log.configure.txt 2>&1

      sed -i 's#wl=""#wl="-Wl,#g' libtool

      make VERBOSE=1 V=1 -j |& tee log.make.txt

      make VERBOSE=1 V=1 -j install |& tee log.install.txt

      cd ${WORK_DIR}/..
      rm -rf ${WORK_DIR}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi

   fi

   # Create a module file for mpich wrappers
   if [ -d "$MODULE_PATH" ]; then
      if [ ! -w ${MODULE_PATH} ]; then
         SUDO="sudo"
      else
         echo "WARNING: not using sudo since user has write access to module path"
      fi
   else
      SUDO="sudo"
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${MPICH_VERSION}
	#%Module1.0

	## Base directory
	set base ${INSTALL_PATH}

	setenv MPICH_WRAPPERS_DIR \$base

	module unload PrgEnv-cray
	module unload rocm
	module load PrgEnv-gnu
	module load craype-x86-${CPU_TYPE}
	module load craype-accel-amd-${AMDGPU_GFXMODEL}
	module load cray-python
	module load cray-mpich/${CRAY_MPICH_VERSION}
	module load rocm-afar/${ROCM_AFAR_VERSION}

	## Paths
	prepend-path LD_LIBRARY_PATH \$base/lib
	prepend-path C_INCLUDE_PATH \$base/include
	prepend-path CPLUS_INCLUDE_PATH \$base/include
	prepend-path PATH \$base/bin
EOF

fi
