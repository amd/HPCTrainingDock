#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Fail fast on errors and surface failures inside pipes.
set -eo pipefail

# ---------------------------------------------------------------------
# MPICH "wrappers" for Cray systems.
#
# On a Cray, cray-mpich ships per-compiler Fortran module files
# (.../ofi/{amd,cray,gnu,rocm-compiler}/.../include/mpi.mod). The amd
# and rocm-compiler ones are in the classic-Flang "V34" .mod format,
# which the next-generation amdflang (amdflang-new, LLVM Flang) cannot
# read. So a Fortran MPI program compiled with amdflang against
# cray-mpich's mpi.mod fails at the `use mpi` line.
#
# This script builds a standalone MPICH from source with FC=amdflang,
# producing an mpi.mod in the amdflang-new .mod format. The resulting
# install is exposed through a PrgEnv-agnostic modulefile so it can be
# loaded on top of PrgEnv-amd-new/* (the environments that drive
# amdflang). PrgEnv-cray-new/* keep using cray-mpich's crayftn mpi.mod
# natively and do NOT need this.
#
# Two build modes:
#   * --amd-install <rocm-dir>  (preferred; used by the run_rocm_build* /
#     craywrap / therock SDK-provisioning callers): module-free build that
#     points CC/CXX/FC at amdclang/amdclang++/amdflang found directly under
#     <rocm-dir>/{bin,llvm/bin}. No `module purge/load` is performed, so it
#     works in a bare post-extract host context where the rocm module may
#     not be loadable. This is the on-disk path PrgEnv-amd-new consumes.
#   * (no --amd-install): legacy interactive build that `module load`s
#     PrgEnv-gnu + the rocm module and compiles C/C++ with gcc/g++ and
#     Fortran with amdflang. Retained for standalone/interactive use.
# ---------------------------------------------------------------------

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/ROCmPlus/mpich-wrappers
BUILD_MPICH_WRAPPERS=0
ROCM_VERSION=23.1.0
ROCM_MODULE=""          # rocm modulefile name to (re)load for amdflang; auto-derived when empty
# --amd-install: full path to the rocm SDK install dir (e.g.
# /nfsapps/opt/rocm-7.2.3). When set, build module-free against
# amdclang/amdclang++/amdflang found under <dir>/{bin,llvm/bin}; when empty,
# fall back to the legacy `module load PrgEnv-gnu`+rocm gcc/amdflang build.
AMD_INSTALL=""
CRAY_MPICH_VERSION=8.1.33
AMDGPU_GFXMODEL=gfx942
CPU_TYPE=genoa
MPICH_VERSION=4.3.0
# Default libfabric prefix for MPICH ch4:ofi. On this Cray the older
# /opt/cray/libfabric/2.2.0rc1 is a header-less stub (empty include/), so
# 2.3.1 is the correct development install. The build branch below ALSO
# auto-detects the highest /opt/cray/libfabric/* that actually has
# include/rdma/fabric.h + a shared lib, so this default is just the
# expected value; a site override via --libfabric-path still wins.
LIBFABRIC_PATH=/opt/cray/libfabric/2.3.1
INSTALL_PATH_INPUT=""   # --install-path-no-version: full leaf dir
ROCMPLUS_PATH_INPUT=""  # --install-path: parent dir; mpich-wrappers appended
INSTALL_PATH=/opt/rocm-${ROCM_VERSION}/mpich-wrappers
# --replace 1: rm -rf the prior install dir + its modulefile before
# building. --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so
# a partial install is left on disk for post-mortem.
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"

if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocm-module [ ROCM_MODULE ] rocm modulefile name for amdflang; default autodetected"
   echo "  --amd-install [ AMD_INSTALL ] rocm SDK dir for a module-free amdclang/amdflang build; default '$AMD_INSTALL'"
   echo "  --cray-mpich-version [ CRAY_MPICH_VERSION ] default $CRAY_MPICH_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default $AMDGPU_GFXMODEL"
   echo "  --cpu-type [ CPU_TYPE ] default $CPU_TYPE"
   echo "  --mpich-version [ MPICH_VERSION ] default $MPICH_VERSION"
   echo "  --libfabric-path [ LIBFABRIC_PATH ] default $LIBFABRIC_PATH"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path-no-version [ INSTALL_PATH_INPUT ] full leaf dir, default $INSTALL_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), INSTALL_PATH = INSTALL_PATH_PARENT/mpich-wrappers"
   echo "  --build-mpich-wrappers [ BUILD_MPICH_WRAPPERS ], set to 1 to build, default is 0"
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
      "--build-mpich-wrappers")
          shift
          BUILD_MPICH_WRAPPERS=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--rocm-module")
          shift
          ROCM_MODULE=${1}
          reset-last
          ;;
      "--amd-install")
          shift
          AMD_INSTALL=${1}
          reset-last
          ;;
      "--cray-mpich-version")
          shift
          CRAY_MPICH_VERSION=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--cpu-type")
          shift
          CPU_TYPE=${1}
          reset-last
          ;;
      "--mpich-version")
          shift
          MPICH_VERSION=${1}
          reset-last
          ;;
      "--libfabric-path")
          shift
          LIBFABRIC_PATH=${1}
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

# Install-path resolution: --install-path-no-version (full leaf dir)
# wins; else --install-path is treated as the parent dir and this script
# appends mpich-wrappers; else fall back to the /opt rocm-<ver> default.
# The wrappers now live IN the rocm-<ver> SDK tree (not rocmplus-<ver>):
# they are provisioned with the SDK so PrgEnv-amd-new has them at creation.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${ROCMPLUS_PATH_INPUT}/mpich-wrappers
else
   INSTALL_PATH=/opt/rocm-${ROCM_VERSION}/mpich-wrappers
fi

# Module version token. mpich-wrappers is keyed on the ROCm version
# (NOT the MPICH version): there is exactly one wrapper build per ROCm
# tree, and the consuming PrgEnv-amd-new/<pe>-<rocm> module loads it by
# this exact name (mpich-wrappers/${ROCM_VERSION}). This matches the
# legacy mpich-wrappers/<rocm-tree> convention and, critically, lets the
# PrgEnv load an unambiguous, version-matched module instead of a bare
# `module load mpich-wrappers` that could resolve to a legacy global
# build. The built MPICH version is still recorded in whatis() below.
MOD_TOKEN="${ROCM_VERSION}"

# ── BUILD_MPICH_WRAPPERS=0 short-circuit: operator opt-out ───────────
# Mirrors the in-script BUILD_<X>=0 gate pattern (see
# extras/scripts/hypre_setup.sh). Exits NOOP_RC=43 so main_setup.sh's
# run_and_log records SKIPPED(no-op), not OK or FAILED. Placed after arg
# parsing + path resolution and BEFORE --replace so "don't build" is
# never confused with "wipe what is there".
NOOP_RC=43
if [ "${BUILD_MPICH_WRAPPERS}" = "0" ]; then
   echo "[mpich-wrappers BUILD_MPICH_WRAPPERS=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# Derive the rocm modulefile token to (re)load for amdflang. Same
# cascade as extras/scripts/hypre_setup.sh: explicit --rocm-module wins,
# then LOADEDMODULES, then ROCM_PATH basename, then rocm/${ROCM_VERSION}.
ROCM_MODULE_NAME="${ROCM_MODULE}"
if [[ -z "${ROCM_MODULE_NAME}" && -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      case "${_m}" in
         rocm/*|rocm-new/*) ROCM_MODULE_NAME="${_m}"; break ;;
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

# ── Early sudo decision (see hipifly_setup.sh / mpi4py_setup.sh) ─────
# Determine whether privilege escalation is needed BEFORE the --replace
# block and EXIT trap (both rm install/module paths via ${SUDO}). When the
# operator owns a writable install tree (e.g. a user-writable
# /shareddata/opt) no sudo is needed -- and forcing it would hit a password
# prompt that fails on a node where the user has no sudo. Probe the nearest
# EXISTING ancestor of INSTALL_PATH (the leaf dir does not exist yet). The
# build branch re-affirms this below.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _probe="${INSTALL_PATH}"
   while [ ! -e "${_probe}" ]; do _probe="$(dirname "${_probe}")"; done
   if [ -w "${_probe}" ]; then
      SUDO=""
      echo "install path ancestor ${_probe} is writable; not using sudo"
   fi
   unset _probe
fi

# ── --replace: remove prior install + modulefile BEFORE building ─────
if [ "${REPLACE}" = "1" ]; then
   echo "[mpich-wrappers --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${MOD_TOKEN}"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${MOD_TOKEN}"
fi

# ── Existence guard: skip if this version is already installed ───────
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[mpich-wrappers existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                                 pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ──────────
_mpich_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[mpich-wrappers fail-cleanup] rc=${rc}: removing partial install + modulefile"
      # ${SUDO} verbatim (NOT ${SUDO:-sudo}): the early-probe may have set
      # SUDO="" for an operator-writable tree; an empty value here must NOT
      # resurrect a failing password prompt on exit. SUDO is always set.
      ${SUDO} rm -rf "${INSTALL_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/${MOD_TOKEN}"
   elif [ ${rc} -ne 0 ]; then
      echo "[mpich-wrappers fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   if [ -n "${WORK_DIR:-}" ] && [ -d "${WORK_DIR}" ]; then
      rm -rf "${WORK_DIR}"
   fi
   return ${rc}
}
trap _mpich_on_exit EXIT

echo ""
echo "==================================="
echo " Installing MPICH Wrappers"
echo " Install directory: $INSTALL_PATH"
echo " Module directory: $MODULE_PATH"
echo " MPICH Version: $MPICH_VERSION"
echo " ROCm module: $ROCM_MODULE_NAME"
echo " ROCm Version: $ROCM_VERSION"
echo " Cray MPICH Version: $CRAY_MPICH_VERSION"
echo " AMDGPU GFX Model: $AMDGPU_GFXMODEL"
echo " CPU Type: $CPU_TYPE"
echo " Libfabric Path: $LIBFABRIC_PATH"
echo " REPLACE: $REPLACE"
echo " KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ -f "${CACHE_FILES}/mpich-wrappers-v${MPICH_VERSION}.tgz" ]; then
   echo ""
   echo "============================"
   echo " Installing Cached MPICH Wrappers"
   echo "============================"
   echo ""

   # Cache tar must contain a top-level mpich-wrappers-v${MPICH_VERSION}/
   # so it lands directly at ${INSTALL_PATH} when extracted under the
   # rocmplus parent dir.
   ${SUDO} mkdir -p "$(dirname "${INSTALL_PATH}")"
   cd "$(dirname "${INSTALL_PATH}")"
   tar -xpzf ${CACHE_FILES}/mpich-wrappers-v${MPICH_VERSION}.tgz
   ${SUDO} chown -R root:root ${INSTALL_PATH}
   if [ "${USER}" != "sysadmin" ]; then
      ${SUDO} rm -f ${CACHE_FILES}/mpich-wrappers-v${MPICH_VERSION}.tgz
   fi

else
   echo ""
   echo "==================================="
   echo " Building MPICH Wrappers from source"
   echo "==================================="
   echo ""

   # ── Build toolchain ──────────────────────────────────────────────
   # The Fortran compiler is amdflang in BOTH modes so the generated
   # mpi.mod is in the amdflang-new .mod format PrgEnv-amd-new consumers
   # need (cray-mpich ships only classic-Flang "V34" .mod files). The two
   # modes differ in how the compilers are located:
   if [ -n "${AMD_INSTALL}" ]; then
      # ── Module-free amdclang/amdflang build (SDK-provisioning path) ──
      # Point CC/CXX/FC at the AMD LLVM drivers under the rocm SDK install
      # (prefer <root>/bin, fall back to <root>/llvm/bin -- some trees ship
      # amdflang only under llvm/bin). No `module purge/load`, so this runs
      # in a bare post-extract host context where the rocm module may not be
      # loadable. MPICH ch4:ofi is built against libfabric directly, so no
      # cray-mpich/craype module wiring is required at build time.
      MPICH_CC="" MPICH_CXX="" MPICH_FC="" _d=""
      for _d in "${AMD_INSTALL}/bin" "${AMD_INSTALL}/llvm/bin"; do
         [ -z "${MPICH_CC}"  ] && [ -x "${_d}/amdclang"   ] && MPICH_CC="${_d}/amdclang"
         [ -z "${MPICH_CXX}" ] && [ -x "${_d}/amdclang++" ] && MPICH_CXX="${_d}/amdclang++"
         [ -z "${MPICH_FC}"  ] && [ -x "${_d}/amdflang"   ] && MPICH_FC="${_d}/amdflang"
      done
      unset _d
      if [ -z "${MPICH_CC}" ] || [ -z "${MPICH_CXX}" ] || [ -z "${MPICH_FC}" ]; then
         echo "[mpich-wrappers] ERROR: amdclang/amdclang++/amdflang not all found under ${AMD_INSTALL}/{bin,llvm/bin}"
         exit 1
      fi
      echo "[mpich-wrappers] module-free build: CC=${MPICH_CC} CXX=${MPICH_CXX} FC=${MPICH_FC}"
   else
      # ── Legacy module-load build (standalone/interactive use) ────────
      # gcc/g++ for C/C++ via PrgEnv-gnu; amdflang for Fortran via the rocm
      # module. craype + cray-mpich + libfabric provide ch4:ofi wiring.
      # Capture the MODULEPATH entry that currently provides the rocm module
      # BEFORE `module purge`. On this site rocm-new/<ver> lives in a
      # PrgEnv-injected tree (e.g. /shareddata/modules/rocm-<ver>) that
      # `module purge` drops along with PrgEnv-amd-new; without re-exposing it
      # the `module load ${ROCM_MODULE_NAME}` below fails ("Unable to locate a
      # modulefile"). Re-`module use` it after loading PrgEnv-gnu.
      _ROCM_MODULEPATH_DIR=""
      _OLD_IFS="${IFS}"; IFS=":"
      for _d in ${MODULEPATH:-}; do
         if [ -e "${_d}/${ROCM_MODULE_NAME}" ] || [ -e "${_d}/${ROCM_MODULE_NAME}.lua" ]; then
            _ROCM_MODULEPATH_DIR="${_d}"; break
         fi
      done
      IFS="${_OLD_IFS}"; unset _OLD_IFS _d

      module purge
      module load PrgEnv-gnu
      module load craype-x86-${CPU_TYPE}
      module load craype-accel-amd-${AMDGPU_GFXMODEL}
      module load cray-python
      # PrgEnv-gnu already pulls in a default cray-mpich; `module load` of a
      # different version would conflict ("conflicts with the currently loaded
      # module"). Swap to the requested version instead, and fall back to
      # whatever PrgEnv-gnu loaded if the requested one is unavailable. The
      # from-source MPICH build below does NOT link cray-mpich (it builds its
      # own MPICH against libfabric), so the cray-mpich version is only
      # environment wiring and any available one is acceptable.
      module swap cray-mpich cray-mpich/${CRAY_MPICH_VERSION} 2>/dev/null \
         || module load cray-mpich/${CRAY_MPICH_VERSION} 2>/dev/null \
         || echo "[mpich-wrappers] cray-mpich/${CRAY_MPICH_VERSION} unavailable; keeping the PrgEnv default"
      [ -n "${_ROCM_MODULEPATH_DIR}" ] && module use "${_ROCM_MODULEPATH_DIR}"
      module load ${ROCM_MODULE_NAME}
      unset _ROCM_MODULEPATH_DIR

      MPICH_CC=$(which gcc)
      MPICH_CXX=$(which g++)
      MPICH_FC=$(which amdflang)
   fi

   # ── libfabric resolution ─────────────────────────────────────────
   # MPICH ch4:ofi needs a libfabric with development headers
   # (include/rdma/fabric.h) AND a shared lib. On this Cray the
   # versioned dirs under /opt/cray/libfabric are partly stubs (empty
   # include/), so the configured --libfabric-path may have no headers.
   # If the requested LIBFABRIC_PATH lacks fabric.h, auto-pick the
   # highest-version /opt/cray/libfabric/* that has both headers and a
   # libfabric shared object.
   if [ ! -f "${LIBFABRIC_PATH}/include/rdma/fabric.h" ]; then
      echo "[mpich-wrappers] ${LIBFABRIC_PATH} has no include/rdma/fabric.h; auto-detecting libfabric"
      _best_lf=""
      for _lf in $(ls -d /opt/cray/libfabric/*/ 2>/dev/null | sort -V); do
         _lf="${_lf%/}"
         if [ -f "${_lf}/include/rdma/fabric.h" ] \
            && ls "${_lf}"/lib*/libfabric.so* >/dev/null 2>&1; then
            _best_lf="${_lf}"   # keep last (highest version via sort -V)
         fi
      done
      if [ -n "${_best_lf}" ]; then
         echo "[mpich-wrappers] using libfabric ${_best_lf}"
         LIBFABRIC_PATH="${_best_lf}"
      else
         echo "[mpich-wrappers] ERROR: no usable libfabric (include/rdma/fabric.h + lib) under /opt/cray/libfabric"
         exit 1
      fi
      unset _best_lf _lf
   fi

   # Re-affirm the early-probe sudo decision. If the leaf install dir already
   # exists and is writable, no sudo is needed. Otherwise keep whatever the
   # early probe decided (SUDO="" when a writable ancestor was found). Only warn
   # about sudo when we are ACTUALLY going to use it (SUDO non-empty) -- on an
   # operator-writable tree the leaf simply doesn't exist yet, which is not a
   # reason to claim we need sudo.
   if [ -d "$INSTALL_PATH" ] && [ -w "${INSTALL_PATH}" ]; then
      SUDO=""
   fi
   if [ -n "${SUDO}" ]; then
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p ${INSTALL_PATH}
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod -R a+w ${INSTALL_PATH}
   fi

   WORK_DIR=$(mktemp -d)
   cd ${WORK_DIR}

   wget -q https://www.mpich.org/static/downloads/${MPICH_VERSION}/mpich-${MPICH_VERSION}.tar.gz
   tar -xzf mpich-${MPICH_VERSION}.tar.gz
   rm mpich-${MPICH_VERSION}.tar.gz
   cd mpich-${MPICH_VERSION}

   CC="${MPICH_CC}" \
   CXX="${MPICH_CXX}" \
   FC="${MPICH_FC}" \
   F77="${MPICH_FC}" \
   ./configure \
       --prefix=${INSTALL_PATH} \
       --enable-fortran=all \
       --enable-cxx \
       --with-device=ch4:ofi \
       --with-libfabric=${LIBFABRIC_PATH} \
       > log.configure.txt 2>&1

   sed -i 's#wl=""#wl="-Wl,"#g' libtool

   make VERBOSE=1 V=1 -j |& tee log.make.txt

   make VERBOSE=1 V=1 -j install |& tee log.install.txt

   cd "${WORK_DIR}/.."
   rm -rf "${WORK_DIR}"
   unset WORK_DIR

   # Only chown to root / strip group-write when we actually hold
   # privilege (SUDO non-empty). On an operator-writable tree the early
   # probe set SUDO="" -- leave the files owned by the operator.
   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
      ${SUDO} chmod go-w ${INSTALL_PATH}
   fi

fi

# ── Modulefile ────────────────────────────────────────────────────────
# Classic Tcl (#%Module1.0) on purpose, NOT Lua: the consuming system is
# a Cray login node running Cray PE Environment Modules 3.2.11, which is
# Tcl-only and cannot read .lua modulefiles. Tcl also loads fine under
# Lmod, so it is the portable choice. (The rest of the rocmplus tree
# uses .lua for Lmod-only sites; mpich-wrappers is Cray-specific.)
#
# PrgEnv-agnostic on purpose: this module is loaded ON TOP OF
# PrgEnv-amd-new/* (which already provides PE_ENV=AMD + amdflang +
# cray-mpich + libfabric), so it must NOT load PrgEnv-gnu / cray-mpich /
# rocm itself -- doing so would conflict with the active PrgEnv. It just
# front-loads the from-source MPICH bin/lib/include (the include dir
# holds the amdflang-format mpi.mod) so mpicc/mpif90 + `use mpi` resolve
# to this build instead of cray-mpich.
#
# Modulefile-write sudo: probe the nearest existing ancestor of
# MODULE_PATH for writability (mirrors the install-path early-probe).
# When the operator owns a writable module tree (e.g. /shareddata/
# modules) no sudo is used; otherwise fall back to sudo.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   if [ -w "${_mprobe}" ]; then
      PKG_SUDO_MOD=""
   else
      PKG_SUDO_MOD="sudo"
   fi
   unset _mprobe
fi
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

# Provenance for the whatis() line below.
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

cat <<EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${MOD_TOKEN} >/dev/null
#%Module1.0

proc ModulesHelp { } {
    puts stderr "MPICH wrappers built with amdflang (amdflang-format mpi.mod for cray-mpich systems)"
    puts stderr "MPICH Version: ${MPICH_VERSION}"
    puts stderr "ROCm Version: ${ROCM_VERSION}"
}

conflict mpich-wrappers

module-whatis "MPICH wrappers built with amdflang for cray-mpich (amdflang-format mpi.mod). MPICH ${MPICH_VERSION}, ROCm ${ROCM_VERSION}."
module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

## Base directory
set base ${INSTALL_PATH}

setenv MPICH_WRAPPERS_DIR \$base

prepend-path PATH \$base/bin
prepend-path LD_LIBRARY_PATH \$base/lib
prepend-path C_INCLUDE_PATH \$base/include
prepend-path CPLUS_INCLUDE_PATH \$base/include
if {[file isdirectory \$base/lib/pkgconfig]} { prepend-path PKG_CONFIG_PATH \$base/lib/pkgconfig }
EOF
