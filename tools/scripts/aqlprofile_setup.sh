#!/bin/bash

# Autodetect defaults
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
ROCM_VERSION="6.2.0"
INSTALL_PATH="/opt/rocm-${ROCM_VERSION}"
INSTALL_PATH_INPUT=""
MODULE_PATH="/etc/lmod/modules/ROCm/aqlprofile"
GITHUB_BRANCH="amd-staging"
BUILD_AQLPROFILE=0

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi


usage()
{
   echo "Usage:"
   echo "  gARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [INSTALL_PATH ] default $INSTALL_PATH"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --github-branch [ GITHUB_BRANCH ] default $GITHUB_BRANCH"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL "
   echo "  --build-aqlprofile: default $BUILD_AQLPROFILE"
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
      "--help")
         usage
         ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--github-branch")
          shift
          GITHUB_BRANCH=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--build-aqlprofile")
          shift
          BUILD_AQLPROFILE=${1}
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

result=`echo $ROCM_VERSION | awk '$1>6.2.0'` && echo $result
if [[ "${result}" == "" ]]; then # ROCM_VERSION < 6.2.0
   echo "The aqlprofile library can be installed only for ROCm versions greater than or equal to 6.2.0"
   echo "You selected this as ROCm version: $ROCM_VERSION"
   echo "Select appropriate ROCm version by specifying --rocm-version $ROCM_VERSION, with $ROCM_VERSION >= 6.2.0"
   exit 1
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   INSTALL_PATH="/opt/rocm-${ROCM_VERSION}"
fi

echo ""
echo "=================================="
echo "Starting AQLprofile Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "INSTALL_PATH: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "GITHUB_BRANCH: $GITHUB_BRANCH"
echo "=================================="
echo ""

${SUDO} apt-get update
${SUDO} apt-get -y install libdw-dev

${SUDO} mkdir -p $INSTALL_PATH

source /etc/profile.d/lmod.sh
module load rocm/${ROCM_VERSION}

#cmake -DGPU_TARGETS="${AMDGPU_GFXMODEL}" -DCMAKE_PREFIX_PATH=/opt/${ROCM_VERSION}/lib:/opt/${ROCM_VERSION}/include/hsa -DCMAKE_INSTALL_PREFIX=$INSTALL_PATH ..

ls -l /opt/rocm-${ROCM_VERSION}/lib/libhsa-amd-aqlprofile64.so*
git clone --branch $GITHUB_BRANCH https://github.com/ROCm/aqlprofile.git

cd aqlprofile

mkdir build && cd build

cmake -DCMAKE_PREFIX_PATH=/opt/rocm-${ROCM_VERSION}/lib:/opt/rocm-${ROCM_VERSION}/include/hsa -DCMAKE_INSTALL_PREFIX=$INSTALL_PATH ..
make -j
echo "Checking for successful build with listing of library"
ls -l libhsa-amd-aqlprofile64.so
${SUDO} make install
echo "Checking if aqlprofile library is currently installed and removing it"
if [[ `ls -l /opt/rocm-${ROCM_VERSION}/lib/libhsa-amd-aqlprofile64.so* |wc -l` -ge 1 ]]; then
   ls -l /opt/rocm-${ROCM_VERSION}/lib/libhsa-amd-aqlprofile64.so*
   rm -f /opt/rocm-${ROCM_VERSION}/lib/libhsa-amd-aqlprofile64.so*
fi
${SUDO} make install
echo "Checking that new library has been installed"
ls -l /opt/rocm-${ROCM_VERSION}/lib/libhsa-amd-aqlprofile64.so*


cd ../..

#sudo rm -rf aqlprofile

# Create a module file for rocprofiler-sdk
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


#${SUDO} mkdir -p ${MODULE_PATH}

#cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
#	whatis("Name: AQLprofile")
#	whatis("ROCm Version: ${ROCM_VERSION}")
#	whatis("Category: AMD")
#	whatis("Github Branch: ${GITHUB_BRANCH}")
#
#	local base = "${INSTALL_PATH}"
#
#	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
#	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
#	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
#	prepend_path("CPATH", pathJoin(base, "include"))
#	prepend_path("PATH", pathJoin(base, "bin"))
#	prepend_path("INCLUDE", pathJoin(base, "include"))
#EOF

