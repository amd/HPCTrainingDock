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

# This script installs the rocSHMEM library (a GPU-centric OpenSHMEM-like
# intra-kernel networking runtime). The simplest use case is:
#   ./rocshmem_setup.sh --rocm-version <ROCM_VERSION>
#
# rocSHMEM now lives in the ROCm/rocm-systems monorepo at
# projects/rocshmem (sparse checkout), EXCEPT for the ROCm 7.1.x and
# 7.2.x releases, which predate that migration and must be pulled from
# the retired standalone ROCm/rocSHMEM repo (sources at the repo root).
# The source repo is selected automatically from --rocm-version (see the
# "Source selection" block below). Three network backends are selectable
# at build time:
#   * IPC -- single-node GPU-to-GPU; no MPI dependency
#   * RO  -- Reverse Offload; requires ROCm-aware OpenMPI + UCX (this
#            repo builds those via openmpi_setup.sh)
#   * GDA -- GPU Direct Async; requires NIC direct-verbs headers
# Default backend config is ro_ipc (RO + IPC), the officially supported
# ROCm 7.0 default; override with --backend-config.

# Variables controlling setup process
ROCM_VERSION=6.4.0
# ROCM_PATH: deliberately NOT reset here. Inherit from the parent shell
# (which has done `module load rocm/...`) or set it via --rocm-path; the
# script needs a real value for the downstream cmake flags.
AMDGPU_GFXMODEL=
# rocSHMEM has two upstream homes and the right one depends on the ROCm
# version being targeted (see the "Source selection" block further down):
#   * monorepo -- ROCm/rocm-systems, sources under projects/rocshmem.
#     Carries rocshmem only on recent refs (develop, therock-X.Y); the
#     conventional rocm-7.1.x/7.2.x release tags predate the migration
#     and do NOT contain it. Default ref is the latest rocshmem-bearing
#     release tag (a therock-X.Y tag), with library version 3.4.0.
#   * legacy   -- ROCm/rocSHMEM (the retired standalone repo), sources at
#     the repo root. This is where the rocm-7.1.x and rocm-7.2.x releases
#     live (tags rocm-<ROCM_VERSION>).
# ROCSHMEM_VERSION_INPUT / GITHUB_BRANCH_INPUT capture explicit operator
# overrides; when empty, per-source defaults are filled in after
# ROCM_VERSION is known.
ROCSHMEM_VERSION_INPUT=""
GITHUB_BRANCH_INPUT=""
ROCSHMEM_MONOREPO_URL=https://github.com/ROCm/rocm-systems.git
ROCSHMEM_LEGACY_URL=https://github.com/ROCm/rocSHMEM.git
ROCSHMEM_MONOREPO_DEFAULT_REF=therock-7.13
ROCSHMEM_MONOREPO_DEFAULT_VERSION=3.4.0
BACKEND_CONFIG=ro_ipc
MPI_MODULE=openmpi
# BUILD_ROCSHMEM is the master "do this script's work at all" gate. Set
# to 0 to short-circuit early (after arg parsing, before --replace and
# the existence check) with NOOP_RC=43, matching the openmpi pattern.
BUILD_ROCSHMEM=1
# BUILD_TESTS: rocSHMEM's functional/unit/python test targets require
# GTest plus an MPI launcher at build time. Kept OFF by default to
# minimise build-failure risk in the image build; --build-tests 1
# re-enables them (and the examples).
BUILD_TESTS=0
REPLACE=0
KEEP_FAILED_INSTALLS=0
DRY_RUN=0
USE_CACHE_BUILD=1
INSTALL_PATH_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/rocshmem

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# pick_sudo_for <path>: prints "sudo" if writing to <path> requires elevation
# for the current user, "" otherwise. If <path> does not exist yet, walks up
# to the nearest existing ancestor and tests that. Used per component so a
# writable parent does not falsely waive sudo for a root-owned subdir, and a
# root-owned parent does not force sudo on a subdir the user already owns.
#
# IMPORTANT: must NOT use `[ -w ]` -- the bash test is implemented on top of
# the NFS client's cached mode/uid view, which can disagree with the
# server's actual permission decision. Instead, do a real probe -- atomically
# create+remove a tempfile -- which exercises the same NFS code path as the
# subsequent install operations.
pick_sudo_for()
{
   local target="$1"
   local probe_dir
   if [ -d "${target}" ]; then
      probe_dir="${target}"
   else
      probe_dir="${target%/*}"
      while [ -n "${probe_dir}" ] && [ ! -d "${probe_dir}" ]; do
         probe_dir="${probe_dir%/*}"
      done
      [ -z "${probe_dir}" ] && probe_dir="/"
   fi
   local probe="${probe_dir}/.rocshmem_setup_writeprobe.$$.${RANDOM}"
   if ( umask 077 && : > "${probe}" ) 2>/dev/null; then
      rm -f "${probe}" 2>/dev/null
      echo ""; return
   fi
   echo "sudo"
}

usage()
{
    echo "Usage:"
    echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
    echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
    echo "  --backend-config [ ro_ipc | ipc_single | all_backends ] default $BACKEND_CONFIG"
    echo "  --build-rocshmem [ BUILD_ROCSHMEM ] master gate; 0 = exit NOOP_RC, default $BUILD_ROCSHMEM"
    echo "  --build-tests [ 0|1 ] build functional/unit/python tests + examples (needs GTest+MPI), default $BUILD_TESTS"
    echo "  --dry-run default off"
    echo "  --github-branch [ GITHUB_BRANCH ] git ref to check out; default is version-dependent: ${ROCSHMEM_MONOREPO_DEFAULT_REF} (rocm-systems) for most ROCm versions, rocm-<ROCM_VERSION> (ROCm/rocSHMEM legacy repo) for ROCm 7.1.x/7.2.x; use develop for tip-of-tree"
    echo "  --install-path [ INSTALL_PATH ] parent dir; the script appends rocshmem-\${ROCSHMEM_VERSION}-\${BACKEND_CONFIG}, default /opt/rocmplus-$ROCM_VERSION"
    echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
    echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
    echo "  --mpi-module [ MPI_MODULE ] module to load for the RO backend, default $MPI_MODULE"
    echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
    echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
    echo "  --rocm-path [ ROCM_PATH ] default none"
    echo "  --rocshmem-version [ ROCSHMEM_VERSION ] label for the install dir + modulefile; default ${ROCSHMEM_MONOREPO_DEFAULT_VERSION} (monorepo) or <ROCM_VERSION> (legacy 7.1.x/7.2.x)"
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--backend-config")
          shift
          BACKEND_CONFIG=${1}
          reset-last
          ;;
      "--build-rocshmem")
          shift
          BUILD_ROCSHMEM=${1}
          reset-last
          ;;
      "--build-tests")
          shift
          BUILD_TESTS=${1}
          reset-last
          ;;
      "--dry-run")
          DRY_RUN=1
          reset-last
          ;;
      "--github-branch")
          shift
          GITHUB_BRANCH_INPUT=${1}
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
      "--keep-failed-installs")
          shift
          KEEP_FAILED_INSTALLS=${1}
          reset-last
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
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--rocm-path")
          shift
          ROCM_PATH=${1}
	  ROCM_VERSION=`cat ${ROCM_PATH}/.info/version | cut -f1 -d'-' `
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--rocshmem-version")
          shift
          ROCSHMEM_VERSION_INPUT=${1}
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

# Validate backend config early so a typo fails fast (before any module
# load / clone) rather than producing a confusing cmake error.
case "${BACKEND_CONFIG}" in
   ro_ipc|ipc_single|all_backends) ;;
   *) send-error "Unsupported --backend-config '${BACKEND_CONFIG}' (expected ro_ipc, ipc_single, or all_backends)" ;;
esac

# RO is active in ro_ipc and all_backends; those builds need an MPI.
BACKEND_USES_RO=0
if [[ "${BACKEND_CONFIG}" == "ro_ipc" || "${BACKEND_CONFIG}" == "all_backends" ]]; then
   BACKEND_USES_RO=1
fi

# ROCM_MODULE_NAME: the actual rocm modulefile token to load / refer to.
# Derivation strategy (most-to-least authoritative):
#   1. LMOD's LOADEDMODULES env var: lists the literal modulefile names
#      currently loaded (e.g. `rocm/therock-afar-23.2.1`). Most
#      authoritative and the only one that handles the therock-afar dual
#      scheme.
#   2. ROCM_PATH basename: works for regular + afar.
#   3. rocm/${ROCM_VERSION}: standalone-invocation fallback.
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

# ── ROCm version guard ────────────────────────────────────────────────
# rocSHMEM requires ROCm 6.4.0 or later (HIP runtime + the RO/IPC build
# paths). awk numeric comparison, same idiom as rocprofiler-sdk_setup.sh.
result=`echo $ROCM_VERSION | awk '$1>=6.4.0'` && echo $result >/dev/null
if [[ "${result}" == "" ]]; then # ROCM_VERSION < 6.4.0
   echo "The rocSHMEM library can be installed only for ROCm versions greater than or equal to 6.4.0"
   echo "You selected this as ROCm version: $ROCM_VERSION"
   echo "Select an appropriate ROCm version with --rocm-version <ROCM_VERSION>, with <ROCM_VERSION> >= 6.4.0"
   exit 1
fi

# ── Source selection ─────────────────────────────────────────────────
# rocSHMEM for ROCm 7.1.x and 7.2.x must be pulled from the legacy
# standalone ROCm/rocSHMEM repository: those releases predate the
# rocSHMEM migration into the rocm-systems monorepo, so the matching
# rocm-systems release tags do NOT carry projects/rocshmem. The legacy
# repo has matching rocm-<ROCM_VERSION> tags with the sources at the
# repo root. All other ROCm versions use the rocm-systems monorepo
# (projects/rocshmem) at the default therock-X.Y release tag.
# Per-source default ref + version label are applied here, honoring any
# explicit --github-branch / --rocshmem-version override.
case "${ROCM_VERSION}" in
   7.1.*|7.2.*)
      ROCSHMEM_SOURCE=legacy
      ROCSHMEM_REPO_URL="${ROCSHMEM_LEGACY_URL}"
      GITHUB_BRANCH="${GITHUB_BRANCH_INPUT:-rocm-${ROCM_VERSION}}"
      # No static VERSION_STRING literal in the legacy tags (it is
      # derived at configure time), so label the install by the ROCm
      # release it was cut for unless the operator overrides it.
      ROCSHMEM_VERSION="${ROCSHMEM_VERSION_INPUT:-${ROCM_VERSION}}"
      ;;
   *)
      ROCSHMEM_SOURCE=monorepo
      ROCSHMEM_REPO_URL="${ROCSHMEM_MONOREPO_URL}"
      GITHUB_BRANCH="${GITHUB_BRANCH_INPUT:-${ROCSHMEM_MONOREPO_DEFAULT_REF}}"
      ROCSHMEM_VERSION="${ROCSHMEM_VERSION_INPUT:-${ROCSHMEM_MONOREPO_DEFAULT_VERSION}}"
      ;;
esac

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}
fi
# Strip any trailing slash so downstream concatenations don't produce
# "//" embedded paths.
INSTALL_PATH="${INSTALL_PATH%/}"

ROCSHMEM_PATH="${INSTALL_PATH}/rocshmem-${ROCSHMEM_VERSION}-${BACKEND_CONFIG}"

# ── BUILD_ROCSHMEM=0 short-circuit: operator opt-out ─────────────────
NOOP_RC=43
if [ "${BUILD_ROCSHMEM}" = "0" ]; then
   echo "[rocshmem BUILD_ROCSHMEM=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

echo ""
echo "============================"
echo " Installing rocSHMEM with:"
echo "   ROCM_VERSION: $ROCM_VERSION"
echo "   ROCM_PATH: ${ROCM_PATH}"
echo "   ROCSHMEM_VERSION: $ROCSHMEM_VERSION"
echo "   BACKEND_CONFIG: $BACKEND_CONFIG"
echo "   ROCSHMEM_SOURCE: $ROCSHMEM_SOURCE ($ROCSHMEM_REPO_URL)"
echo "   GITHUB_BRANCH: $GITHUB_BRANCH"
echo "   ROCSHMEM_PATH: $ROCSHMEM_PATH"
echo "   MODULE_PATH: $MODULE_PATH"
echo "   REPLACE: $REPLACE"
echo "   KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "============================"
echo ""

# ── --replace: remove prior install + modulefile BEFORE building ─────
MODULEFILE="${MODULE_PATH}/${ROCSHMEM_VERSION}-${BACKEND_CONFIG}.lua"
if [ "${REPLACE}" = "1" ]; then
   echo "[rocshmem --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${ROCSHMEM_PATH}"
   echo "  modulefile:  ${MODULEFILE}"
   ${SUDO} rm -rf "${ROCSHMEM_PATH}"
   ${SUDO} rm -f  "${MODULEFILE}"
fi

# ── Existence guard: skip if this version+backend is already installed ─
if [ -d "${ROCSHMEM_PATH}" ]; then
   echo ""
   echo "[rocshmem existence-check] ${ROCSHMEM_PATH} already installed; skipping."
   echo "                           pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# PKG_SUDO is independent of the install-path-writability-derived SUDO:
# apt-get / yum operate on root-owned /var/lib/{apt,dpkg,rpm}; the only
# condition under which they should run without sudo is EUID==0.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO=""
else
   PKG_SUDO="sudo"
fi

# Per-component sudo: the install lands in ${ROCSHMEM_PATH}, the
# modulefile under ${MODULE_PATH}. Decide each independently.
if [ -z "${SUDO}" ]; then
   SUDO_INSTALL=""
else
   SUDO_INSTALL=$(pick_sudo_for "${ROCSHMEM_PATH}")
fi

# ── EXIT trap: build-dir cleanup + fail-cleanup ──────────────────────
_rocshmem_on_exit() {
   local rc=$?
   [ -n "${ROCSHMEM_BUILD_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${ROCSHMEM_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[rocshmem fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${ROCSHMEM_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE}"
   elif [ ${rc} -ne 0 ]; then
      echo "[rocshmem fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _rocshmem_on_exit EXIT

# ── Preflight + load required modules ────────────────────────────────
# Always need rocm; the RO backend additionally needs an MPI module so
# cmake's find_package(MPI) succeeds. preflight_modules exits the script
# with rc=42 (MISSING_PREREQ) on the first module that doesn't resolve;
# main_setup.sh's run_and_log treats that as SKIPPED rather than FAILED.
REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" )
if [ "${BACKEND_USES_RO}" == "1" ]; then
   REQUIRED_MODULES+=( "${MPI_MODULE}" )
fi
preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

# ── amdclang compiler module (hierarchical, loaded after rocm) ────────
# Some ROCm packagings ship LLVM/clang as a SEPARATE module rather than
# bundling it under ${ROCM_PATH}/lib/llvm. On those (e.g. ROCm 7.x split
# packaging on the sh5 nodes) hipcc cannot locate clang++/amdclang++
# until the amdclang module is loaded -- the symptom is cmake's compiler
# check failing with "/opt/rocm/lib/llvm/bin/clang++: not found" even
# though rocm is loaded. The amdclang module only becomes visible AFTER
# rocm is loaded (hierarchical MODULEPATH), so we probe + load it here,
# after the rocm preflight above. When no amdclang module exists we
# assume the rocm module already carries a working hipcc toolchain.
if module --redirect -t avail amdclang 2>/dev/null | grep -qi '^amdclang'; then
   echo "preflight: amdclang module present -> loading it for the hipcc toolchain"
   if ! module load amdclang 2>&1; then
      echo "ERROR: amdclang module is available but failed to load." >&2
      exit ${MISSING_PREREQ_RC}
   fi
else
   echo "preflight: no amdclang module visible; assuming rocm provides hipcc's clang toolchain"
fi

# ── ROCM_PATH must come from the rocm module (no /opt/rocm here) ──────
# rocSHMEM's cmake/setup_project.cmake does NOT consult the environment
# ROCM_PATH: when the *CMake* variable ROCM_PATH is undefined it hard-
# falls-back to /opt/rocm AND overwrites ENV{ROCM_PATH} with /opt/rocm,
# which then makes hipcc look for clang++ under /opt/rocm. This is a
# multi-ROCm-version site with NO /opt/rocm, so that fallback is fatal.
# We pass -DROCM_PATH=${ROCM_PATH} to cmake (below) so the build uses the
# ROCm the module selected. That requires a valid ROCM_PATH here; if the
# loaded rocm module did not provide one, rocSHMEM cannot be built on
# this site -> mark uninstallable (NOOP_RC), per site policy.
if [ -z "${ROCM_PATH:-}" ] || [ ! -f "${ROCM_PATH}/.info/version" ]; then
   echo "[rocshmem] ROCM_PATH is not a valid ROCm install (got '${ROCM_PATH:-<unset>}')."
   echo "           This site has no /opt/rocm; rocSHMEM must build against the"
   echo "           ROCM_PATH set by the loaded rocm module. Marking uninstallable."
   exit ${NOOP_RC}
fi
echo "Using ROCM_PATH=${ROCM_PATH} for the rocSHMEM build"

# ── Distro build dependencies ────────────────────────────────────────
# git for the fetch; build toolchain (gcc/g++/make) for the host parts;
# libnuma for the GDA backend (CMake silently disables GDA if libnuma is
# absent). ROCmCMakeBuildTools comes from the rocm install.
#
# IMPORTANT: do NOT apt/yum-install cmake. On these clusters cmake is
# provided as a pip build under /usr/local/bin (pinned to the version the
# ROCm builds need); the distro cmake package is older AND its cmake-data
# post-install pulls in emacsen-common/emacs, which fails to configure on
# the 22.04 nodes (emacs needs GLIBC_2.38; the nodes ship GLIBC 2.35),
# breaking the whole apt transaction. We rely on the existing
# /usr/local/bin cmake and only verify it is present below.
if [ "${DISTRO}" = "ubuntu" ]; then
   echo "Install of git build-essential libnuma-dev packages (cmake intentionally NOT installed; using /usr/local/bin pip cmake)"
   if [[ "${DRY_RUN}" == "0" ]]; then
      ${PKG_SUDO} apt-get update
      ${PKG_SUDO} apt-get install -y git build-essential libnuma-dev
   fi
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   echo "Install of git gcc-c++ make numactl-devel packages (cmake intentionally NOT installed; using /usr/local/bin pip cmake)"
   if [[ "${DRY_RUN}" == "0" ]]; then
      ${PKG_SUDO} yum install -y git gcc-c++ make numactl-devel
   fi
else
   echo "DISTRO version ${DISTRO} not recognized or supported"
   exit ${NOOP_RC}
fi

# Verify cmake is available (expected: the pip build in /usr/local/bin).
# Fail fast with guidance rather than letting a missing cmake surface as
# a confusing configure error.
if ! command -v cmake >/dev/null 2>&1; then
   echo "ERROR: cmake not found on PATH. This script does NOT install cmake;"
   echo "       it expects the pip-provided cmake in /usr/local/bin. Install it, e.g.:"
   echo "         ${PKG_SUDO:-sudo} pip install --upgrade cmake"
   echo "       then re-run."
   exit 1
fi
echo "Using cmake: $(command -v cmake) ($(cmake --version | head -1))"

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
CACHE_TARBALL=rocshmem-${ROCSHMEM_VERSION}-${BACKEND_CONFIG}.tgz

if [[ "${DRY_RUN}" == "0" ]] && [[ ! -d ${INSTALL_PATH} ]] ; then
   ${SUDO} mkdir -p "${INSTALL_PATH}"
fi

if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f ${CACHE_FILES}/${CACHE_TARBALL} ]]; then
   echo ""
   echo "============================"
   echo " Installing Cached rocSHMEM"
   echo "============================"
   echo ""

   echo "cached file is ${CACHE_FILES}/${CACHE_TARBALL}"
   ${SUDO_INSTALL} mkdir -p ${ROCSHMEM_PATH}
   cd ${INSTALL_PATH}
   ${SUDO_INSTALL} tar -xzpf ${CACHE_FILES}/${CACHE_TARBALL}
   # Normalize ownership to root only when we actually installed with
   # elevation (SUDO_INSTALL non-empty). When the install path is owned by
   # the current user (SUDO_INSTALL=""), the files are already correctly
   # owned and `chown root:root` without sudo would fail ("Operation not
   # permitted") and abort the script.
   if [ -n "${SUDO_INSTALL}" ]; then
      ${SUDO_INSTALL} find ${ROCSHMEM_PATH} -type f -execdir chown root:root "{}" +
      ${SUDO_INSTALL} find ${ROCSHMEM_PATH} -type d -execdir chown root:root "{}" +
   fi
   if [ "${USER}" != "sysadmin" ]; then
      ${SUDO} rm "${CACHE_FILES}"/${CACHE_TARBALL}
   fi
else

   echo ""
   echo "============================"
   echo " Building rocSHMEM (${BACKEND_CONFIG})"
   echo "============================"
   echo ""

   # Per-job throwaway build dir under /tmp (or $TMPDIR if Slurm set
   # one). Cleaned up by the EXIT trap. Only `cmake --install` writes
   # hit the (possibly NFS) install path.
   ROCSHMEM_BUILD_DIR=$(mktemp -d -t rocshmem-build.XXXXXX)
   cd "${ROCSHMEM_BUILD_DIR}"

   # Fetch the rocshmem sources. Two layouts depending on the source
   # selected above (by ROCm version):
   #   * monorepo -- sparse checkout of just the projects/rocshmem
   #     subtree from rocm-systems (the documented fetch method; avoids
   #     pulling the whole monorepo blob history).
   #   * legacy   -- a shallow clone of the retired standalone
   #     ROCm/rocSHMEM repo at the matching rocm-<ROCM_VERSION> tag;
   #     here the sources live at the repo root.
   if [ "${ROCSHMEM_SOURCE}" = "monorepo" ]; then
      git clone --no-checkout --filter=blob:none "${ROCSHMEM_REPO_URL}" rocm-systems-source
      cd rocm-systems-source
      git sparse-checkout set --cone projects/rocshmem
      git checkout ${GITHUB_BRANCH}
      SRC_DIR="${ROCSHMEM_BUILD_DIR}/rocm-systems-source/projects/rocshmem"
   else
      git clone --depth 1 --branch ${GITHUB_BRANCH} "${ROCSHMEM_REPO_URL}" rocshmem-source
      SRC_DIR="${ROCSHMEM_BUILD_DIR}/rocshmem-source"
   fi
   cd "${SRC_DIR}"

   # Backend toggles equivalent to the upstream scripts/build_configs/*
   # configs. We invoke cmake directly (rather than calling the
   # build_configs script) so the install step can run under ${SUDO} --
   # the upstream configs run `cmake --install .` with no sudo, which
   # fails writing to a root-owned /opt. Mirrors the cmake-direct +
   # sudo-install pattern in rocprofiler-sdk_setup.sh.
   BACKEND_ARGS=()
   case "${BACKEND_CONFIG}" in
      ro_ipc)
         BACKEND_ARGS=( -DUSE_RO=ON -DUSE_IPC=ON -DUSE_GDA=OFF )
         ;;
      ipc_single)
         BACKEND_ARGS=( -DUSE_RO=OFF -DUSE_IPC=ON -DUSE_GDA=OFF -DUSE_SINGLE_NODE=ON -DUSE_EXTERNAL_MPI=OFF )
         ;;
      all_backends)
         BACKEND_ARGS=( -DUSE_RO=ON -DUSE_IPC=ON -DUSE_GDA=ON -DGDA_MLX5=ON -DGDA_BNXT=ON -DGDA_IONIC=ON )
         ;;
   esac

   if [ "${BUILD_TESTS}" == "1" ]; then
      TESTS_ON=ON
   else
      TESTS_ON=OFF
   fi

   cmake \
      -B build \
      -DCMAKE_INSTALL_PREFIX="${ROCSHMEM_PATH}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_VERBOSE_MAKEFILE=OFF \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DCMAKE_CXX_COMPILER="${ROCM_PATH}/bin/hipcc" \
      -DROCM_PATH="${ROCM_PATH}" \
      -DCMAKE_PREFIX_PATH="${ROCM_PATH}" \
      -DGPU_TARGETS="${AMDGPU_GFXMODEL}" \
      -DPROFILE=OFF \
      -DBUILD_FUNCTIONAL_TESTS=${TESTS_ON} \
      -DBUILD_UNIT_TESTS=${TESTS_ON} \
      -DBUILD_PYTHON_TESTS=${TESTS_ON} \
      -DBUILD_EXAMPLES=${TESTS_ON} \
      "${BACKEND_ARGS[@]}" \
      "${SRC_DIR}"

   cmake --build build --parallel $(nproc)

   if [[ "${DRY_RUN}" == "0" ]]; then
      if [ -n "${SUDO_INSTALL}" ]; then
         ${SUDO_INSTALL} -E env "PATH=$PATH" cmake --install build
      else
         cmake --install build
      fi
   fi

   # Normalize ownership to root only when we installed with elevation
   # (SUDO_INSTALL non-empty). For a user-owned install path the files are
   # already correctly owned and a non-sudo `chown root:root` would fail.
   if [ -n "${SUDO_INSTALL}" ] && [ -d "${ROCSHMEM_PATH}" ]; then
      ${SUDO_INSTALL} find ${ROCSHMEM_PATH} -type f -execdir chown root:root "{}" +
      ${SUDO_INSTALL} find ${ROCSHMEM_PATH} -type d -execdir chown root:root "{}" +
   fi

   # ROCSHMEM_BUILD_DIR (clone + build tree) is removed by the EXIT trap.
fi

if [[ "${DRY_RUN}" == "0" ]] && [[ ! -d "${ROCSHMEM_PATH}/lib" ]] && [[ ! -d "${ROCSHMEM_PATH}/lib64" ]]; then
   echo "rocSHMEM installation failed -- missing installation directories"
   echo " rocSHMEM Installation path is ${ROCSHMEM_PATH}"
   ls -l "${ROCSHMEM_PATH}" || true
   exit 1
fi

# Drop the loaded modules from the running shell so the next leaf script
# starts from the same baseline.
if [ "${BACKEND_USES_RO}" == "1" ]; then
   module unload "${MPI_MODULE}" || true
fi
module unload "${ROCM_MODULE_NAME}" || true

# ── Create a module file for rocSHMEM ────────────────────────────────
if [[ "${DRY_RUN}" == "0" ]]; then

   # Modulefile-write sudo: canonical PKG_SUDO pattern.
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # Provenance: capture this leaf script's git state for the modulefile
   # whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured
   # at the top of this script before any cd). Self-contained: falls
   # back to "unknown" when run from a stripped-of-.git context.
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

   # The - option suppresses tabs. For the RO backend we also `load`
   # the MPI module so the host-side reverse-offload runtime is on the
   # library/launch path at runtime.
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("Name: rocSHMEM")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: rocshmem-${ROCSHMEM_VERSION}-${BACKEND_CONFIG}")
	whatis("Backend: ${BACKEND_CONFIG}")
	whatis("Description: ROCm OpenSHMEM (rocSHMEM) GPU-centric intra-kernel networking library")
	whatis("URL: https://github.com/ROCm/rocm-systems")
	
	local base = "${ROCSHMEM_PATH}"
	
	setenv("ROCSHMEM_PATH", base)
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prereq("${ROCM_MODULE_NAME}")
EOF

   if [ "${BACKEND_USES_RO}" == "1" ]; then
      echo "	load(\"${MPI_MODULE}\")" | ${PKG_SUDO_MOD} tee -a ${MODULEFILE}
   fi

fi
