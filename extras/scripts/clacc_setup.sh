#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

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
      "--build-clacc-latest")
          shift
          BUILD_CLACC_LATEST=${1}
          ;;
      *)
         echo "Unknown option: ${1}"
         exit 1
         ;;
   esac
   n=$((${n} + 1))
   shift
done

if [ "$(printf '%s\n' "6.1.0" "${ROCM_VERSION}" | sort --version-sort | head -n1)" = "6.1.0" ]; then
   # C++ Standard Parallel is included in the released compiler
   exit;
fi

echo ""
echo "==================================="
echo "Starting CLACC Install with"
echo "BUILD_CLACC_LATEST: $BUILD_CLACC_LATEST"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

if [ "${BUILD_CLACC_LATEST}" = "1" ]; then
   if [ -f /opt/rocmplus-${ROCM_VERSION}/clacc_clang.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached CLACC"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf clacc_clang.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/clacc_clang
      rm clacc_clang.tgz
   else
      echo ""
      echo "============================"
      echo " Building CLACC"
      echo "============================"
      echo ""

      CLACC_BUILD_DIR=$(pwd)
      git clone -b clacc/main https://github.com/llvm-doe-org/llvm-project.git clacc-clang

      cd clacc-clang

      mkdir llvm-build
      cd llvm-build
      cmake -G Ninja -DCMAKE_INSTALL_PREFIX=/opt/rocmplus-${ROCM_VERSION}/clacc_clang \
        -DCMAKE_BUILD_TYPE=Release               \
        -DLLVM_ENABLE_PROJECTS="clang;flang;lld" \
        -DLLVM_ENABLE_RUNTIMES=openmp            \
        -DLLVM_TARGETS_TO_BUILD="host;AMDGPU"    \
        -DLIBOMPTARGET_AMDGCN_GFXLIST="${AMDGPU_GFXMODEL}" \
        -DLLVM_PARALLEL_COMPILE_JOBS=20          \
        -DLLVM_PARALLEL_LINK_JOBS=10             \
         ../llvm
       ninja -j20 -l10
       ninja install

       rm -rf ${CLACC_BUILD_DIR}/clacc-clang
   fi

   # In either case, create a module file for CLACC compiler
   export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/clacc

   ${SUDO} mkdir -p ${MODULE_PATH}

   # Derive ROCM_MODULE_NAME from the actual ROCM_PATH basename so RC
   # trees (rocm-therock-*, rocm-afar-*) match their loaded module
   # name instead of the SDK numeric. Falls back to the rocm/<version>
   # form for direct standalone invocation where ROCM_PATH is unset.
   if [[ -n "${ROCM_PATH:-}" ]]; then
      _rp_bn="${ROCM_PATH##*/}"
      ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
      unset _rp_bn
   else
      ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
   fi

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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/clang-17.0.0.lua
	whatis("Clang OpenMP Compiler with CLACC version 17.0-0 based on LLVM")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "/opt/rocmplus-${ROCM_VERSION}/clacc_clang"

	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("CC", pathJoin(base, "bin/clang"))
	setenv("CXX", pathJoin(base, "bin/clang++"))
	setenv("FC", pathJoin(base, "bin/flang-new"))
	setenv("F77", pathJoin(base, "bin/flang-new"))
	setenv("F90", pathJoin(base, "bin/flang-new"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "libexec"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("MANPATH", pathJoin(base, "man"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prereq("${ROCM_MODULE_NAME}")
	family("compiler")
EOF
fi
