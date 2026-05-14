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
MODULE_PATH=/etc/lmod/modules/ROCmPlus/elpa
BUILD_ELPA=0
ROCM_VERSION=6.2.0
# ELPA_VERSION is a label only -- the actual checkout is pinned to a
# specific commit on a development branch (master_pre_stage) because
# upstream has not cut a numbered release that includes the AMD GPU
# kernels we need. The default version string embeds the short commit
# so the modulefile name is unambiguous; --elpa-version overrides it.
ELPA_VERSION="master-c7234ec"
ELPA_GIT_REPO="https://gitlab.mpcdf.mpg.de/elpa/elpa.git"
ELPA_GIT_BRANCH="master_pre_stage"
ELPA_GIT_COMMIT="c7234ecf26a51041946df4d9640214f2943abf06"
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/elpa-v${ELPA_VERSION}
INSTALL_PATH_INPUT=""
# --install-path: parent dir; the script appends elpa-v${ELPA_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over
# --install-path when both are set, for callers that need exact control
# of the final install directory.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf prior install dir + ${ELPA_VERSION}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"
MPI_MODULE="openmpi"
# ELPA needs ScaLAPACK + reference BLAS/LAPACK at link time (see the
# SCALAPACK_LDFLAGS configure arg below). The petsc module is the
# canonical source on this stack -- it sets PETSC_PATH and ships
# libscalapack/libflapack/libfblas under ${PETSC_PATH}/lib. The petsc
# modulefile also load()s the MPI module so we get both transitively.
PETSC_MODULE="petsc"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

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
   echo "  WARNING: when selecting the module to supply to --mpi-module, make sure it sets the MPI_PATH environment variable"
   echo "  WARNING: when selecting the module to supply to --petsc-module, make sure it sets the PETSC_PATH environment variable"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path-no-version [ INSTALL_PATH_INPUT ] default $INSTALL_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), INSTALL_PATH = ROCMPLUS_PATH/elpa-v\${ELPA_VERSION}"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --petsc-module [ PETSC_MODULE ] default $PETSC_MODULE"
   echo "  --elpa-version [ ELPA_VERSION ] default $ELPA_VERSION"
   echo "  --elpa-git-branch [ ELPA_GIT_BRANCH ] default $ELPA_GIT_BRANCH"
   echo "  --elpa-git-commit [ ELPA_GIT_COMMIT ] default $ELPA_GIT_COMMIT"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --build-elpa [ BUILD_ELPA ] default is 0"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: this usage information"
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
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--build-elpa")
          shift
          BUILD_ELPA=${1}
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
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--petsc-module")
          shift
          PETSC_MODULE=${1}
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
      "--elpa-version")
          shift
          ELPA_VERSION=${1}
          reset-last
          ;;
      "--elpa-git-branch")
          shift
          ELPA_GIT_BRANCH=${1}
          reset-last
          ;;
      "--elpa-git-commit")
          shift
          ELPA_GIT_COMMIT=${1}
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
   INSTALL_PATH=${INSTALL_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends elpa-v${ELPA_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for elpa.
   INSTALL_PATH=${ROCMPLUS_PATH_INPUT}/elpa-v${ELPA_VERSION}
else
   # override path in case ROCM_VERSION or ELPA_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/elpa-v${ELPA_VERSION}
fi

# ── BUILD_ELPA=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_ELPA}" = "0" ]; then
   echo "[elpa BUILD_ELPA=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── --replace: remove prior install + modulefile BEFORE building ─────
if [ "${REPLACE}" = "1" ]; then
   echo "[elpa --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${ELPA_VERSION}.lua"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${ELPA_VERSION}.lua"
fi

# ── Existence guard: skip if already installed ───────────────────────
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[elpa existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                       pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

echo ""
echo "==================================="
echo "Starting ELPA Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_ELPA: $BUILD_ELPA"
echo "ELPA_VERSION: $ELPA_VERSION"
echo "ELPA_GIT_BRANCH: $ELPA_GIT_BRANCH"
echo "ELPA_GIT_COMMIT: $ELPA_GIT_COMMIT"
echo "Installing ELPA in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "MPI_MODULE: $MPI_MODULE"
echo "PETSC_MODULE: $PETSC_MODULE"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

# Build the --offload-arch flags. AMDGPU_GFXMODEL is semicolon-separated
# when multiple targets are autodetected (e.g. "gfx90a;gfx942"); HIPCC
# accepts repeated --offload-arch=<gfx> for multi-target binaries.
# Pattern lifted from cupy_setup.sh.
OFFLOAD_ARCH_FLAGS=""
for _arch in $(echo ${AMDGPU_GFXMODEL} | tr ';' ' '); do
   OFFLOAD_ARCH_FLAGS+=" --offload-arch=${_arch}"
done
unset _arch

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

if [ -f ${CACHE_FILES}/elpa-v${ELPA_VERSION}.tgz ]; then
   echo ""
   echo "============================"
   echo " Installing Cached ELPA v${ELPA_VERSION}"
   echo "============================"
   echo ""

   # Cache tar must be named elpa-v${ELPA_VERSION}.tgz and contain a
   # top-level directory elpa-v${ELPA_VERSION}/ so it lands directly at
   # ${INSTALL_PATH} when extracted under /opt/rocmplus-X.
   cd /opt/rocmplus-${ROCM_VERSION}
   ${SUDO} tar -xpzf ${CACHE_FILES}/elpa-v${ELPA_VERSION}.tgz
   ${SUDO} chown -R root:root ${INSTALL_PATH}
   if [ "${USER}" != "sysadmin" ]; then
      ${SUDO} rm ${CACHE_FILES}/elpa-v${ELPA_VERSION}.tgz
   fi

else
   echo ""
   echo "============================"
   echo " Building ELPA"
   echo "============================"
   echo ""

   REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" "${PETSC_MODULE}" )
   preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
   if [[ -z "${MPI_PATH:-}" ]]; then
      echo "MPI module ${MPI_MODULE} is not setting the MPI_PATH env variable, aborting..."
      exit 1
   fi
   if [[ -z "${PETSC_PATH:-}" ]]; then
      echo "PETSC module ${PETSC_MODULE} is not setting the PETSC_PATH env variable, aborting..."
      exit 1
   fi
   if [[ -z "${ROCM_PATH:-}" ]]; then
      echo "ROCm module ${ROCM_MODULE_NAME} is not setting the ROCM_PATH env variable, aborting..."
      exit 1
   fi

   # binutils-dev provides libbfd / libiberty headers/libs that ELPA's
   # linker step pulls in for backtrace support on some configurations.
   # apt-get needs root regardless of the install-path SUDO state
   # (PKG_SUDO pattern, see petsc_setup.sh / openmpi_setup.sh).
   PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO} env DEBIAN_FRONTEND=noninteractive apt-get update
   ${PKG_SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y binutils-dev

   # don't use sudo if user has write access to install path
   if [ -d "${INSTALL_PATH}" ]; then
      if [ -w ${INSTALL_PATH} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      # if install path does not exist yet, the check on write access will fail
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p ${INSTALL_PATH}
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod -R a+w ${INSTALL_PATH}
   fi

   # Per-job throwaway build dir on local disk. Keeps concurrent
   # rocm-version sweeps from racing on a shared NFS source tree
   # (same pattern hypre_setup.sh adopted in the 8221/8222/8223 audit).
   # Cleanup is consolidated into _elpa_on_exit (registered above) so
   # the same EXIT handler covers both build-dir and install rollback.
   ELPA_BUILD_DIR=$(mktemp -d -t elpa-build.XXXXXX)
   cd "${ELPA_BUILD_DIR}"

   git clone -b ${ELPA_GIT_BRANCH} ${ELPA_GIT_REPO}
   cd elpa
   git reset --hard ${ELPA_GIT_COMMIT}

   # ── ELPA alignment patch: tridiag_gpu.h memcpy through char* ─────
   # Upstream commit 81fb8d0c replaced "*xf_host_or_dev" with std::memcpy
   # to fix a Fortran<->C++ alignment mismatch for complex datatype
   # pointers, but the parameter is typed T* with alignof(T) == 16
   # (HIP_vector_type<double,2u>) so Clang/hipcc folds the memcpy back
   # into a 16-byte aligned MOVAPS pair. The Fortran caller, on the
   # useCCL=.false. branch (>1 rank/GPU), passes loc(xf) where xf is a
   # COMPLEX(real64) scalar -- only 8-byte aligned per the Fortran ABI
   # -- and the load SIGSEGVs. Laundering the source through char*
   # forces movups (unaligned), which is correct on x86_64 and the
   # only thing the kernel actually needs since the value is then
   # passed by value into the GPU kernel.
   #
   # Three call sites in src/elpa1/GPU/tridiag_gpu.h:
   #   gpu_set_e_vec_scale_set_one_store_v_row -> xf_host_or_dev
   #   gpu_store_u_v_in_uv_vu                  -> vav_host_or_dev, tau_host_or_dev
   #
   # If ELPA_GIT_COMMIT is bumped past the upstream fix for this issue,
   # this patch will fail to apply (no matching lines) and the verify
   # block below will exit 1 -- re-validate against the new commit.
   sed -i \
      -e 's|std::memcpy(&xf_host_value, xf_host_or_dev, sizeof(T));|std::memcpy(\&xf_host_value, reinterpret_cast<const char*>(xf_host_or_dev), sizeof(T));|' \
      -e 's|std::memcpy(&vav_host_value, vav_host_or_dev, sizeof(T));|std::memcpy(\&vav_host_value, reinterpret_cast<const char*>(vav_host_or_dev), sizeof(T));|' \
      -e 's|std::memcpy(&tau_host_value, tau_host_or_dev, sizeof(T));|std::memcpy(\&tau_host_value, reinterpret_cast<const char*>(tau_host_or_dev), sizeof(T));|' \
      src/elpa1/GPU/tridiag_gpu.h

   _n=$(grep -c 'reinterpret_cast<const char\*>' src/elpa1/GPU/tridiag_gpu.h)
   if [ "${_n}" != "3" ]; then
      echo "ERROR: ELPA alignment patch did not apply (got ${_n} hits in tridiag_gpu.h, expected 3)"
      echo "       The file may have changed at ${ELPA_GIT_COMMIT}; re-validate the patch."
      exit 1
   fi
   unset _n

   ./autogen.sh
   mkdir build && cd build

   # Strip inherited CFLAGS/CXXFLAGS so module/site flags (Lmod stack,
   # mpicc wrappers) don't silently merge -Werror=... into ELPA's
   # compile-only probes. configure.ac's "SSE3 with gcc intrinsics"
   # test deliberately uses an uninitialized double* and an unused
   # __m128d; with -Werror=uninitialized or -Werror=unused-variable
   # in flight that probe fails AC_COMPILE_IFELSE and SSE3 is reported
   # as "no" even on CPUs that support it. ELPA_GCC_WARNINGS is
   # belt-and-braces in case a wrapper re-injects -Werror after ours.
   unset CFLAGS CXXFLAGS
   ELPA_GCC_WARNINGS="-Wno-error=uninitialized -Wno-error=unused-variable"

   ../configure \
      --enable-amd-gpu-kernels \
      --enable-hipcub \
      --with-AMD-gpu-support-only \
      --prefix=${INSTALL_PATH} \
      SCALAPACK_LDFLAGS="-L${PETSC_PATH}/lib -lscalapack -lflapack -lfblas -lpthread -lm -Wl,-rpath,${PETSC_PATH}/lib" \
      SCALAPACK_FCFLAGS="-L${PETSC_PATH}/lib -lscalapack -lflapack -lfblas -lpthread -lm -I${PETSC_PATH}/include" \
      LDFLAGS="-L${ROCM_PATH}/lib -L${PETSC_PATH}/lib -lstdc++" \
      CPPFLAGS="-I${ROCM_PATH}/include -I${ROCM_PATH}/include/rocsolver" \
      CFLAGS="-g -O3 -march=native ${ELPA_GCC_WARNINGS}" \
      CXXFLAGS="-g -O3 -march=native ${ELPA_GCC_WARNINGS}" \
      FCFLAGS="-g -O3" \
      HIPCCFLAGS="-g -O3${OFFLOAD_ARCH_FLAGS}" \
      FC=mpifort \
      CC=mpicc \
      CXX=mpicxx \
      --enable-avx512=yes  \
      --with-rocsolver \
      --with-mpi=yes \
      --enable-c-tests=no \
      --enable-cpp-tests=no \
      --enable-single-precision=no \
      --enable-gpu-ccl=rccl \
      LIBS='-lamdhip64'

   # ── libtool patch: fix amdflang (FC tag) linker flags ────────────
   # configure generates build/libtool with empty pic_flag/wl values
   # in the [FC] tag section because libtool's autoconf macros don't
   # know amdflang. Without -fPIC we can't link the shared library;
   # without `-Wl,` we can't pass linker-only flags through the
   # Fortran driver. Patch ONLY the FC section (sed range bounded by
   # the BEGIN/END tag-config markers in the libtool template) so
   # the C/CXX/F77 sections stay untouched.
   if [ ! -f libtool ]; then
      echo "ERROR: build/libtool not found after ./configure -- cannot apply FC-tag patch"
      exit 1
   fi
   sed -i '/^# ### BEGIN LIBTOOL TAG CONFIG: FC$/,/^# ### END LIBTOOL TAG CONFIG: FC$/{
s|^pic_flag=""$|pic_flag=" -fPIC"|
s|^wl=""$|wl="-Wl,"|
}' libtool

   # Verify the patch took -- the FC section should now contain both
   # rewritten lines. If the libtool template changes upstream, fail
   # loudly here rather than later in the link step with a confusing
   # "missing -fPIC" or "unrecognized -Wl flag" error.
   _libtool_fc_section=$(awk '/^# ### BEGIN LIBTOOL TAG CONFIG: FC$/,/^# ### END LIBTOOL TAG CONFIG: FC$/' libtool)
   if ! echo "${_libtool_fc_section}" | grep -q '^pic_flag=" -fPIC"$'; then
      echo "ERROR: libtool FC-tag patch did not apply (pic_flag rewrite missing)"
      echo "       The libtool template may have changed upstream; re-validate the patch."
      exit 1
   fi
   if ! echo "${_libtool_fc_section}" | grep -q '^wl="-Wl,"$'; then
      echo "ERROR: libtool FC-tag patch did not apply (wl rewrite missing)"
      echo "       The libtool template may have changed upstream; re-validate the patch."
      exit 1
   fi
   unset _libtool_fc_section

   # Build as user (no sudo) so the compiler emits user-owned object
   # files in the build dir; sudo only the install step below (file
   # copies into ${INSTALL_PATH}). Prevents root-owned .o files in
   # the per-job /tmp build dir that would race the EXIT-trap cleanup.
   #
   # The make-time HIPCCFLAGS overrides are intentional and additive
   # to the configure-time HIPCCFLAGS: they re-add the -I flags for
   # rocsolver / rocblas headers that some ELPA HIP TUs need but
   # configure doesn't propagate. Keep in sync with the configure
   # CPPFLAGS above.
   make -j$(nproc) \
      FC=`which mpifort` \
      CC=`which mpicc` \
      HIPCC=`which hipcc` \
      HIPCCFLAGS="-g -O3${OFFLOAD_ARCH_FLAGS} -I${ROCM_PATH}/include -I${ROCM_PATH}/include/rocsolver -I${ROCM_PATH}/include/rocblas" \
      FCFLAGS="-g -O3"

   # Install only the libtool libraries + data (headers, pkgconfig).
   # Skip the test-program install targets -- configure already passed
   # --enable-c-tests=no --enable-cpp-tests=no so those binaries aren't
   # built, and `make install` would otherwise try to recurse into
   # those subdirs. install-libLTLIBRARIES + install-data is the
   # minimal viable install for downstream consumers.
   ${SUDO} make install-libLTLIBRARIES install-data

   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
   fi
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod go-w ${INSTALL_PATH}
   fi

   # Tolerate unloads under `set -e` (line 12). Some module managers
   # leave a no-op dependency state where these unloads return non-zero;
   # `||true` keeps a successful build from being demoted to FAILED at
   # the very last step.
   module unload ${PETSC_MODULE} 2>/dev/null || true
   module unload ${MPI_MODULE}   2>/dev/null || true
   module unload ${ROCM_MODULE_NAME} 2>/dev/null || true

fi

# Create a module file for elpa
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

# The - option suppresses tabs.
#
# We prereq() the rocm module and load() the petsc module. The petsc
# modulefile already load()s the MPI module internally, so we get
# openmpi (or whichever MPI was used at build time) transitively and
# don't have to duplicate that load() here.
#
# ELPA_PATH is the project-internal convention used by HPCTrainingDock;
# ELPA_DIR / ELPA_ROOT / ELPA_HOME are aliases for downstream consumers
# that follow CMake (<Pkg>_ROOT), spack (<Pkg>_DIR), or hand-rolled
# (<Pkg>_HOME) conventions.
cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${ELPA_VERSION}.lua
	whatis("ELPA Version ${ELPA_VERSION} - Eigenvalue SoLvers for Petaflop-Applications, AMD GPU build")
	whatis("Source: ${ELPA_GIT_REPO} (branch ${ELPA_GIT_BRANCH}, commit ${ELPA_GIT_COMMIT:0:12})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${INSTALL_PATH}"

	prereq("${ROCM_MODULE_NAME}")
	load("${PETSC_MODULE}")
	setenv("ELPA_PATH", base)
	setenv("ELPA_DIR",  base)
	setenv("ELPA_ROOT", base)
	setenv("ELPA_HOME", base)
	prepend_path("PATH",            pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LIBRARY_PATH",    pathJoin(base, "lib"))
	prepend_path("PKG_CONFIG_PATH", pathJoin(base, "lib", "pkgconfig"))
	prepend_path("CPATH",           pathJoin(base, "include"))
EOF
