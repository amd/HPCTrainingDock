#!/bin/bash

# Autodetect defaults
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
ROCM_VERSION="6.2.0"
#INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/rocprofiler-sdk"
INSTALL_PATH="/opt/rocm-${ROCM_VERSION}"
INSTALL_PATH_INPUT=""
MODULE_PATH="/etc/lmod/modules/ROCm/rocprofiler-sdk"
GITHUB_BRANCH="amd-staging"
BUILD_ROCPROFILER_SDK=0

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi


usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [INSTALL_PATH ] default $INSTALL_PATH"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --github-branch [ GITHUB_BRANCH ] default $GITHUB_BRANCH"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL "
   echo "  --build-rocprofiler-sdk: default $BUILD_ROCPROFILER_SDK"
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
      "--build-rocprofiler-sdk")
          shift
          BUILD_ROCPROFILER_SDK=${1}
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
   echo "The rocprofiler-sdk library can be installed only for ROCm versions greater than or equal to 6.2.0"
   echo "You selected this as ROCm version: $ROCM_VERSION"
   echo "Select appropriate ROCm version by specifying --rocm-version $ROCM_VERSION, with $ROCM_VERSION >= 6.2.0"
   exit 1
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   #INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/rocprofiler-sdk"
   INSTALL_PATH="/opt/rocm-${ROCM_VERSION}"
fi

#LIBDW_FLAGS=""
## don't use sudo if user has write access to install path
#if [ -d "$INSTALL_PATH" ]; then
#   # don't use sudo if user has write access to install path
#   if [ -w ${INSTALL_PATH} ]; then
#      SUDO=""
#      if [ "${DISTRO}" == "ubuntu" ]; then
#         export LIBDW_PATH=$INSTALL_PATH/libdw
#         mkdir libdw_install
#         cd libdw_install
#         apt-get source libdw-dev
#         cd elfutils-*
#         ./configure --prefix=$LIBDW_PATH --disable-libdebuginfod --disable-debuginfod
#         make -j
#         make install
#         export PATH=$PATH:$LIBDW_PATH:$LIBDW_PATH/bin
#         cd ../../
#         rm -rf libdw_install
#         LIBDW_FLAGS="-I$LIBDW_PATH/include -L$LIBDW_PATH/lib -ldw"
#      else
#         echo " ------ WARNING: your distribution is not ubuntu ------ "
#         echo " ------ WARNING: install will fail if libdw is not found ------ "
#      fi
#   else
#      echo " ------ WARNING: using an install path that requires sudo ------ "
#      if [ "${DISTRO}" == "ubuntu" ]; then
#         sudo apt-get update
#         sudo apt-get install -y libdw-dev
#      else
#         echo " ------ WARNING: your distribution is not ubuntu ------"
#         echo " ------ WARNING: install will fail if libdw is not found ------ "
#      fi
#   fi
#else
#   # if install path does not exist yet, the check on write access will fail
#   echo "WARNING: using sudo, make sure you have sudo privileges"
   if [ "${DISTRO}" == "ubuntu" ]; then
      sudo apt-get update
      sudo apt-get install -y libdw-dev
#   else
#      echo " ------ WARNING: your distribution is not ubuntu ------"
#      echo " ------ WARNING: install will fail if libdw is not found ------ "
   fi
#fi

echo ""
echo "=================================="
echo "Starting Rocprofiler-sdk Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "INSTALL_PATH: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "GITHUB_BRANCH: $GITHUB_BRANCH"
echo "=================================="
echo ""

source /etc/profile.d/lmod.sh
module load rocm/${ROCM_VERSION}
module load openmpi

${SUDO} mkdir -p $INSTALL_PATH

AMDGPU_GFXMODEL_SINGLE=`echo $AMDGPU_GFXMODEL | cut -f1 -d';'`
echo "AMDGPU_GFXMODEL is ${AMDGPU_GFXMODEL}"
echo "AMDGPU_GFXMODEL_SINGLE is ${AMDGPU_GFXMODEL_SINGLE}"
      #-DROCPROFILER_BUILD_TESTS=ON \

#cmake                                         \
#      -B rocprofiler-sdk-build                \
#      -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH}  \
#      -DOPENMP_GPU_TARGETS="${AMDGPU_GFXMODEL}" \
#      -DGPU_TARGETS="${AMDGPU_GFXMODEL}" \
#      -DROCPROFILER_BUILD_TESTS=ON -DROCPROFILER_BUILD_SAMPLES=ON \
#      -DCMAKE_PREFIX_PATH=${INSTALL_PATH}     \
#       rocprofiler-sdk-source

git clone --branch $GITHUB_BRANCH https://github.com/ROCm/rocprofiler-sdk.git rocprofiler-sdk-source

#you can either install the decoder in '/opt/rocm-6.4.1/lib64' or '/opt/rocm-6.4.1/lib' or use --att-library-path /path/to/lib
wget https://github.com/ROCm/rocprof-trace-decoder/releases/download/0.1.2/rocprof-trace-decoder-manylinux-2.28-0.1.2-Linux.tar.gz
tar -xzvf rocprof-trace-decoder-manylinux-2.28-0.1.2-Linux.tar.gz
${SUDO} cp rocprof-trace-decoder-manylinux-2.28-0.1.2-Linux/opt/rocm/lib/librocprof-trace-decoder.so $INSTALL_PATH/lib

cmake                                         \
      -B rocprofiler-sdk-build                \
      -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH}  \
      -DGPU_TARGETS="${AMDGPU_GFXMODEL}" \
      -DCMAKE_PREFIX_PATH=${INSTALL_PATH}     \
       rocprofiler-sdk-source

nproc=8
cmake --build rocprofiler-sdk-build --target all --parallel $(nproc)

${SUDO} cmake --build rocprofiler-sdk-build --target install

rm -rf rocprofiler-sdk-source rocprofiler-sdk-build
rm -rf rocprof-trace-decoder-manylinux-2.28-0.1.2-Linux

# Create a module file for rocprofiler-sdk
#if [ -d "$MODULE_PATH" ]; then
#   # use sudo if user does not have write access to module path
#   if [ ! -w ${MODULE_PATH} ]; then
#      SUDO="sudo"
#    else
#       echo "WARNING: not using sudo since user has write access to module path"
#    fi
#else
#    # if module path dir does not exist yet, the check on write access will fail
#    SUDO="sudo"
#    echo "WARNING: using sudo, make sure you have sudo privileges"
#fi


#${SUDO} mkdir -p ${MODULE_PATH}

#cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
#	whatis("Name: Rocprofiler-sdk")
#	whatis("ROCm Version: ${ROCM_VERSION}")
#	whatis("Category: AMD")
#	whatis("Github Branch: ${GITHUB_BRANCH}")
#
#	local base = "${INSTALL_PATH}"
#
#	load("rocm/${ROCM_VERSION}")
#	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
#	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
#	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
#	prepend_path("CPATH", pathJoin(base, "include"))
#	prepend_path("PATH", pathJoin(base, "bin"))
#	prepend_path("INCLUDE", pathJoin(base, "include"))
#EOF

