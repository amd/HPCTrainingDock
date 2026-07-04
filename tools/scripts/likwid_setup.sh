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
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus/likwid
BUILD_LIKWID=0
ROCM_VERSION=6.2.0
LIKWID_VERSION="5.5.1"
LIKWID_PATH=/opt/rocmplus-${ROCM_VERSION}/likwid-v${LIKWID_VERSION}
LIKWID_PATH_INPUT=""
# --install-path: parent dir; the script appends likwid-v${LIKWID_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over
# --install-path when both are set, for callers that need exact control
# of the final install directory (and for legacy --likwid-install-path
# back-compat below).
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf the prior likwid-v${LIKWID_VERSION} install dir
# and its modulefile BEFORE building. Idempotent if nothing to remove.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so the
# partial install + modulefile are left on disk for post-mortem.
# Together these replace the legacy main_setup.sh `replace_pkg` /
# `PKG_CLEAN_DIRS`/`PKG_CLEAN_MODS` arrays. See hypre_setup.sh for
# the canonical template description.
REPLACE=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version (or --likwid-install-path) and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-likwid: default $BUILD_LIKWID"
   echo "  --likwid-version [ LIKWID_VERSION ] default $LIKWID_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path-no-version [ LIKWID_PATH_INPUT ] full leaf dir, default $LIKWID_PATH"
   echo "  --likwid-install-path [ LIKWID_PATH_INPUT ] alias for --install-path-no-version (legacy)"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), LIKWID_PATH = ROCMPLUS_PATH/likwid-v\${LIKWID_VERSION}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--build-likwid")
          shift
          BUILD_LIKWID=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--install-path-no-version"|"--likwid-install-path")
          shift
          LIKWID_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--likwid-version")
          shift
          LIKWID_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
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

# Recompute install path now that ROCM_VERSION / LIKWID_VERSION may have
# been overridden. Precedence (matches hypre_setup.sh):
#   1. --install-path-no-version / --likwid-install-path  (full leaf dir)
#   2. --install-path                                     (parent dir; append likwid-v${LIKWID_VERSION})
#   3. legacy /opt/rocmplus-${ROCM_VERSION}/likwid-v${LIKWID_VERSION}
LIKWID_PATH=/opt/rocmplus-${ROCM_VERSION}/likwid-v${LIKWID_VERSION}
if [ "${LIKWID_PATH_INPUT}" != "" ]; then
   LIKWID_PATH=${LIKWID_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   LIKWID_PATH=${ROCMPLUS_PATH_INPUT}/likwid-v${LIKWID_VERSION}
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   # Stderr-silenced + `|| true`: rocminfo can fail when the SDK is built
   # against a newer glibc than the host (ROCm 7.2.3 binaries need
   # GLIBC_2.38; jammy has 2.35) and under pipefail would kill the script.
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi

# ── BUILD_LIKWID=0 short-circuit: operator opt-out ────────────────────
# Replaces the prior `exit` (rc=0) with NOOP_RC=43 so main_setup.sh's
# run_and_log records this as SKIPPED(no-op) (or DESELECTED when the
# operator used --packages / --quick-installs to gate it off) in the
# per-package summary, instead of silently OK-bucketing a build that
# never happened. See hypre_setup.sh for the canonical pattern.
NOOP_RC=43
if [ "${BUILD_LIKWID}" = "0" ]; then
   echo "[likwid BUILD_LIKWID=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── --replace: remove prior install + modulefile BEFORE building ─────
# Symmetric with --replace-existing 1 in main_setup.sh; safe if
# nothing is there to remove. Other versions' installs are not
# touched (multi-version coexistence; install dir is version-suffixed).
# Two modulefile flavors: Lmod consumes <ver>.lua, classic Tcl Environment
# Modules consumes an extensionless Tcl file. Track both so --replace and
# the fail-cleanup trap remove whichever was written previously (and so a
# Tcl site -- e.g. this Cray -- gets a loadable modulefile; see the
# flavor-detection block at modulefile creation below).
MODULEFILE_LUA="${MODULE_PATH}/${LIKWID_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${LIKWID_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[likwid --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${LIKWID_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${LIKWID_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if this version is already installed ───────
# Replaces what main_setup.sh used to do via `[[ ! -d ... ]]` wrappers.
# Skipped (NOOP_RC=43) when the install dir already exists; pass
# --replace 1 to force a clean rebuild of this version. Placed AFTER
# --replace so a wipe + rebuild flow always passes through to the
# install path below.
if [ -d "${LIKWID_PATH}" ]; then
   echo ""
   echo "[likwid existence-check] ${LIKWID_PATH} already installed; skipping."
   echo "                         pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ──────────
# On a non-zero exit (configure/build/install error, preflight miss,
# etc.) remove any partial artifacts so the next sweep starts clean.
# Skipped when --keep-failed-installs 1 (operator wants to inspect
# the partial install for post-mortem). Cleanup paths derive from the
# same LIKWID_PATH / MODULE_PATH / LIKWID_VERSION variables the
# install side uses, so they cannot drift. See hypre_setup.sh.
_likwid_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[likwid fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${LIKWID_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[likwid fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   if [ -n "${LIKWID_BUILD_ROOT:-}" ] && [ -d "${LIKWID_BUILD_ROOT}" ]; then
      ${SUDO:-sudo} rm -rf "${LIKWID_BUILD_ROOT}"
   fi
   return ${rc}
}
trap _likwid_on_exit EXIT

echo ""
echo "==================================="
echo "Starting LIKWID Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_LIKWID: $BUILD_LIKWID"
echo "LIKWID_VERSION: $LIKWID_VERSION"
echo "LIKWID_PATH: $LIKWID_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

# Build / cache-restore branch (BUILD_LIKWID=0 short-circuit handled above).
if true; then
   if [ -f "${CACHE_FILES}/likwid.tgz" ]; then
      echo ""
      echo "============================"
      echo " Installing Cached LIKWID"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xpzf ${CACHE_FILES}/likwid.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/likwid.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building LIKWID"
      echo "============================"
      echo ""

      # Ensure the `module` function is available in this build branch.
      # Source whichever modules init exists -- Lmod (/etc/profile.d/lmod.sh)
      # OR classic Tcl Environment Modules (/usr/share/Modules/init/bash) --
      # but only if `module` isn't already defined. A hardcoded
      # `source /etc/profile.d/lmod.sh` aborts under `set -e` on a Tcl-only
      # Cray where that file does not exist.
      if ! type module >/dev/null 2>&1; then
         [ -r /etc/profile.d/lmod.sh ]              && . /etc/profile.d/lmod.sh
         [ -r /usr/share/lmod/lmod/init/bash ]      && . /usr/share/lmod/lmod/init/bash
         [ -r /usr/share/Modules/init/bash ]        && . /usr/share/Modules/init/bash
      fi
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
      # taking the first match would key the build + modulefile on the
      # wrong SDK.
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
      module load ${ROCM_MODULE_NAME}

      # Install-path sudo: probe the nearest existing ancestor of
      # LIKWID_PATH for user-writability. The old `[ -w $LIKWID_PATH ]`
      # test only fired when the leaf dir already existed; for a fresh
      # install it left SUDO=sudo even on a user-owned tree, which fails on
      # a cluster with no passwordless sudo (this Cray). Walk up to the
      # first existing dir and probe it instead. Mirrors the petsc/rocshmem
      # writability probe. EUID==0 needs no sudo regardless.
      if [ "${EUID:-$(id -u)}" -eq 0 ]; then
         SUDO=""
      else
         _iprobe="${LIKWID_PATH}"
         while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
         _itest=$(mktemp --tmpdir="${_iprobe}" .likwid-inst-probe.XXXXXX 2>/dev/null || true)
         if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
            rm -f "${_itest}"
            SUDO=""
            echo "likwid: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
         else
            SUDO="sudo"
            echo "likwid: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
         fi
         unset _iprobe _itest
      fi

      ${SUDO} mkdir -p ${LIKWID_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+rwX ${LIKWID_PATH}
      fi

      # Per-job throwaway build dir; replaces a fixed `cd /tmp; rm -rf
      # likwid*` pattern that would race with -- and clobber -- any
      # other concurrent likwid build on the same node (different
      # ROCm versions, sweeps, etc.). NOTE: do NOT register a separate
      # `trap '...' EXIT` here -- that would silently REPLACE the
      # _likwid_on_exit trap registered above and disable fail-cleanup
      # of partial install dirs/modulefile (same audit as
      # hpctoolkit_setup.sh line ~277). Build-dir rm is folded into
      # _likwid_on_exit, which reads ${LIKWID_BUILD_ROOT} lazily.
      LIKWID_BUILD_ROOT=$(mktemp -d -t likwid-build.XXXXXX)
      cd "${LIKWID_BUILD_ROOT}"
      wget -q https://github.com/RRZE-HPC/likwid/archive/refs/tags/v${LIKWID_VERSION}.tar.gz
      tar -xzf v${LIKWID_VERSION}.tar.gz
      cd likwid-${LIKWID_VERSION}
      sed -i -e '/^ROCM_INTERFACE/s/false/true/' \
             -e '/^PREFIX/s!/usr/local!'"${LIKWID_PATH}"'!' \
             config.mk

      # likwid's rocmon backend targets the LEGACY rocprofiler *v1* API
      # (rocprofiler_feature_t / ROCPROFILER_MODE_* / rocprofiler_open), which
      # it reaches via #include <rocprofiler.h> under ROCPROFILERINCLUDE
      # (default $(ROCM_HOME)/include/rocprofiler, the classic layout).
      #
      # ROCm 7.x TheRock/AFAR SDKs (e.g. 7.12.0, 7.13.0, rocm-afar-23.x) REMOVED
      # the v1 API entirely and ship only rocprofiler-sdk (the v3 API) under
      # include/rocprofiler-sdk/. That header EXISTS but does not declare any of
      # the v1 symbols, so pointing ROCPROFILERINCLUDE at it merely converts a
      # "rocprofiler.h: No such file" build error into a
      # "rocprofiler_feature_t undeclared" one (slurm-13278-rocmplus-7.12.0.out
      # ~line 3793: rocmon.c fails, openmpi-independent likwid rc=2).
      #
      # No TAGGED likwid release builds rocmon against rocprofiler-sdk yet: v1
      # rocmon support is the latest tag (v5.5.1, 2025-12-23); the rocprofiler-sdk
      # rewrite landed upstream in PR #716 (2026-01-28) on master, unreleased.
      # NOTE (numeric ROCm 6.4.x / 7.0.x / 7.1.x / 7.2.x still ship the classic
      # v1 header, so rocmon builds fine there -- this only disables the GPU
      # backend on the sdk-only TheRock/AFAR trees.)
      #
      # Gate ROCM_INTERFACE on the actual v1 SYMBOL, not on a file merely named
      # rocprofiler.h. When the v1 API is absent, disable rocmon and build a
      # CPU-only likwid (module still installs; no hard failure) rather than
      # attempting a compile that is guaranteed to fail.
      if grep -rqs 'rocprofiler_feature_t' "${ROCM_PATH}/include/rocprofiler/rocprofiler.h" 2>/dev/null; then
         echo "likwid: legacy rocprofiler v1 API present (include/rocprofiler/rocprofiler.h); ROCM_INTERFACE=true (rocmon enabled)"
      elif grep -rqs 'rocprofiler_feature_t' "${ROCM_PATH}/include/rocprofiler-sdk/rocprofiler.h" 2>/dev/null; then
         echo "likwid: legacy rocprofiler v1 API present under include/rocprofiler-sdk; repointing ROCPROFILERINCLUDE there"
         sed -i -e '/^ROCPROFILERINCLUDE/s#=.*#= $(ROCM_HOME)/include/rocprofiler-sdk#' config.mk
      else
         echo "likwid: NOTE this ROCm SDK has no legacy rocprofiler v1 API (rocprofiler_feature_t not found);"
         echo "likwid:       likwid ${LIKWID_VERSION} rocmon cannot build against rocprofiler-sdk (v3) yet"
         echo "likwid:       (upstream PR #716 is unreleased). Disabling ROCM_INTERFACE -> CPU-only likwid."
         sed -i -e '/^ROCM_INTERFACE/s/true/false/' config.mk
      fi

      # Access mode: likwid's default `accessdaemon` builds a setuid-root
      # helper (likwid-accessD) and `make install` chowns it to root +
      # chmod 4755 -- which requires root. On a user-writable, non-root
      # install (this Cray has no passwordless sudo and a user-owned tree)
      # that `install -o root` step fails. When we cannot install setuid
      # (not EUID 0 and no working sudo), switch to perf_event access mode
      # and disable the daemon/freq setuid tools so `make install`
      # succeeds; likwid-perfctr then reads counters via the Linux
      # perf_event interface. Root installs keep the accessdaemon default.
      if [ "${EUID:-$(id -u)}" -ne 0 ] && [ -z "${SUDO}" ]; then
         echo "likwid: non-root user-writable install -> ACCESSMODE=perf_event, BUILDDAEMON/BUILDFREQ=false (no setuid daemon)"
         sed -i -e '/^ACCESSMODE/s/accessdaemon/perf_event/' \
                -e '/^BUILDDAEMON/s/true/false/' \
                -e '/^BUILDFREQ/s/true/false/' \
                config.mk
      fi

      export ROCM_HOME=${ROCM_PATH}
      make -j
      ${SUDO} make install

      # trap handles cleanup of ${LIKWID_BUILD_ROOT}

      # Normalize ownership to root only when we installed with elevation
      # (SUDO non-empty). On a user-owned tree the files are already
      # correctly owned and a non-sudo `chown root:root` would fail.
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${LIKWID_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${LIKWID_PATH} -type d -execdir chown root:root "{}" +
         ${SUDO} chmod go-w ${LIKWID_PATH}
      fi

      module unload ${ROCM_MODULE_NAME}

   fi

   # Create a module file for likwid
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
      _mtest=$(mktemp --tmpdir="${_mprobe}" .likwid-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         PKG_SUDO_MOD=""
         echo "likwid: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         PKG_SUDO_MOD="sudo"
         echo "likwid: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
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

   # ── rocmon (AMD GPU backend) state for the module load banner ──────────
   # Recompute the ROCM_INTERFACE decision (v1-symbol probe) here so the
   # load-time message is correct on BOTH the from-source and cache-restore
   # paths (the cache path never runs the build-section probe). See the
   # rocprofiler v1 vs rocprofiler-sdk (v3) discussion in the build section.
   if grep -rqs 'rocprofiler_feature_t' \
         "${ROCM_PATH}/include/rocprofiler/rocprofiler.h" \
         "${ROCM_PATH}/include/rocprofiler-sdk/rocprofiler.h" 2>/dev/null; then
      LIKWID_GPU_TAG="GPU-ENABLED"
      LIKWID_GPU_MSG="AMD GPU monitoring (rocmon) is ENABLED for ROCm ${ROCM_VERSION}."
   else
      LIKWID_GPU_TAG="CPU-ONLY"
      LIKWID_GPU_MSG="CPU-ONLY build -- AMD GPU monitoring (rocmon) is DISABLED for ROCm ${ROCM_VERSION} (this SDK lacks the legacy rocprofiler v1 API that likwid ${LIKWID_VERSION} requires)."
   fi

   # ── Modulefile flavor: Lua (Lmod) vs Tcl (classic Environment Modules) ─
   # Lmod consumes <ver>.lua; classic Tcl `environment-modules` consumes an
   # extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
   # when Lmod is absent (this Cray runs Tcl Environment Modules). Without
   # this the .lua file is invisible to a Tcl `module` and `module load
   # likwid/...` fails. Mirrors hdf5/netcdf/fftw/petsc/rocshmem.
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
         ROCM_PREREQ_TCL="rocm-new/${_RPV} rocm/${_RPV}"
         ROCM_PREREQ_LUA="prereq_any(\"rocm-new/${_RPV}\", \"rocm/${_RPV}\")"
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
	whatis("LIKWID - Lightweight performance tools")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${LIKWID_PATH}"

	${ROCM_PREREQ_LUA}
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))

	whatis("AMD GPU support: ${LIKWID_GPU_TAG}")
	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#####################################################################")
	  LmodMessage("#  LIKWID ${LIKWID_VERSION}  (${LIKWID_GPU_TAG})")
	  LmodMessage("#  ${LIKWID_GPU_MSG}")
	  LmodMessage("#####################################################################")
	  LmodMessage("")
	end
EOF
   else
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "LIKWID - Lightweight performance tools"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${LIKWID_PATH}"

	prereq ${ROCM_PREREQ_TCL}
	prepend-path PATH \$base/bin
	prepend-path LD_LIBRARY_PATH \$base/lib

	module-whatis "AMD GPU support: ${LIKWID_GPU_TAG}"
	if { [module-info mode load] } {
	  puts stderr ""
	  puts stderr "#####################################################################"
	  puts stderr "#  LIKWID ${LIKWID_VERSION}  (${LIKWID_GPU_TAG})"
	  puts stderr "#  ${LIKWID_GPU_MSG}"
	  puts stderr "#####################################################################"
	  puts stderr ""
	}
EOF
   fi

fi
