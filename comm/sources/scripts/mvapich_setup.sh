#!/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mvapich
ROCM_VERSION=`cat /opt/rocm*/.info/version | head -1 | cut -f1 -d'-' `
ROCM_PATH=/opt/rocm-${ROCM_VERSION}
REPLACE=0
DRY_RUN=0
SUDO="sudo"
DEBIAN_FRONTEND_MODE="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEBIAN_FRONTEND_MODE=""
fi


# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "--dry-run default off"
   echo "--help: this usage information"
   echo "--install-path [ INSTALL_PATH ] default /opt/rocmplus-<ROCM_VERSION>/mvapich"
   echo "--module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-MPI/mvapich"
   echo "--replace default off"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "--rocm-path [ ROCM_PATH ] default /opt/rocm-$ROCM_VERSION"
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
      "--dry-run")
          DRY_RUN=1
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
      "--replace")
          REPLACE=1
          reset-last
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
   INSTALL_PATH="${INSTALL_PATH_INPUT}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/mvapich
fi

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
   ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/mvapich

   cd /tmp
   # install the GPU aware version of mvapich using an rpm (MVPlus3.0)
   wget -q ${MVAPICH_DOWNLOAD_URL}/${MVAPICH_RPM_NAME}
   if [[ "${DRY_RUN}" == "0" ]]; then
      ${SUDO} rpm --prefix ${INSTALL_PATH} -Uvh --nodeps ${MVAPICH_RPM_NAME}
      ${INSTALL_PATH}/mvapich/bin/mpicc -show
   fi
   rm ${MVAPICH_RPM_NAME}
fi
if [ "${DISTRO}" = "ubuntu" ]; then
   ${SUDO} ${DEBIAN_FRONTEND_MODE} apt-get -qqy install alien
   ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/mvapich

   # install the GPU aware version of mvapich using an rpm (MVPlus3.0)
   ${SUDO} wget -q ${MVAPICH_DOWNLOAD_URL}/${MVAPICH_RPM_NAME}
   ls -l ${MVAPICH_RPM_NAME}
   ${SUDO} apt-get install -y alien ${MVAPICH_RPM_NAME}
   /opt/rocmplus-${ROCM_VERSION}/mvapich/bin/mpicc --show
   rm -rf ${MVAPICH_RPM_NAME}
fi
if [ "${DISTRO}" = "opensuse leap" ]; then
   echo "Mvapich install on Suse not working yet"
   exit
fi

# Create a module file for Mvapich
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mvapich

${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/3.0.lua
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
