#!/usr/bin/env bash

ROCM_VERSION=6.1.2
REPLACE=0
DRY_RUN=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/openmpi
INSTALL_PATH_INPUT=""
UCX_PATH_INPUT=""
UCC_PATH_INPUT=""
OPENMPI_PATH_INPUT=""
USE_CACHE_BUILD=1

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`

usage()
{
    echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
    echo "--dry-run default off"
    echo "--help: this usage information"
    echo "--install-path [ INSTALL_PATH ] default /opt/rocmplus-<ROCM_VERSION>/openmpi (ucx, and ucc)"
    echo "--module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-MPI/openmpi"
    echo "--replace default off"
    echo "--rocm-version [ ROCM_VERSION ] default 6.1.2"
    echo "--ucc-path default <INSTALL_PATH>/ucc"
    echo "--ucx-path default <INSTALL_PATH>/ucx"
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
      "--dry_run")
          DRY_RUN=1
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
      "--replace")
          REPLACE=1
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
      "--ucx-path")
          shift
          UCX_PATH_INPUT=${1}
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

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}
fi

if [ "${UCX_PATH_INPUT}" != "" ]; then
   UCX_PATH="${UCX_PATH_INPUT}"
else
   UCX_PATH="${INSTALL_PATH}"/ucx
fi

if [ "${UCC_PATH_INPUT}" != "" ]; then
   UCC_PATH="${UCC_PATH_INPUT}"
else
   UCC_PATH="${INSTALL_PATH}"/ucc
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

if [ -f ${INSTALL_PATH}/CacheFiles/ucx.tgz ]; then
   echo ""
   echo "============================"
   echo " Installing Cached UCX"
   echo "============================"
   echo ""

   #install the cached version
   echo "cached file is ${INSTALL_PATH}/CacheFiles/ucx.tgz"
   sudo tar -xzf ${INSTALL_PATH}/CacheFiles/ucx.tgz
   sudo chown -R root:root "${INSTALL_PATH}"/ucx
   sudo rm "${INSTALL_PATH}"/CacheFiles/ucx.tgz
else
   if [[ -d "${UCX_PATH}" ]] && [[ "${REPLACE}" == "0" ]] ; then
      echo "There is a previous installation and the replace flag is false"
      echo "  use --replace to request replacing the current installation" 
      exit
   fi

   echo ""
   echo "============================"
   echo " Building UCX"
   echo "============================"
   echo ""

   export OMPI_ALLOW_RUN_AS_ROOT=1
   export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

   export OMPI_MCA_pml=ucx
   export OMPI_MCA_osc=ucx

   export OMPI_MCA_pml_ucx_tls=any
   export OMPI_MCA_pml_ucx_devices=any
   export OMPI_MCA_pml_ucx_verbose=100

   count=0
   while [ "$count" -lt 3 ]; do
      wget -q --continue --tries=10 https://github.com/openucx/ucx/releases/download/v1.16.0/ucx-1.16.0.tar.gz && break
      $((count++))
   done
   if [ ! -f ucx-1.16.0.tar.gz ]; then
      echo "Failed to download ucx-1.16.0.tar.gz package ... exiting"
      exit 1
   fi
   tar xzf ucx-1.16.0.tar.gz
   cd ucx-1.16.0
   mkdir build && cd build

   echo "../contrib/configure-release --prefix="${UCX_PATH}" --with-rocm=/opt/rocm-${ROCM_VERSION}  --without-cuda --enable-mt  --enable-optimizations  --disable-logging --disable-debug --enable-assertions --enable-params-check --enable-examples"
   ../contrib/configure-release --prefix="${UCX_PATH}" \
      --with-rocm=/opt/rocm-${ROCM_VERSION}  --without-cuda \
      --enable-mt  --enable-optimizations  --disable-logging \
      --disable-debug --enable-assertions --enable-params-check \
      --enable-examples
      make -j 16
      if [[ "${DRY_RUN}" == "0" ]]; then
         sudo make install
      fi

   cd ../..
   rm -rf ucx-1.16.0 ucx-1.16.0.tar.gz
fi

if [[ ! -d /opt/rocmplus-6.1.2/ucx/lib ]] ; then
   echo "OpenMPI installation failed -- missing installation directories"
   ls -l /opt/rocmplus-6.1.2/ucx 
   exit 1
fi

#
# Install UCC
#

if [ -f "${INSTALL_PATH}"/CacheFiles/ucc.tgz ]; then
   echo ""
   echo "============================"
   echo " Installing Cached UCC"
   echo "============================"
   echo ""

   #install the cached version
   cd "${INSTALL_PATH}"
   sudo tar -xzf "${INSTALL_PATH}"/CacheFiles/ucc.tgz
   sudo chown -R root:root "${INSTALL_PATH}"/ucc
   sudo rm "${INSTALL_PATH}"/CacheFiles/ucc.tgz
else
   if [[ -d "${UCC_PATH}" ]] && [[ "${REPLACE}" == "0" ]] ; then
      echo "There is a previous installation and the replace flag is false"
      echo "  use --replace to request replacing the current installation" 
      exit
   fi

   echo ""
   echo "============================"
   echo " Building UCC"
   echo "============================"
   echo ""

   export OMPI_ALLOW_RUN_AS_ROOT=1
   export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

   export OMPI_MCA_pml=ucx
   export OMPI_MCA_osc=ucx

   export OMPI_MCA_pml_ucx_tls=any
   export OMPI_MCA_pml_ucx_devices=any
   export OMPI_MCA_pml_ucx_verbose=100

   count=0
   while [ "$count" -lt 3 ]; do
      wget -q --continue --tries=10 https://github.com/openucx/ucc/archive/refs/tags/v1.3.0.tar.gz && break
      $((count++))
   done
   if [ ! -f v1.3.0.tar.gz ]; then
      echo "Failed to download ucc v1.3.0.tar.gz package ... exiting"
      exit 1
   fi
   tar xzf v1.3.0.tar.gz
   cd ucc-1.3.0

   export AMDGPU_GFXMODEL_UCC=${AMDGPU_GFXMODEL}
   echo 'Defaults:%sudo env_keep += "AMDGPU_GFXMODEL_UCC"' | sudo EDITOR='tee -a' visudo

   sudo sed -i '31i cmd="${@:3:2} -x hip -target x86_64-unknown-linux-gnu --offload-arch='"${AMDGPU_GFXMODEL_UCC}"' ${@:5} -fPIC -O3 -o ${pic_filepath}"' cuda_lt.sh
   sudo sed -i '32d' cuda_lt.sh
   sudo sed -i '41i cmd="${@:3:2} -x hip -target x86_64-unknown-linux-gnu --offload-arch='"${AMDGPU_GFXMODEL_UCC}"' ${@:5} -O3 -o ${npic_filepath}"' cuda_lt.sh
   sudo sed -i '42d' cuda_lt.sh

   ./autogen.sh
   echo "./configure --prefix=${UCC_PATH}  --with-rocm=/opt/rocm-${ROCM_VERSION}  --with-ucx=${UCX_PATH} "
   ./configure --prefix="${UCC_PATH}"  --with-rocm=/opt/rocm-${ROCM_VERSION} --with-ucx="${UCX_PATH}"
   make -j 16

   if [[ "${DRY_RUN}" == "0" ]]; then
      sudo make install
   fi

   cd ..
   rm -rf ucc-1.3.0 v1.3.0.tar.gz
fi

if [[ ! -d /opt/rocmplus-6.1.2/ucc/lib ]] ; then
   echo "OpenMPI installation failed -- missing installation directories"
   ls -l /opt/rocmplus-6.1.2/ucc
   exit 1
fi

#
# Install OpenMPI
#

if [ -f "${INSTALL_PATH}"/CacheFiles/openmpi.tgz ]; then
   echo ""
   echo "============================"
   echo " Installing Cached OpenMPI"
   echo "============================"
   echo ""

   #install the cached version
   cd "${INSTALL_PATH}"
   sudo tar -xzf "${INSTALL_PATH}"/CacheFiles/openmpi.tgz
   sudo chown -R root:root "${INSTALL_PATH}"/openmpi
   sudo rm "${INSTALL_PATH}"/CacheFiles/openmpi.tgz
else
   if [[ -d "${INSTALL_PATH}/openmpi" ]] && [[ "${REPLACE}" == "0" ]] ; then
      echo "There is a previous installation and the replace flag is false"
      echo "  use --replace to request replacing the current installation" 
      exit
   fi

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

   set -v

   count=0
   while [ "$count" -lt 3 ]; do
      wget -q --continue --tries=10 https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-5.0.3.tar.bz2 && break
      $((count++))
   done
   if [ ! -f openmpi-5.0.3.tar.bz2 ]; then
      echo "Failed to download openmpi-5.0.3.tar.bz2 package ... exiting"
      exit 1
   fi
   tar -xjf openmpi-5.0.3.tar.bz2
   cd openmpi-5.0.3
   mkdir build && cd build
   ../configure --prefix="${INSTALL_PATH}"/openmpi \
                --with-ucx="${UCX_PATH}" \
		--with-ucc="${UCC__PATH}" \
                --enable-mca-no-build=btl-uct \
                --enable-mpi --enable-mpi-fortran \
                --disable-debug   CC=gcc CXX=g++ FC=gfortran
   make -j 16

   if [[ "${DRY_RUN}" == "0" ]]; then
      sudo make install
   fi
   # make ucx the default point-to-point
   echo "pml = ucx" | sudo tee -a "${INSTALL_PATH}"/openmpi/etc/openmpi-mca-params.conf
   cd ../..
   rm -rf openmpi-5.0.3 openmpi-5.0.3.tar.bz2
fi

if [[ ! -d /opt/rocmplus-6.1.2/openmpi/lib ]] ; then
   echo "OpenMPI installation failed -- missing installation directories"
   ls -l /opt/rocmplus-6.1.2/openmpi
   exit 1
fi

# In either case of Cache or Build from source, create a module file for OpenMPI

if [[ "${DRY_RUN}" == "0" ]]; then
   sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
   cat <<-EOF | sudo tee ${MODULE_PATH}/5.0.3.lua
	whatis("Name: GPU-aware openmpi")
	whatis("Version: 5.0.3")
	whatis("Description: An open source Message Passing Interface implementation")
	whatis(" This is a GPU-Aware version of OpenMPI")
	whatis("URL: https://github.com/open-mpi/ompi.git")

	local base = "${INSTALL_PATH}/openmpi"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	load("rocm/${ROCM_VERSION}")
	family("MPI")
EOF

fi
