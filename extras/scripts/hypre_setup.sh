#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

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
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus/hypre
BUILD_HYPRE=0
ROCM_VERSION=6.2.0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
AMDGPU_GFXMODEL_INPUT=""
USE_SPACK=0
HYPRE_VERSION="3.1.0"
MPI_MODULE="openmpi"
HYPRE_PATH=/opt/rocmplus-${ROCM_VERSION}/hypre-v${HYPRE_VERSION}
HYPRE_PATH_INPUT=""
# --install-path: parent dir; the script appends hypre-v${HYPRE_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf the prior hypre-v${HYPRE_VERSION} install dir and
# its modulefile BEFORE building. Idempotent if nothing to remove.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so the
# partial install + modulefile are left on disk for post-mortem.
# Together these replace the legacy main_setup.sh `replace_pkg` /
# `PKG_CLEAN_DIRS`/`PKG_CLEAN_MODS` arrays -- which had drifted out
# of sync with the actual install paths during the versioning pass --
# so the install-layout knowledge lives in exactly one place: this
# script. main_setup.sh just threads through `--replace
# ${REPLACE_EXISTING}` and `--keep-failed-installs ${KEEP_FAILED_INSTALLS}`.
REPLACE=0
KEEP_FAILED_INSTALLS=0

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default is $MODULE_PATH "
   echo "  --install-path-no-version [ HYPRE_PATH_INPUT ] default is $HYPRE_PATH "
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), HYPRE_PATH = ROCMPLUS_PATH/hypre-v\${HYPRE_VERSION}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL_INPUT ] default autodetected "
   echo "  --hypre-version [ HYPRE_VERSION ] default is $HYPRE_VERSION "
   echo "  --use-spack [ USE_SPACK ] default is $USE_SPACK "
   echo "  --build-hypre [ BUILD_HYPRE ] default is 0 "
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information "
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--build-hypre")
          shift
          BUILD_HYPRE=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--hypre-version")
          shift
          HYPRE_VERSION=${1}
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
      "--install-path-no-version")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--use-spack")
          shift
          USE_SPACK=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--keep-failed-installs")
          shift
          KEEP_FAILED_INSTALLS=${1}
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
   HYPRE_PATH=${INSTALL_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends hypre-v${HYPRE_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for hypre.
   HYPRE_PATH=${ROCMPLUS_PATH_INPUT}/hypre-v${HYPRE_VERSION}
else
   # override path in case ROCM_VERSION or HYPRE_VERSION has been supplied as input
   HYPRE_PATH=/opt/rocmplus-${ROCM_VERSION}/hypre-v${HYPRE_VERSION}
fi

# ── BUILD_HYPRE=0 short-circuit: operator opt-out ────────────────────
# Replaces the `if [[ "${BUILD_HYPRE}" == "1" ]]; then run_and_log
# hypre ...; fi` wrapper that previously gated this script's entire
# invocation in bare_system/main_setup.sh. Moving the gate inside has
# two effects:
#   * BUILD_HYPRE is now interpreted in exactly one place (here),
#     beside its only consumer; main_setup.sh just threads the value
#     through unconditionally and lets each script decide its own fate.
#   * the per-package summary records a SKIPPED(no-op) line for every
#     opted-out package (vs. the prior silent omission), which makes
#     it obvious from a single log grep what was actually built vs.
#     what the operator turned off.
# Placement: AFTER arg parsing + path resolution (so BUILD_HYPRE has
# its final value and any echo references resolve correctly) and
# BEFORE the --replace block (so --replace 1 + BUILD_HYPRE=0 does NOT
# wipe an existing install -- "don't install" must not be confused
# with "wipe what is there"). Also before the existence-check guard
# and the EXIT-trap install for the same reason. Exits ${NOOP_RC}=43
# so run_and_log classifies this as SKIPPED, not OK.
NOOP_RC=43
if [ "${BUILD_HYPRE}" = "0" ]; then
   echo "[hypre BUILD_HYPRE=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── --replace: remove prior install + modulefile BEFORE building ─────
# Invoked when the operator (or main_setup.sh's --replace-existing 1
# pass-through) wants this version's install dir + ${HYPRE_VERSION}.lua
# wiped before a fresh install. Safe if nothing is there to remove.
# Other versions' installs are NOT touched (multi-version coexistence).
if [ "${REPLACE}" = "1" ]; then
   echo "[hypre --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HYPRE_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${HYPRE_VERSION}.lua"
   ${SUDO} rm -rf "${HYPRE_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${HYPRE_VERSION}.lua"
fi

# ── Existence guard: skip if this version is already installed ───────
# Replaces the `[[ ! -d ${ROCMPLUS}/hypre-v${HYPRE_VERSION} ]]` clause
# that previously gated this script's invocation in
# bare_system/main_setup.sh. Moving the check into the script keeps the
# install-path knowledge in exactly one place (the same HYPRE_PATH /
# HYPRE_VERSION resolved above), which matters because:
#   * --hypre-version on the CLI overrides what main_setup.sh passed,
#     and only the script sees the final value;
#   * multi-component scripts (magma+openblas, netcdf-c/f/pnetcdf,
#     openmpi+xpmem+ucx+ucc, etc.) check ALL of their components here,
#     not just the first one main_setup.sh happened to know about.
# Placement: AFTER the --replace block (so --replace 1 wipes first and
# this check passes through to a real rebuild) and BEFORE the EXIT trap
# install (so the NOOP_RC exit below is not interpreted as a partial
# install and does not trigger fail-cleanup of the install we just
# confirmed is intact). Exits with NOOP_RC=43 (set in the BUILD_HYPRE=0
# block above); main_setup.sh's run_and_log records this as
# SKIPPED(no-op) in the per-package summary.
if [ -d "${HYPRE_PATH}" ]; then
   echo ""
   echo "[hypre existence-check] ${HYPRE_PATH} already installed; skipping."
   echo "                        pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ──────────
# On a non-zero exit (configure error, build error, install error,
# preflight miss, etc.) remove any partial artifacts this script left
# behind so the next sweep starts from a clean state. Skipped when
# --keep-failed-installs 1 (operator wants to inspect the partial
# install for post-mortem). This replaces the `cleanup_pkg` helper +
# PKG_CLEAN_DIRS/PKG_CLEAN_MODS arrays that used to live in
# bare_system/main_setup.sh and that had to be kept in sync with the
# script's install layout by hand. Now the cleanup paths are derived
# from the same HYPRE_PATH / MODULE_PATH / HYPRE_VERSION variables the
# install side uses, so they cannot drift.
_hypre_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hypre fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HYPRE_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${HYPRE_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[hypre fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # 2026-05-05: also clean the local build dir if set (regular non-spack
   # branch puts the source extraction under /tmp via mktemp; see
   # comment-block above the HYPRE_BUILD_DIR=mktemp call). The spack
   # branch installs its own EXIT trap that handles SPACK_USER_*
   # dirs as well as its own HYPRE_BUILD_DIR; that trap REPLACES this
   # one so this block does not run on the spack code path.
   if [ -n "${HYPRE_BUILD_DIR:-}" ] && [ -d "${HYPRE_BUILD_DIR}" ]; then
      ${SUDO:-sudo} rm -rf "${HYPRE_BUILD_DIR}"
   fi
   return ${rc}
}
trap _hypre_on_exit EXIT

echo ""
echo "==================================="
echo "Starting HYPRE Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HYPRE: $BUILD_HYPRE"
echo "HYPRE_VERSION: $HYPRE_VERSION"
echo "HYPRE_PATH: $HYPRE_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi


AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_HYPRE}" = "0" ]; then

   echo "HYPRE will not be built, according to the specified value of BUILD_HYPRE"
   echo "BUILD_HYPRE: $BUILD_HYPRE"
   exit

else
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

   if [ -f ${CACHE_FILES}/hypre-v${HYPRE_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HYPRE"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # hypre-v${HYPRE_VERSION}.tgz and contain a top-level directory
      # hypre-v${HYPRE_VERSION}/ so it lands directly at ${HYPRE_PATH}
      # when extracted under /opt/rocmplus-X.
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/hypre-v${HYPRE_VERSION}.tgz
      chown -R root:root ${HYPRE_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/hypre-v${HYPRE_VERSION}.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building HYPRE"
      echo "============================"
      echo ""

      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # don't use sudo if user has write access to install path
      if [ -d "$HYPRE_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${HYPRE_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${HYPRE_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${HYPRE_PATH}
      fi

      HYPRE_PATH_ORIGINAL=$HYPRE_PATH
      # ------------ Installing HYPRE

      if [[ $USE_SPACK == 1 ]]; then

         echo " WARNING: installing hypre with spack: the build is a work in progress, fails can happen..."

         # PKG_SUDO: apt needs root regardless of install-path SUDO.
         # The previous `[[ ${SUDO} != "" ]]` guard skipped libssl-dev
         # whenever the install path was admin-writable, leading to a
         # spack build that silently failed when libevent couldn't
         # find openssl. See openmpi_setup.sh / audit_2026_05_01.md
         # Issue 2.
         PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
         ${PKG_SUDO} apt-get update
         ${PKG_SUDO} apt-get install -y libssl-dev unzip

         # Spack user-scope isolation: see scorep_setup.sh for full
         # rationale. Per-job throwaway dirs keep `spack external
         # find --all` from polluting ~/.spack/packages.yaml across
         # rocm versions and prevent any stale user-scope
         # install_tree.root from over-riding the defaults edit below.
         SPACK_USER_CONFIG_PATH=$(mktemp -d -t spack-user-config.XXXXXX)
         SPACK_USER_CACHE_PATH=$(mktemp -d -t spack-user-cache.XXXXXX)
         export SPACK_USER_CONFIG_PATH SPACK_USER_CACHE_PATH

         # Spack clone goes under /tmp (compute-node local disk) so
         # concurrent rocm-version builds don't race on ${PWD}/spack
         # in the shared HPCTrainingDock checkout (observed
         # 2026-04-30: 7952's scorep_setup.sh hit "destination path
         # 'spack' already exists" because 7954 created it earlier).
         # EXIT trap covers the build dir + the two spack user-scope
         # dirs above.
         HYPRE_BUILD_DIR=$(mktemp -d -t hypre-build.XXXXXX)
         trap '${SUDO:-sudo} rm -rf "${HYPRE_BUILD_DIR:-/nonexistent}" "${SPACK_USER_CONFIG_PATH:-/nonexistent}" "${SPACK_USER_CACHE_PATH:-/nonexistent}"' EXIT
         cd "${HYPRE_BUILD_DIR}"

         git clone https://github.com/spack/spack.git

         # load spack environment
         source spack/share/spack/setup-env.sh

         # find already installed libs for spack
         spack external find --all

         spack install rocm-core@${ROCM_VERSION} rocm-cmake@${ROCM_VERSION} hipblas-common@${ROCM_VERSION} rocthrust@${ROCM_VERSION} rocprim@${ROCM_VERSION}

         # change spack install dir for Hypre
         sed -i 's|$spack/opt/spack|'"${HYPRE_PATH}"'|g' spack/etc/spack/defaults/base/config.yaml 

         # install hypre with spack
         #spack install hypre+rocm+rocblas+unified-memory
         spack install hypre@$HYPRE_VERSION+rocm+unified-memory+gpu-aware-mpi amdgpu_target=$AMDGPU_GFXMODEL

         # get hypre install dir created by spack
         HYPRE_PATH=$(spack location -i hypre)

         # HYPRE_BUILD_DIR (under /tmp, contains the spack clone) is
         # removed by the EXIT trap above.

      else

         # 2026-05-05: isolate the regular (non-spack) hypre build under
         # /tmp (compute-node local disk) instead of PWD (the shared NFS
         # HPCTrainingDock checkout). Without this, three concurrent
         # rocm-version sweeps that hit the hypre step at the same time
         # collide on a single ~/HPCTrainingDock/hypre-${HYPRE_VERSION}/
         # directory and corrupt each other's source trees. Observed in
         # the overnight 8221/8222/8223 sweep (2026-05-05 ~05:52 UTC):
         #   - 8221 (sh5-pl1-s12-09): `rm -rf hypre-3.1.0` failed with
         #     "Directory not empty" because 8222 was concurrently
         #     extracting into the same directory; rc=1.
         #   - 8222 (sh5-pl1-s12-12): later `sed -i IJ_mv/IJMatrix_parcsr_device.c`
         #     hit ENOENT because 8221's partial rm had unlinked the file
         #     after 8222's tar wrote it; rc=2.
         #   - 8223 (sh5-pl1-s12-33): hit hypre 7 min later (after the
         #     other two failed and their fail-cleanup traps fired);
         #     PWD was clean by then; succeeded.
         # Per-job /tmp dir gives each sweep its own scratch tree, so
         # rm/wget/tar/cd/sed never see another job's intermediate state.
         # The spack branch above (line ~412) already used this pattern;
         # extending to the regular branch closes the gap. Cleanup
         # consolidated into _hypre_on_exit (which also handles install
         # rollback), see the trap registration earlier in this script.
         HYPRE_BUILD_DIR=$(mktemp -d -t hypre-build.XXXXXX)
         cd "${HYPRE_BUILD_DIR}"

         ${SUDO} rm -rf v${HYPRE_VERSION}.tar.gz hypre-${HYPRE_VERSION}
         wget -q https://github.com/hypre-space/hypre/archive/refs/tags/v${HYPRE_VERSION}.tar.gz
         tar -xzf v${HYPRE_VERSION}.tar.gz
         cd hypre-${HYPRE_VERSION}/src

         # ROCm-build patches. Two classes:
         #   (a) HYPRE_THRUST_IDENTITY -> thrust::identity<T>() inlining.
         #       Verified the macro definition is byte-identical in 3.0.0
         #       and 3.1.0 (utilities/_hypre_utilities.hpp:451-453,
         #       utilities/device_utils.h:233-235), so these 9 string
         #       substitutions remain valid across both versions.
         #   (b) Commenting out the user-defined __syncwarp() shim that
         #       collides with ROCm's own. In 3.0.0 the shim sits at
         #       _hypre_utilities.hpp:1481-1484; in 3.1.0 the file was
         #       refactored (now 2869 lines vs 3704; line numbers shifted)
         #       and the patch needs to be re-validated. v3.1.0 was
         #       advertised with "rocm 7.0 support" added upstream
         #       (https://github.com/hypre-space/hypre/releases/tag/v3.1.0),
         #       which suggests the conflict may have been resolved
         #       upstream. Apply the line-range patch only for 3.0.0;
         #       for 3.1.0 (and beyond) we skip it and let the build
         #       fail loudly if the conflict is back -- at which point
         #       we'll patch the new line range with a fresh diagnosis
         #       rather than blindly comment out random lines.
         if [ "${HYPRE_VERSION}" = "3.0.0" ]; then
            sed -i -e '1481,1484s!^!//!' utilities/_hypre_utilities.hpp
         else
            echo "hypre: skipping legacy 1481-1484 __syncwarp comment-out patch for HYPRE_VERSION=${HYPRE_VERSION}"
            echo "hypre: (line numbers shifted upstream; if build fails on __syncwarp redefinition, re-add a version-correct patch here)"
         fi

         sed -i -e 's/HYPRE_THRUST_IDENTITY(char)/thrust::identity<char>()/' seq_mv/csr_spgemm_device_symbl.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(char)/thrust::identity<char>()/' IJ_mv/IJMatrix_parcsr_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(char)/thrust::identity<char>()/' IJ_mv/IJVector_parcsr_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Int)/thrust::identity<HYPRE_Int>()/' parcsr_mv/par_csr_fffc_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Int)/thrust::identity<HYPRE_Int>()/' parcsr_ls/ame.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Int)/thrust::identity<HYPRE_Int>()/' parcsr_ls/par_coarsen_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Int)/thrust::identity<HYPRE_Int>()/' parcsr_ls/par_mod_multi_interp_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Complex)/thrust::identity<HYPRE_Complex>()/' IJ_mv/IJMatrix_parcsr_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Complex)/thrust::identity<HYPRE_Complex>()/' IJ_mv/IJVector_parcsr_device.c
         sed -i -e 's/HYPRE_THRUST_IDENTITY(HYPRE_Complex)/thrust::identity<HYPRE_Complex>()/' parcsr_ls/ams.c

         mkdir build && cd build

	 cmake -DCMAKE_INSTALL_PREFIX=$HYPRE_PATH -DHYPRE_ENABLE_MIXEDINT=ON -DHYPRE_ENABLE_MPI=ON -DHYPRE_ENABLE_OPENMP=ON \
                -DHYPRE_BUILD_TESTS=ON -DHYPRE_ENABLE_HIP=ON -DCMAKE_HIP_ARCHITECTURES="$AMDGPU_GFXMODEL" -DHYPRE_ENABLE_UMPIRE=OFF \
                -DHYPRE_ENABLE_GPU_PROFILING=ON -DHYPRE_ENABLE_GPU_AWARE_MPI=ON -DBUILD_SHARED_LIBS=ON -DHYPRE_ENABLE_UNIFIED_MEMORY=ON ..

         make -j
         ${SUDO} make install
         cd ../../..
         rm -rf hypre-${HYPRE_VERSION} v${HYPRE_VERSION}.tar.gz

      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
            ${SUDO} find ${HYPRE_PATH_ORIGINAL} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${HYPRE_PATH_ORIGINAL}
      fi

      module unload ${ROCM_MODULE_NAME}
      module unload ${MPI_MODULE}

   fi

   # Create a module file for hypre
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

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
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/$HYPRE_VERSION.lua
	whatis("HYPRE - solver package")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${HYPRE_PATH}"

	prereq("${ROCM_MODULE_NAME}")
	load("${MPI_MODULE}")
	setenv("HYPRE_PATH", base)
	prepend_path("PATH",pathJoin(base, "bin"))
	prepend_path("PATH","${HYPRE_PATH}/bin")
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH","/usr/lib")
EOF

fi
