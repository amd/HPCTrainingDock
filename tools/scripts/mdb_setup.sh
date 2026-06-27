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
ROCM_VERSION=6.4.3
BUILD_MDB=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus/mdb
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
MDB_PATH=""           # default derived below from MDB_VERSION
MDB_PATH_INPUT=""
# --install-path: parent dir; the script appends mdb-v${MDB_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version (mirrors cupy_setup.sh's path convention).
# --install-path-no-version (full leaf dir, no version appended) wins
# over --install-path when both are set, for callers that need exact
# control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# mdb upstream release tag (https://github.com/TomMelt/mdb/tags). Pin
# to the latest stable release so the modulefile name and the install
# dir reflect a real, reproducible version. Pass --mdb-version main to
# build from the current main branch instead.
MDB_VERSION="1.0.6"
# --replace 1: rm -rf prior install dir + ${MDB_VERSION}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-mdb [ BUILD_MDB ] default $BUILD_MDB "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path-no-version [ MDB_PATH ] default $MDB_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), MDB_PATH = ROCMPLUS_PATH/mdb-v\${MDB_VERSION}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --mdb-version [ MDB_VERSION ] git tag/branch/commit to check out after clone (default: $MDB_VERSION)"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
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
          reset-last
          ;;
      "--build-mdb")
          shift
          BUILD_MDB=${1}
          reset-last
          ;;
      "--mdb-version")
          shift
          MDB_VERSION=${1}
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
          MDB_PATH_INPUT=${1}
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

# Resolve MDB_PATH: explicit no-version > parent dir + appended version
# > /opt/rocmplus-${ROCM_VERSION}/mdb-v${MDB_VERSION} default. Matches
# the same priority order as cupy_setup.sh.
if [ "${MDB_PATH_INPUT}" != "" ]; then
   MDB_PATH=${MDB_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   MDB_PATH=${ROCMPLUS_PATH_INPUT}/mdb-v${MDB_VERSION}
else
   MDB_PATH=/opt/rocmplus-${ROCM_VERSION}/mdb-v${MDB_VERSION}
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${MDB_VERSION}.lua to match the
# `tee ${MODULE_PATH}/${MDB_VERSION}.lua` write below.
# ── BUILD_MDB=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_MDB}" = "0" ]; then
   echo "[mdb BUILD_MDB=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# Two modulefile flavors: Lmod consumes <ver>.lua, classic Tcl Environment
# Modules consumes an extensionless Tcl file. Track both so --replace and
# the fail-cleanup trap remove whichever was written previously (and so a
# Tcl site -- e.g. this Cray -- gets a loadable modulefile; see the
# flavor-detection block at modulefile creation below).
MODULEFILE_LUA="${MODULE_PATH}/${MDB_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${MDB_VERSION}"

# Install-path sudo (EARLY): probe the nearest existing ancestor of
# MDB_PATH for user-writability and set SUDO accordingly BEFORE anything
# that uses ${SUDO} -- the --replace rm below and the _mdb_on_exit trap's
# fail-cleanup. The default SUDO=sudo (set above) otherwise makes
# `--replace 1` hit a password prompt on a user-writable tree that has no
# passwordless sudo (this Cray), failing the whole leaf before the build
# branch's own probe (further below) ever runs. Mirrors that probe and is
# idempotent with it.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _iprobe="${MDB_PATH}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .mdb-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "mdb: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo"
   else
      SUDO="sudo"
      echo "mdb: install ancestor ${_iprobe} not user-writable (probe failed); using sudo"
   fi
   unset _iprobe _itest
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[mdb --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${MDB_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${MDB_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${MDB_PATH}" ]; then
   echo ""
   echo "[mdb existence-check] ${MDB_PATH} already installed; skipping."
   echo "                      pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (MDB_BUILD_ROOT, set under
# BUILD_MDB=1) PLUS fail-cleanup of partial install + modulefile.
# Replaces inline build-dir-only traps.
_mdb_on_exit() {
   local rc=$?
   [ -n "${MDB_BUILD_ROOT:-}" ] && ${SUDO} rm -rf "${MDB_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[mdb fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${MDB_PATH}"
      ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[mdb fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _mdb_on_exit EXIT

# mdb is primarily useful on AMD systems with the rocgdb backend, so we
# preflight rocm/<ver> here -- mdb still works against system gdb if the
# rocm module is missing, but pinning to a specific ROCm SDK in the
# rocmplus tree is the whole point of installing per-rocm-version.
#
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
# Two-pass over LOADEDMODULES: prefer a rocm/* matching the requested
# ROCM_VERSION before falling back to the first rocm/*. A Cray
# PrgEnv-amd-new shell can have several rocm/* loaded at once (e.g.
# rocm/7.0.3 AND rocm/7.2.3 alongside the PrgEnv's rocm-new/7.2.3);
# taking the first match would key the build + modulefile on the wrong SDK.
ROCM_MODULE_NAME=""
if [[ -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      case "${_m}" in
         rocm/${ROCM_VERSION}) ROCM_MODULE_NAME="${_m}"; break ;;
      esac
   done
   if [[ -z "${ROCM_MODULE_NAME}" ]]; then
      for _m in ${LOADEDMODULES}; do
         case "${_m}" in
            rocm/*) ROCM_MODULE_NAME="${_m}"; break ;;
         esac
      done
   fi
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
REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" )
preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

echo ""
echo "==================================="
echo "Starting mdb Install with"
echo "ROCM_VERSION:    $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_MDB:       $BUILD_MDB"
echo "MDB_VERSION:     $MDB_VERSION"
echo "MDB_PATH:        $MDB_PATH"
echo "MODULE_PATH:     $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_MDB}" = "0" ]; then

   echo "mdb will not be built, according to the specified value of BUILD_MDB"
   echo "BUILD_MDB: $BUILD_MDB"
   exit

else
   # Per-job throwaway build dir; replaces a fixed `cd /tmp` (with a
   # later `rm -rf mdb mdb_build`) that would race with any other
   # concurrent mdb build on the same node.
   MDB_BUILD_ROOT=$(mktemp -d -t mdb-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into the _mdb_on_exit trap
   # installed above (so the same EXIT handler also does fail-cleanup
   # of any partial install / modulefile).
   cd "${MDB_BUILD_ROOT}"

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f "${CACHE_FILES}/mdb-v${MDB_VERSION}.tgz" ]; then
      echo ""
      echo "============================"
      echo " Installing Cached mdb"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # mdb-v${MDB_VERSION}.tgz and contain a top-level directory
      # mdb-v${MDB_VERSION}/ so it lands directly at ${MDB_PATH}
      # when extracted under /opt/rocmplus-X.
      ${SUDO} mkdir -p ${MDB_PATH}
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/mdb-v${MDB_VERSION}.tgz
      chown -R root:root ${MDB_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/mdb-v${MDB_VERSION}.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building mdb"
      echo "============================"
      echo ""

      # Install-path sudo: probe the nearest existing ancestor of MDB_PATH
      # for user-writability. The old `[ -w $MDB_PATH ]` test only fired
      # when the leaf dir already existed; for a fresh install it left
      # SUDO=sudo even on a user-owned tree, which fails on a cluster with
      # no passwordless sudo (this Cray). Walk up to the first existing dir
      # and probe it. Mirrors the petsc/rocshmem writability probe.
      if [ "${EUID:-$(id -u)}" -eq 0 ]; then
         SUDO=""
      else
         _iprobe="${MDB_PATH}"
         while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
         _itest=$(mktemp --tmpdir="${_iprobe}" .mdb-inst-probe.XXXXXX 2>/dev/null || true)
         if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
            rm -f "${_itest}"
            SUDO=""
            echo "mdb: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
         else
            SUDO="sudo"
            echo "mdb: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
         fi
         unset _iprobe _itest
      fi

      ${SUDO} mkdir -p $MDB_PATH
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} chmod a+w $MDB_PATH
      fi

      # mdb is a pure-Python project; clone the requested tag/branch
      # and pip-install with --target into ${MDB_PATH}. The
      # `[termgraph]` extra pulls in optional terminal-plot support
      # (recommended by upstream README).
      git clone https://github.com/TomMelt/mdb.git
      if [ -n "${MDB_VERSION}" ] && [ "${MDB_VERSION}" != "main" ]; then
         # Upstream tags are published with a leading 'v' (v1.0.6,
         # v1.0.5, ...) except the early 1.0.3 tag which is bare.
         # Try the v-prefixed form first; fall back to the bare ref.
         echo "Checking out mdb ref: ${MDB_VERSION}"
         (cd mdb && (git checkout "v${MDB_VERSION}" 2>/dev/null || git checkout "${MDB_VERSION}"))
      fi
      cd mdb

      # ── Pick a Python >= 3.10 (mdb requires it) ──────────────────────
      # mdb's pyproject pins requires-python >= 3.10. On RHEL9 the default
      # `python3` is 3.9, so a naive `python3 -m venv` install dies with
      # "requires a different Python: 3.9.x not in '>=3.10'". Prefer the
      # plain `python3` when it is already >= 3.10; otherwise fall back to
      # the newest python3.1x on PATH (RHEL9 ships /usr/bin/python3.11; a
      # Cray PE also offers cray-python). If none is found, mark the build
      # uninstallable (NOOP_RC) rather than failing the whole sweep.
      _py_ok() { "$1" -c "import sys; sys.exit(0 if sys.version_info[:2] >= (3,10) else 1)" >/dev/null 2>&1; }
      PYTHON_BIN=""
      if command -v python3 >/dev/null 2>&1 && _py_ok python3; then
         PYTHON_BIN="$(command -v python3)"
      else
         for _c in python3.13 python3.12 python3.11 python3.10; do
            if command -v "${_c}" >/dev/null 2>&1 && _py_ok "${_c}"; then
               PYTHON_BIN="$(command -v "${_c}")"; break
            fi
         done
      fi
      if [ -z "${PYTHON_BIN}" ]; then
         echo "[mdb] no Python >= 3.10 found on PATH (mdb requires >=3.10); marking uninstallable."
         echo "      load a newer python (e.g. 'module load cray-python') and re-run."
         exit ${NOOP_RC}
      fi
      echo "mdb: using ${PYTHON_BIN} ($(${PYTHON_BIN} --version 2>&1)) for the build venv"

      # Build inside a per-job venv (cleaner than touching the host python)
      # and install into ${MDB_PATH} via pip --target so the install is
      # self-contained and doesn't depend on the venv surviving past
      # end-of-build. The console-script shebang is rewritten below to
      # ${PYTHON_BIN} so `mdb` runs under a >=3.10 interpreter regardless
      # of the consumer's default python3.
      "${PYTHON_BIN}" -m venv "${MDB_BUILD_ROOT}/mdb_build"
      # shellcheck disable=SC1091
      source "${MDB_BUILD_ROOT}/mdb_build/bin/activate"
      python3 -m pip install --upgrade pip
      python3 -m pip install --target=$MDB_PATH ".[termgraph]" --no-cache
      deactivate

      export PYTHONPATH=$PYTHONPATH:$MDB_PATH

      # ── Shebang rewrite ────────────────────────────────────────────
      # pip console_script wrappers (mdb) get baked with
      # `#!${MDB_BUILD_ROOT}/mdb_build/bin/python3` because pip
      # --target invokes the venv's python. The /tmp build dir
      # disappears with the EXIT trap at end-of-job, so any
      # PATH-resolved `mdb` afterwards would fail with "bad
      # interpreter". Same root cause + same fix as
      # pytorch_setup.sh / cupy_setup.sh, but we pin the shebang to the
      # ABSOLUTE ${PYTHON_BIN} chosen above (a >=3.10 interpreter) rather
      # than /usr/bin/env python3: on RHEL9 the consumer's default python3
      # is 3.9, under which the mdb package (requires >=3.10) won't even
      # import. ${PYTHON_BIN} is a stable system/Cray interpreter path, so
      # `mdb` works after `module load mdb` regardless of the default
      # python3 (the modulefile still prepends ${MDB_PATH} onto PYTHONPATH).
      if [ -d "${MDB_PATH}/bin" ]; then
         ${SUDO} find ${MDB_PATH}/bin -maxdepth 1 -type f \
            -exec sed -i '1s|^#!.*python3.*$|#!'"${PYTHON_BIN}"'|' {} + 2>/dev/null || true
      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $MDB_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $MDB_PATH -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} chmod go-w $MDB_PATH
      fi

      # cleanup: trap handles ${MDB_BUILD_ROOT}/{mdb,mdb_build}
      cd /
      module unload ${ROCM_MODULE_NAME}
   fi

   # Create a module file for mdb
   #
   # Modulefile-write sudo: probe the module tree for user-writability so a
   # user-owned module tree (a Cray $HOME deployment or a standalone run)
   # needs no sudo, and forcing it would hit a password prompt that fails
   # where the user has no sudo. Mirrors petsc/netcdf_setup.sh.
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      PKG_SUDO_MOD=""
   else
      _mprobe="${MODULE_PATH}"
      while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
      _mtest=$(mktemp --tmpdir="${_mprobe}" .mdb-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         PKG_SUDO_MOD=""
         echo "mdb: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         PKG_SUDO_MOD="sudo"
         echo "mdb: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
      fi
      unset _mprobe _mtest
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

   # ── Modulefile flavor: Lua (Lmod) vs Tcl (classic Environment Modules) ─
   # Lmod consumes <ver>.lua; classic Tcl `environment-modules` consumes an
   # extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
   # when Lmod is absent (this Cray runs Tcl Environment Modules). Without
   # this the .lua file is invisible to a Tcl `module` and `module load
   # mdb/...` fails. Mirrors hdf5/netcdf/fftw/petsc/rocshmem.
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      MODULEFILE="${MODULEFILE_LUA}"; MODFLAVOR="lua"
   else
      MODULEFILE="${MODULEFILE_TCL}"; MODFLAVOR="tcl"
   fi

   # ROCm prereq: accept rocm-new/<ver> OR rocm/<ver>. Under PrgEnv-amd-new
   # the loaded ROCm module is rocm-new/<ver>, not rocm/<ver>, so a plain
   # `prereq rocm/<ver>` fails there. Widen only when a rocm-new modulefile
   # is discoverable on MODULEPATH (AAC7 / TheRock site); stock sites (AAC6)
   # keep the plain rocm/<ver> prereq. Mirrors hipifly/hdf5/petsc.
   rocm_new_available() {
      local _d _OIFS="${IFS}"; IFS=":"
      for _d in ${MODULEPATH:-}; do
         if [ -d "${_d}/rocm-new" ]; then IFS="${_OIFS}"; return 0; fi
      done
      IFS="${_OIFS}"; return 1
   }
   _RPV="${ROCM_MODULE_NAME##*/}"
   case "${ROCM_MODULE_NAME}" in
      rocm/*|rocm-new/*)
         if rocm_new_available; then
            ROCM_PREREQ_TCL="rocm-new/${_RPV} rocm/${_RPV}"
            ROCM_PREREQ_LUA="prereq_any(\"rocm-new/${_RPV}\", \"rocm/${_RPV}\")"
         else
            ROCM_PREREQ_TCL="rocm/${_RPV}"
            ROCM_PREREQ_LUA="prereq(\"rocm/${_RPV}\")"
         fi
         ;;
      *)
         ROCM_PREREQ_TCL="${ROCM_MODULE_NAME}"
         ROCM_PREREQ_LUA="prereq(\"${ROCM_MODULE_NAME}\")"
         ;;
   esac
   unset _RPV

   # The - option suppresses leading tabs.
   if [ "${MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("mdb: an MPI-aware frontend for serial debuggers (gdb / lldb / rocgdb)")
	whatis("Upstream: https://github.com/TomMelt/mdb")
	whatis("Version:  ${MDB_VERSION}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	${ROCM_PREREQ_LUA}
	prepend_path("PYTHONPATH","${MDB_PATH}")
	prepend_path("PATH","${MDB_PATH}/bin")
	setenv("MDB_HOME","${MDB_PATH}")
EOF
   else
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "mdb: an MPI-aware frontend for serial debuggers (gdb / lldb / rocgdb)"
	module-whatis "Upstream: https://github.com/TomMelt/mdb"
	module-whatis "Version:  ${MDB_VERSION}"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_PREREQ_TCL}
	prepend-path PYTHONPATH "${MDB_PATH}"
	prepend-path PATH "${MDB_PATH}/bin"
	setenv MDB_HOME "${MDB_PATH}"
EOF
   fi

fi
