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

# Builds the IBM mpitrace library (https://github.com/IBM/mpitrace) -- a
# lightweight MPI profiling library (libmpitrace.so) used via LD_PRELOAD, no
# recompilation of the application required -- and writes a modulefile so that,
# with the module tree on MODULEPATH:
#   module load rocm/<ver> mpitrace/<ver>
#   mpirun -np <N> ./your.exe    # LD_PRELOAD is set automatically by the module
# Simplest use: ./mpitrace_setup.sh --rocm-version <ROCM_VERSION>
# mpitrace only needs mpicc-with-gcc to build (the Fortran MPI wrappers are C
# compiled by mpicc); rocm is loaded only because the openmpi module requires
# it on this cluster. The built libmpitrace.so carries an rpath into the
# rocmplus-<ver>/openmpi tree, so there is one install per rocm+openmpi combo.

ROCM_VERSION=6.4.0
# Skip rocminfo autodetect when --amdgpu-gfxmodel is given: under pipefail an
# unguarded rocminfo can abort the script if the SDK needs a newer glibc than
# the host. mpitrace is not GPU-arch specific; AMDGPU_GFXMODEL is accepted for
# harness compatibility (COMMON_OPTIONS threads it) but otherwise unused.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
MPITRACE_REPO_URL=https://github.com/IBM/mpitrace.git
MPI_MODULE=openmpi
BUILD_MPITRACE=1          # master gate; 0 = exit NOOP_RC (operator opt-out)
REPLACE=0
KEEP_FAILED_INSTALLS=0
INSTALL_PATH_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mpitrace
# Cluster Lmod spider-cache refresh script (bumps the cache so `module load`
# sees the new modulefile without --ignore_cache).
MODULE_CACHE_REFRESH=/nfsapps/ubuntu-24.04/moduleData/refresh_module_cache.sh
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
   local probe="${probe_dir}/.mpitrace_setup_writeprobe.$$.${RANDOM}"
   if ( umask 077 && : > "${probe}" ) 2>/dev/null; then
      rm -f "${probe}" 2>/dev/null; echo ""; return
   fi
   echo "sudo"
}

usage()
{
    echo "Usage:"
    echo "  WARNING: --install-path and --module-path must already exist (the script checks for write permissions)"
    echo "  --amdgpu-gfxmodel [ GFXMODEL ] accepted for harness compatibility; unused (mpitrace is not GPU-arch specific)"
    echo "  --build-mpitrace [ 0|1 ] master gate; 0 = exit NOOP_RC, default $BUILD_MPITRACE"
    echo "  --install-path [ PATH ] parent dir; appends mpitrace-\${ROCM_VERSION}, default /opt/rocmplus-$ROCM_VERSION"
    echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup on failure, default $KEEP_FAILED_INSTALLS"
    echo "  --module-path [ PATH ] default $MODULE_PATH"
    echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
    echo "  --rocm-version [ VER ] default $ROCM_VERSION"
    echo "  --help: print this usage information"
    exit 1
}

send-error() { usage; echo -e "\nError: ${@}"; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--amdgpu-gfxmodel")      shift; AMDGPU_GFXMODEL=${1};         reset-last ;;
      "--build-mpitrace")       shift; BUILD_MPITRACE=${1};          reset-last ;;
      "--install-path")         shift; INSTALL_PATH_INPUT=${1};      reset-last ;;
      "--keep-failed-installs") shift; KEEP_FAILED_INSTALLS=${1};    reset-last ;;
      "--module-path")          shift; MODULE_PATH=${1};             reset-last ;;
      "--replace")              shift; REPLACE=${1};                 reset-last ;;
      "--rocm-version")         shift; ROCM_VERSION=${1};            reset-last ;;
      "--help")                        usage ;;
      "--*")  send-error "Unsupported argument at position $((${n} + 1)) :: ${1}" ;;
      *)      last ${1} ;;
   esac
   n=$((${n} + 1)); shift
done

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
if [ "${BUILD_MPITRACE}" = "0" ]; then
   echo "[mpitrace BUILD_MPITRACE=0] operator opt-out; skipping."
   exit ${NOOP_RC}
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT%/}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}
fi
MPITRACE_PATH="${INSTALL_PATH}/mpitrace-${ROCM_VERSION}"
MODULEFILE="${MODULE_PATH}/${ROCM_VERSION}.lua"

echo ""
echo "============================"
echo " Installing mpitrace with:"
echo "   ROCM_VERSION: $ROCM_VERSION"
echo "   ROCM_MODULE_NAME: ${ROCM_MODULE_NAME}"
echo "   MPITRACE_PATH: $MPITRACE_PATH"
echo "   MPI_MODULE: $MPI_MODULE"
echo "   MODULE_PATH: $MODULE_PATH"
echo "   REPLACE: $REPLACE   KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "============================"
echo ""

# Per-destination sudo (install dir vs module tree), decided by a real write
# probe. Singularity sets SUDO="" which waives elevation everywhere.
if [ -z "${SUDO}" ]; then
   SUDO_INSTALL=""; SUDO_MOD=""
else
   SUDO_INSTALL=$(pick_sudo_for "${MPITRACE_PATH}")
   SUDO_MOD=$(pick_sudo_for "${MODULE_PATH}")
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[mpitrace --replace 1] removing prior install + modulefile if present"
   ${SUDO_INSTALL} rm -rf "${MPITRACE_PATH}"
   ${SUDO_MOD} rm -f  "${MODULEFILE}"
fi

if [ -d "${MPITRACE_PATH}" ]; then
   echo "[mpitrace existence-check] ${MPITRACE_PATH} already installed; skipping (pass --replace 1 to rebuild)."
   exit ${NOOP_RC}
fi

# EXIT trap (armed AFTER the NOOP/skip exits above so a clean skip never runs
# cleanup): always remove the temp build dir (user-owned, under /tmp); on
# failure also remove the partial install + modulefile unless
# --keep-failed-installs 1, using the per-destination sudo decided above.
_mpitrace_on_exit() {
   local rc=$?
   [ -n "${MPITRACE_BUILD_DIR:-}" ] && rm -rf "${MPITRACE_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[mpitrace fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO_INSTALL} rm -rf "${MPITRACE_PATH}"; ${SUDO_MOD} rm -f "${MODULEFILE}"
   fi
   return ${rc}
}
trap _mpitrace_on_exit EXIT

# rocm must be loaded before openmpi (the openmpi module declares rocm as a
# prereq on this cluster); openmpi provides the mpicc-with-gcc mpitrace needs.
preflight_modules "${ROCM_MODULE_NAME}" "${MPI_MODULE}" || exit $?

_missing=()
for _c in git make mpicc; do command -v "${_c}" >/dev/null 2>&1 || _missing+=("${_c}"); done
if [ "${#_missing[@]}" -gt 0 ]; then
   echo "ERROR: build tools missing: ${_missing[*]}; skipping."
   exit ${NOOP_RC}
fi

echo ""
echo "============================"
echo " Building mpitrace"
echo "============================"
echo ""

# Throwaway build dir (removed by the EXIT trap); only the final copy writes
# to the (possibly NFS) install path.
MPITRACE_BUILD_DIR=$(mktemp -d -t mpitrace-build.XXXXXX)
cd "${MPITRACE_BUILD_DIR}"
git clone --depth 1 "${MPITRACE_REPO_URL}" mpitrace-source
cd mpitrace-source/src

# configure copies makefile.in -> makefile and verifies mpicc drives gcc. No
# Fortran/PAPI/binutils options: the Fortran MPI wrappers are C code compiled
# by mpicc, and we build only the core libmpitrace.so.
./configure
make libmpitrace.so

if [ ! -f libmpitrace.so ]; then
   echo "ERROR: build produced no libmpitrace.so in $(pwd)" >&2
   exit 1
fi

${SUDO_INSTALL} mkdir -p "${MPITRACE_PATH}/lib" "${MPITRACE_PATH}/include"
${SUDO_INSTALL} cp libmpitrace.so "${MPITRACE_PATH}/lib/"
${SUDO_INSTALL} cp mpitrace.h "${MPITRACE_PATH}/include/" 2>/dev/null || true
if [ -d ../doc ]; then
   ${SUDO_INSTALL} cp -r ../doc "${MPITRACE_PATH}/doc"
fi
if [ -n "${SUDO_INSTALL}" ]; then
   ${SUDO_INSTALL} chown -R root:root "${MPITRACE_PATH}"
fi

if [ ! -f "${MPITRACE_PATH}/lib/libmpitrace.so" ]; then
   echo "mpitrace installation failed -- ${MPITRACE_PATH}/lib/libmpitrace.so missing"
   exit 1
fi

# Reset the running shell so the next leaf script starts from a clean baseline.
module unload "${MPI_MODULE}" 2>/dev/null || true
module unload "${ROCM_MODULE_NAME}" 2>/dev/null || true

# ── Modulefile (Lmod .lua) ───────────────────────────────────────────
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
	whatis("Name: mpitrace")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: mpitrace-master (rocm ${ROCM_VERSION})")
	whatis("Description: IBM MPI profiling library (libmpitrace.so via LD_PRELOAD)")
	whatis("URL: https://github.com/IBM/mpitrace")

	help([[
	IBM mpitrace: lightweight MPI profiling via LD_PRELOAD (no recompilation).

	Loading this module sets LD_PRELOAD to libmpitrace.so automatically;
	unloading it restores LD_PRELOAD to its previous value (i.e. unsets it).
	Just run your MPI program as usual:

	  module load ${ROCM_MODULE_NAME} mpitrace/${ROCM_VERSION}
	  mpirun -np <N> ./your.exe
	  module unload mpitrace/${ROCM_VERSION}
	]])

	local base = "${MPITRACE_PATH}"
	local lib  = pathJoin(base, "lib", "libmpitrace.so")

	setenv("MPITRACE_PATH", base)
	setenv("MPITRACE_HOME", base)
	setenv("MPITRACE_LIB", lib)
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	-- pushenv sets LD_PRELOAD on load and restores the prior value on unload,
	-- so 'module unload mpitrace' effectively fires the 'unset LD_PRELOAD'.
	pushenv("LD_PRELOAD", lib)
	prereq("${ROCM_MODULE_NAME}")
	load("${MPI_MODULE}")
	EOF

# Refresh the cluster Lmod spider cache so `module load mpitrace` sees the new
# modulefile; without it the file is only visible via --ignore_cache until the
# cluster's periodic refresh runs.
if [ -x "${MODULE_CACHE_REFRESH}" ]; then
   echo "[mpitrace] refreshing Lmod spider cache via ${MODULE_CACHE_REFRESH} ..."
   ${SUDO_MOD:-sudo} "${MODULE_CACHE_REFRESH}" --force || \
      echo "[mpitrace] WARNING: cache refresh failed; users may need 'module --ignore_cache load mpitrace'"
else
   echo "[mpitrace] NOTE: ${MODULE_CACHE_REFRESH} not found; skipping cache refresh."
   echo "                 Users may need 'module --ignore_cache load mpitrace' until the next refresh."
fi
