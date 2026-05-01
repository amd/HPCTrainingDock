#!/bin/bash

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# ── Preflight: declare and load required Lmod modules ─────────────────
# Inlined (formerly bare_system/lib/preflight.sh) so this script is
# self-contained and can be copied/run standalone. preflight_modules
# loads each module in order; on the first failure it prints the Lmod
# diagnostic and returns MISSING_PREREQ_RC=42, which the parent
# main_setup.sh re-classifies as SKIPPED rather than FAILED.
MISSING_PREREQ_RC=42
if ! type module >/dev/null 2>&1; then
   [ -r /etc/profile.d/lmod.sh ]            && . /etc/profile.d/lmod.sh
   [ -r /usr/share/lmod/lmod/init/bash ]    && . /usr/share/lmod/lmod/init/bash
fi
preflight_modules() {
   [ "$#" -eq 0 ] && return 0
   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command not available; needed:$(printf ' %s' "$@")" >&2
      return ${MISSING_PREREQ_RC}
   fi
   echo "preflight: required modules:$(printf ' %s' "$@")"
   local m err
   err=$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)
   for m in "$@"; do
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         [ -s "${err}" ] && sed 's/^/  module> /' "${err}" >&2
         rm -f "${err}"
         return ${MISSING_PREREQ_RC}
      fi
   done
   rm -f "${err}"
   echo "preflight: all required modules loaded."
}

# Variables controlling setup process
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus/kokkos
BUILD_KOKKOS=0
ROCM_VERSION=6.2.0
# Kokkos AMD GPU arch flags. Defaults are OFF; turned ON per-arch below
# from semicolon-separated AMDGPU_GFXMODEL. This cluster's gfx942 nodes
# are MI300A (APU mode), hence the _APU variant; on MI300X dGPU clusters
# this should be Kokkos_ARCH_AMD_GFX942 (no _APU). The legacy gfx900 /
# Kokkos_ARCH_VEGA90A path was removed (not present on this cluster, and
# the variable was never plumbed into the cmake call anyway).
KOKKOS_ARCH_AMD_GFX90A="OFF"
KOKKOS_ARCH_AMD_GFX942_APU="OFF"
KOKKOS_VERSION="4.7.02"
KOKKOS_PATH=/opt/rocmplus-${ROCM_VERSION}/kokkos
KOKKOS_PATH_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ KOKKOS_PATH ] default $KOKKOS_PATH"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL_INPUT ] default is autodetected "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --kokkos-version [ KOKKOS_VERSION ] default $KOKKOS_VERSION (used as git branch/tag)"
   echo "  --build-kokkos [ BUILD_KOKKOS ], set to 1 to build Kokkos, default is 0"
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
      "--build-kokkos")
          shift
          BUILD_KOKKOS=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          KOKKOS_PATH_INPUT=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--kokkos-version")
          shift
          KOKKOS_VERSION=${1}
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

if [ "${KOKKOS_PATH_INPUT}" != "" ]; then
   KOKKOS_PATH=${KOKKOS_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   KOKKOS_PATH=/opt/rocmplus-${ROCM_VERSION}/kokkos
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

echo ""
echo "==================================="
echo "Starting Kokkos Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_KOKKOS: $BUILD_KOKKOS"
echo "KOKKOS_PATH:  $KOKKOS_PATH"
echo "MODULE_PATH:  $MODULE_PATH"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "==================================="
echo ""

if [ "${BUILD_KOKKOS}" = "0" ]; then

   echo "Kokkos will not be built, according to the specified value of BUILD_KOKKOS"
   echo "BUILD_KOKKOS: $BUILD_KOKKOS"
   exit

else
   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Kokkos"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/kokkos.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/kokkos
      ${SUDO} rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos.tgz

   else
      echo ""
      echo "============================"
      echo " Building Kokkos"
      echo "============================"
      echo ""

      # don't use sudo if user has write access to install path
      if [ -d "$KOKKOS_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${KOKKOS_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${KOKKOS_PATH}

      # Parse semicolon-separated AMDGPU_GFXMODEL. main_setup.sh passes
      # multi-arch values like "gfx90a;gfx942" by design (see
      # bare_system/main_setup.sh:79); the prior strict-equality chain
      # matched none of them on this cluster and left every Kokkos_ARCH_*
      # empty, which made Kokkos 4.7's check_amd_apu() autodetection
      # fire and fail. Audited as the kokkos rc=1 cause in
      # slurm-7950-rocmplus-7.0.2.out (log_kokkos line 53). Multi-arch
      # builds are supported by Kokkos 4.5+.
      case ";${AMDGPU_GFXMODEL};" in
         *";gfx90a;"*) KOKKOS_ARCH_AMD_GFX90A="ON" ;;
      esac
      case ";${AMDGPU_GFXMODEL};" in
         *";gfx942;"*) KOKKOS_ARCH_AMD_GFX942_APU="ON" ;;
      esac

      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # Build everything (source clone + build tree) under /tmp on the
      # compute node's local disk so failed configures don't leave a
      # kokkos/ tree polluting the HPCTrainingDock checkout, and so the
      # multi-arch -> single-arch fallback below can wipe the build dir
      # cheaply. Mirrors the scorep S6.C / openmpi S7.B pattern. EXIT
      # trap covers cleanup even on `set -e` aborts.
      KOKKOS_BUILD_ROOT=$(mktemp -d -t kokkos-build.XXXXXX)
      trap '[ -n "${KOKKOS_BUILD_ROOT:-}" ] && rm -rf "${KOKKOS_BUILD_ROOT}"' EXIT
      cd "${KOKKOS_BUILD_ROOT}"

      git clone --branch ${KOKKOS_VERSION} https://github.com/kokkos/kokkos
      cd kokkos

      ${SUDO} mkdir build
      cd build

      HIP_MALLOC_ASYNC_OFF=""
      if [ "$(printf '%s\n' "7.0.0" "$ROCM_VERSION" | sort -V | head -n1)" = "7.0.0" ]; then
         echo "ROCM_VERSION is >= 7.0.0"
         HIP_MALLOC_ASYNC_OFF="-DKokkos_ENABLE_IMPL_HIP_MALLOC_ASYNC=OFF"
      fi

      # Use amdclang++ instead of hipcc.  hipcc is a deprecated wrapper around
      # amdclang++ whose new offload driver produces fat binaries that CMake
      # cannot parse for CXX ABI info.  That failure left CMAKE_SIZEOF_VOID_P
      # and CMAKE_LIBRARY_ARCHITECTURE unset, which broke find_library for
      # system libs like libdl and caused a hardcoded /usr/include to leak
      # into KokkosTargets.cmake.  It also prevented FindOpenMP from setting
      # link libraries.  amdclang++ avoids all of these issues.
      #
      # sudo strips LD_LIBRARY_PATH even with -E, so pass it explicitly.
      SUDO_ENV=""
      if [ -n "${SUDO}" ]; then
         SUDO_ENV="${SUDO} -E env PATH=$PATH LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
      fi

      # Wrap cmake configure in a function so we can retry with reduced
      # flags if multi-arch fails. Only configure is retried -- a partial
      # build from a failed configure isn't reusable; the wipe-and-retry
      # path below ensures the second attempt sees a virgin tree.
      kokkos_cmake_configure() {
         local gpu_targets="$1"
         ${SUDO_ENV} cmake -DCMAKE_INSTALL_PREFIX=${KOKKOS_PATH} \
                       -DCMAKE_PREFIX_PATH=${ROCM_PATH} \
                       -DKokkos_ENABLE_SERIAL=ON \
                       -DKokkos_ENABLE_HIP=ON \
                       ${HIP_MALLOC_ASYNC_OFF} \
                       -DKokkos_ENABLE_OPENMP=ON \
                       -DKokkos_ARCH_AMD_GFX90A=${KOKKOS_ARCH_AMD_GFX90A} \
                       -DKokkos_ARCH_AMD_GFX942_APU=${KOKKOS_ARCH_AMD_GFX942_APU} \
                       -DKokkos_ARCH_ZEN4=ON \
                       -DGPU_TARGETS="${gpu_targets}" \
                       -DCMAKE_CXX_COMPILER=${ROCM_PATH}/llvm/bin/amdclang++ ..
      }

      # Attempt 1: multi-arch. Some Kokkos / CMake combinations reject
      # combos that worked in prior versions; the fallback below retries
      # with only the first model from AMDGPU_GFXMODEL.
      set +e
      kokkos_cmake_configure "${AMDGPU_GFXMODEL}"
      cmake_rc=$?
      set -e

      if [ ${cmake_rc} -ne 0 ]; then
         FIRST_ARCH="${AMDGPU_GFXMODEL%%;*}"
         echo ""
         echo "============================"
         echo " Multi-arch cmake FAILED (rc=${cmake_rc})"
         echo " Falling back to single-arch: ${FIRST_ARCH}"
         echo "============================"
         echo ""
         KOKKOS_ARCH_AMD_GFX90A="OFF"
         KOKKOS_ARCH_AMD_GFX942_APU="OFF"
         case "${FIRST_ARCH}" in
            gfx90a) KOKKOS_ARCH_AMD_GFX90A="ON" ;;
            gfx942) KOKKOS_ARCH_AMD_GFX942_APU="ON" ;;
            *)
               echo "ERROR: Unrecognized first arch '${FIRST_ARCH}' in" >&2
               echo "       AMDGPU_GFXMODEL='${AMDGPU_GFXMODEL}'." >&2
               exit 1
               ;;
         esac
         # Wipe the failed-configure build dir for a clean retry. cd-out,
         # rm-rf, mkdir, cd-back so cmake sees a virgin tree (CMakeCache
         # in particular taints retries if left in place).
         cd ..
         ${SUDO} rm -rf build
         ${SUDO} mkdir build
         cd build
         kokkos_cmake_configure "${FIRST_ARCH}"
      fi

      ${SUDO_ENV} make -j
      ${SUDO_ENV} make install

      # Cleanup of ${KOKKOS_BUILD_ROOT} (source clone + build tree) is
      # handled by the EXIT trap registered above. cd to / so subsequent
      # module-file generation isn't running from a dir about to be
      # removed.
      cd /

      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for kokkos
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

   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${KOKKOS_VERSION}.lua
        whatis("Kokkos version ${KOKKOS_VERSION} - Performance Portability Language")

        prereq("rocm/${ROCM_VERSION}")
        prepend_path("PATH","${KOKKOS_PATH}")
        setenv("Kokkos_ROOT","${KOKKOS_PATH}")
        setenv("Kokkos_DIR","${KOKKOS_PATH}/lib/cmake/Kokkos")
        setenv("HSA_XNACK","1")
EOF

fi
