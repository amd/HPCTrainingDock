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

echo "ROCM_VERSION is $ROCM_VERSION"

#
# Install UCX
#

if [ -f /opt/rocmplus-${ROCM_VERSION}/ucx.tgz ]; then
   #install the cached version
   cd /opt/rocmplus-${ROCM_VERSION}
   tar -xzf ucx.tgz
   chown -R root:root /opt/rocmplus-${ROCM_VERSION}/ucx
   rm /opt/rocmplus-${ROCM_VERSION}/ucx.tgz
else
   export OMPI_ALLOW_RUN_AS_ROOT=1
   export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

   export OMPI_MCA_pml=ucx
   export OMPI_MCA_osc=ucx

   export OMPI_MCA_pml_ucx_tls=any
   export OMPI_MCA_pml_ucx_devices=any
   export OMPI_MCA_pml_ucx_verbose=100

   # using /app rather than /tmp because prte encodes the HLD and removing /tmp files may cause problems
   cd /app
   wget -q https://github.com/openucx/ucx/releases/download/v1.16.0/ucx-1.16.0.tar.gz
   tar xzf ucx-1.16.0.tar.gz
   cd ucx-1.16.0
   mkdir build && cd build
   ../contrib/configure-release --prefix=/opt/rocmplus-${ROCM_VERSION}/ucx \
      --with-rocm=/opt/rocm-${ROCM_VERSION}  --without-cuda \
      --enable-mt  --enable-optimizations  --disable-logging \
      --disable-debug --enable-assertions --enable-params-check \
      --enable-examples
      make -j 16
      make install

   cd /app
   rm -rf ucx-1.16.0 ucx-1.16.0.tar.gz
fi

#
# Install OpenMPI
#

if [ -f /opt/rocmplus-${ROCM_VERSION}/openmpi.tgz ]; then
   #install the cached version
   cd /opt/rocmplus-${ROCM_VERSION}
   tar -xzf openmpi.tgz
   chown -R root:root /opt/rocmplus-${ROCM_VERSION}/openmpi
   rm /opt/rocmplus-${ROCM_VERSION}/openmpi.tgz
else
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
   # using /app rather than /tmp because prte encodes the HLD and removing /tmp files may cause problems
   cd /app

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
   make install
   # make ucx the default point-to-point
   echo "pml = ucx" >> /opt/rocmplus-${ROCM_VERSION}/openmpi/etc/openmpi-mca-params.conf
   cd /app
   rm -rf openmpi-5.0.3 openmpi-5.0.3.tar.bz2
fi

# In either case of Cache or Build from source, create a module file for OpenMPI
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/openmpi

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/5.0.3.lua <<-EOF
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
