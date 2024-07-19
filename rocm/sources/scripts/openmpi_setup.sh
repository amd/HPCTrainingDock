#!/usr/bin/env bash

# This script installs OpenMPI along with the UCX and UCC libraries. The simplest use case is:
#   ./openmpi_setup.sh --rocm-version <ROCM_VERSION>
# Most of the needed information for the install is autodetected. Others are set to the latest
# available versions. Cross-compiling for a different GPU model can be done by specifying
# the --amdgpu-gfxmodel <AMDGPU-GFXMODEL> option
#
# Best recommended installation also includes xpmem. That is not currently handled in this
# script since it requires a kernel modification. Handling that in a container will take
# some more effort.

# Variables controlling setup process
ROCM_VERSION=6.1.2
ROCM_PATH=/opt/rocm-6.1.2
REPLACE=0
DRY_RUN=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/openmpi
INSTALL_PATH_INPUT=""
UCX_PATH_INPUT=""
UCC_PATH_INPUT=""
OPENMPI_PATH_INPUT=""
USE_CACHE_BUILD=1
UCX_VERSION=1.17.0
UCX_MD5CHECKSUM=53537757b71e5eae4d283e6fc32907ba
UCC_VERSION=1.3.0
UCC_MD5CHECKSUM=b2d14666cb9a18b0aee57898ce0a8c8b
OPENMPI_VERSION=5.0.3
OPENMPI_MD5CHECKSUM=af6896a78969b258da908d424c1c34ca
C_COMPILER=gcc
CXX_COMPILER=g++
FC_COMPILER=gfortran

# Autodetect defaults
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
    echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
    echo "--c-compiler [ CC ] default gcc"
    echo "--cxx-compiler [ CXX ] default g++"
    echo "--dry-run default off"
    echo "--fc-compiler [ FC ] default gfortran"
    echo "--help: this usage information"
    echo "--install-path [ INSTALL_PATH ] default /opt/rocmplus-<ROCM_VERSION>/openmpi (ucx, and ucc)"
    echo "--module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-MPI/openmpi"
    echo "--openmpi-path [OPENMPI_PATH] default $INSTALL_PATH/openmpi-$OPENMPI_VERSION-ucc-$UCC_VERSION-ucx-$UCX_VERSION"
    echo "--openmpi-version [VERSION] default $OPENMPI_VERSION"
    echo "--openmpi-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "--replace default off"
    echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
    echo "--rocm-path [ ROCM_PATH ] default /opt/rocm-$ROCM_VERSION"
    echo "--ucc-path default <INSTALL_PATH>/ucc"
    echo "--ucc-version [VERSION] default $UCC_VERSION"
    echo "--ucc-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "--ucx-path default <INSTALL_PATH>/ucx"
    echo "--ucx-version [VERSION] default $UCX_VERSION"
    echo "--ucx-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
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
      "--dry_run")
          DRY_RUN=1
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
      "--module_path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--openmpi-path")
          shift
          OPENMPI_PATH=${1}
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
          ;;
      "--rocm-path")
          shift
          ROCM_PATH_INPUT=${1}
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

if [ "${ROCM_PATH_INPUT}" != "" ]; then
   ROCM_PATH="${ROCM_PATH_INPUT}"
else
   ROCM_PATH="/opt/rocm-${ROCM_VERSION}"
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}
fi

if [ "${UCX_PATH_INPUT}" != "" ]; then
   UCX_PATH="${UCX_PATH_INPUT}"
else
   UCX_PATH="${INSTALL_PATH}"/ucx-${UCX_VERSION}
fi

if [ "${UCC_PATH_INPUT}" != "" ]; then
   UCC_PATH="${UCC_PATH_INPUT}"
else
   UCC_PATH="${INSTALL_PATH}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}
fi

if [ "${OPENMPI_PATH_INPUT}" != "" ]; then
   OPENMPI_PATH="${OPENMPI_PATH_INPUT}"
else
   OPENMPI_PATH="${INSTALL_PATH}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}
fi

echo ""
echo "============================"
echo " Installing OpenMPI with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "============================"
echo ""

if [ "${DISTRO}" = "ubuntu" ]; then
   echo "Install of libpmix-dev libhwloc-dev libevent-dev libfuse3-dev librdmacm-dev libtcmalloc-minimal4 doxygen packages"
   if [[ "${DRY_RUN}" == "0" ]]; then
      # these are for openmpi :  libpmix-dev  libhwloc-dev  libevent-dev
      sudo DEBIAN_FRONTEND=noninteractive apt-get update && \
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libpmix-dev libhwloc-dev libevent-dev \
         libfuse3-dev librdmacm-dev libtcmalloc-minimal4 doxygen
   fi
elif [ "${DISTRO}" = "rocky linux" ]; then
   echo "Install of pmix and hwloc packages"
   if [[ "${DRY_RUN}" == "0" ]]; then
      # these are for openmpi :  libpmix-dev  libhwloc-dev  libevent-dev
      yum update && \
      yum install -y pmix hwloc
   fi
fi

# omnitrace (omnitrace-avail) will throw this message using default values, so change default to 2
# [omnitrace][116] /proc/sys/kernel/perf_event_paranoid has a value of 3. Disabling PAPI (requires a value <= 2)...
# [omnitrace][116] In order to enable PAPI support, run 'echo N | sudo tee /proc/sys/kernel/perf_event_paranoid' where                   N is <= 2
if (( `cat /proc/sys/kernel/perf_event_paranoid` > 0 )); then echo "Please do:  echo 0  | sudo tee /proc/sys/kernel/perf_event_paranoid"; fi

if [[ "${DRY_RUN}" == "0" ]] && [[ ! -d ${INSTALL_PATH} ]] ; then
   mkdir -p "${INSTALL_PATH}"
fi
cd "${INSTALL_PATH}"

#
# Install UCX
#

if [[ -d "${UCX_PATH}" ]] && [[ "${REPLACE}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${UCX_PATH}" ]] && [[ "${REPLACE}" != "0" ]] ; then
      rm -rf "${UCX_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f ${INSTALL_PATH}/CacheFiles/ucx-${UCX_VERSION}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached UCX"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${INSTALL_PATH}/CacheFiles/ucx-${UCX_VERSION}.tgz"
      sudo tar -xzf ${INSTALL_PATH}/CacheFiles/ucx-${UCX_VERSION}.tgz
      sudo chown -R root:root "${INSTALL_PATH}"/ucx-${UCX_VERSION}
      sudo rm "${INSTALL_PATH}"/CacheFiles/ucx-${UCX_VERSION}.tgz
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

      echo ""
      echo "UCX_CONFIGURE_COMMAND: "
      echo "${UCX_CONFIGURE_COMMAND}" | sed 's/\s\+/ \\\n   /g'
      echo ""

      ${UCX_CONFIGURE_COMMAND}

      make -j 16
      if [[ "${DRY_RUN}" == "0" ]]; then
         sudo make install
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

if [[ -d "${UCC_PATH}" ]] && [[ "${REPLACE}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${UCC_PATH}" ]] && [[ "${REPLACE}" != "0" ]] ; then
      rm -rf "${UCC_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f "${INSTALL_PATH}"/CacheFiles/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached UCC"
      echo "============================"
      echo ""

      #install the cached version
      cd "${INSTALL_PATH}"
      sudo tar -xzf "${INSTALL_PATH}"/CacheFiles/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}.tgz
      sudo chown -R root:root "${INSTALL_PATH}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}
      sudo rm "${INSTALL_PATH}"/CacheFiles/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}.tgz
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

      export AMDGPU_GFXMODEL_UCC=${AMDGPU_GFXMODEL}
      echo 'Defaults:%sudo env_keep += "AMDGPU_GFXMODEL_UCC"' | sudo EDITOR='tee -a' visudo

      sudo sed -i '31i cmd="${@:3:2} -x hip -target x86_64-unknown-linux-gnu --offload-arch='"${AMDGPU_GFXMODEL_UCC}"' ${@:5} -fPIC -O3 -o ${pic_filepath}"' cuda_lt.sh
      sudo sed -i '32d' cuda_lt.sh
      sudo sed -i '41i cmd="${@:3:2} -x hip -target x86_64-unknown-linux-gnu --offload-arch='"${AMDGPU_GFXMODEL_UCC}"' ${@:5} -O3 -o ${npic_filepath}"' cuda_lt.sh
      sudo sed -i '42d' cuda_lt.sh

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
         sudo make install
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

if [[ -d "${OPENMPI_PATH}" ]] && [[ "${REPLACE}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${OPENMPI_PATH}" ]] && [[ "${REPLACE}" != "0" ]] ; then
      rm -rf "${OPENMPI_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f "${INSTALL_PATH}"/CacheFiles/openmpi-${OPENMPI_VERSION}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached OpenMPI"
      echo "============================"
      echo ""

      #install the cached version
      cd "${INSTALL_PATH}"
      sudo tar -xzf "${INSTALL_PATH}"/CacheFiles/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}.tgz
      sudo chown -R root:root "${INSTALL_PATH}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}
      sudo rm "${INSTALL_PATH}"/CacheFiles/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}.tgz
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
         sudo make install
      fi
      # make ucx the default point-to-point
      echo "pml = ucx" | sudo tee -a "${INSTALL_PATH}"/openmpi/etc/openmpi-mca-params.conf
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

# In either case of Cache or Build from source, create a module file for OpenMPI

if [[ "${DRY_RUN}" == "0" ]]; then
   sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
   cat <<-EOF | sudo tee ${MODULE_PATH}/${OPENMPI_VERSION}-ucc${UCC_VERSION}-ucx${UCX_VERSION}.lua
        whatis("Name: GPU-aware openmpi")
        whatis("Version: openmpi-${OPENMPI_VERSION}-ucc${UCC_VERSION}-ucx${UCX_VERSION}")
        whatis("Description: An open source Message Passing Interface implementation")
        whatis(" This is a GPU-Aware version of OpenMPI")
        whatis("URL: https://github.com/open-mpi/ompi.git")

        local base = "${OPENMPI_PATH}"

        prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
        prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("PATH", pathJoin(base, "bin"))
        load("rocm/${ROCM_VERSION}")
        family("MPI")
EOF

fi
