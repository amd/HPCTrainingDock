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
ROCM_VERSION=6.2.0
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mpi4py
BUILD_MPI4PY=0
MPI4PY_VERSION=4.1.0
MPI4PY_PATH=/opt/rocmplus-${ROCM_VERSION}/mpi4py-v${MPI4PY_VERSION}
MPI4PY_PATH_INPUT=""
# --install-path: parent dir; the script appends mpi4py-v${MPI4PY_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
MPI_PATH="/usr"
MPI_MODULE="openmpi"
SUDO="sudo"
# --replace 1: rm -rf the prior install dir + ${MPI4PY_VERSION}.lua before building.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup on non-zero exit.
# See hypre_setup.sh for the full design rationale (single source of truth
# for install layout, replaces main_setup.sh's `replace_pkg`/`PKG_CLEAN_*`).
REPLACE=0
KEEP_FAILED_INSTALLS=0

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-mpi4py [ BUILD_MPI4PY ] default is $BUILD_MPI4PY"
   echo "  --mpi-module [ MPI_MODULE ] default is $MPI_MODULE "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --install-path-no-version [ MPI4PY_PATH_INPUT ] default $MPI4PY_PATH "
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), MPI4PY_PATH = ROCMPLUS_PATH/mpi4py-v\${MPI4PY_VERSION}"
   echo "  --mpi4py-version [ MPI4PY_VERSION ] default is $MPI4PY_VERSION "
   echo "  --mpi-path [MPI_PATH] default is from MPI module"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
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
          ;;
      "--build-mpi4py")
          shift
          BUILD_MPI4PY=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--mpi4py-version")
          shift
          MPI4PY_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path-no-version")
          shift
          MPI4PY_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--mpi-path")
          shift
          MPI_PATH=${1}
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

if [ "${MPI4PY_PATH_INPUT}" != "" ]; then
   # Direct full leaf override (back-compat path; --install-path-no-version semantics unchanged).
   MPI4PY_PATH=${MPI4PY_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # mpi4py_setup.sh appends mpi4py-v${MPI4PY_VERSION} from its own
   # default. Lets main_setup.sh stay version-agnostic for mpi4py.
   MPI4PY_PATH=${ROCMPLUS_PATH_INPUT}/mpi4py-v${MPI4PY_VERSION}
else
   # override path in case ROCM_VERSION or MPI4PY_VERSION has been supplied as input
   MPI4PY_PATH=/opt/rocmplus-${ROCM_VERSION}/mpi4py-v${MPI4PY_VERSION}
fi

# ── AAC7 (HPE/Cray) gate for sudo-avoidance ──────────────────────────
# On an HPE/Cray PE system (AAC7) the install / module trees are typically
# operator-writable (e.g. /shareddata/opt, /shareddata/modules) and the
# build user often has no sudo there, so sudo must be AVOIDED. On AAC6
# (non-Cray) the /shared/apps + /nfsapps trees are root-owned and sudo IS
# required -- and the bash `[ -w ]` test is UNRELIABLE on this NFS client:
# it reported a root-owned dir as writable on a compute node, SUDO was
# dropped, and the --replace `rm -rf` then failed with EACCES from the
# server (slurm 12810, 2026-06-25). So the no-sudo path is restricted to
# root OR a genuinely-writable tree on a Cray system, decided with a REAL
# create/remove probe (mirrors openmpi_setup.sh:pick_sudo_for) rather than
# `[ -w ]`. On non-Cray non-root this preserves origin/main's behavior of
# unconditional sudo.
_is_cray_system() {
   [ -n "${CRAY_MPICH_VERSION:-}" ] \
   || { [ -n "${MPICH_DIR:-}" ] && [ -d "${MPICH_DIR}" ]; } \
   || [ -d /opt/cray/pe/mpich ]
}
# _tree_really_writable <path>: real write probe on the nearest EXISTING
# ancestor of <path> (the leaf dir may not exist yet). Returns 0 iff an
# atomic create+remove succeeds -- the same NFS code path the subsequent
# install ops exercise, so it cannot be fooled by a stale client mode cache.
_tree_really_writable() {
   local p="${1}"
   while [ ! -e "${p}" ]; do p="$(dirname "${p}")"; done
   local probe="${p}/.mpi4py_writeprobe.$$.${RANDOM}"
   if ( umask 077 && : > "${probe}" ) 2>/dev/null; then
      rm -f "${probe}" 2>/dev/null
      return 0
   fi
   return 1
}

# ── Early sudo decision ──────────────────────────────────────────────
# Determine whether privilege escalation is needed BEFORE the --replace
# block and the EXIT trap run, both of which rm install/module paths via
# ${SUDO}. See the AAC7 gate above for why the no-sudo path is Cray-gated
# and uses a real probe. The build branch re-affirms this decision later.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif _is_cray_system && _tree_really_writable "${MPI4PY_PATH}"; then
   SUDO=""
   echo "install tree for ${MPI4PY_PATH} is operator-writable on a Cray system; not using sudo"
fi

# ── BUILD_MPI4PY=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_MPI4PY}" = "0" ]; then
   echo "[mpi4py BUILD_MPI4PY=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── --replace: remove prior install + modulefile BEFORE building ─────
# Only this version's dir + ${MPI4PY_VERSION}.lua are removed; other
# installed versions are left in place for multi-version coexistence.
if [ "${REPLACE}" = "1" ]; then
   echo "[mpi4py --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${MPI4PY_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${MPI4PY_VERSION}{,.lua}"
   ${SUDO} rm -rf "${MPI4PY_PATH}"
   # Remove both flavors (Lmod .lua and Tcl no-extension); only one is ever
   # written per site, but cover both so a flavor switch doesn't orphan one.
   ${SUDO} rm -f  "${MODULE_PATH}/${MPI4PY_VERSION}.lua" "${MODULE_PATH}/${MPI4PY_VERSION}"
fi

# ── Existence guard: skip if this version is already installed ───────
# Replaces the [[ ! -d ${ROCMPLUS}/mpi4py-v${MPI4PY_VERSION} ]] clause
# that previously gated this script's invocation in main_setup.sh; see
# the canonical comment block in extras/scripts/hypre_setup.sh for the
# rationale (single source of truth for the install path; multi-version
# coexistence; honors --mpi4py-version overrides; multi-component-aware
# in scripts that have several install dirs). Placed AFTER --replace
# (so --replace 1 wipes first and falls through to a fresh build) and
# BEFORE the EXIT trap install (so NOOP_RC=43 does not look like a
# failed partial install to fail-cleanup).
NOOP_RC=43
if [ -d "${MPI4PY_PATH}" ]; then
   echo ""
   echo "[mpi4py existence-check] ${MPI4PY_PATH} already installed; skipping."
   echo "                         pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: build-dir cleanup + fail-cleanup ──────────────────────
# Always removes the per-job build dir under /tmp (set later as
# MPI4PY_BUILD_DIR by mktemp -d). On non-zero exit ALSO removes any
# partial install + modulefile this script wrote, unless
# --keep-failed-installs 1 was set. Single source of truth for the
# install layout so the cleanup paths cannot drift from the install
# paths. Replaces main_setup.sh's PKG_CLEAN_DIRS/PKG_CLEAN_MODS for
# this package.
_mpi4py_on_exit() {
   local rc=$?
   # Use ${SUDO} verbatim (NOT ${SUDO:-sudo}): once the build has decided
   # the operator owns a writable tree it sets SUDO="" , and these cleanups
   # (the /tmp build dir always; the install/modulefile on failure) must
   # then run WITHOUT sudo. ${SUDO:-sudo} would resurrect sudo on the
   # empty value and re-trigger a password prompt on every exit. SUDO is
   # always set (default "sudo" at the top of this script), so a bare
   # ${SUDO} is safe even on an early-exit before the writability probe.
   [ -n "${MPI4PY_BUILD_DIR:-}" ] && ${SUDO} rm -rf "${MPI4PY_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[mpi4py fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${MPI4PY_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/${MPI4PY_VERSION}.lua" "${MODULE_PATH}/${MPI4PY_VERSION}"
   elif [ ${rc} -ne 0 ]; then
      echo "[mpi4py fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _mpi4py_on_exit EXIT

echo ""
echo "==================================="
echo "Starting MPI4PY Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_MPI4PY: $BUILD_MPI4PY"
echo "MPI4PY_VERSION: $MPI4PY_VERSION"
echo "MPI4PY_PATH: $MPI4PY_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Loading MPI module: $MPI_MODULE"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

if [ "${BUILD_MPI4PY}" = "0" ]; then

   echo "MPI4PY will not be built, according to the specified value of BUILD_MPI4PY"
   echo "BUILD_MPI4PY: $BUILD_MPI4PY"
   exit

else
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f "${CACHE_FILES}/mpi4py-v${MPI4PY_VERSION}.tgz" ]; then
      echo ""
      echo "============================"
      echo " Installing Cached MPI4PY"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # mpi4py-v${MPI4PY_VERSION}.tgz and contain a top-level
      # directory mpi4py-v${MPI4PY_VERSION}/ so it lands directly
      # at ${MPI4PY_PATH} when extracted under /opt/rocmplus-X.
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/mpi4py-v${MPI4PY_VERSION}.tgz
      chown -R root:root ${MPI4PY_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/mpi4py-v${MPI4PY_VERSION}.tgz
      fi

   else

      echo ""
      echo "============================"
      echo " Building MPI4PY"
      echo "============================"
      echo ""

      # Derive the actual rocm modulefile token to (re-)load. For RC
      # trees (rocm-therock-23.2.0, rocm-afar-22.2.0, ...) the
      # modulefile name does NOT match `rocm/${ROCM_VERSION}` because
      # the ROCM_VERSION here is the SDK numeric (e.g. 7.13.0 for
      # therock-23.2.0). Trying `module load rocm/7.13.0` would fail
      # with "no such file" even though the SDK is already loaded.
      #
      # Strategy: LMOD's LOADEDMODULES is the most authoritative source --
      # it lists the literal modulefile name (e.g. rocm/therock-afar-23.2.1).
      # We pull the first 'rocm/*' entry from there. Falling back to the
      # ROCM_PATH basename works when the install-dir and module names are
      # the same shape (regular releases, afar) but DOES NOT WORK for
      # therock-afar where install dir is rocm-therock-afar-<NUMERIC>
      # while the module is rocm/therock-afar-<RELEASE_TAG>. Last resort
      # for standalone invocation: rocm/${ROCM_VERSION}.
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
      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # Re-affirm the sudo decision (see the AAC7 gate near the top): no
      # sudo only when root, or on a Cray with a genuinely operator-writable
      # tree (real create/remove probe). On non-Cray non-root keep sudo --
      # origin/main behavior -- since the AAC6 NFS trees are root-owned and
      # `[ -w ]` lies on this client.
      if [ "${EUID:-$(id -u)}" -eq 0 ]; then
         SUDO=""
      elif _is_cray_system && _tree_really_writable "${MPI4PY_PATH}"; then
         SUDO=""
         echo "install tree for ${MPI4PY_PATH} is operator-writable on a Cray system; not using sudo"
      else
         echo "using sudo for install path ${MPI4PY_PATH} (requires privileges)"
      fi

      ${SUDO} mkdir -p ${MPI4PY_PATH}
      if [ -n "${SUDO}" ] && [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${MPI4PY_PATH}
      fi

      # Per-job throwaway build dir under /tmp (or $TMPDIR if Slurm
      # set one, e.g. /tmp/admin/<jobid>/). Replaces a clone into
      # ${PWD}/mpi4py which is the shared NFS HPCTrainingDock
      # checkout — concurrent rocm-version jobs would race on that
      # path (matches the spack-clone collision pattern fixed in
      # commit 688fa43). Only `pip install --target=${MPI4PY_PATH}`
      # writes hit NFS. EXIT trap cleans up the build dir and the
      # mpi4py_build_venv it contains.
      MPI4PY_BUILD_DIR=$(mktemp -d -t mpi4py-build.XXXXXX)
      # NOTE: build-dir cleanup is now consolidated into the _mpi4py_on_exit
      # trap installed at the top of this script (after MPI4PY_PATH was
      # finalized) so that the same EXIT handler also does fail-cleanup
      # of any partial install / modulefile.
      cd "${MPI4PY_BUILD_DIR}"

      git clone --branch $MPI4PY_VERSION https://github.com/mpi4py/mpi4py.git
      cd mpi4py

      echo "[model]              = ${MPI_PATH}" >> mpi.cfg
      echo "mpi_dir              = ${MPI_PATH}" >> mpi.cfg
      echo "mpicc                = ${MPI_PATH}/bin/mpicc" >> mpi.cfg
      echo "mpic++               = ${MPI_PATH}/bin/mpic++" >> mpi.cfg
      echo "library_dirs         = %(mpi_dir)s/lib" >> mpi.cfg
      echo "include_dirs         = %(mpi_dir)s/include" >> mpi.cfg

      python3 -m venv mpi4py_build_venv
      source mpi4py_build_venv/bin/activate
      pip install --upgrade pip setuptools wheel cython

      CC=${ROCM_PATH}/bin/amdclang CXX=${ROCM_PATH}/bin/amdclang++ python3 setup.py build --mpi=model
      CC=${ROCM_PATH}/bin/amdclang CXX=${ROCM_PATH}/bin/amdclang++ python3 setup.py bdist_wheel

      pip install -v --target=${MPI4PY_PATH} dist/mpi4py-*.whl

      deactivate

      # Tighten ownership to root only when we have the privilege to do so
      # (running as root, or sudo is in use). In the user-owned-tree /
      # no-sudo case, leave the files owned by the building operator -- who
      # owns the whole install tree anyway -- since `chown root:root` would
      # fail for a non-root user and abort the build under `set -e`.
      if [ "${USER}" != "root" ] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${MPI4PY_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${MPI4PY_PATH} -type d -execdir chown root:root "{}" +

	 ${SUDO} chmod go-w ${MPI4PY_PATH}
      fi

      # MPI4PY_BUILD_DIR (under /tmp, contains the mpi4py clone and
      # the build venv) is removed by the EXIT trap above.
      module unload ${ROCM_MODULE_NAME}
      module unload ${MPI_MODULE}

   fi


   # Create a module file for mpi4py
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   # Prefer no sudo when the module tree is operator-writable on a Cray
   # (user-owned module path, e.g. /shareddata/modules), decided with a real
   # create/remove probe (see the AAC7 gate near the top). On non-Cray
   # non-root fall back to sudo -- origin/main behavior -- since the AAC6
   # module trees are root-owned and `[ -w ]` lies on this NFS client.
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      PKG_SUDO_MOD=""
   elif _is_cray_system && _tree_really_writable "${MODULE_PATH}"; then
      PKG_SUDO_MOD=""
   else
      PKG_SUDO_MOD="sudo"
   fi
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

   # Emit the modulefile in the flavor the site's module tool understands.
   # Lmod reads Lua (.lua); classic Tcl "Environment Modules" (the Cray PE
   # default here, e.g. 3.2.11) reads Tcl and does NOT parse .lua at all
   # (it just reports ERROR:105 "Unable to locate a modulefile"). Detect
   # Lmod via its env markers ($LMOD_CMD / $LMOD_VERSION); otherwise write
   # a Tcl modulefile with NO .lua extension. The two bodies are
   # semantically identical (whatis + PYTHONPATH prepend + load the MPI
   # module).
   if [ -n "${LMOD_CMD:-}" ] || [ -n "${LMOD_VERSION:-}" ]; then
      MODULE_FILE="${MODULE_PATH}/${MPI4PY_VERSION}.lua"
      # The - option suppresses tabs
      cat <<-EOF | ${PKG_SUDO_MOD} tee "${MODULE_FILE}"
	whatis(" MPI4PY - provides Python bindings for MPI")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	
	prepend_path("PYTHONPATH", "${MPI4PY_PATH}")
	load("${MPI_MODULE}")
EOF
   else
      MODULE_FILE="${MODULE_PATH}/${MPI4PY_VERSION}"
      cat <<-EOF | ${PKG_SUDO_MOD} tee "${MODULE_FILE}"
	#%Module
	module-whatis " MPI4PY - provides Python bindings for MPI"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"
	
	prepend-path PYTHONPATH ${MPI4PY_PATH}
	if { ![is-loaded ${MPI_MODULE}] } { module load ${MPI_MODULE} }
EOF
   fi

fi

