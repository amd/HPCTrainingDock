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
if [ "${REPLACE}" = "1" ]; then
   echo "[likwid --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${LIKWID_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${LIKWID_VERSION}.lua"
   ${SUDO} rm -rf "${LIKWID_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${LIKWID_VERSION}.lua"
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
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${LIKWID_VERSION}.lua"
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
   if [ -f ${CACHE_FILES}/likwid.tgz ]; then
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

      source /etc/profile.d/lmod.sh
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
      module load ${ROCM_MODULE_NAME}

      # don't use sudo if user has write access to install path
      if [ -d "$LIKWID_PATH" ]; then
         if [ -w ${LIKWID_PATH} ]; then
            SUDO=""
            echo "WARNING: not using sudo since user has write access to install path"
         else
            echo "WARNING: using install paths that require sudo"
         fi
      else
         # if install path does not exist yet
         echo "WARNING: using sudo, make sure you have sudo privileges"
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

      export ROCM_HOME=${ROCM_PATH}
      make -j
      ${SUDO} make install

      # trap handles cleanup of ${LIKWID_BUILD_ROOT}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${LIKWID_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${LIKWID_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${LIKWID_PATH}
      fi

      module unload ${ROCM_MODULE_NAME}

   fi

   # Create a module file for likwid
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
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${LIKWID_VERSION}.lua
	whatis("LIKWID - Lightweight performance tools")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${LIKWID_PATH}"

	prereq("${ROCM_MODULE_NAME}")
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
EOF

fi
