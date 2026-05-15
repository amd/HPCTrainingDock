#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi

ROCM_VERSION=6.1.0
BUILD_GCC_LATEST=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          ;;
      "--build-gcc-latest")
          shift
          BUILD_GCC_LATEST=${1}
          ;;
      *)
         echo "Unknown option: ${1}"
         exit 1
         ;;
   esac
   n=$((${n} + 1))
   shift
done

export GCC_VERSION_NUMBER=13.2.0
export GCC_VERSION=gcc-${GCC_VERSION_NUMBER}

echo ""
echo "==================================="
echo "Starting AMD GCC Latest Install with"
echo "BUILD_GCC_LATEST: $BUILD_GCC_LATEST"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "GCC_VERSION: $GCC_VERSION"
echo "==================================="
echo ""

if [ "${BUILD_GCC_LATEST}" = "1" ] ; then
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if  [ -f ${CACHE_FILES}/${GCC_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached AMD GCC Latest"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xpzf ${CACHE_FILES}/${GCC_VERSION}.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/${GCC_VERSION}.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building AMD GCC Latest"
      echo "============================"
      echo ""

      export LLVM_DIR=llvm-project-llvmorg-13.0.1
      export LLVM_DIR_SHORT=llvmorg-13.0.1

      # Set install directory
      export DEST=/opt/rocmplus-${ROCM_VERSION}/${GCC_VERSION}
      chmod a+w /opt
      ${SUDO} mkdir $DEST

      # Derive the rocm modulefile token to (re-)load. Three sources, in
      # decreasing order of authority:
      #   1. LMOD's LOADEDMODULES: the literal modulefile name currently
      #      loaded (e.g. rocm/therock-afar-23.2.1). Only source that
      #      handles the therock-afar dual scheme where install dir is
      #      rocm-therock-afar-<NUMERIC> but the module is keyed on the
      #      release tag (rocm/therock-afar-<RELEASE>).
      #   2. ROCM_PATH basename: install-dir basename minus the `rocm-`
      #      prefix. Correct for regular releases + afar (install-dir
      #      basename == module name) but wrong for therock-afar.
      #   3. rocm/${ROCM_VERSION}: standalone-invocation fallback when
      #      neither LOADEDMODULES nor ROCM_PATH is populated.
      ROCM_MODULE_NAME=""
      if [[ -n "${LOADEDMODULES:-}" ]]; then
         _OLD_IFS="${IFS}"; IFS=":"
         for _m in ${LOADEDMODULES}; do
            case "${_m}" in
               rocm/*) ROCM_MODULE_NAME="${_m}"; break ;;
            esac
         done
         IFS="${_OLD_IFS}"; unset _OLD_IFS _m
      fi
      if [[ -z "${ROCM_MODULE_NAME}" ]]; then
         if [[ -n "${ROCM_PATH:-}" ]]; then
            _rp_bn="${ROCM_PATH##*/}"
            ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
            unset _rp_bn
         else
            ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
         fi
      fi

      # modules
      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh
      module load ${ROCM_MODULE_NAME}

      wget -q https://github.com/llvm/llvm-project/archive/refs/tags/${LLVM_DIR_SHORT}.tar.gz
      tar xf ${LLVM_DIR_SHORT}.tar.gz
      mkdir builds && cd builds
      cmake -D 'LLVM_TARGETS_TO_BUILD=X86;AMDGPU' -D LLVM_ENABLE_PROJECTS=lld ../${LLVM_DIR}/llvm && \
      make -j 12 || exit 1

      #On n'installe pas mais on déplace en les renommant certains binaires.
      mkdir -p $DEST/amdgcn-amdhsa/bin
      cp -a ./bin/llvm-ar $DEST/amdgcn-amdhsa/bin/ar
      cp -a ./bin/llvm-ar $DEST/amdgcn-amdhsa/bin/ranlib
      cp -a ./bin/llvm-mc $DEST/amdgcn-amdhsa/bin/as
      cp -a ./bin/llvm-nm $DEST/amdgcn-amdhsa/bin/nm
      cp -a ./bin/lld $DEST/amdgcn-amdhsa/bin/ld
      cd ..

      rm -rf builds
      rm -rf ${LLVM_DIR} ${LLVM_DIR_SHORT}

      git clone https://sourceware.org/git/newlib-cygwin.git newlib
      git clone https://gcc.gnu.org/git/gcc.git gcc
      cd gcc
      git checkout releases/${GCC_VERSION}
      ./contrib/download_prerequisites

      target=$(./config.guess)
      echo "Target ",$target

      ln -s ../newlib/newlib ./newlib
      mkdir build && cd build
      ../configure --prefix=$DEST --target=amdgcn-amdhsa --enable-languages=c,c++,lto,fortran --disable-sjlj-exceptions --with-newlib \
                   --enable-as-accelerator-for=$target --with-build-time-tools=$DEST/amdgcn-amdhsa/bin --disable-libquadmath \
                   --disable-bootstrap
      make -j 16
      make install
      cd ..
      rm newlib

      mkdir buildhost && cd buildhost && \
      ../configure --prefix=$DEST --build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu --target=x86_64-pc-linux-gnu --disable-multilib \
      --enable-offload-targets=amdgcn-amdhsa=$DEST/amdgcn-amdhsa --disable-bootstrap

      make -j 16
      ${SUDO} make install
      cd ..

      rm -rf build buildhost
      cd ..
      rm -rf gcc newlib ${LLVM_DIR_SHORT}.tar.gz

      chmod a-w /opt
   fi

   # In either case, create a module file for AMD-GCC compiler
   export MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/amd-gcc

   mkdir -p ${MODULE_PATH}

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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/13.2.0.lua
	whatis("Custom built GCC Version 13.2.0 compiler")
	whatis("This version enables offloading to AMD GPUs")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "/opt/rocmplus-${ROCM_VERSION}/gcc-13.2.0"

	setenv("CC", pathJoin(base, "bin/gcc"))
	setenv("CXX", pathJoin(base, "bin/g++"))
	setenv("F77", pathJoin(base, "bin/gfortran"))
	setenv("F90", pathJoin(base, "bin/gfortran"))
	setenv("FC", pathJoin(base,"bin/gfortran"))
	append_path("INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
	prereq("${ROCM_MODULE_NAME}")
	family("compiler")
EOF
fi
