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

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/misc/hipifly
# BUILD_HIPIFLY is the master "do this script's work at all" gate. Set
# to 0 to short-circuit early (after arg parsing, before --replace and
# the existence check) with NOOP_RC=43, matching the prior wrapper
# `if [[ "${BUILD_HIPIFLY}" == "1" ]]; then run_and_log ...; fi` that
# used to live in bare_system/main_setup.sh. HIPIFLY_MODULE controls
# whether to write the modulefile and is consulted later in the build
# path; it is independent of the BUILD_HIPIFLY master gate.
BUILD_HIPIFLY=1
HIPIFLY_MODULE=0
HIPIFLY_HEADER_PATH=`pwd`
ROCM_VERSION=6.2.0
HIPIFLY_PATH=/opt/rocmplus-${ROCM_VERSION}/hipifly
HIPIFLY_PATH_INPUT=""
# --replace 1: rm -rf prior install dir + dev.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --hipifly-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-hipifly [ BUILD_HIPIFLY ] master gate; 0 = exit NOOP_RC, default $BUILD_HIPIFLY"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hipifly-module [ HIPIFLY_MODULE ], set to 1 to create hipifly, default is $HIPIFLY_MODULE"
   echo "  --hipifly-path [ HIPIFLY_PATH ], default is $HIPIFLY_PATH"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before installing, default $REPLACE"
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
      "--build-hipifly")
          shift
          BUILD_HIPIFLY=${1}
          reset-last
          ;;
      "--hipifly-module")
          shift
          HIPIFLY_MODULE=${1}
          reset-last
          ;;
      "--hipifly-path")
          shift
          HIPIFLY_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          # Alias for --hipifly-path. bare_system/main_setup.sh's
          # path_args helper (see L613-618) emits --install-path for every
          # package; sister scripts (hdf5_setup.sh, kokkos_setup.sh, etc.)
          # already accept it. Without this alias the parser fell through
          # to the catch-all *) -> last -> send-error -> usage path, which
          # exited 1 with only the usage banner in the log (the Error
          # message was silently swallowed because usage exits 1 before
          # send-error's echo runs). Audited as the hipifly rc=1 cause in
          # slurm-7950-rocmplus-7.0.2.out.
          shift
          HIPIFLY_PATH_INPUT=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
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

if [ "${HIPIFLY_PATH_INPUT}" != "" ]; then
   HIPIFLY_PATH=${HIPIFLY_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   HIPIFLY_PATH=/opt/rocmplus-${ROCM_VERSION}/hipifly
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is dev.lua (no version baked in).
# ── BUILD_HIPIFLY=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_HIPIFLY}" = "0" ]; then
   echo "[hipifly BUILD_HIPIFLY=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── Early sudo decision (see mpi4py_setup.sh) ───────────────────────
# Determine whether privilege escalation is needed BEFORE the --replace
# block and EXIT trap (both rm install/module paths via ${SUDO}). When the
# operator owns a writable install tree (e.g. a user-writable
# /shareddata/opt) no sudo is needed -- and forcing it would hit a password
# prompt that fails on a node where the user has no sudo. Probe the nearest
# EXISTING ancestor of HIPIFLY_PATH (the leaf dir does not exist yet). The
# build branch re-affirms this below.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _probe="${HIPIFLY_PATH}"
   while [ ! -e "${_probe}" ]; do _probe="$(dirname "${_probe}")"; done
   # Real write test (mktemp), NOT `[ -w ]`: on NFS `-w` is a LYING probe --
   # it reported "writable" on the compute node for a root:root 0755 tree
   # where actual writes / rm fail (the exact failure mode netcdf_setup.sh
   # warns about). Mirrors the hdf5/cupy/rocshmem mktemp probe.
   _wtest=$(mktemp --tmpdir="${_probe}" .hipifly-write-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_wtest}" ] && [ -f "${_wtest}" ]; then
      rm -f "${_wtest}"
      SUDO=""
      echo "install path ancestor ${_probe} is writable (probe succeeded); not using sudo"
   else
      echo "install path ancestor ${_probe} not user-writable (probe failed); using sudo"
   fi
   unset _wtest
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[hipifly --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HIPIFLY_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/dev{,.lua}"
   ${SUDO} rm -rf "${HIPIFLY_PATH}"
   # Remove both flavors (Lmod .lua and Tcl no-extension).
   ${SUDO} rm -f  "${MODULE_PATH}/dev.lua" "${MODULE_PATH}/dev"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${HIPIFLY_PATH}" ]; then
   echo ""
   echo "[hipifly existence-check] ${HIPIFLY_PATH} already installed; skipping."
   echo "                          pass --replace 1 to force a clean rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (HIPIFLY_BUILD_DIR set
# under HIPIFLY_MODULE=1 below) PLUS fail-cleanup. Replaces the inline
# `trap '... rm HIPIFLY_BUILD_DIR ...' EXIT`.
_hipifly_on_exit() {
   local rc=$?
   # ${SUDO} verbatim (NOT ${SUDO:-sudo}): once the early-probe decides the
   # tree is operator-writable it sets SUDO="" , and these cleanups must
   # then run WITHOUT sudo (else an empty value resurrects a failing
   # password prompt on every exit). SUDO is always set (default "sudo").
   [ -n "${HIPIFLY_BUILD_DIR:-}" ] && ${SUDO} rm -rf "${HIPIFLY_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hipifly fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${HIPIFLY_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/dev.lua" "${MODULE_PATH}/dev"
   elif [ ${rc} -ne 0 ]; then
      echo "[hipifly fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _hipifly_on_exit EXIT

echo ""
echo "==========================================="
echo "Setting Up the HIPIFLY Module"
echo "HIPIFLY_MODULE: $HIPIFLY_MODULE"
echo "HIPIFLY_PATH: $HIPIFLY_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "============================================"
echo ""

if [ "${HIPIFLY_MODULE}" = "0" ]; then

   echo "Hipifly module  will not be created, according to the specified value of HIPIFLY_MODULE"
   echo "HIPIFLY_MODULE: $HIPIFLY_MODULE"
   exit

else

      # SUDO was already decided by the early-probe block above (writable
      # ancestor -> ""). Honor it instead of re-probing the not-yet-created
      # leaf dir (which always forced sudo).
      ${SUDO} mkdir -p ${HIPIFLY_PATH}
      # Per-job throwaway scratch dir under /tmp (or $TMPDIR if Slurm
      # set one). Replaces a wget into ${PWD}/hipifly.h which is the
      # shared NFS HPCTrainingDock checkout — concurrent rocm-version
      # jobs would both download to the same path and the second's
      # `rm ./hipifly.h` could remove the first's file mid-flight.
      # Only the `cp` to ${HIPIFLY_PATH} writes hit NFS.
      HIPIFLY_BUILD_DIR=$(mktemp -d -t hipifly-build.XXXXXX)
      # NOTE: build-dir cleanup is consolidated into _hipifly_on_exit
      # installed above (so the same EXIT handler also does fail-cleanup
      # of any partial install / modulefile).
      cd "${HIPIFLY_BUILD_DIR}"
      wget -q https://raw.githubusercontent.com/amd/HPCTrainingDock/main/extras/sources/hipifly/hipifly.h
      ${SUDO} cp ./hipifly.h ${HIPIFLY_PATH}
      # HIPIFLY_BUILD_DIR (under /tmp) is removed by the EXIT trap.

      # Modulefile-write sudo: probe the nearest existing ancestor of
      # MODULE_PATH for writability (mirrors the install-path early-probe).
      # When the operator owns a writable module tree (e.g. /shareddata/
      # modules) no sudo is used; otherwise fall back to sudo.
      if [ "${EUID:-$(id -u)}" -eq 0 ]; then
         PKG_SUDO_MOD=""
      else
         _mprobe="${MODULE_PATH}"
         while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
         # Real write test (mktemp), NOT `[ -w ]` (NFS lying-probe; see above).
         _mwtest=$(mktemp --tmpdir="${_mprobe}" .hipifly-mod-probe.XXXXXX 2>/dev/null || true)
         if [ -n "${_mwtest}" ] && [ -f "${_mwtest}" ]; then
            rm -f "${_mwtest}"
            PKG_SUDO_MOD=""
         else
            PKG_SUDO_MOD="sudo"
         fi
         unset _mprobe _mwtest
      fi
      ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

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
   # Lmod consumes <name>.lua; classic Tcl `environment-modules` consumes an
   # extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
   # when Lmod is absent (this site runs Tcl Environment Modules 3.2.11).
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      _MODFILE="${MODULE_PATH}/dev.lua"
      _MODFLAVOR="lua"
   else
      _MODFILE="${MODULE_PATH}/dev"
      _MODFLAVOR="tcl"
   fi

   # A consumer satisfies the ROCm dependency with either the local TheRock
   # real module (rocm-new/<ver>) or its alias (rocm/<ver>): PrgEnv-amd-new
   # loads rocm-new directly, while a bare `module load rocm/<ver>` pulls it
   # in under the alias name. Tcl `prereq` with several names is satisfied if
   # ANY is loaded; Lmod's equivalent is prereq_any(). Non-rocm module names
   # are emitted unchanged.
   # AAC7 gate: the rocm-new/<ver> alias is only meaningful on a TheRock /
   # PrgEnv-amd-new site (AAC7), where rocm-new is a real modulefile. On a
   # stock site (e.g. AAC6) only rocm/<ver> exists, so widening the prereq
   # to rocm-new would reference a phantom module name -- gate it on whether
   # a rocm-new modulefile is actually discoverable on MODULEPATH. When it is
   # not, emit the original plain prereq("rocm/<ver>").
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

   # The - option suppresses leading tabs in the heredoc body.
   if [ "${_MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	whatis(" Hipifly header file ")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	${ROCM_PREREQ_LUA}
	setenv("HIPIFLY_PATH","${HIPIFLY_PATH}")
EOF
   else
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	#%Module1.0
	module-whatis " Hipifly header file "
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"
	prereq ${ROCM_PREREQ_TCL}
	setenv HIPIFLY_PATH ${HIPIFLY_PATH}
EOF
   fi
   unset _MODFILE _MODFLAVOR ROCM_PREREQ_TCL ROCM_PREREQ_LUA

fi

