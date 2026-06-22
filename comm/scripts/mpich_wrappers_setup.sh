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
# This script builds a standalone MPICH from source with FC=amdflang
# (C/C++ with gcc/g++, which are the better-tested wrapper backends),
# producing an mpi.mod in the amdflang-new .mod format. The resulting
# install is exposed through a PrgEnv-agnostic modulefile so it can be
# loaded on top of PrgEnv-amd-new/* (the environments that drive
# amdflang). PrgEnv-cray-new/* keep using cray-mpich's crayftn mpi.mod
# natively and do NOT need this.
# ---------------------------------------------------------------------

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/ROCmPlus/mpich-wrappers
BUILD_MPICH_WRAPPERS=0
ROCM_VERSION=23.1.0
ROCM_MODULE=""          # rocm modulefile name to (re)load for amdflang; auto-derived when empty
CRAY_MPICH_VERSION=8.1.33
AMDGPU_GFXMODEL=gfx942
CPU_TYPE=genoa
MPICH_VERSION=4.3.0
LIBFABRIC_PATH=/opt/cray/libfabric/2.2.0rc1
INSTALL_PATH_INPUT=""   # --install-path-no-version: full leaf dir
ROCMPLUS_PATH_INPUT=""  # --install-path: parent dir; mpich-wrappers-v${MPICH_VERSION} appended
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/mpich-wrappers-v${MPICH_VERSION}
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
   echo "  --cray-mpich-version [ CRAY_MPICH_VERSION ] default $CRAY_MPICH_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default $AMDGPU_GFXMODEL"
   echo "  --cpu-type [ CPU_TYPE ] default $CPU_TYPE"
   echo "  --mpich-version [ MPICH_VERSION ] default $MPICH_VERSION"
   echo "  --libfabric-path [ LIBFABRIC_PATH ] default $LIBFABRIC_PATH"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path-no-version [ INSTALL_PATH_INPUT ] full leaf dir, default $INSTALL_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), INSTALL_PATH = ROCMPLUS_PATH/mpich-wrappers-v\${MPICH_VERSION}"
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
# wins; else --install-path is treated as the rocmplus parent dir and
# this script appends mpich-wrappers-v${MPICH_VERSION} so main_setup.sh
# stays version-agnostic; else fall back to the /opt default.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${ROCMPLUS_PATH_INPUT}/mpich-wrappers-v${MPICH_VERSION}
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/mpich-wrappers-v${MPICH_VERSION}
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
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${MOD_TOKEN}"
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

   # Build toolchain: gcc/g++ for C/C++ (the better-tested MPICH wrapper
   # backends) and amdflang for Fortran so the generated mpi.mod is in
   # the amdflang-new .mod format that PrgEnv-amd-new consumers need.
   # PrgEnv-gnu supplies gcc/g++; the rocm module supplies amdflang; the
   # craype + cray-mpich + libfabric bits provide the ch4:ofi network
   # backend wiring on the Cray.
   module purge
   module load PrgEnv-gnu
   module load craype-x86-${CPU_TYPE}
   module load craype-accel-amd-${AMDGPU_GFXMODEL}
   module load cray-python
   module load cray-mpich/${CRAY_MPICH_VERSION}
   module load ${ROCM_MODULE_NAME}

   if [ -d "$INSTALL_PATH" ]; then
      if [ -w ${INSTALL_PATH} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
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

   CC=$(which gcc) \
   CXX=$(which g++) \
   FC=$(which amdflang) \
   F77=$(which amdflang) \
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

   if [[ "${USER}" != "root" ]]; then
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
# Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit).
PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
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

module-whatis "MPICH wrappers built with amdflang for cray-mpich (amdflang-format mpi.mod). MPICH ${MPICH_VERSION}, ROCm ${ROCM_VERSION}."
module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

## Base directory
set base ${INSTALL_PATH}

setenv MPICH_WRAPPERS_DIR \$base

prepend-path PATH \$base/bin
prepend-path LD_LIBRARY_PATH \$base/lib
prepend-path C_INCLUDE_PATH \$base/include
prepend-path CPLUS_INCLUDE_PATH \$base/include
EOF
