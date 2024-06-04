#!/usr/bin/env bash

: ${ROCM_VERSIONS:="6.0"}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
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

echo ""
echo "============================"
echo " Installing OpenMPI with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "============================"
echo ""

if [ "${DISTRO}" = "ubuntu" ]; then
   # these are for openmpi :  libpmix-dev  libhwloc-dev  libevent-dev 
   sudo DEBIAN_FRONTEND=noninteractive apt-get update && \
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libpmix-dev libhwloc-dev libevent-dev \
      libfuse3-dev librdmacm-dev libtcmalloc-minimal4 doxygen
fi
if [ "${DISTRO}" = "rocky linux" ]; then
   # these are for openmpi :  libpmix-dev  libhwloc-dev  libevent-dev 
   yum update && \
   yum install -y pmix hwloc
fi

# omnitrace (omnitrace-avail) will throw this message using default values, so change default to 2
# [omnitrace][116] /proc/sys/kernel/perf_event_paranoid has a value of 3. Disabling PAPI (requires a value <= 2)...
# [omnitrace][116] In order to enable PAPI support, run 'echo N | sudo tee /proc/sys/kernel/perf_event_paranoid' where                   N is <= 2
if (( `cat /proc/sys/kernel/perf_event_paranoid` > 0 )); then echo "Please do:  echo 0  | sudo tee /proc/sys/kernel/perf_event_paranoid"; fi

mkdir -p /opt/rocmplus-${ROCM_VERSION}

#
# Install UCX
#

if [ -f /opt/rocmplus-${ROCM_VERSION}/ucx.tgz ]; then
   echo ""
   echo "============================"
   echo " Installing Cached UCX"
   echo "============================"
   echo ""

   #install the cached version
   cd /opt/rocmplus-${ROCM_VERSION}
   sudo tar -xzf ucx.tgz
   sudo chown -R root:root /opt/rocmplus-${ROCM_VERSION}/ucx
   sudo rm /opt/rocmplus-${ROCM_VERSION}/ucx.tgz
else
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

   wget -q https://github.com/openucx/ucx/releases/download/v1.16.0/ucx-1.16.0.tar.gz
   tar xzf ucx-1.16.0.tar.gz
   cd ucx-1.16.0
   mkdir build && cd build

   echo "../contrib/configure-release --prefix=/opt/rocmplus-${ROCM_VERSION}/ucx --with-rocm=/opt/rocm-${ROCM_VERSION}  --without-cuda --enable-mt  --enable-optimizations  --disable-logging --disable-debug --enable-assertions --enable-params-check --enable-examples"
   ../contrib/configure-release --prefix=/opt/rocmplus-${ROCM_VERSION}/ucx \
      --with-rocm=/opt/rocm-${ROCM_VERSION}  --without-cuda \
      --enable-mt  --enable-optimizations  --disable-logging \
      --disable-debug --enable-assertions --enable-params-check \
      --enable-examples
      make -j 16
      sudo make install

   cd ../..
   rm -rf ucx-1.16.0 ucx-1.16.0.tar.gz
fi

#
# Install OpenMPI
#

if [ -f /opt/rocmplus-${ROCM_VERSION}/openmpi.tgz ]; then
   echo ""
   echo "============================"
   echo " Installing Cached OpenMPI"
   echo "============================"
   echo ""

   #install the cached version
   cd /opt/rocmplus-${ROCM_VERSION}
   sudo tar -xzf openmpi.tgz
   sudo chown -R root:root /opt/rocmplus-${ROCM_VERSION}/openmpi
   sudo rm /opt/rocmplus-${ROCM_VERSION}/openmpi.tgz
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

   wget -q https://download.open-mpi.org/release/open-mpi/v5.0/openmpi-5.0.3.tar.bz2
   tar -xjf openmpi-5.0.3.tar.bz2
   cd openmpi-5.0.3
   mkdir build && cd build
   ../configure --prefix=/opt/rocmplus-${ROCM_VERSION}/openmpi \
                --with-ucx=/opt/rocmplus-${ROCM_VERSION}/ucx \
                --enable-mca-no-build=btl-uct \
                --enable-mpi --enable-mpi-fortran \
                --disable-debug   CC=gcc CXX=g++ FC=gfortran
   make -j 16
   sudo make install
   # make ucx the default point-to-point
   echo "pml = ucx" | sudo tee -a /opt/rocmplus-${ROCM_VERSION}/openmpi/etc/openmpi-mca-params.conf
   cd ../..
   rm -rf openmpi-5.0.3 openmpi-5.0.3.tar.bz2
fi

# In either case of Cache or Build from source, create a module file for OpenMPI
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/openmpi

sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | sudo tee ${MODULE_PATH}/5.0.3.lua
	whatis("Name: GPU-aware openmpi")
	whatis("Version: 5.0.3")
	whatis("Description: An open source Message Passing Interface implementation")
	whatis(" This is a GPU-Aware version of OpenMPI")
	whatis("URL: https://github.com/open-mpi/ompi.git")

	local base = "/opt/rocmplus-${ROCM_VERSION}/openmpi"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	load("rocm/${ROCM_VERSION}")
	family("MPI")
EOF
