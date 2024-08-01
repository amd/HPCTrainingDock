#!/bin/bash

reset-last()
{
    last() { send-error "Unsupported argument :: ${1}"; }
}

ROCM_VERSION=6.0

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
echo " Installing MVAPICH with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "============================"
echo ""

#
# Install mvapich
#

MVAPICH_RPM_NAME=mvapich-plus-rocm5.6.0.multiarch.ucx.gnu8.5.0-3.0-1.el8.x86_64.rpm
MVAPICH_DOWNLOAD_URL=https://mvapich.cse.ohio-state.edu/download/mvapich/plus/3.0/rocm/UCX/mofed5.0

if [ "${DISTRO}" = "rocky linux" ]; then
   sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/mvapich

   cd /tmp
   # install the GPU aware version of mvapich using an rpm (MVPlus3.0)
   wget -q ${MVAPICH_DOWNLOAD_URL}/${MVAPICH_RPM_NAME}
   sudo rpm --prefix /opt/rocmplus-${ROCM_VERSION}/mvapich -Uvh --nodeps ${MVAPICH_RPM_NAME}
   /opt/rocmplus-${ROCM_VERSION}/mvapich/bin/mpicc -show
   rm ${MVAPICH_RPM_NAME}
fi
if [ "${DISTRO}" = "ubuntu" ]; then
   sudo DEBIAN_FRONTEND=noninteractive apt-get -qqy install alien
   sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/mvapich

   # install the GPU aware version of mvapich using an rpm (MVPlus3.0)
   sudo wget -q ${MVAPICH_DOWNLOAD_URL}/${MVAPICH_RPM_NAME}
   ls -l ${MVAPICH_RPM_NAME}
   sudo apt-get install -y alien ${MVAPICH_RPM_NAME}
   /opt/rocmplus-${ROCM_VERSION}/mvapich/bin/mpicc --show
fi
if [ "${DISTRO}" = "opensuse leap" ]; then
   echo "Mvapich install on Suse not working yet"
   exit
fi

# Create a module file for Mvapich
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mvapich

sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | sudo tee ${MODULE_PATH}/3.0.lua
        whatis("Name: GPU-aware mvapich")
        whatis("Version: 3.0.0")
        whatis("Description: An open source Message Passing Interface implementation")
        whatis(" This is a GPU-aware version of Mvapich3")

        local base = "/opt/rocmplus-${ROCM_VERSION}/mvapich/"
        local mbase = "/etc/lmod/modules/ROCmPlus-MPI"

        setenv("MV2_PATH", base)
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib64"))
        prepend_path("C_INCLUDE_PATH",pathJoin(base, "include"))
        prepend_path("CPLUS_INCLUDE_PATH",pathJoin(base, "include"))
        prepend_path("PATH",pathJoin(base, "bin"))
        load("rocm/${ROCM_VERSION}")
        family("MPI")
EOF
