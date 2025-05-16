#!/bin/bash

# This script installs OpenMPI along with the XPEM, UCX and UCC libraries. The simplest use case is:
#   ./openmpi_setup.sh --rocm-version <ROCM_VERSION>
# Most of the needed information for the install is autodetected. Others are set to the latest
# available versions. Cross-compiling for a different GPU model can be done by specifying
# the --amdgpu-gfxmodel <AMDGPU-GFXMODEL> option
#

# Variables controlling setup process
ROCM_VERSION=
ROCM_PATH=
REPLACE=0
REPLACE_XPMEM=0
REPLACE_UCX=0
REPLACE_UCC=0
REPLACE_OPENMPI=0
DRY_RUN=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/openmpi
INSTALL_PATH_INPUT=""
XPMEM_PATH_INPUT=""
BUILD_XPMEM="1"
UCX_PATH_INPUT=""
UCC_PATH_INPUT=""
OPENMPI_PATH_INPUT=""
USE_CACHE_BUILD=1
UCX_VERSION=1.18.1
UCX_MD5CHECKSUM=32c295d04994e305fb9db7331597bd05
UCC_VERSION=1.4.4
UCC_MD5CHECKSUM=1e45e0dac6765cdabd4fbcf55fc48563
XPMEM_VERSION=2.7.4
#XPMEM_MD5CHECKSUM=a161703b2f4740edbf6b9049a16ccb94
OPENMPI_VERSION=5.0.7
OPENMPI_MD5CHECKSUM=0529027472015810e5f0d749136ca0a3
C_COMPILER=gcc
CXX_COMPILER=g++
FC_COMPILER=gfortran

# Autodetect defaults
AMDGPU_GFXMODEL=
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

usage()
{
    echo "Usage:"
    echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
    echo "  --build-xpmem [ BUILD_XPMEM ] default 1-yes"
    echo "  --c-compiler [ CC ] default $C_COMPILER"
    echo "  --cxx-compiler [ CXX ] default $CXX_COMPILER"
    echo "  --dry-run default off"
    echo "  --fc-compiler [ FC ] default $FC_COMPILER"
    echo "  --install-path [ INSTALL_PATH ] default /opt/rocmplus-$ROCM_VERSION/openmpi (ucx, and ucc)"
    echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
    echo "  --openmpi-path [OPENMPI_PATH] default $INSTALL_PATH/openmpi-$OPENMPI_VERSION-ucc-$UCC_VERSION-ucx-$UCX_VERSION-xpmem-$XPMEM_VERSION"
    echo "  --openmpi-version [VERSION] default $OPENMPI_VERSION"
    echo "  --openmpi-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "  --replace default off"
    echo "  --replace-xpmem default off"
    echo "  --replace-ucx default off"
    echo "  --replace-ucc default off"
    echo "  --replace-openmpi default off"
    echo "  --rocm-version [ ROCM_VERSION ] default none"
    echo "  --rocm-path [ ROCM_PATH ] default none"
    echo "  --ucc-path default $INSTALL_PATH/ucc-$UCC_VERSION-ucx-$UCX_VERSION-xpmem-$XPMEM_VERSION"
    echo "  --ucc-version [VERSION] default $UCC_VERSION"
    echo "  --ucc-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "  --ucx-path default $INSTALL_PATH/ucx-$UCX_VERSION-xpmem-$XPMEM_VERSION"
    echo "  --ucx-version [VERSION] default $UCX_VERSION"
    echo "  --ucx-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "  --xpmem-path default ${INSTALL_PATH}/xpmem-${XPMEM_VERSION}"
    echo "  --xpmem-version [VERSION] default $UCX_VERSION"
    echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--build-xpmem")
          shift
          BUILD_XPMEM=${1}
          reset-last
          ;;
      "--c-compiler")
          shift
          C_COMPILER=${1}
          reset-last
          ;;
      "--cxx-compiler")
          shift
          CXX_COMPILER=${1}
          reset-last
          ;;
      "--dry-run")
          DRY_RUN=1
          reset-last
          ;;
      "--fc-compiler")
          shift
          FC_COMPILER=${1}
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
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--openmpi-path")
          shift
          OPENMPI_PATH_INPUT=${1}
          reset-last
          ;;
      "--openmpi-version")
          shift
          OPENMPI_VERSION=${1}
          reset-last
          ;;
      "--openmpi-md5checksum")
          shift
          OPENMPI_MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             OPENMPI_MD5CHECKSUM="skip"
          fi
          reset-last
          ;;
      "--replace")
          REPLACE=1
          reset-last
          ;;
      "--replace-xpmen")
          REPLACE_XPMEM=1
          reset-last
          ;;
      "--replace-ucc")
          REPLACE_UCC=1
          reset-last
          ;;
      "--replace-ucx")
          REPLACE_UCX=1
          reset-last
          ;;
      "--replace-openmpi")
          REPLACE_OPENMPI=1
          reset-last
          ;;
      "--rocm-path")
          shift
          ROCM_PATH=${1}
	  ROCM_VERSION=`cat ${ROCM_PATH}/.info/version | cut -f1 -d'-' `
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--ucc-path")
          shift
          UCC_PATH_INPUT=${1}
          reset-last
          ;;
      "--ucc-version")
          shift
          UCC_VERSION=${1}
          reset-last
          ;;
      "--ucc-md5checksum")
          shift
          UCC_MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             UCC_MD5CHECKSUM="skip"
          fi
          reset-last
          ;;
      "--ucx-path")
          shift
          UCX_PATH_INPUT=${1}
          reset-last
          ;;
      "--ucx-version")
          shift
          UCX_VERSION=${1}
          reset-last
          ;;
      "--ucx-md5checksum")
          shift
          UCX_MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             UCX_MD5CHECKSUM="skip"
          fi
          reset-last
          ;;
      "--xpmem-path")
          shift
          XPMEM_PATH_INPUT=${1}
          reset-last
          ;;
      "--xpmem-version")
          shift
          XPMEM_VERSION=${1}
          reset-last
          ;;
      "--xpmem-md5checksum")
          shift
          XPMEM_MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             XPMEM_MD5CHECKSUM="skip"
          fi
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

# Load the ROCm version for this build
source /etc/profile.d/lmod.sh
source /etc/profile.d/z01_lmod.sh
module load rocm/${ROCM_VERSION}

echo ""
echo "============================"
echo " Installing OpenMPI with:"
echo "   ROCM_VERSION: $ROCM_VERSION"
echo "   ROCM_PATH: ${ROCM_PATH}"
echo "============================"
echo ""

IS_DOCKER=0
if [ -f "/run/systemd/container" ]; then
  IS_DOCKER=`grep -E '^docker$' /run/systemd/container |wc -l`
fi
if [ "${IS_DOCKER}" == "1" ]; then
   BUILD_XPMEM=0
fi

if [ "${BUILD_XPMEM}" == "1" ]; then
   XPMEM_STRING=-xpmem-${XPMEM_VERSION}
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}
fi

if [ "${XPMEM_PATH_INPUT}" != "" ]; then
   XPMEM_PATH="${XPMEM_PATH_INPUT}"
else
   XPMEM_PATH="${INSTALL_PATH}"/xpmem-${XPMEM_VERSION}
fi

if [ "${UCX_PATH_INPUT}" != "" ]; then
   UCX_PATH="${UCX_PATH_INPUT}"
else
   UCX_PATH="${INSTALL_PATH}"/ucx-${UCX_VERSION}${XPMEM_STRING}
fi

if [ "${UCC_PATH_INPUT}" != "" ]; then
   UCC_PATH="${UCC_PATH_INPUT}"
else
   UCC_PATH="${INSTALL_PATH}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}
fi

if [ "${OPENMPI_PATH_INPUT}" != "" ]; then
   OPENMPI_PATH="${OPENMPI_PATH_INPUT}"
else
   OPENMPI_PATH="${INSTALL_PATH}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}
fi

if [ "${REPLACE}" == "1" ]; then
   REPLACE_XPMEM=1
   REPLACE_UCX=1
   REPLACE_UCC=1
   REPLACE_OPENMPI=1
fi

if [ -d "$INSTALL_PATH" ]; then
   # don't use sudo if user has write access to install path
   if [ -w ${INSTALL_PATH} ]; then
      SUDO=""
      echo "WARNING: not using sudo since user has write privileges to install path, some dependencies may fail to get installed"
   else
      echo "WARNING: using an install path that requires sudo"
   fi
else
   # if install path does not exist yet, the check on write access will fail
   echo "WARNING: using sudo, make sure you have sudo privileges"
fi

if [ "${DISTRO}" = "ubuntu" ]; then
   echo "Install of libpmix-dev libhwloc-dev libevent-dev libfuse3-dev librdmacm-dev libtcmalloc-minimal4 doxygen packages"
   if [[ "${DRY_RUN}" == "0" ]]; then
      # these are for openmpi :  libpmix-dev  libhwloc-dev  libevent-dev
      ${SUDO} apt-get update
      ${SUDO} ${DEB_FRONTEND} apt-get install -y libpmix-dev libhwloc-dev libevent-dev \
         libfuse3-dev librdmacm-dev libtcmalloc-minimal4 doxygen
      if [ "${IS_DOCKER}" != "1" ]; then
         ${SUDO} ${DEB_FRONTEND} apt-get install -y linux-headers-$(uname -r)
      fi
   fi
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   echo "Install of pmix and hwloc packages"
   if [[ "${DRY_RUN}" == "0" ]]; then
      # these are for openmpi :  libpmix-dev  libhwloc-dev  libevent-dev
      ${SUDO} yum update
      ${SUDO} yum install -y pmix hwloc
   fi
else
   echo "DISTRO version ${DISTRO} not recognized or supported"
   exit
fi

if [[ "${DRY_RUN}" == "0" ]] && [[ ! -d ${INSTALL_PATH} ]] ; then
   ${SUDO} mkdir -p "${INSTALL_PATH}"
fi
cd "${INSTALL_PATH}"

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

#
# Install XPMEM
#

if [ "${BUILD_XPMEM}" == "1" ]; then
   if [[ -d "${XPMEM_PATH}" ]] && [[ "${REPLACE_XPMEM}" == "0" ]] ; then
      echo "There is a previous installation and the replace flag is false"
      echo "  use --replace to request replacing the current installation"
   else
      if [[ -d "${XPMEM_PATH}" ]] && [[ "${REPLACE_XPMEM}" != "0" ]] ; then
         ${SUDO} rm -rf "${XPMEM_PATH}"
      fi
      if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f ${CACHE_FILES}/xpmem-${XPMEM_VERSION}.tgz ]]; then
         echo ""
         echo "============================"
         echo " Installing Cached XPMEM"
         echo "============================"
         echo ""

         #install the cached version
         echo "cached file is ${CACHE_FILES}/xpmem-${XPMEM_VERSION}.tgz"
         ${SUDO} mkdir -p ${XPMEM_PATH}
         cd ${INSTALL_PATH}
         ${SUDO} tar -xzpf ${CACHE_FILES}/xpmem-${XPMEM_VERSION}.tgz
         if [ "${USER}" != "root" ]; then
            ${SUDO} find ${XPMEM_PATH} -type f -execdir chown root:root "{}" +
            ${SUDO} find ${XPMEM_PATH} -type d -execdir chown root:root "{}" +
         fi
         if [ "${USER}" != "sysadmin" ]; then
            ${SUDO} rm "${CACHE_FILES}"/xpmem-${XPMEM_VERSION}.tgz
         fi
      else

         echo ""
         echo "============================"
         echo " Building XPMEM"
         echo "============================"
         echo ""

         cd /tmp

         XPMEM_DOWNLOAD_URL=https://github.com/openucx/xpmem/archive/refs/tags/v${XPMEM_VERSION}.tar.gz
         count=0
         while [ "$count" -lt 3 ]; do
            wget -q --continue --tries=10 ${XPMEM_DOWNLOAD_URL} && break
            count=$((count+1))
         done
         if [ ! -f v${XPMEM_VERSION}.tar.gz ]; then
            echo "Failed to download v${XPMEM_VERSION}.tar.gz package from: "
            echo "    ${XPMEM_DOWNLOAD_URL} ... exiting"
            exit 1
         else
            MD5SUM_XPMEM=`md5sum v${XPMEM_VERSION}.tar.gz | cut -f1 -d' ' `
            if [[ "${XPMEM_MD5CHECKSUM}" =~ "skip" ]]; then
               echo "MD5SUM is ${MD5SUM_XPMEM}, no check requested"
            elif [[ "${MD5SUM_XPMEM}" == "${XPMEM_MD5CHECKSUM}" ]]; then
               echo "MD5SUM is verified: actual ${MD5SUM_XPMEM}, expecting ${XPMEM_MD5CHECKSUM}"
            else
               echo "Error: Wrong MD5Sum for v${XPMEM_VERSION}.tar.gz:"
               echo "MD5SUM is ${MD5SUM_XPMEM}, expecting ${XPMEM_MD5CHECKSUM}"
               exit 1
            fi
         fi
         tar xzf v${XPMEM_VERSION}.tar.gz
         cd xpmem-${XPMEM_VERSION}

         ./autogen.sh
         ./configure --prefix=${XPMEM_PATH}

         make -j 16
         if [[ "${DRY_RUN}" == "0" ]]; then
            ${SUDO} make install
         fi

         cd ../..
         rm -rf xpmem-${XPMEM_VERSION} v${XPMEM_VERSION}.tar.gz
      fi

      if [[ ! -d ${XPMEM_PATH}/lib ]] ; then
         echo "XPMEM (OpenMPI) installation failed -- missing installation directories"
         echo " XPMEM Installation path is ${XPMEM_PATH}"
         ls -l "${XPMEM_PATH}"
         exit 1
      fi
   fi
fi

#
# Install UCX
#

if [[ -d "${UCX_PATH}" ]] && [[ "${REPLACE_UCX}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${UCX_PATH}" ]] && [[ "${REPLACE_UCX}" != "0" ]] ; then
      ${SUDO} rm -rf "${UCX_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f ${CACHE_FILES}/ucx-${UCX_VERSION}${XPMEM_STRING}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached UCX"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${CACHE_FILES}/ucx-${UCX_VERSION}${XPMEM_STRING}.tgz"
      ${SUDO} mkdir -p ${UCX_PATH}
      cd ${INSTALL_PATH}
      ${SUDO} tar -xzpf ${CACHE_FILES}/ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      if [ "${USER}" != "root" ]; then
         ${SUDO} find ${UCX_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${UCX_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm "${CACHE_FILES}"/ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      fi
   else

      echo ""
      echo "============================"
      echo " Building UCX"
      echo "============================"
      echo ""

      cd /tmp

      UCX_DOWNLOAD_URL=https://github.com/openucx/ucx/releases/download/v${UCX_VERSION}/ucx-${UCX_VERSION}.tar.gz
      count=0
      while [ "$count" -lt 3 ]; do
         wget -q --continue --tries=10 ${UCX_DOWNLOAD_URL} && break
         count=$((count+1))
      done
      if [ ! -f ucx-${UCX_VERSION}.tar.gz ]; then
         echo "Failed to download ucx-${UCX_VERSION}.tar.gz package from: "
         echo "    ${UCX_DOWNLOAD_URL} ... exiting"
         exit 1
      else
         MD5SUM_UCX=`md5sum ucx-${UCX_VERSION}.tar.gz | cut -f1 -d' ' `
         if [[ "${UCX_MD5CHECKSUM}" =~ "skip" ]]; then
            echo "MD5SUM is ${MD5SUM_UCX}, no check requested"
         elif [[ "${MD5SUM_UCX}" == "${UCX_MD5CHECKSUM}" ]]; then
            echo "MD5SUM is verified: actual ${MD5SUM_UCX}, expecting ${UCX_MD5CHECKSUM}"
         else
            echo "Error: Wrong MD5Sum for ucx-${UCX_VERSION}.tar.gz:"
            echo "MD5SUM is ${MD5SUM_UCX}, expecting ${UCX_MD5CHECKSUM}"
            exit 1
         fi
      fi
      tar xzf ucx-${UCX_VERSION}.tar.gz
      cd ucx-${UCX_VERSION}
      mkdir build && cd build

if [ "${BUILD_XPMEM}" == "1" ]; then
      UCX_CONFIGURE_COMMAND="../contrib/configure-release \
         --prefix=${UCX_PATH} \
         --with-rocm=${ROCM_PATH} \
         --with-xpmem=${XPMEM_PATH} \
         --without-cuda \
         --enable-mt \
         --enable-optimizations \
         --disable-logging \
         --disable-debug \
         --enable-assertions \
         --enable-params-check \
         --enable-examples"
else
      UCX_CONFIGURE_COMMAND="../contrib/configure-release \
         --prefix=${UCX_PATH} \
         --with-rocm=${ROCM_PATH} \
         --without-cuda \
         --enable-mt \
         --enable-optimizations \
         --disable-logging \
         --disable-debug \
         --enable-assertions \
         --enable-params-check \
         --enable-examples"
fi

      echo ""
      echo "UCX_CONFIGURE_COMMAND: "
      echo "${UCX_CONFIGURE_COMMAND}" | sed 's/\s\+/ \\\n   /g'
      echo ""

      ${UCX_CONFIGURE_COMMAND}

      make -j 16
      if [[ "${DRY_RUN}" == "0" ]]; then
         ${SUDO} make install
      fi

      cd ../..
      rm -rf ucx-${UCX_VERSION} ucx-${UCX_VERSION}.tar.gz
   fi

   if [[ ! -d ${UCX_PATH}/lib ]] ; then
      echo "UCX (OpenMPI) installation failed -- missing installation directories"
      echo " UCX Installation path is ${UCX_PATH}"
      ls -l "${UCX_PATH}"
      exit 1
   fi
fi

#
# Install UCC
#

if [[ -d "${UCC_PATH}" ]] && [[ "${REPLACE_UCC}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${UCC_PATH}" ]] && [[ "${REPLACE_UCC}" != "0" ]] ; then
      ${SUDO} rm -rf "${UCC_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f "${CACHE_FILES}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached UCC"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${CACHE_FILES}/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz"
      ${SUDO} mkdir -p ${UCC_PATH}
      cd "${INSTALL_PATH}"
      ${SUDO} tar -xzpf "${CACHE_FILES}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      if [ "${USER}" != "root" ]; then
         ${SUDO} find ${UCC_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${UCC_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm "${CACHE_FILES}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      fi
   else

      echo ""
      echo "============================"
      echo " Building UCC"
      echo "============================"
      echo ""

      count=0
      while [ "$count" -lt 3 ]; do
         wget -q --continue --tries=10 https://github.com/openucx/ucc/archive/refs/tags/v${UCC_VERSION}.tar.gz && break
         count=$((count+1))
      done
      if [ ! -f v${UCC_VERSION}.tar.gz ]; then
         echo "Failed to download ucc v${UCC_VERSION}.tar.gz package ... exiting"
         exit 1
      else
         MD5SUM_UCC=`md5sum v${UCC_VERSION}.tar.gz | cut -f1 -d' ' `
         if [[ "${UCC_MD5CHECKSUM}" =~ "skip" ]]; then
            echo "MD5SUM is ${MD5SUM_UCC}, no check requested"
         elif [[ "${MD5SUM_UCC}" == "${UCC_MD5CHECKSUM}" ]]; then
            echo "MD5SUM is verified: actual ${MD5SUM_UCC}, expecting ${UCC_MD5CHECKSUM}"
         else
            echo "Error: Wrong MD5Sum for v${UCC_VERSION}.tar.gz:"
            echo "MD5SUM is ${MD5SUM_UCC}, expecting ${UCC_MD5CHECKSUM}"
            exit 1
         fi
      fi
      tar xzf v${UCC_VERSION}.tar.gz
      cd ucc-${UCC_VERSION}

      export AMDGPU_GFXMODEL_UCC=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/ --offload-arch=/g'`
      AMDGPU_GFXMODEL_UCC="--offload-arch=${AMDGPU_GFXMODEL_UCC}"

      sed -i '31i cmd="${@:3:2} -x hip -target x86_64-unknown-linux-gnu "${AMDGPU_GFXMODEL_UCC}" ${@:5} -fPIC -O3 -o ${pic_filepath}"' cuda_lt.sh
      sed -i '32d' cuda_lt.sh
      sed -i '41i cmd="${@:3:2} -x hip -target x86_64-unknown-linux-gnu "${AMDGPU_GFXMODEL_UCC}" ${@:5} -O3 -o ${npic_filepath}"' cuda_lt.sh
      sed -i '42d' cuda_lt.sh

      ./autogen.sh

      UCC_CONFIGURE_COMMAND="./configure \
        --prefix=${UCC_PATH} \
        --with-rocm=${ROCM_PATH} \
        --with-ucx=${UCX_PATH}"

      echo ""
      echo "UCC_CONFIGURE_COMMAND: "
      echo "${UCC_CONFIGURE_COMMAND}" | sed 's/\s\+/ \\\n   /g'
      echo ""

      ${UCC_CONFIGURE_COMMAND}

      make -j 16

      if [[ "${DRY_RUN}" == "0" ]]; then
         ${SUDO} make install
      fi

      cd ..
      rm -rf ucc-${UCC_VERSION} v${UCC_VERSION}.tar.gz
   fi

   if [[ ! -d "${UCC_PATH}"/lib ]] ; then
      echo "UCC (OpenMPI) installation failed -- missing installation directories"
      echo " UCC Installation path is ${UCC_PATH}"
      ls -l "${UCC_PATH}"
      exit 1
   fi
fi

#
# Install OpenMPI
#

if [[ -d "${OPENMPI_PATH}" ]] && [[ "${REPLACE_OPENMPI}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${OPENMPI_PATH}" ]] && [[ "${REPLACE_OPENMPI}" != "0" ]] ; then
      ${SUDO} rm -rf "${OPENMPI_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f "${CACHE_FILES}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached OpenMPI"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${CACHE_FILES}/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz"
      ${SUDO} mkdir -p ${OPENMPI_PATH}
      cd "${INSTALL_PATH}"
      ${SUDO} tar -xzpf "${CACHE_FILES}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      if [ "${USER}" != "root" ]; then
         ${SUDO} find ${OPENMPI_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${OPENMPI_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm "${CACHE_FILES}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      fi
   else

      echo ""
      echo "============================"
      echo " Building OpenMPI"
      echo "============================"
      echo ""

      # no cached version, so build it

      export OMPI_ALLOW_RUN_AS_ROOT=1
      export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

      export OMPI_MCA_pml=ucx
      export OMPI_MCA_osc=ucx

      export OMPI_MCA_pml_ucx_tls=any
      export OMPI_MCA_pml_ucx_devices=any
      export OMPI_MCA_pml_ucx_verbose=100

      # dad 3/25/3023 removed --enable-mpi-f90 --enable-mpi-c as they apparently are not options
      # dad 3/30/2023 remove --with-pmix

      OPENMPI_SHORT_VERSION=`echo ${OPENMPI_VERSION} | cut -f1-2 -d'.' `
      count=0
      while [ "$count" -lt 3 ]; do
         wget -q --continue --tries=10 https://download.open-mpi.org/release/open-mpi/v${OPENMPI_SHORT_VERSION}/openmpi-${OPENMPI_VERSION}.tar.bz2 && break
         count=$((count+1))
      done
      if [ ! -f openmpi-${OPENMPI_VERSION}.tar.bz2 ]; then
         echo "Failed to download openmpi-${OPENMPI_VERSION}.tar.bz2 package ... exiting"
         exit 1
      else
         MD5SUM_OPENMPI=`md5sum openmpi-${OPENMPI_VERSION}.tar.bz2 | cut -f1 -d' ' `
         if [[ "${OPENMPI_MD5CHECKSUM}" =~ "skip" ]]; then
            echo "MD5SUM is ${MD5SUM_OPENMPI}, no check requested"
         elif [[ "${MD5SUM_OPENMPI}" == "${OPENMPI_MD5CHECKSUM}" ]]; then
            echo "MD5SUM is verified: actual ${MD5SUM_OPENMPI}, expecting ${OPENMPI_MD5CHECKSUM}"
         else
            echo "Error: Wrong MD5Sum for openmpi-${OPENMPI_VERSION}.tar.bz2:"
            echo "MD5SUM is ${MD5SUM_OPENMPI}, expecting ${OPENMPI_MD5CHECKSUM}"
            exit 1
         fi
      fi
      tar -xjf openmpi-${OPENMPI_VERSION}.tar.bz2
      cd openmpi-${OPENMPI_VERSION}
      mkdir build && cd build

      OPENMPI_CONFIGURE_COMMAND="../configure \
         --prefix=${OPENMPI_PATH} \
         --with-rocm=${ROCM_PATH} \
         --with-ucx=${UCX_PATH} \
         --with-ucc=${UCC_PATH} \
         --enable-mca-no-build=btl-uct \
         --enable-mpi \
	 --enable-mpi-fortran \
         --disable-debug \
       	 CC=${C_COMPILER} CXX=${CXX_COMPILER} FC=${FC_COMPILER}"

      echo ""
      echo "OPENMPI_CONFIGURE_COMMAND: "
      echo "${OPENMPI_CONFIGURE_COMMAND}" | sed 's/\s\+/ \\\n   /g'
      echo ""

      ${OPENMPI_CONFIGURE_COMMAND}

      make -j 16

      if [[ "${DRY_RUN}" == "0" ]]; then
         ${SUDO} make install
	 for file in ${OPENMPI_PATH}/share/man/man1/*
         do
            ${SUDO} gzip $file
         done
      fi
      # make ucx the default point-to-point
      echo "pml = ucx" | ${SUDO} tee -a "${OMPI_PATH}"/etc/openmpi-mca-params.conf
      cd ../..
      rm -rf openmpi-${OPENMPI_VERSION} openmpi-${OPENMPI_VERSION}.tar.bz2
   fi

   if [[ ! -d ${OPENMPI_PATH}/lib ]] ; then
      echo "OpenMPI installation failed -- missing installation directories"
      echo " OpenMPI Installation path is ${OPENMPI_PATH}"
      ls -l "${OPENMPI_PATH}"
      exit 1
   fi
fi

#sudo update-alternatives \
#   --install /usr/bin/mpirun    mpirun  ${OPENMPI_PATH}/bin/mpirun 80 \
#   --slave   /usr/bin/mpiexec   mpiexec ${OPENMPI_PATH}/bin/mpiexec \
#   --slave   /usr/share/man/man1/mpirun.1.gz   mpirun.1.gz ${OPENMPI_PATH}/share/man/man1/mpirun.1.gz
#
#sudo update-alternatives \
#   --install /usr/bin/mpi       mpi     ${OPENMPI_PATH}/bin/mpicc  80 \
#   --slave   /usr/bin/mpicc     mpicc   ${OPENMPI_PATH}/bin/mpicc     \
#   --slave   /usr/bin/mpic++    mpic++  ${OPENMPI_PATH}/bin/mpic++    \
#   --slave   /usr/bin/mpiCC     mpiCC   ${OPENMPI_PATH}/bin/mpiCC     \
#   --slave   /usr/bin/mpicxx    mpicxx  ${OPENMPI_PATH}/bin/mpicxx    \
#   --slave   /usr/bin/mpif77    mpif77  ${OPENMPI_PATH}/bin/mpif77    \
#   --slave   /usr/bin/mpif90    mpif90  ${OPENMPI_PATH}/bin/mpif90    \
#   --slave   /usr/bin/mpifort   mpifort ${OPENMPI_PATH}/bin/mpifort   \
#   --slave   /usr/share/man/man1/mpic++.1.gz   mpic++.1.gz ${OPENMPI_PATH}/share/man/man1/mpic++.1.gz    \
#   --slave   /usr/share/man/man1/mpicc.1.gz    mpicc.1.gz ${OPENMPI_PATH}/share/man/man1/mpicc.1.gz      \
#   --slave   /usr/share/man/man1/mpicxx.1.gz   mpicxx.1.gz ${OPENMPI_PATH}/share/man/man1/mpicxx.1.gz    \
#   --slave   /usr/share/man/man1/mpif77.1.gz   mpif77.1.gz ${OPENMPI_PATH}/share/man/man1/mpif77.1.gz    \
#   --slave   /usr/share/man/man1/mpif90.1.gz   mpif90.1.gz ${OPENMPI_PATH}/share/man/man1/mpif90.1.gz    \
#   --slave   /usr/share/man/man1/mpifort.1.gz  mpifort.1.gz ${OPENMPI_PATH}/share/man/man1/mpifort.1.gz

module unload rocm/${ROCM_VERSION}

# In either case of Cache or Build from source, create a module file for OpenMPI

if [[ "${DRY_RUN}" == "0" ]]; then

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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${OPENMPI_VERSION}-ucc${UCC_VERSION}-ucx${UCX_VERSION}${XPMEM_STRING}.lua
	whatis("Name: GPU-aware openmpi")
	whatis("Version: openmpi-${OPENMPI_VERSION}-ucc${UCC_VERSION}-ucx${UCX_VERSION}${XPMEM_STRING}")
	whatis("Description: An open source Message Passing Interface implementation")
	whatis(" This is a GPU-Aware version of OpenMPI")
	whatis("URL: https://github.com/open-mpi/ompi.git")

	local base = "${OPENMPI_PATH}"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("MPI_PATH","${OPENMPI_PATH}")
	load("rocm/${ROCM_VERSION}")
	family("MPI")
EOF

fi
