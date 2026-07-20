#!/bin/bash

# Absolute path to this script, captured BEFORE any cd, so the git
# provenance block at the bottom can find it after the build cd's away.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Fail fast; -u is intentionally omitted (conditional code relies on unset vars).
set -eo pipefail

# preflight_modules loads each named module; on the first failure it prints
# the Lmod diagnostic and returns 42, which main_setup.sh treats as SKIPPED
# (not FAILED). Inlined so this script runs standalone.
MISSING_PREREQ_RC=42
if ! type module >/dev/null 2>&1; then
   [ -r /etc/profile.d/lmod.sh ]         && . /etc/profile.d/lmod.sh
   [ -r /usr/share/lmod/lmod/init/bash ] && . /usr/share/lmod/lmod/init/bash
fi
preflight_modules() {
   [ "$#" -eq 0 ] && return 0
   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command not available; needed:$(printf ' %s' "$@")" >&2
      return ${MISSING_PREREQ_RC}
   fi
   local m err
   err=$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)
   for m in "$@"; do
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         [ -s "${err}" ] && sed 's/^/  module> /' "${err}" >&2
         rm -f "${err}"; return ${MISSING_PREREQ_RC}
      fi
   done
   rm -f "${err}"
}

# Builds RCCL Tests (https://github.com/ROCm/rccl-tests) -- the RCCL
# collective benchmarks (all_reduce_perf, all_gather_perf, ...) -- and writes
# a modulefile so that, with the module tree on MODULEPATH:
#   module load rccl-tests
#   mpirun -np 8 --bind-to numa all_reduce_perf -b 8 -e 8G -f 2 -g 1
# Simplest use: ./rccl-tests_setup.sh --rocm-version <ROCM_VERSION>
# RCCL ships inside ROCm, so the tests link against the loaded rocm module's
# librccl. MPI support (multi-process/node) is on by default; if the MPI
# module won't load, the build degrades to a single-process (MPI=0) build.

ROCM_VERSION=6.4.0
# ROCM_PATH: inherited from the parent shell's `module load rocm/...` or set
# via --rocm-path. Skip rocminfo autodetect when --amdgpu-gfxmodel is given:
# under pipefail an unguarded rocminfo can abort the script if the SDK needs
# a newer glibc than the host (mirrors pytorch_setup.sh).
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
RCCL_TESTS_REPO_URL=https://github.com/ROCm/rccl-tests.git
GITHUB_BRANCH_INPUT=""
# Pinned to a specific commit rather than tracking develop: develop carries a
# regression (rocm-systems#3588, 2026-03-05, "ROCM-3816 Out of Memory fix")
# that leaves the send/recv buffers unallocated in the default
# (non-parallel-init) run path, so every default *_perf run crashes on the
# first collective with a HIP illegal memory access. a52452e is the last
# develop commit before that regression. Bump this once upstream fixes it.
# --github-branch still accepts a branch, tag, or commit SHA.
GITHUB_BRANCH_DEFAULT=a52452e891d5dc07c83cf4edaea01ae4ab684b3a
RCCL_TESTS_VERSION_INPUT=""
BUILD_MPI=1
MPI_MODULE=openmpi
BUILD_RCCL_TESTS=1        # master gate; 0 = exit NOOP_RC (operator opt-out)
REPLACE=0
KEEP_FAILED_INSTALLS=0
DRY_RUN=0
INSTALL_PATH_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/rccl-tests
SUDO="sudo"
[ -f /.singularity.d/Singularity ] && SUDO=""

# pick_sudo_for <path>: echoes "sudo" if writing <path> needs elevation, else
# "". Walks up to the nearest existing ancestor when <path> is absent. Uses a
# real create+remove probe, NOT `[ -w ]`: the bash test reads the NFS client's
# cached mode/uid, which can disagree with the server's actual decision.
pick_sudo_for()
{
   local target="$1" probe_dir
   if [ -d "${target}" ]; then
      probe_dir="${target}"
   else
      probe_dir="${target%/*}"
      while [ -n "${probe_dir}" ] && [ ! -d "${probe_dir}" ]; do probe_dir="${probe_dir%/*}"; done
      [ -z "${probe_dir}" ] && probe_dir="/"
   fi
   local probe="${probe_dir}/.rccl_tests_setup_writeprobe.$$.${RANDOM}"
   if ( umask 077 && : > "${probe}" ) 2>/dev/null; then
      rm -f "${probe}" 2>/dev/null; echo ""; return
   fi
   echo "sudo"
}

usage()
{
    echo "Usage:"
    echo "  WARNING: --install-path and --module-path must already exist (the script checks for write permissions)"
    echo "  --amdgpu-gfxmodel [ GFXMODEL ] default autodetected via rocminfo; multiple separated by ';' (e.g. gfx942;gfx90a)"
    echo "  --build-mpi [ 0|1 ] link tests against MPI for multi-process/node runs, default $BUILD_MPI"
    echo "  --build-rccl-tests [ 0|1 ] master gate; 0 = exit NOOP_RC, default $BUILD_RCCL_TESTS"
    echo "  --dry-run default off"
    echo "  --github-branch [ REF ] git ref to check out, default ${GITHUB_BRANCH_DEFAULT}"
    echo "  --install-path [ PATH ] parent dir; appends rccl-tests-\${RCCL_TESTS_VERSION}, default /opt/rocmplus-$ROCM_VERSION"
    echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup on failure, default $KEEP_FAILED_INSTALLS"
    echo "  --module-path [ PATH ] default $MODULE_PATH"
    echo "  --mpi-module [ NAME ] module to load for the MPI build, default $MPI_MODULE"
    echo "  --rccl-tests-version [ VER ] label for install dir + modulefile, default = --github-branch"
    echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
    echo "  --rocm-version [ VER ] default $ROCM_VERSION"
    echo "  --rocm-path [ PATH ] default none"
    echo "  --help: print this usage information"
    exit 1
}

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--amdgpu-gfxmodel")   shift; AMDGPU_GFXMODEL=${1};          reset-last ;;
      "--build-mpi")         shift; BUILD_MPI=${1};                reset-last ;;
      "--build-rccl-tests")  shift; BUILD_RCCL_TESTS=${1};         reset-last ;;
      "--dry-run")                  DRY_RUN=1;                     reset-last ;;
      "--github-branch")     shift; GITHUB_BRANCH_INPUT=${1};      reset-last ;;
      "--help")                     usage ;;
      "--install-path")      shift; INSTALL_PATH_INPUT=${1};       reset-last ;;
      "--keep-failed-installs") shift; KEEP_FAILED_INSTALLS=${1};  reset-last ;;
      "--module-path")       shift; MODULE_PATH=${1};              reset-last ;;
      "--mpi-module")        shift; MPI_MODULE=${1};               reset-last ;;
      "--rccl-tests-version") shift; RCCL_TESTS_VERSION_INPUT=${1}; reset-last ;;
      "--replace")           shift; REPLACE=${1};                  reset-last ;;
      "--rocm-path")         shift; ROCM_PATH=${1}
                             ROCM_VERSION=`cat ${ROCM_PATH}/.info/version | cut -f1 -d'-'`; reset-last ;;
      "--rocm-version")      shift; ROCM_VERSION=${1};             reset-last ;;
      "--*")  send-error "Unsupported argument at position $((${n} + 1)) :: ${1}" ;;
      *)      last ${1} ;;
   esac
   n=$((${n} + 1)); shift
done

GITHUB_BRANCH="${GITHUB_BRANCH_INPUT:-${GITHUB_BRANCH_DEFAULT}}"
RCCL_TESTS_VERSION="${RCCL_TESTS_VERSION_INPUT:-${GITHUB_BRANCH}}"

# ROCM_MODULE_NAME: the rocm modulefile token to load / prereq. Prefer the
# literal name from LOADEDMODULES (handles the afar dual scheme), then the
# ROCM_PATH basename, then rocm/${ROCM_VERSION}.
ROCM_MODULE_NAME=""
if [[ -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      case "${_m}" in rocm/${ROCM_VERSION}) ROCM_MODULE_NAME="${_m}"; break ;; esac
   done
   [[ -z "${ROCM_MODULE_NAME}" ]] && for _m in ${LOADEDMODULES}; do
      case "${_m}" in rocm/*) ROCM_MODULE_NAME="${_m}"; break ;; esac
   done
   IFS="${_OLD_IFS}"; unset _OLD_IFS _m
fi
if [[ -z "${ROCM_MODULE_NAME}" ]]; then
   if [[ -n "${ROCM_PATH:-}" ]]; then
      _rp_bn="${ROCM_PATH##*/}"; ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"; unset _rp_bn
   else
      ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
   fi
fi

NOOP_RC=43
if [ "${BUILD_RCCL_TESTS}" = "0" ]; then
   echo "[rccl-tests BUILD_RCCL_TESTS=0] operator opt-out; skipping."
   exit ${NOOP_RC}
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT%/}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}
fi
RCCL_TESTS_PATH="${INSTALL_PATH}/rccl-tests-${RCCL_TESTS_VERSION}"
MODULEFILE="${MODULE_PATH}/${RCCL_TESTS_VERSION}.lua"

echo ""
echo "============================"
echo " Installing RCCL Tests with:"
echo "   ROCM_VERSION: $ROCM_VERSION"
echo "   ROCM_PATH: ${ROCM_PATH}"
echo "   RCCL_TESTS_VERSION: $RCCL_TESTS_VERSION (ref ${GITHUB_BRANCH})"
echo "   RCCL_TESTS_PATH: $RCCL_TESTS_PATH"
echo "   BUILD_MPI: $BUILD_MPI (MPI_MODULE: $MPI_MODULE)"
echo "   AMDGPU_GFXMODEL: ${AMDGPU_GFXMODEL:-<all supported>}"
echo "   MODULE_PATH: $MODULE_PATH"
echo "   REPLACE: $REPLACE   KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "============================"
echo ""

# Per-destination sudo (install dir vs module tree), decided by a real write
# probe. Singularity sets SUDO="" which waives elevation everywhere.
if [ -z "${SUDO}" ]; then
   SUDO_INSTALL=""; SUDO_MOD=""
else
   SUDO_INSTALL=$(pick_sudo_for "${RCCL_TESTS_PATH}")
   SUDO_MOD=$(pick_sudo_for "${MODULE_PATH}")
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[rccl-tests --replace 1] removing prior install + modulefile if present"
   ${SUDO_INSTALL} rm -rf "${RCCL_TESTS_PATH}"
   ${SUDO_MOD} rm -f  "${MODULEFILE}"
fi

if [ -d "${RCCL_TESTS_PATH}" ]; then
   echo "[rccl-tests existence-check] ${RCCL_TESTS_PATH} already installed; skipping (pass --replace 1 to rebuild)."
   exit ${NOOP_RC}
fi

# EXIT trap (armed AFTER the NOOP/skip exits above so a clean skip never runs
# cleanup): always remove the temp build dir (user-owned, under /tmp); on
# failure also remove the partial install + modulefile unless
# --keep-failed-installs 1, using the per-destination sudo decided above.
_rccl_tests_on_exit() {
   local rc=$?
   [ -n "${RCCL_TESTS_BUILD_DIR:-}" ] && rm -rf "${RCCL_TESTS_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[rccl-tests fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO_INSTALL} rm -rf "${RCCL_TESTS_PATH}"; ${SUDO_MOD} rm -f "${MODULEFILE}"
   fi
   return ${rc}
}
trap _rccl_tests_on_exit EXIT

# rocm is mandatory (hipcc + librccl). MPI is optional: soft-load it and
# degrade to a non-MPI build if unavailable rather than skipping.
preflight_modules "${ROCM_MODULE_NAME}" || exit $?
if [ -z "${ROCM_PATH:-}" ]; then
   echo "ERROR: ROCM_PATH not set even after loading ${ROCM_MODULE_NAME}; pass --rocm-path." >&2
   exit 1
fi

MPI_HOME=""
if [ "${BUILD_MPI}" == "1" ]; then
   if module load "${MPI_MODULE}" 2>/dev/null && command -v mpicc >/dev/null 2>&1; then
      MPI_HOME="$(dirname "$(dirname "$(command -v mpicc)")")"
      echo "rccl-tests: MPI build via '${MPI_MODULE}' (MPI_HOME=${MPI_HOME})"
   else
      echo "rccl-tests: WARNING: MPI module '${MPI_MODULE}' unavailable; building without MPI (single-process)."
      echo "            (use --mpi-module <name> or --build-mpi 0 to silence)"
      BUILD_MPI=0
   fi
fi

_missing=()
for _c in git make; do command -v "${_c}" >/dev/null 2>&1 || _missing+=("${_c}"); done
[ -x "${ROCM_PATH}/bin/hipcc" ] || command -v hipcc >/dev/null 2>&1 || _missing+=("hipcc")
if [ "${#_missing[@]}" -gt 0 ]; then
   echo "ERROR: build tools missing: ${_missing[*]}; skipping."
   exit ${NOOP_RC}
fi

# Makefile GPU_TARGETS is comma-separated (--amdgpu-gfxmodel uses ';').
GPU_TARGETS_MAKE=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/,/g'`

echo ""
echo "============================"
echo " Building RCCL Tests (ref ${GITHUB_BRANCH})"
echo "============================"
echo ""

# Throwaway build dir (removed by the EXIT trap); only the final copy writes
# to the (possibly NFS) install path.
RCCL_TESTS_BUILD_DIR=$(mktemp -d -t rccl-tests-build.XXXXXX)
cd "${RCCL_TESTS_BUILD_DIR}"
# Full clone (not --depth 1 --branch): GITHUB_BRANCH may be a branch, tag, OR
# a commit SHA, and a shallow --branch clone cannot check out an arbitrary
# commit. The rccl-tests repo is small, so the extra history is cheap.
git clone "${RCCL_TESTS_REPO_URL}" rccl-tests-source
cd rccl-tests-source
git checkout --detach "${GITHUB_BRANCH}"
# Resolved rccl-tests source commit, recorded in the modulefile whatis so the
# pinned upstream commit is traceable from `module whatis rccl-tests/<ver>`.
RCCL_TESTS_SRC_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# RCCL lives inside ROCm, so NCCL_HOME=HIP_HOME=ROCM_PATH. GPU_TARGETS is
# passed only when known (empty -> Makefile builds all supported archs).
MAKE_ARGS=( HIP_HOME="${ROCM_PATH}" NCCL_HOME="${ROCM_PATH}" )
[ "${BUILD_MPI}" == "1" ] && MAKE_ARGS+=( MPI=1 MPI_HOME="${MPI_HOME}" )
[ -n "${GPU_TARGETS_MAKE}" ] && MAKE_ARGS+=( GPU_TARGETS="${GPU_TARGETS_MAKE}" )

echo "make -j$(nproc) ${MAKE_ARGS[*]}"
if [[ "${DRY_RUN}" == "0" ]]; then
   make -j"$(nproc)" "${MAKE_ARGS[@]}"

   # The Makefile drops the *_perf binaries into ./build; install them.
   if ! ls build/*_perf >/dev/null 2>&1; then
      echo "ERROR: no *_perf binaries produced in $(pwd)/build" >&2
      ls -l build 2>/dev/null || true; exit 1
   fi
   ${SUDO_INSTALL} mkdir -p "${RCCL_TESTS_PATH}/bin"
   ${SUDO_INSTALL} cp -a build/*_perf "${RCCL_TESTS_PATH}/bin/"
   if [ -n "${SUDO_INSTALL}" ]; then
      ${SUDO_INSTALL} chown -R root:root "${RCCL_TESTS_PATH}"
   fi

   if [ ! -x "${RCCL_TESTS_PATH}/bin/all_reduce_perf" ]; then
      echo "RCCL Tests installation failed -- ${RCCL_TESTS_PATH}/bin/all_reduce_perf missing"
      exit 1
   fi
fi

# Reset the running shell so the next leaf script starts from a clean baseline.
[ "${BUILD_MPI}" == "1" ] && module unload "${MPI_MODULE}" 2>/dev/null || true
module unload "${ROCM_MODULE_NAME}" 2>/dev/null || true

# ── Modulefile (Lmod .lua) ───────────────────────────────────────────
if [[ "${DRY_RUN}" == "0" ]]; then
   ${SUDO_MOD} mkdir -p ${MODULE_PATH}

   # Provenance for the whatis() line; falls back to "unknown" outside a git
   # work tree (Docker layer / release tarball).
   LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
   LEAF_SCRIPT_COMMIT=unknown; LEAF_SCRIPT_DIRTY=unknown
   _leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
   if command -v git >/dev/null 2>&1 && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
      [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"; unset _commit
      [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ] \
         && LEAF_SCRIPT_DIRTY=dirty || LEAF_SCRIPT_DIRTY=clean
   fi
   unset _leaf_dir

   # The - option suppresses leading tabs.
   cat <<-EOF | ${SUDO_MOD} tee ${MODULEFILE}
	whatis("Name: rccl-tests")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: rccl-tests-${RCCL_TESTS_VERSION} (source: ${RCCL_TESTS_SRC_COMMIT}, MPI build: ${BUILD_MPI})")
	whatis("Description: RCCL performance and correctness benchmarks (all_reduce_perf, ...)")
	whatis("URL: https://github.com/ROCm/rccl-tests")
	
	local base = "${RCCL_TESTS_PATH}"
	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("RCCL_TESTS_PATH", base)
	prereq("${ROCM_MODULE_NAME}")
	EOF
   if [ "${BUILD_MPI}" == "1" ]; then
      echo "	load(\"${MPI_MODULE}\")" | ${SUDO_MOD} tee -a ${MODULEFILE}
   fi
fi
