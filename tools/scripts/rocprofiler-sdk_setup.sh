#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Autodetect defaults
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO_PACKAGE_INSTALL="sudo"
SUDO_MODULE_INSTALL="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
ROCM_VERSION="6.2.0"
INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/rocprofiler-sdk"
INSTALL_PATH_INPUT=""
MODULE_PATH="/etc/lmod/modules/ROCm/rocprofiler-sdk"
MPI_MODULE="openmpi"
GITHUB_BRANCH="develop"
BUILD_ROCPROFILER_SDK=0

if [  -f /.singularity.d/Singularity ]; then
   SUDO_PACKAGE_INSTALL=""
   DEB_FRONTEND=""
fi


usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [ INSTALL_PATH ] default $INSTALL_PATH"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
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
      "--mpi-module")
          shift
          MPI_MODULE=${1}
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

if [ "$BUILD_ROCPROFILER_SDK" == "0" ]; then
   echo "Rocprofiler SDK build flag is turned off"
   exit 1
fi

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
   INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/rocprofiler-sdk"
fi

# check if install path exists, if it does and user has write access, do not use sudo
if [ -d "$INSTALL_PATH" ]; then
   if [ -w ${INSTALL_PATH} ]; then
      # don't use sudo if user has write access to install path
      SUDO_PACKAGE_INSTALL=""
   fi
fi

# check if module path exists, if it does and user has write access, do not use sudo
if [ -d "$MODULE_PATH" ]; then
   if [ -w ${MODULE_PATH} ]; then
      # don't use sudo if user has write access to module path
      SUDO_MODULE_INSTALL=""
   fi
fi

# install libdw if OS is ubuntu
if [ "${DISTRO}" == "ubuntu" ]; then
   if [ "${SUDO_PACKAGE_INSTALL}" == "" ]; then
        export LIBDW_PATH=$INSTALL_PATH/libdw
        mkdir libdw_install
        cd libdw_install
        apt-get source libdw-dev
        cd elfutils-*
        ./configure --prefix=$LIBDW_PATH --disable-libdebuginfod --disable-debuginfod
        make -j
        make install
        export PATH=$PATH:$LIBDW_PATH:$LIBDW_PATH/bin
        cd ../../
        rm -rf libdw_install
        LIBDW_FLAGS="-I$LIBDW_PATH/include -L$LIBDW_PATH/lib -ldw"
   else
         sudo apt-get update
         sudo apt-get install -y libdw-dev
   fi
else
    echo " ------ WARNING: your distribution is not ubuntu ------ "
    echo " ------ WARNING: install will fail if libdw is not found ------ "
fi

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
# Derive ROCM_MODULE_NAME from the actual ROCM_PATH basename so RC
# trees (rocm-therock-*, rocm-afar-*) match their loaded module name
# instead of the SDK numeric. Falls back to the rocm/<version> form
# for direct standalone invocation where ROCM_PATH is unset.
if [[ -n "${ROCM_PATH:-}" ]]; then
   _rp_bn="${ROCM_PATH##*/}"
   ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
   unset _rp_bn
else
   ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
fi
module load ${ROCM_MODULE_NAME}
module load ${MPI_MODULE}

${SUDO_PACKAGE_INSTALL} mkdir -p ${INSTALL_PATH}/lib/rocprofiler-sdk

wget https://github.com/ROCm/rocprof-trace-decoder/releases/download/0.1.2/rocprof-trace-decoder-manylinux-2.28-0.1.2-Linux.tar.gz
tar -xzvf rocprof-trace-decoder-manylinux-2.28-0.1.2-Linux.tar.gz
${SUDO_PACKAGE_INSTALL} mv rocprof-trace-decoder-manylinux-2.28-0.1.2-Linux/opt/rocm/lib/librocprof-trace-decoder.so $INSTALL_PATH/lib

git clone --branch $GITHUB_BRANCH https://github.com/ROCm/rocm-systems.git rocm-systems-source

nproc=8
cmake                                         \
      -B rocprofiler-sdk-build                \
      -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH}  \
      -DGPU_TARGETS=\"${AMDGPU_GFXMODEL}\" \
      -DOPENMP_GPU_TARGETS=\"${AMDGPU_GFXMODEL}\" \
      -DCMAKE_PREFIX_PATH=/opt/rocm-${ROCM_VERSION} \
       rocm-systems-source/projects/rocprofiler-sdk

cmake --build rocprofiler-sdk-build --target all --parallel $(nproc)
${SUDO_PACKAGE_INSTALL} cmake --build rocprofiler-sdk-build --target install

rm -rf rocprofiler-sdk-build
rm -rf rocprof-trace-decoder-*

cmake                                        \
       -B aqlprofile-build                   \
       -DGPU_TARGETS="${AMDGPU_GFXMODEL}"    \
       -DCMAKE_PREFIX_PATH=/opt/rocm-${ROCM_VERSION}/lib:/opt/rocm-${ROCM_VERSION}/include/hsa \
       -DCMAKE_INSTALL_PREFIX=$INSTALL_PATH  \
       rocm-systems-source/projects/aqlprofile

cmake --build aqlprofile-build --target all --parallel $(nproc)
${SUDO_PACKAGE_INSTALL} cmake --build aqlprofile-build --target install

rm -rf rocm-systems-source aqlprofile-build

${SUDO_MODULE_INSTALL} mkdir -p ${MODULE_PATH}

# Provenance: capture this leaf script's git state for the modulefile
# whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured
# at the top of this script before any cd) so this works even after
# the script has cd'd into a temp build dir. Self-contained: falls
# back to "unknown" when run from a stripped-of-.git context (Docker
# layer, release tarball, or git binary missing).
LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
LEAF_SCRIPT_COMMIT=unknown
LEAF_SCRIPT_DIRTY=unknown
_leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
if [ -d "${_leaf_dir}" ] && command -v git >/dev/null 2>&1 \
   && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
   _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
   [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
   unset _commit
   if [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
      LEAF_SCRIPT_DIRTY=dirty
   else
      LEAF_SCRIPT_DIRTY=clean
   fi
fi
unset _leaf_dir

cat <<-EOF | ${SUDO_MODULE_INSTALL} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: Rocprofiler-sdk")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("ROCm Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("Github Branch: ${GITHUB_BRANCH}")

	local base = "${INSTALL_PATH}"

	prereq("${ROCM_MODULE_NAME}")
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
EOF
