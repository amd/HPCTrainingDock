#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          ;;
      "--build-llvm-latest")
          shift
          BUILD_LLVM_LATEST=${1}
          ;;
      *)
         echo "Unknown option: ${1}"
         exit 1
         ;;
   esac
   n=$((${n} + 1))
   shift
done

echo ""
echo "==================================="
echo "Starting LLVM Latest Install with"
echo "BUILD_LLVM_LATEST: $BUILD_LLVM_LATEST"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

if [ "${BUILD_LLVM_LATEST}" = "1" ]; then
   if [ -f /opt/rocmplus-${ROCM_VERSION}/llvm-latest.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing LLVM Latest"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf llvm-latest.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/llvm-latest
      rm /opt/rocmplus-${ROCM_VERSION}/llvm-latest.tgz
   else
      echo ""
      echo "============================"
      echo " Building LLVM Latest"
      echo "============================"
      echo ""

      INSTALL_DIR=/opt/rocmplus-${ROCM_VERSION}/llvm-latest
      LLVM_BUILD_DIR=$(pwd)
      git clone https://github.com/llvm/llvm-project.git
      cd llvm-project

      GITSHA=a40bada91aeda276a772acfbcae6e8de26755a11
      git checkout $GITSHA
      wget -q https://raw.githubusercontent.com/ROCm/roc-stdpar/main/data/patches/LLVM/CLANG_LLVM.patch
      patch -p1 < CLANG_LLVM.patch

      mkdir llvm-build
      cd llvm-build
      cmake -G Ninja -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="clang;lld;flang" \
        -DLLVM_ENABLE_RUNTIMES="libcxxabi;libcxx;openmp" \
        -DLLVM_TARGETS_TO_BUILD="host;AMDGPU"    \
        -DLIBOMPTARGET_AMDGCN_GFXLIST="${AMDGPU_GFXMODEL}" \
        -DLLVM_PARALLEL_COMPILE_JOBS=20          \
        -DLLVM_PARALLEL_LINK_JOBS=10             \
         ../llvm

      ninja -j20 -l10
      ninja install

      cd ${INSTALL_DIR}/include
      wget -q https://raw.githubusercontent.com/ROCm/roc-stdpar/main/include/hipstdpar_lib.hpp

      rm -rf ${LLVM_BUILD_DIR}/llvm-project
   fi

   # In either case, create a module file for llvm-latest compiler
   export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/llvm-latest

   ${SUDO} mkdir -p ${MODULE_PATH}

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

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/gcc11_hipstdpar.lua
	whatis("LLVM latest compiler version with stdpar patch applied")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "/opt/rocmplus-${ROCM_VERSION}/llvm-latest"

	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("CC", pathJoin(base, "bin/clang"))
	setenv("CXX", pathJoin(base, "bin/clang++"))
	setenv("FC", pathJoin(base, "bin/flang"))
	setenv("F77", pathJoin(base, "bin/flang"))
	setenv("F90", pathJoin(base, "bin/flang"))
	setenv("STDPAR_PATH", pathJoin(base, "include"))
	setenv("STDPAR_CXX", pathJoin(base, "bin/clang++"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "libexec"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("MANPATH", pathJoin(base, "man"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prereq("rocm/${ROCM_VERSION}")
	family("compiler")
EOF
fi
