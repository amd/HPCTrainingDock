#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Fail fast on errors (errexit) and surface failures inside pipes
# (pipefail). Without this the audited PnetCDF + netcdf-c failures in
# job 7865 were hidden under rc=0 and the modulefiles were still
# written. Note: NOT using -u (nounset); some conditional code paths
# below intentionally use unset variables.
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
NETCDF_C_MODULE_PATH=/etc/lmod/modules/ROCmPlus/netcdf-c
NETCDF_F_MODULE_PATH=/etc/lmod/modules/ROCmPlus/netcdf-fortran
PNETCDF_MODULE_PATH=/etc/lmod/modules/ROCmPlus/pnetcdf
BUILD_NETCDF=0
ROCM_VERSION=6.2.0
ROCM_MODULE="rocm"
C_COMPILER=gcc
C_COMPILER_INPUT=""
CXX_COMPILER=g++
CXX_COMPILER_INPUT=""
F_COMPILER=gfortran
F_COMPILER_INPUT=""
NETCDF_C_VERSION="4.10.0"
# NETCDF_F_VERSION is auto-derived from NETCDF_C_VERSION via the
# NETCDF_C_TO_F map below unless the operator passes
# --netcdf-f-version explicitly (which writes NETCDF_F_VERSION_INPUT).
# The map keeps the leaf script as the single source of truth for the
# C->F compatibility matrix; main_setup.sh exposes only --netcdf-c-version
# as the sweep-CLI knob (see bare_system/main_setup.sh PKG_VER_FLAG).
NETCDF_F_VERSION=""
NETCDF_F_VERSION_INPUT=""
NETCDF_F_VERSION_FALLBACK="4.6.2"
# PnetCDF version (build-time dep, also installed as its own first-class
# rocmplus module after the 2026-05-20 versioning migration). Default is
# the latest stable upstream release. Operator override via
# --pnetcdf-version; main_setup.sh threads it through from the sweep CLI
# (--pnetcdf-version on run_rocmplus_install_sweep.sh).
PNETCDF_VERSION="1.14.1"
# C->F compatibility map. Update when netcdf-fortran releases catch up.
# netcdf-fortran tracks netcdf-c slowly, so most C bumps share an F.
declare -A NETCDF_C_TO_F=(
   [4.9.3]="4.6.2"
   [4.10.0]="4.6.2"
)
# C->HDF5-module compatibility map. The preflight uses this to pick the
# correct hdf5 modulefile when multiple coexist on the tree (e.g.
# rocmplus-7.2.3 has both hdf5/1.14.6 and hdf5/2.1.1 after the
# 2026-05-20 hdf5 2.x rollout). Empty string = bare `hdf5` module (let
# Lmod default-resolution pick; preserved for legacy 4.9.3 builds where
# 1.14.x was the only hdf5 available at original build time).
# netcdf-c 4.10.0 added HDF5 2.x compat (PR #3237); it should NOT be
# built against 1.14.x (configure aborts on missing 2.x APIs).
declare -A NETCDF_C_TO_HDF5=(
   [4.9.3]=""
   [4.10.0]="2.1.1"
)
HDF5_MODULE="hdf5"
# netcdf depends on hdf5, which itself depends on openmpi. Without
# loading openmpi explicitly here, the only MPI on the build path was
# whatever hdf5's modulefile happened to drag in -- when hdf5 was
# rebuilt against a /nfsapps rocm SDK that exposed mismatched libstdc++,
# netcdf's PnetCDF + netcdf-c configure picked up the wrong toolchain.
# Loading the openmpi module up front fixes that and matches what
# hdf5_setup.sh, hypre_setup.sh, petsc_setup.sh, etc. already do.
MPI_MODULE="openmpi"
# NETCDF_INSTALL_BASE is the rocmplus parent directory under which the
# three netcdf components land at top level so multiple versions can
# coexist:
#   ${NETCDF_INSTALL_BASE}/netcdf-c-v${NETCDF_C_VERSION}
#   ${NETCDF_INSTALL_BASE}/netcdf-fortran-v${NETCDF_F_VERSION}
#   ${NETCDF_INSTALL_BASE}/pnetcdf       (build-time-only dep, unversioned)
NETCDF_INSTALL_BASE=/opt/rocmplus-${ROCM_VERSION}
NETCDF_INSTALL_BASE_INPUT=""
ENABLE_PNETCDF="OFF"
# Per-component --replace flags. netcdf is multi-component (similar in
# spirit to openmpi_setup.sh's --replace-xpmem/--replace-ucx/...), so
# rather than a single coarse --replace we expose one knob per
# top-level install dir under ${NETCDF_INSTALL_BASE}:
#   --replace-netcdf-c   removes netcdf-c-v${NETCDF_C_VERSION} + its .lua
#   --replace-netcdf-f   removes netcdf-fortran-v${NETCDF_F_VERSION} + .lua
#   --replace-pnetcdf    removes the (unversioned) pnetcdf build-only dep
# --replace is kept as a convenience alias that flips ALL three on (and
# is what main_setup.sh threads through from --replace-existing).
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
REPLACE_NETCDF_C=0
REPLACE_NETCDF_F=0
REPLACE_PNETCDF=0
KEEP_FAILED_INSTALLS=0

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
# VERSION_CODENAME is a Debian/Ubuntu field and is ABSENT on RHEL-family
# /etc/os-release. Under `set -eo pipefail` the grep no-match (rc=1)
# propagates through the pipeline and aborts the whole script before any
# output -- the silent-exit-1 failure mode seen on RHEL 9.6 Cray nodes.
# Tolerate the missing field with `|| true` (DISTRO_CODENAME stays empty,
# which is fine -- it is only used for opensuse messaging below).
DISTRO_CODENAME=`{ cat /etc/os-release | grep '^VERSION_CODENAME' || true; } | sed -e 's/VERSION_CODENAME=//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path, --netcdf-c-module-path,  and --netcdf-f-module-path the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocm-module [ ROCM_MODULE ] default $ROCM_MODULE"
   echo "  --netcdf-c-version [ NETCDF_C_VERSION ] default $NETCDF_C_VERSION"
   echo "  --netcdf-f-version [ NETCDF_F_VERSION ] auto-derived from NETCDF_C_VERSION via NETCDF_C_TO_F map; pass explicitly to override (fallback: $NETCDF_F_VERSION_FALLBACK)"
   echo "  --pnetcdf-version  [ PNETCDF_VERSION ] default $PNETCDF_VERSION; install lands at <base>/pnetcdf-v\$PNETCDF_VERSION and emits a pnetcdf/\$PNETCDF_VERSION modulefile"
   echo "  --netcdf-c-module-path [ NETCDF_C_MODULE_PATH ] default $NETCDF_C_MODULE_PATH"
   echo "  --netcdf-f-module-path [ NETCDF_F_MODULE_PATH ] default $NETCDF_F_MODULE_PATH"
   echo "  --pnetcdf-module-path  [ PNETCDF_MODULE_PATH ] default $PNETCDF_MODULE_PATH"
   echo "  --hdf5-module [ HDF5_MODULE ] default $HDF5_MODULE"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --install-path [ NETCDF_INSTALL_BASE ] BASE dir; netcdf-c lands in <base>/netcdf-c-v\$NETCDF_C_VERSION, netcdf-fortran in <base>/netcdf-fortran-v\$NETCDF_F_VERSION, pnetcdf in <base>/pnetcdf-v\$PNETCDF_VERSION; default $NETCDF_INSTALL_BASE"
   echo "  --c-compiler [ C_COMPILER ] default ${C_COMPILER}"
   echo "  --cxx-compiler [ CXX_COMPILER ] default ${CXX_COMPILER}"
   echo "  --f-compiler [ F_COMPILER ] default ${F_COMPILER}"
   echo "  --build-netcdf [ BUILD_NETCDF ], set to 1 to build netcdf-c and netcdf-fortran, default is 0"
   echo "  --replace [ 0|1 ] convenience: same as --replace-netcdf-c 1 --replace-netcdf-f 1 --replace-pnetcdf 1, default $REPLACE"
   echo "  --replace-netcdf-c [ 0|1 ] remove prior netcdf-c install + modulefile before building, default $REPLACE_NETCDF_C"
   echo "  --replace-netcdf-f [ 0|1 ] remove prior netcdf-fortran install + modulefile before building, default $REPLACE_NETCDF_F"
   echo "  --replace-pnetcdf  [ 0|1 ] remove prior pnetcdf install before building, default $REPLACE_PNETCDF"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
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
      "--build-netcdf")
          shift
          BUILD_NETCDF=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--netcdf-c-module-path")
          shift
          NETCDF_C_MODULE_PATH=${1}
          reset-last
          ;;
      "--netcdf-f-module-path")
          shift
          NETCDF_F_MODULE_PATH=${1}
          reset-last
          ;;
      "--pnetcdf-module-path")
          shift
          PNETCDF_MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          NETCDF_INSTALL_BASE_INPUT=${1}
          reset-last
          ;;
      "--hdf5-module")
          shift
          HDF5_MODULE=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--c-compiler")
          shift
          C_COMPILER=${1}
          reset-last
          ;;
      "--cxx-compiler")
          shift
          CXX_COMPILER=${1}
          reset-last
          ;;
      "--f-compiler")
          shift
          F_COMPILER=${1}
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
      "--netcdf-c-version")
          shift
          NETCDF_C_VERSION=${1}
          reset-last
          ;;
      "--netcdf-f-version")
          shift
          NETCDF_F_VERSION_INPUT=${1}
          reset-last
          ;;
      "--pnetcdf-version")
          shift
          PNETCDF_VERSION=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
          reset-last
          ;;
      "--replace-netcdf-c")
          shift
          REPLACE_NETCDF_C=${1}
          reset-last
          ;;
      "--replace-netcdf-f")
          shift
          REPLACE_NETCDF_F=${1}
          reset-last
          ;;
      "--replace-pnetcdf")
          shift
          REPLACE_PNETCDF=${1}
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

# ── Auto-derive NETCDF_F_VERSION from NETCDF_C_VERSION ────────────────
# Single sweep-CLI knob is --netcdf-c-version (see main_setup.sh
# PKG_VER_FLAG[netcdf]); the matching netcdf-fortran release is looked
# up in NETCDF_C_TO_F above. An explicit --netcdf-f-version (passed
# directly to this leaf script) still wins. If the C version is not in
# the map we fall back to NETCDF_F_VERSION_FALLBACK with a loud
# warning -- silently picking a stale F version against a new C would
# produce broken modulefiles that fail at link time, not build time.
if [ -n "${NETCDF_F_VERSION_INPUT}" ]; then
   NETCDF_F_VERSION="${NETCDF_F_VERSION_INPUT}"
   echo "netcdf: using operator-supplied netcdf-fortran version ${NETCDF_F_VERSION} (NETCDF_C_VERSION=${NETCDF_C_VERSION})"
elif [ -n "${NETCDF_C_TO_F[${NETCDF_C_VERSION}]:-}" ]; then
   NETCDF_F_VERSION="${NETCDF_C_TO_F[${NETCDF_C_VERSION}]}"
   echo "netcdf: auto-picked netcdf-fortran ${NETCDF_F_VERSION} for netcdf-c ${NETCDF_C_VERSION} (from NETCDF_C_TO_F map)"
else
   echo "WARNING: no netcdf-fortran version mapped for netcdf-c ${NETCDF_C_VERSION};" >&2
   echo "         falling back to ${NETCDF_F_VERSION_FALLBACK}. Add an entry to" >&2
   echo "         NETCDF_C_TO_F in netcdf_setup.sh, or pass --netcdf-f-version" >&2
   echo "         to override explicitly." >&2
   NETCDF_F_VERSION="${NETCDF_F_VERSION_FALLBACK}"
fi

if [ "${NETCDF_INSTALL_BASE_INPUT}" != "" ]; then
   NETCDF_INSTALL_BASE=${NETCDF_INSTALL_BASE_INPUT}
else
   # override base in case ROCM_VERSION has been supplied as input
   NETCDF_INSTALL_BASE=/opt/rocmplus-${ROCM_VERSION}
fi
# Strip a trailing "/netcdf" for backward compatibility with callers
# (e.g. older main_setup.sh) that pre-appended the leaf dir.
NETCDF_INSTALL_BASE=${NETCDF_INSTALL_BASE%/}
NETCDF_INSTALL_BASE=${NETCDF_INSTALL_BASE%/netcdf}

NETCDF_C_PATH=${NETCDF_INSTALL_BASE}/netcdf-c-v${NETCDF_C_VERSION}
NETCDF_F_PATH=${NETCDF_INSTALL_BASE}/netcdf-fortran-v${NETCDF_F_VERSION}
# PnetCDF install path is now versioned (2026-05-20). Prior installs at
# the unversioned <base>/pnetcdf path on the live tree were migrated to
# <base>/pnetcdf-v1.14.0 with a backward-compat symlink so existing
# netcdf-c modulefiles that bake the unversioned path still resolve.
PNETCDF_PATH=${NETCDF_INSTALL_BASE}/pnetcdf-v${PNETCDF_VERSION}

# ── BUILD_NETCDF=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_NETCDF}" = "0" ]; then
   echo "[netcdf BUILD_NETCDF=0] operator opt-out; skipping (no source build, no cache restore for any of netcdf-c, netcdf-fortran, pnetcdf)."
   exit ${NOOP_RC}
fi

# ── Early sudo decision (port of hdf5_setup.sh early-probe) ──────────
# Decide whether privilege escalation is needed BEFORE the --replace block
# and EXIT trap (both rm install dirs / modulefiles via ${SUDO}). The
# from-source branch re-affirms this later with a real touch-probe, but that
# is too late for --replace / fail-cleanup. On a Cray the rocmplus tree under
# /shareddata is user-writable and the compute nodes have NO passwordless
# sudo -- so a default SUDO="sudo" made `--replace 1` (and the EXIT-trap
# fail-cleanup) abort with "sudo: a password is required", and partial
# mkdir'd install dirs were then left behind (causing a later false
# "already installed" skip). Probe the nearest EXISTING ancestor of
# NETCDF_INSTALL_BASE; if writable, clear SUDO.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :  # already cleared (e.g. inside a Singularity container)
else
   _probe="${NETCDF_INSTALL_BASE}"
   while [ ! -e "${_probe}" ]; do _probe="$(dirname "${_probe}")"; done
   # Real touch probe (mktemp), NOT `[ -w ]`: on /nfsapps (NFSv4 + ACLs)
   # `[ -w root-owned-755-dir ]` returned TRUE on a compute node for a
   # non-root user while real writes still hit EACCES (slurm 12810) -- the
   # same lying-probe failure mode the from-source re-probe + the
   # modulefile-write PKG_SUDO_MOD pattern below already avoid. A wrong
   # early SUDO="" here would make --replace's rm/mkdir and the EXIT-trap
   # fail-cleanup die on the root-owned /nfsapps tree. Mirrors
   # hdf5/cupy/magma_setup.sh.
   _wtest=$(mktemp --tmpdir="${_probe}" .netcdf-early-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_wtest}" ] && [ -f "${_wtest}" ]; then
      rm -f "${_wtest}"
      SUDO=""
      echo "netcdf: install base ancestor ${_probe} is user-writable (probe succeeded); not using sudo for install/replace/cleanup"
   else
      echo "netcdf: install base ancestor ${_probe} not user-writable (probe failed); using sudo for install/replace/cleanup"
   fi
   unset _probe _wtest
fi

# ── Early sudo decision for the MODULE tree (separate from install tree) ──
# The modulefiles live in a DIFFERENT tree (NETCDF_*_MODULE_PATH, e.g.
# /shared/apps/modules/.../rocmplus-<v>/netcdf-c) than the install base
# (NETCDF_INSTALL_BASE, e.g. /shared/apps/ubuntu/opt/rocmplus-<v>). These two
# trees can have DIFFERENT ownership: on AAC the install tree is user-writable
# (so the early probe above clears ${SUDO}) but the module tree is root-owned.
# The --replace block and the EXIT-trap fail-cleanup remove the OLD modulefile
# with sudo-or-not, and keying that off the install-tree ${SUDO}="" made the
# modulefile rm hit:
#   rm: cannot remove '.../netcdf-c/4.10.0.lua': Permission denied
# which under `set -e` aborted the whole build BEFORE compiling (7.2.3 nightly,
# job 12981). Decide sudo for modulefile REMOVAL independently by probing the
# module tree's nearest existing ancestor -- the same mktemp touch-probe the
# PKG_SUDO_MOD block below uses for modulefile WRITES, but computed early so
# --replace / fail-cleanup can delete a root-owned modulefile. mktemp (NOT
# `[ -w ]`) for the NFS/ACL lying-probe reason noted above. On a Cray the
# module tree is user-writable and compute nodes have no passwordless sudo, so
# the probe correctly yields SUDO_MOD="" there (no spurious `sudo` prompt).
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO_MOD=""
else
   _mprobe="${NETCDF_C_MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mwtest=$(mktemp --tmpdir="${_mprobe}" .netcdf-early-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mwtest}" ] && [ -f "${_mwtest}" ]; then
      rm -f "${_mwtest}"
      SUDO_MOD=""
      echo "netcdf: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile removal"
   else
      SUDO_MOD="sudo"
      echo "netcdf: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile removal"
   fi
   unset _mprobe _mwtest
fi

# ── --replace: remove prior installs + modulefiles BEFORE building ────
# --replace 1 acts as a convenience alias that flips all three
# component knobs on. Individual --replace-netcdf-{c,f}/--replace-pnetcdf
# flags still win if the operator wants finer-grained control.
if [ "${REPLACE}" = "1" ]; then
   REPLACE_NETCDF_C=1
   REPLACE_NETCDF_F=1
   REPLACE_PNETCDF=1
fi
if [ "${REPLACE_NETCDF_C}" = "1" ]; then
   echo "[netcdf --replace-netcdf-c 1] removing prior netcdf-c install + modulefile if present"
   echo "  install dir: ${NETCDF_C_PATH}"
   echo "  modulefile:  ${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}{,.lua}"
   ${SUDO} rm -rf "${NETCDF_C_PATH}"
   # Modulefile removal uses ${SUDO_MOD} (module-tree decision), not ${SUDO}
   # (install-tree): the two trees can differ in ownership. Remove both
   # flavors (Lmod .lua and Tcl no-extension).
   ${SUDO_MOD} rm -f  "${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}.lua" "${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}"
fi
if [ "${REPLACE_NETCDF_F}" = "1" ]; then
   echo "[netcdf --replace-netcdf-f 1] removing prior netcdf-fortran install + modulefile if present"
   echo "  install dir: ${NETCDF_F_PATH}"
   echo "  modulefile:  ${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}{,.lua}"
   ${SUDO} rm -rf "${NETCDF_F_PATH}"
   # Modulefile removal uses ${SUDO_MOD} (module-tree decision), not ${SUDO}.
   # Remove both flavors (Lmod .lua and Tcl no-extension).
   ${SUDO_MOD} rm -f  "${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}.lua" "${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}"
fi
if [ "${REPLACE_PNETCDF}" = "1" ]; then
   echo "[netcdf --replace-pnetcdf 1] removing prior pnetcdf install"
   echo "  install dir: ${PNETCDF_PATH}"
   ${SUDO} rm -rf "${PNETCDF_PATH}"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Multi-component: skip ONLY if all three components (netcdf-c-v${VER},
# netcdf-fortran-v${VER}, pnetcdf) are already on disk. If any one is
# missing we proceed -- the per-component build branches below
# short-circuit on the components that are already present. This is
# more correct than the old main_setup.sh `[[ ! -d netcdf-c-v${VER} ]]`
# guard, which could leave netcdf-fortran or pnetcdf permanently
# unbuilt if netcdf-c happened to land first.
NOOP_RC=43
if [ -d "${NETCDF_C_PATH}" ] && [ -d "${NETCDF_F_PATH}" ] && [ -d "${PNETCDF_PATH}" ]; then
   echo ""
   echo "[netcdf existence-check] all three components already installed; skipping."
   echo "  netcdf-c:       ${NETCDF_C_PATH}"
   echo "  netcdf-fortran: ${NETCDF_F_PATH}"
   echo "  pnetcdf:        ${PNETCDF_PATH}"
   echo "  pass --replace 1 (or per-component --replace-netcdf-{c,f}/--replace-pnetcdf) to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Per-component pre-existence flags. Used by:
#   (a) the build branches below to skip components already on disk
#       (enables single-component builds when --pnetcdf-version is
#       bumped while netcdf-c / netcdf-fortran are already installed),
#   (b) the EXIT trap so fail-cleanup only nukes dirs we created in
#       this run (don't wipe a working sibling component on failure).
_pre_existed_netcdf_c=0
_pre_existed_netcdf_f=0
_pre_existed_pnetcdf=0
[ -d "${NETCDF_C_PATH}" ] && _pre_existed_netcdf_c=1
[ -d "${NETCDF_F_PATH}" ] && _pre_existed_netcdf_f=1
[ -d "${PNETCDF_PATH}"  ] && _pre_existed_pnetcdf=1

# ── EXIT trap: fail-cleanup of all three components ──────────────────
# On non-zero exit, remove any partial install + modulefile this script
# may have written for ANY of the three components, since we don't know
# in advance which one was in flight. Replaces main_setup.sh
# PKG_CLEAN_*[netcdf]/[netcdf-fortran]/[pnetcdf]. Skipped when
# --keep-failed-installs 1.
_netcdf_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[netcdf fail-cleanup] rc=${rc}: removing partial installs + modulefiles for components this run created"
      # Only nuke components that did NOT pre-exist at script entry.
      # Otherwise a single-component build (e.g. only pnetcdf-v1.14.1 on
      # top of an existing netcdf-c-v4.10.0) would wipe the working
      # sibling component on PnetCDF build failure.
      # Remove both modulefile flavors (Lmod .lua and Tcl no-extension).
      # Install dirs use ${SUDO} (install-tree decision); modulefiles use
      # ${SUDO_MOD} (module-tree decision) -- the two trees can have different
      # ownership (AAC: install-tree user-writable, module-tree root-owned).
      # Both are verbatim (NOT ${VAR:-sudo}): a user-writable tree clears the
      # respective var to "" and cleanup must then run WITHOUT sudo (compute
      # nodes have no passwordless sudo). Mirrors hdf5_setup.sh.
      if [ "${_pre_existed_netcdf_c:-0}" != "1" ]; then
         ${SUDO} rm -rf "${NETCDF_C_PATH}"
         ${SUDO_MOD} rm -f  "${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}.lua" "${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}"
      fi
      if [ "${_pre_existed_netcdf_f:-0}" != "1" ]; then
         ${SUDO} rm -rf "${NETCDF_F_PATH}"
         ${SUDO_MOD} rm -f  "${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}.lua" "${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}"
      fi
      if [ "${_pre_existed_pnetcdf:-0}" != "1" ]; then
         ${SUDO} rm -rf "${PNETCDF_PATH}"
         ${SUDO_MOD} rm -f  "${PNETCDF_MODULE_PATH}/${PNETCDF_VERSION}.lua" "${PNETCDF_MODULE_PATH}/${PNETCDF_VERSION}"
      fi
   elif [ ${rc} -ne 0 ]; then
      echo "[netcdf fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Always wipe the /tmp build dir (regardless of rc / KEEP_FAILED).
   # This used to be a separate `trap ... EXIT` further down which
   # silently overwrote this trap; folded in here so the build-dir
   # cleanup AND the per-component fail-cleanup both fire reliably.
   if [ -n "${NETCDF_BUILD_DIR:-}" ] && [ -d "${NETCDF_BUILD_DIR}" ]; then
      rm -rf "${NETCDF_BUILD_DIR}"
   fi
   return ${rc}
}
trap _netcdf_on_exit EXIT

if [ "${BUILD_NETCDF}" = "0" ]; then

   echo "NETCDF will not be built, according to the specified value of BUILD_NETCDF"
   echo "BUILD_NETCDF: $BUILD_NETCDF"
   echo "Make sure to set '--build-netcdf 1' when running this install script"
   exit

else

   echo ""
   echo "==============================================="
   echo " Installing NETCDF"
   echo " Install base directory: $NETCDF_INSTALL_BASE"
   echo " Netcdf-c Version: $NETCDF_C_VERSION"
   echo " Netcdf-c Install Directory: $NETCDF_C_PATH"
   echo " Netcdf-c Module Directory: $NETCDF_C_MODULE_PATH"
   echo " Netcdf-fortran Version: $NETCDF_F_VERSION"
   echo " Netcdf-fortran Install Directory: $NETCDF_F_PATH"
   echo " Netcdf-fortran Module Directory: $NETCDF_F_MODULE_PATH"
   echo " PnetCDF Install Directory: $PNETCDF_PATH"
   echo " ROCm Version: $ROCM_VERSION"
   echo "==============================================="
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

   NETCDF_C_TGZ=${CACHE_FILES}/netcdf-c-v${NETCDF_C_VERSION}.tgz
   NETCDF_F_TGZ=${CACHE_FILES}/netcdf-fortran-v${NETCDF_F_VERSION}.tgz
   PNETCDF_TGZ=${CACHE_FILES}/pnetcdf.tgz
   if [ -f "${NETCDF_C_TGZ}" ] && [ -f "${NETCDF_F_TGZ}" ]; then
      echo ""
      echo "============================"
      echo " Installing Cached NETCDF"
      echo "============================"
      echo ""

      # Install the cached version. Each cache tar must contain a single
      # top-level directory matching its install path so it lands directly
      # under ${NETCDF_INSTALL_BASE} when extracted there:
      #   netcdf-c-v${NETCDF_C_VERSION}.tgz       -> netcdf-c-v.../
      #   netcdf-fortran-v${NETCDF_F_VERSION}.tgz -> netcdf-fortran-v.../
      #   pnetcdf.tgz (optional, build-time-only) -> pnetcdf/
      # PnetCDF is shared across netcdf versions (like PDT for scorep),
      # hence unversioned; only present when the cache build had
      # HDF5_ENABLE_PARALLEL=ON.
      cd ${NETCDF_INSTALL_BASE}
      tar -xzf ${NETCDF_C_TGZ}
      tar -xzf ${NETCDF_F_TGZ}
      chown -R root:root ${NETCDF_C_PATH} ${NETCDF_F_PATH}
      if [ -f "${PNETCDF_TGZ}" ]; then
         tar -xzf ${PNETCDF_TGZ}
         chown -R root:root ${PNETCDF_PATH}
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${NETCDF_C_TGZ} ${NETCDF_F_TGZ} ${PNETCDF_TGZ}
      fi

   else
      echo ""
      echo "================================"
      echo " Installing NETCDF from source"
      echo "================================"
      echo ""

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh

      # don't use sudo if user has actual write access to the install base.
      #
      # Real touch probe instead of the bash `[ -w ]` test: on /nfsapps
      # (NFSv4 + ACLs) `[ -w root-owned-755-dir ]` returned TRUE on the
      # compute node for a non-root user, but real writes still hit
      # EACCES. Same lying-probe failure mode the modulefile-write
      # PKG_SUDO_MOD pattern below already replaced (job 8063 audit).
      # Probe with mktemp -p (creates a uniquely-named file under
      # NETCDF_INSTALL_BASE); cleans up regardless of outcome.
      if [ -d "$NETCDF_INSTALL_BASE" ]; then
         _probe=""
         _probe=$(mktemp --tmpdir="${NETCDF_INSTALL_BASE}" .netcdf-write-probe.XXXXXX 2>/dev/null) || true
         if [ -n "${_probe}" ] && [ -f "${_probe}" ]; then
            rm -f "${_probe}"
            SUDO=""
            echo "netcdf: ${NETCDF_INSTALL_BASE} is user-writable (probe succeeded); SUDO cleared."
         else
            echo "WARNING: ${NETCDF_INSTALL_BASE} exists but is not user-writable (probe failed); using sudo"
         fi
         unset _probe
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: ${NETCDF_INSTALL_BASE} does not exist yet; using sudo, make sure you have sudo privileges"
      fi

      # install libcurl. PKG_SUDO: apt/yum need root regardless of the
      # install-path-derived SUDO. The previous `[[ ${SUDO} == "" ]]`
      # guards skipped libcurl whenever the install path was
      # admin-writable, which would silently produce a netcdf without
      # curl support. See openmpi_setup.sh / audit_2026_05_01.md Issue 2.
      #
      # Presence guard: skip the package-manager install entirely when the
      # curl development header is already present. On a Cray (RHEL 9.x)
      # libcurl-devel ships in the base image, and the compute nodes have NO
      # passwordless sudo -- so the unconditional `sudo yum install` aborted
      # the whole netcdf build with "sudo: a password is required" (and the
      # EXIT trap then nuked the partial install). Checking for curl.h first
      # makes the install a no-op where it's already satisfied and avoids the
      # needless privilege escalation. Only when the header is missing do we
      # attempt the install (and even then, a sudo failure is non-fatal: the
      # subsequent netcdf-c cmake DAP probe will report the real diagnostic).
      if [ -f /usr/include/curl/curl.h ] || [ -f /usr/include/x86_64-linux-gnu/curl/curl.h ]; then
         echo "netcdf: libcurl development header already present; skipping libcurl install."
      else
         PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
         if [ "${DISTRO}" = "ubuntu" ]; then
            echo "...installing libcurl..."
            ${PKG_SUDO} apt-get update || echo "netcdf: WARNING: apt-get update failed (continuing; curl may already be available)"
            ${PKG_SUDO} apt-get install -y libcurl4-gnutls-dev || echo "netcdf: WARNING: libcurl install failed (continuing; netcdf-c DAP probe will report if curl is truly missing)"
         elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
            echo "...installing libcurl..."
            ${PKG_SUDO} yum install -y libcurl-devel || echo "netcdf: WARNING: libcurl install failed (continuing; netcdf-c DAP probe will report if curl is truly missing)"
         elif [ "${DISTRO}" = "opensuse" ]; then
            echo "opensuse is not tested yet, not installing libcurl"
         fi
      fi

      ${SUDO} mkdir -p ${NETCDF_C_PATH}
      ${SUDO} mkdir -p ${NETCDF_F_PATH}
      ${SUDO} mkdir -p ${PNETCDF_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${NETCDF_C_PATH} ${NETCDF_F_PATH} ${PNETCDF_PATH}
      fi

      # Order matters: ROCm first (extends MODULEPATH with rocmplus-<v>
      # so MPI / HDF5 / etc. are findable), then MPI before HDF5 so
      # mpicc / mpifort and openmpi's runtime libs are first on
      # PATH / LD_LIBRARY_PATH (otherwise the hdf5 module's MPI hints
      # can be inconsistent with what PnetCDF / netcdf-c pick up via
      # `which mpicc`).
      #
      # Pattern history: original form resolved to `rocm/7.13.0` for
      # therock-23.2.0 and tripped preflight rc=42 (slurm 8225,
      # 2026-05-05), taking down netcdf-c + netcdf-fortran + pnetcdf in
      # one shot. Pattern ported from mpi4py_setup.sh:310-316 then
      # upgraded to the LOADEDMODULES-first shape below (2026-05-15)
      # when the therock-afar dual-segment scheme exposed a residual
      # mismatch in the ROCM_PATH-basename heuristic.
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
      #   3. ${ROCM_MODULE}/${ROCM_VERSION}: standalone-invocation fallback when
      #      neither LOADEDMODULES nor ROCM_PATH is populated.
      ROCM_MODULE_NAME=""
      if [[ -n "${LOADEDMODULES:-}" ]]; then
         _OLD_IFS="${IFS}"; IFS=":"
         for _m in ${LOADEDMODULES}; do
            case "${_m}" in
               ${ROCM_MODULE:-rocm}/*) ROCM_MODULE_NAME="${_m}"; break ;;
            esac
         done
         IFS="${_OLD_IFS}"; unset _OLD_IFS _m
      fi
      if [[ -z "${ROCM_MODULE_NAME}" ]]; then
         if [[ -n "${ROCM_PATH:-}" ]]; then
            _rp_bn="${ROCM_PATH##*/}"
            ROCM_MODULE_NAME="${ROCM_MODULE}/${_rp_bn#rocm-}"
            unset _rp_bn
         else
            ROCM_MODULE_NAME="${ROCM_MODULE}/${ROCM_VERSION}"
         fi
      fi
      # Pin hdf5 by mapped version when NETCDF_C_TO_HDF5 has an entry
      # for this netcdf-c version. Avoids relying on Lmod's
      # default-resolution when multiple hdf5 modulefiles coexist on a
      # tree (e.g. rocmplus-7.2.3 has both hdf5/1.14.6 and hdf5/2.1.1
      # after the 2026-05-20 hdf5 2.x rollout). Bare `hdf5` is kept as
      # the legacy fallback for netcdf-c versions not in the map.
      HDF5_MODULE_NAME="${HDF5_MODULE}"
      if [ -n "${NETCDF_C_TO_HDF5[${NETCDF_C_VERSION}]:-}" ]; then
         HDF5_MODULE_NAME="${HDF5_MODULE}/${NETCDF_C_TO_HDF5[${NETCDF_C_VERSION}]}"
         echo "netcdf: pinning ${HDF5_MODULE_NAME} for netcdf-c ${NETCDF_C_VERSION} (from NETCDF_C_TO_HDF5 map)"
      else
         echo "netcdf: no NETCDF_C_TO_HDF5 entry for ${NETCDF_C_VERSION}; loading bare '${HDF5_MODULE}' (Lmod default)"
      fi
      # ── MPI module auto-correct on a Cray PE (mirror hdf5_setup.sh) ──
      # The leaf default MPI_MODULE is "openmpi", but a Cray system ships
      # cray-mpich (no openmpi module) -- preflight would fail. If cray-mpich
      # is active and the caller did not override the MPI, switch to it so the
      # prereq load and the parallel build use the PrgEnv's own MPI.
      if [ "${MPI_MODULE}" = "openmpi" ] \
           && { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; }; then
         MPI_MODULE="cray-mpich"
         echo "netcdf: Cray MPICH detected; MPI_MODULE -> cray-mpich"
      fi

      # ── mpich-wrappers resolution (new-flang mpi.mod on a Cray) ──────
      # cray-mpich's amd/rocm-compiler mpi.mod is CLASSIC-Flang V34, which the
      # new LLVM Flang (amdflang / ftn on ROCm 7.x) cannot read -- a
      # parallel-Fortran `use mpi` build (netcdf-fortran, PnetCDF) fails. The
      # mpich-wrappers leaf builds a standalone MPICH with FC=amdflang
      # (NEW-flang mpi.mod, MPICH-ABI compatible with cray-mpich). When the
      # caller asks for it (main_setup threads --mpi-module mpich-wrappers),
      # resolve the bare name to the concrete version-matched modulefile token
      # by scanning MODULEPATH. Fall back to cray-mpich if none is found.
      if [ "${MPI_MODULE}" = "mpich-wrappers" ]; then
         _mw_tok=""
         _OLD_IFS="${IFS}"; IFS=":"
         for _d in ${MODULEPATH:-}; do
            for _cand in "mpich-wrappers/${ROCM_VERSION}" "mpich-wrappers"; do
               if [ -e "${_d}/${_cand}" ] || [ -e "${_d}/${_cand}.lua" ]; then
                  _mw_tok="${_cand}"; break 2
               fi
            done
         done
         IFS="${_OLD_IFS}"; unset _OLD_IFS _d _cand
         if [ -n "${_mw_tok}" ]; then
            MPI_MODULE="${_mw_tok}"
            echo "netcdf: using mpich-wrappers module '${_mw_tok}' (new-flang mpi.mod)"
         else
            echo "netcdf: WARNING: --mpi-module mpich-wrappers requested but no mpich-wrappers modulefile found on MODULEPATH; falling back to cray-mpich"
            MPI_MODULE="cray-mpich"
         fi
         unset _mw_tok
      fi

      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" "${HDF5_MODULE_NAME}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?
      if [[ `which h5dump | wc -l` -eq 0 ]]; then
         echo "h5dump was not found in PATH after loading the hdf5 module"
         echo "hdf5 is a requirement for netcdf, please make sure hdf5"
         echo "is installed and present in PATH, then retry"
         exit
      else
         C_COMPILER=$HDF5_C_COMPILER
         CXX_COMPILER=$HDF5_CXX_COMPILER
         F_COMPILER=$HDF5_F_COMPILER
      fi

      # override flags with user defined values if present
      if [ "${C_COMPILER_INPUT}" != "" ]; then
         C_COMPILER=${C_COMPILER_INPUT}
      fi
      if [ "${CXX_COMPILER_INPUT}" != "" ]; then
         CXX_COMPILER=${CXX_COMPILER_INPUT}
      fi
      if [ "${F_COMPILER_INPUT}" != "" ]; then
         F_COMPILER=${F_COMPILER_INPUT}
      fi

      # ── Cray PE: pin flang-new for the ftn/cc/CC wrappers ────────────
      # On a Cray, F_COMPILER resolves to the craype `ftn` wrapper (see
      # hdf5_setup.sh compiler-selection block). Which Fortran compiler
      # that wrapper actually drives is governed by AMD_COMPILER_TYPE:
      # the PrgEnv-amd-new/8.7.0-<ver> stack (amd-new modulefile) sets
      # AMD_COMPILER_TYPE=DEFAULT so ftn/cc/CC drive the NEW LLVM
      # amdflang/amdclang; when it is UNSET the wrappers silently fall
      # back to flang-CLASSIC (and emit an 'Unrecognized' warning).
      #
      # This script loads only rocm/MPI/hdf5 -- it never loads the
      # amd-new compiler module -- so if the build is not already inside
      # a PrgEnv-amd-new context, ftn drops to flang-classic. The classic
      # runtime is linked DYNAMICALLY (NEEDED libflang.so), whereas
      # flang-new links its runtime statically. The resulting
      # netcdf-fortran (and any example built later with `nf-config
      # --fc`) then needs libflang.so at run time -- which the
      # amdflang-new / PrgEnv-amd-new runtime path does not expose, so it
      # fails with "libflang.so: cannot open shared object file"
      # (Netcdf_Fortran_Check_Pres_Temp_4D_RD regression, aac7-rocm-7.2.3).
      #
      # Pin AMD_COMPILER_TYPE=DEFAULT when the craype wrappers are in play
      # so the netcdf-c / netcdf-fortran / PnetCDF builds use flang-new,
      # consistent with PrgEnv-amd-new. Respect an operator-set value.
      # No-op off a Cray PE (the var is only read by the craype AMD
      # wrappers; OpenMPI's mpifort/amdflang ignore it).
      if { [ -n "${CRAYPE_VERSION:-}" ] || [ -n "${CRAY_MPICH_VERSION:-}" ] \
             || [ -n "${MPICH_DIR:-}" ] || [ "${MPI_MODULE}" = "cray-mpich" ] \
             || [ "${MPI_MODULE#mpich-wrappers}" != "${MPI_MODULE}" ]; } \
           && command -v ftn >/dev/null 2>&1; then
         export AMD_COMPILER_TYPE="${AMD_COMPILER_TYPE:-DEFAULT}"
         echo "netcdf: Cray PE detected; AMD_COMPILER_TYPE=${AMD_COMPILER_TYPE} (ftn/cc/CC -> flang-new, matches PrgEnv-amd-new)"
      fi

      # ── Drop the cray-libsci / cray-mpich link when mpich-wrappers is
      #    the MPI (so the new-flang build keeps NO libflang.so runtime) ──
      #
      # The mpich-wrappers leaf builds a STANDALONE MPICH with FC=amdflang
      # (flang-new): its libmpi.so.12 / libmpifort.so.12 link the flang
      # runtime STATICALLY and need NO libflang.so. HDF5-Fortran and
      # PnetCDF (autotools, driven by `mpifort -show`) link those clean
      # mpich-wrappers libs and come out clean.
      #
      # netcdf-fortran is the lone exception: its CMake FindMPI runs a
      # *verbose* link probe and over-captures the craype-injected
      # classic-flang Cray PE libs that PrgEnv-amd-new still has loaded --
      #   -L/opt/cray/pe/libsci/.../AMD/... -lsci_amd_mpi -lsci_amd
      #   -L/opt/cray/pe/mpich/.../amd/...  -lmpi_amd
      # baking libsci_amd*.so.6 / libmpi_amd.so.12 / libmpifort_amd.so.12
      # into libnetcdff.so as DT_NEEDED. Those AMD libs are built with
      # flang-CLASSIC, so each pulls libflang.so -- reintroducing exactly
      # the runtime dep mpich-wrappers exists to avoid
      # (Netcdf_Fortran_Check_Pres_Temp_4D_RD, aac7-rocm-7.2.3:
      #  "libflang.so: cannot open shared object file"). netcdf-fortran
      # needs neither BLAS/LAPACK (cray-libsci) nor cray-mpich -- the
      # whole point of the mpich-wrappers MPI is to REPLACE cray-mpich.
      #
      # Unloading both before the cmake builds makes FindMPI resolve to
      # the mpich-wrappers libmpi.so.12 / libmpifort.so.12 only, so
      # libnetcdff.so links clean (verified: no libsci_amd / _amd / 
      # libflang.so). Guarded on mpich-wrappers: when the operator
      # explicitly asked for cray-mpich we leave its stack intact.
      if [ "${MPI_MODULE#mpich-wrappers}" != "${MPI_MODULE}" ]; then
         for _craylib in cray-libsci cray-mpich; do
            if module -t list 2>&1 | grep -q "^${_craylib}"; then
               module unload "${_craylib}" 2>/dev/null \
                  && echo "netcdf: unloaded ${_craylib} (classic-flang Cray PE lib; mpich-wrappers replaces it, avoids libflang.so)"
            fi
         done
      fi

      # OpenMPI wrapper-compiler fallback for ROCm 6.3.x trees.
      # openmpi/5.0.10 on rocmplus-6.x was configured against amdflang.
      # ROCm 6.3.x SDKs only ship amdflang under ${ROCM_PATH}/llvm/bin/,
      # which is NOT on PATH after `module load rocm/6.3.x` (the
      # module prepends ${ROCM_PATH}/bin only). Result: mpifort fails
      # with "Open MPI wrapper compiler was unable to find the
      # specified compiler amdflang in your PATH", which breaks BOTH
      # the pnetcdf ./configure (MPIF90=mpifort) AND the
      # netcdf-fortran cmake Fortran-ABI probe (slurm 10220-10224,
      # 2026-05-20 sweep). Same root cause and same fix as
      # hdf5_setup.sh -- see the long comment there for the full
      # history including why OMPI_FC=gfortran does NOT work
      # (amdflang-classic's V34 .mod format is unreadable by gfortran).
      # No-op on ROCm 7.x and 6.4.x (amdflang already on PATH).
      if ! command -v amdflang >/dev/null 2>&1 \
           && [ -n "${ROCM_PATH:-}" ] \
           && [ -x "${ROCM_PATH}/llvm/bin/amdflang" ]; then
         export PATH="${ROCM_PATH}/llvm/bin:${PATH}"
         echo "netcdf: amdflang not on PATH; prepending ${ROCM_PATH}/llvm/bin (mpifort wrapper depends on it)"
      fi

      # Use all available cores for the netcdf builds. Without -j, each of
      # pnetcdf, netcdf-c, netcdf-fortran ran serially on one core (~10min
      # combined on sh5); with -j$(nproc) it drops to a couple of minutes.
      MAKE_JOBS=$(nproc 2>/dev/null || echo 16)

      # Build all three sources (PnetCDF, netcdf-c, netcdf-fortran) under
      # a fresh /tmp dir so failed builds don't leave a PnetCDF/,
      # netcdf-c/, or netcdf-fortran/ tree polluting the HPCTrainingDock
      # checkout. Audited as the netcdf rc=128 cause in
      # slurm-7950-rocmplus-7.0.2.out (log_netcdf line 36):
      #   "fatal: destination path 'PnetCDF' already exists"
      # came from a leftover PnetCDF/ in the repo root from a prior
      # aborted run; git clone refused to overwrite. Mirrors the scorep
      # S6.C / openmpi S7.B / kokkos /tmp-build patterns. EXIT trap
      # guarantees cleanup even on `set -e` aborts.
      NETCDF_BUILD_DIR=$(mktemp -d -t netcdf-build.XXXXXX)
      # Don't `trap ... EXIT` here -- that would overwrite the
      # _netcdf_on_exit fail-cleanup trap installed above (line ~451),
      # leaving partial install dirs / modulefiles behind on failure.
      # _netcdf_on_exit knows about NETCDF_BUILD_DIR via the global var
      # and rms it itself at the end of the trap function.
      cd "${NETCDF_BUILD_DIR}"

      if [ "${HDF5_ENABLE_PARALLEL}" = "ON" ]; then
         ENABLE_PNETCDF="ON"
         # HDF5_MPI_MODULE was historically referenced here but never set
         # by main_setup.sh -- a latent no-op. The MPI_MODULE load above
         # is what was actually wanted. Keep the conditional load only if
         # an explicit override is provided (defensive).
         if [ -n "${HDF5_MPI_MODULE:-}" ]; then
            module load "${HDF5_MPI_MODULE}"
         fi
      fi
      # Per-component idempotence guard: skip the PnetCDF build branch
      # when the versioned install dir already exists. The HDF5_ENABLE_PARALLEL
      # decision above still sets ENABLE_PNETCDF=ON so the netcdf-c
      # build below + modulefile heredoc still wire in the existing
      # pnetcdf install.
      if [ "${ENABLE_PNETCDF}" = "ON" ] && [ "${_pre_existed_pnetcdf}" = "1" ]; then
         echo ""
         echo "[netcdf per-component] pnetcdf-v${PNETCDF_VERSION} already installed at ${PNETCDF_PATH}; skipping PnetCDF build."
         echo ""
      fi
      if [ "${ENABLE_PNETCDF}" = "ON" ] && [ "${_pre_existed_pnetcdf}" != "1" ]; then
         # install pnetcdf — use the official release tarball
         # (pnetcdf-${VER}.tar.gz) rather than git clone + autoreconf.
         # The tarball ships a pre-generated `configure` script so
         # we don't need a recent libtool on the build node. Audit
         # basis: slurm 10200 (2026-05-20) job failed because PnetCDF
         # 1.14.1's configure.ac bumped LT_PREREQ to 2.5.4, but
         # Ubuntu 22.04 ships libtool 2.4.6:
         #   configure.ac:459: error: Libtool version 2.5.4 or higher is required
         # Switching to the upstream tarball sidesteps the autoreconf
         # path entirely. The git-clone fallback below covers the rare
         # case of a network blip against parallel-netcdf.github.io.
         PNETCDF_TARBALL="pnetcdf-${PNETCDF_VERSION}.tar.gz"
         PNETCDF_URL="https://parallel-netcdf.github.io/Release/${PNETCDF_TARBALL}"
         PNETCDF_SRCDIR=""

         # ── Operator escape-hatch: pre-staged official tarball ──────────
         # The official PnetCDF tarball (with a PRE-GENERATED `configure`)
         # lives ONLY on parallel-netcdf.github.io. On clusters whose
         # COMPUTE nodes can reach github.com but NOT github.io (the latter
         # is a GitHub Pages host -- e.g. this Cray's compute nodes go
         # through a proxy that allows github.com and blocks github.io), the
         # wget below fails and the git-clone fallback then needs Autoconf
         # 2.70+ / libtool 2.5.4+ for autoreconf (RHEL 9 ships autoconf
         # 2.69 -> "Autoconf version 2.70 or higher is required"). To build
         # there, an operator can stage the official tarball once from a
         # host that DOES reach github.io and point this var at it:
         #   export NETCDF_PNETCDF_TARBALL=/shareddata/src/pnetcdf-1.14.1.tar.gz
         # When set and readable, it is used verbatim (no network), so the
         # pre-generated configure is preserved and autoreconf is skipped.
         if [ -n "${NETCDF_PNETCDF_TARBALL:-}" ] && [ -f "${NETCDF_PNETCDF_TARBALL}" ]; then
            echo "PnetCDF: using operator-staged tarball ${NETCDF_PNETCDF_TARBALL} (no network)"
            cp "${NETCDF_PNETCDF_TARBALL}" "${PNETCDF_TARBALL}"
            tar -xzf "${PNETCDF_TARBALL}"
            rm -f "${PNETCDF_TARBALL}"
            for _cand in "pnetcdf-${PNETCDF_VERSION}" "parallel-netcdf-${PNETCDF_VERSION}"; do
               if [ -d "${_cand}" ]; then
                  PNETCDF_SRCDIR="${_cand}"
                  break
               fi
            done
            unset _cand
            if [ -z "${PNETCDF_SRCDIR}" ]; then
               echo "ERROR: staged ${NETCDF_PNETCDF_TARBALL} extracted but neither pnetcdf-${PNETCDF_VERSION}/ nor parallel-netcdf-${PNETCDF_VERSION}/ exist." >&2
               ls -1 >&2
               exit 1
            fi
            echo "PnetCDF: extracted staged tarball into ${PNETCDF_SRCDIR}/"
         fi

         if [ -n "${PNETCDF_SRCDIR}" ]; then
            : # already populated from the operator-staged tarball above
         elif echo "PnetCDF: downloading release tarball ${PNETCDF_URL}" && wget -q "${PNETCDF_URL}" -O "${PNETCDF_TARBALL}"; then
            # Extract first, then locate the top-level dir on disk.
            # Earlier draft used `tar -tzf | head -n1` to probe the
            # name before extraction, but `head` closes the pipe
            # after reading one line and tar dies with SIGPIPE (rc=141
            # under set -e) -- slurm 10201 (2026-05-20) failed at
            # exactly this line. Extraction-first sidesteps SIGPIPE
            # entirely. Modern releases (>=1.11) extract to
            # pnetcdf-${VER}/; pre-1.11 to parallel-netcdf-${VER}/.
            tar -xzf "${PNETCDF_TARBALL}"
            rm -f "${PNETCDF_TARBALL}"
            for _cand in "pnetcdf-${PNETCDF_VERSION}" "parallel-netcdf-${PNETCDF_VERSION}"; do
               if [ -d "${_cand}" ]; then
                  PNETCDF_SRCDIR="${_cand}"
                  break
               fi
            done
            unset _cand
            if [ -z "${PNETCDF_SRCDIR}" ]; then
               echo "ERROR: extracted ${PNETCDF_TARBALL} but neither pnetcdf-${PNETCDF_VERSION}/ nor parallel-netcdf-${PNETCDF_VERSION}/ exist." >&2
               echo "       Top-level entries in CWD ($(pwd)):" >&2
               ls -1 >&2
               exit 1
            fi
            echo "PnetCDF: extracted tarball into ${PNETCDF_SRCDIR}/"
         else
            echo "WARNING: tarball download failed; falling back to git clone (requires libtool >= 2.5.4 for autoreconf)"
            PNETCDF_TAG=""
            for _cand in "checkpoint.${PNETCDF_VERSION}" "${PNETCDF_VERSION}" "pnetcdf-${PNETCDF_VERSION}"; do
               if git ls-remote --exit-code --tags https://github.com/Parallel-NetCDF/PnetCDF.git \
                     "refs/tags/${_cand}" >/dev/null 2>&1; then
                  PNETCDF_TAG="${_cand}"
                  break
               fi
            done
            unset _cand
            if [ -z "${PNETCDF_TAG}" ]; then
               echo "ERROR: no git tag matching PnetCDF ${PNETCDF_VERSION} (tried 'checkpoint.${PNETCDF_VERSION}', '${PNETCDF_VERSION}', 'pnetcdf-${PNETCDF_VERSION}')." >&2
               exit 1
            fi
            echo "PnetCDF: using git tag '${PNETCDF_TAG}'"
            git clone --depth=1 --branch "${PNETCDF_TAG}" https://github.com/Parallel-NetCDF/PnetCDF.git PnetCDF
            PNETCDF_SRCDIR="PnetCDF"
            cd "${PNETCDF_SRCDIR}"
            autoreconf -i
            cd ..
         fi
         cd "${PNETCDF_SRCDIR}"

         # ---------------------------------------------------------------------
         # PnetCDF Fortran-runtime fix (audit_2026_05_01.md Issue 4):
         #
         # MPIF90 wraps amdflang (per the openmpi build), so PnetCDF's *.f90
         # objects emit references to LLVM-flang runtime symbols
         # (Fortran::runtime::*, _FortranA*).  libtool then drives the final
         # link of libpnetcdf.so with gcc, which does NOT auto-link flang's
         # runtime, leaving those symbols UNDEFINED in libpnetcdf.so.  When
         # netcdf-c later links ncdump/ncgen against -lpnetcdf, the runtime
         # symbols cannot be resolved (collect2: ld returned 1) and the whole
         # netcdf install aborts.  Verified failing log:
         #   logs_04_30_2026/rocm-7.0.2_7957/log_netcdf_04_30_2026.txt
         # vs. passing log:
         #   logs_05_01_2026/rocm-7.2.1_7959/log_netcdf_05_01_2026.txt
         #
         # Fix: discover the amdflang runtime archive(s) and pass them via LIBS
         # so libtool/ld bakes the symbols into libpnetcdf.so itself.  ROCm
         # relocated the runtime between 7.0.x and 7.2.x:
         #   * 7.0.x / 7.1.x : ${ROCM_PATH}/llvm/lib/libFortranRuntime.a
         #                     ${ROCM_PATH}/llvm/lib/libFortranDecimal.a
         #   * 7.2.x+        : ${ROCM_PATH}/lib/llvm/lib/clang/<ver>/lib/<triple>/libflang_rt.runtime.a
         # ---------------------------------------------------------------------
         PNETCDF_FORTRAN_LIBS=""
         if [ -n "${ROCM_PATH:-}" ]; then
            # 7.2.x+ : single combined runtime archive in clang resource dir.
            # Constrain the lib/<triple>/ glob to the HOST triple
            # (x86_64-unknown-linux-gnu) -- not a wildcard. ROCm 7.2.x
            # ships only the host archive at this path, so a wildcard
            # happens to work, but rocm-therock-23.2.0 (and presumably
            # future rocm 7.3+) ships BOTH lib/x86_64-unknown-linux-gnu/
            # AND lib/amdgcn-amd-amdhsa/. Bash glob expansion is
            # alphabetical, so a wildcard returns amdgcn first. The
            # amdgcn archive contains LLVM IR bitcode for GPU device
            # code -- not linkable into libpnetcdf.so on x86_64 host.
            # Linking PnetCDF's Fortran tests against the device archive
            # produces undefined-symbol noise that PnetCDF's configure
            # interprets as "no correspond data type in C" and aborts
            # the integer*1 size-mapping check (slurm 8285, 2026-05-05,
            # rocm-therock-23.2.0). The host triple `x86_64-unknown-
            # linux-gnu` is the LLVM convention on Linux regardless of
            # distro (Ubuntu/RHEL/SUSE all the same).
            for f in "${ROCM_PATH}"/lib/llvm/lib/clang/*/lib/x86_64-unknown-linux-gnu/libflang_rt.runtime.a \
                     "${ROCM_PATH}"/llvm/lib/clang/*/lib/x86_64-unknown-linux-gnu/libflang_rt.runtime.a; do
               if [ -f "${f}" ]; then
                  PNETCDF_FORTRAN_LIBS="${f}"
                  break
               fi
            done
            # 7.0.x / 7.1.x : split FortranRuntime + FortranDecimal archives
            if [ -z "${PNETCDF_FORTRAN_LIBS}" ] && [ -f "${ROCM_PATH}/llvm/lib/libFortranRuntime.a" ]; then
               PNETCDF_FORTRAN_LIBS="${ROCM_PATH}/llvm/lib/libFortranRuntime.a"
               if [ -f "${ROCM_PATH}/llvm/lib/libFortranDecimal.a" ]; then
                  PNETCDF_FORTRAN_LIBS="${PNETCDF_FORTRAN_LIBS} ${ROCM_PATH}/llvm/lib/libFortranDecimal.a"
               fi
            fi
         fi
         # ---------------------------------------------------------------------
         # Fortran-PIC fix (audit_2026_05_07.md, jobs 8492/8493/8494):
         #
         # On ROCm 6.x SDKs `mpifort` wraps `amdflang` (flang-classic 18.0.0
         # on 6.3.x, 19.0.0 on 6.4.x), which does NOT default to -fPIC. PnetCDF
         # builds .f / .f90 objects into static libf77.a / libf90.a and then
         # libtool assembles them into the SHARED libpnetcdf.so. Without
         # -fPIC the link fails on Ubuntu's binutils:
         #   /usr/bin/ld: ../binding/f77/.libs/libf77.a(strerrnof.o):
         #     relocation R_X86_64_32S against `.rodata' can not be used
         #     when making a shared object; recompile with -fPIC
         # Verified failing log:
         #   logs_05_06_2026/rocm-6.3.{2,3,4}_849{4,3,2}/log_netcdf_05_06_2026.txt
         # No-op cost on rocm 7.x (amdflang-new defaults to PIC) and on
         # gfortran (also no-op for shared-lib builds).
         #
         # Companion fix to extras/scripts/hdf5_setup.sh:434
         # (-DCMAKE_Fortran_FLAGS="-fPIC"); the same root cause manifests
         # there in CMake form.
         # ---------------------------------------------------------------------
         PNETCDF_FORTRAN_PIC_FLAGS=( FFLAGS="-fPIC" FCFLAGS="-fPIC" )

         # ---------------------------------------------------------------------
         # amdflang-classic SHARED-runtime rpath embedding (ROCm 6.x / 7.0.x).
         #
         # PnetCDF's configure inspects `mpifort -v` and discovers amdflang's
         # default link line:
         #   -L${ROCM_PATH}/lib/llvm/lib -lflang -lflangrti -lompstub -lpgmath
         # so libpnetcdf.so links successfully and gets NEEDED entries for
         # libflang.so / libompstub.so / libflangrti.so / libpgmath.so. BUT
         # PnetCDF does NOT embed -rpath for those locations -- libpnetcdf.so's
         # RUNPATH only mentions openmpi/ucc/ucx/xpmem, not the rocm flang
         # runtime dir.
         # Consequence: when netcdf-c later links ncdump/nccopy/ncgen
         # against -lnetcdf -lpnetcdf with LDFLAGS=-Wl,--no-undefined (set
         # by netcdf-c-4.10.0's default cmake config), ld walks libpnetcdf
         # for transitive symbol resolution, can't find libflang.so /
         # libompstub.so on its search path, and aborts with:
         #   warning: libflang.so, needed by libpnetcdf.so, not found
         #            (try using -rpath or -rpath-link)
         #   undefined reference to `f90_ptr_alloc04a_i8' etc.
         # Verified failing log:
         #   logs_05_20_2026/rocm-6.4.3_10241/log_netcdf_v4.10.0_05_20_2026.txt
         # vs. legacy passing log (-Wl,--no-undefined was apparently absent
         # on netcdf-c-4.9.3's stricter mode chain):
         #   logs_05_08_2026/rocm-6.4.3_8678/log_netcdf_05_08_2026.txt
         #
         # Fix: when amdflang-classic's libflang.so is in
         # ${ROCM_PATH}/lib/llvm/lib, embed that path as an RPATH in
         # libpnetcdf.so via LDFLAGS="-Wl,-rpath,...". The RPATH lets ld
         # auto-resolve transitive deps when downstream consumers link
         # against libpnetcdf at link time AND lets the dynamic loader
         # find them at runtime without users having to load extra
         # modules.
         # Companion fix to extras/scripts/hdf5_setup.sh + netcdf_setup.sh
         # PATH-extension (also 2026-05-20) which makes amdflang itself
         # findable by mpifort on ROCm 6.3.x.
         # No-op on ROCm 7.x (no libflang.so under lib/llvm/lib -- the
         # amdflang-new toolchain ships static libflang_rt.runtime.a only,
         # and PNETCDF_FORTRAN_LIBS handles that case via the
         # LIBS=... path above).
         # ---------------------------------------------------------------------
         PNETCDF_AMDFLANG_RPATH_FLAGS=()
         if [ -n "${ROCM_PATH:-}" ] && [ -f "${ROCM_PATH}/lib/llvm/lib/libflang.so" ]; then
            PNETCDF_AMDFLANG_RPATH_FLAGS=( LDFLAGS="-Wl,-rpath,${ROCM_PATH}/lib/llvm/lib -L${ROCM_PATH}/lib/llvm/lib" )
            echo "PnetCDF: embedding rpath for amdflang-classic runtime at ${ROCM_PATH}/lib/llvm/lib"
         fi

         # ---------------------------------------------------------------------
         # C++ runtime (-lstdc++) for the Cray MPI path.
         #
         # On a Cray, mpicc (mpich-wrappers, or cray-mpich's cc) links the GPU
         # transport layer libmpi_gtl_hsa, which is C++ -- so libpnetcdf.so
         # picks up NEEDED C++ runtime symbols (std::ios_base_library_init(),
         # __cxa_call_terminate, ...). mpicc drives a C link that does NOT pull
         # in libstdc++, so those symbols are left UNDEFINED in libpnetcdf.so
         # and the very next utility link (ncmpigen, a C program) aborts:
         #   libpnetcdf.so: undefined reference to `std::ios_base_library_init()'
         #   libpnetcdf.so: undefined reference to `__cxa_call_terminate'
         # (verified on rocm-7.2.3 / mpich-wrappers, RHEL 9 gcc-toolset-14 ld).
         # Append -lstdc++ to LIBS so libpnetcdf.so links the C++ runtime and
         # downstream consumers resolve the transitive symbols. Scoped to the
         # Cray MPI (cray-mpich / mpich-wrappers, or CRAY_MPICH_VERSION /
         # MPICH_DIR present); a no-op on OpenMPI/MVAPICH where the MPI does
         # not drag in C++.
         PNETCDF_CXX_LIBS=""
         if [ "${MPI_MODULE}" = "cray-mpich" ] \
              || [ "${MPI_MODULE#mpich-wrappers}" != "${MPI_MODULE}" ] \
              || [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; then
            PNETCDF_CXX_LIBS="-lstdc++"
            echo "PnetCDF: Cray MPI -> appending -lstdc++ (libpnetcdf.so needs the C++ runtime pulled in by the GPU GTL)"
            # gcc-toolset C++ ABI-compat archive.
            #
            # The ROCm flang runtime archive (libflang_rt.runtime.a, built by
            # AMD clang/22) and the cray-mpich GPU GTL reference newer
            # libstdc++ symbols (e.g. std::ios_base_library_init(),
            # _ZSt21ios_base_library_initv -- introduced in GCC 13). RHEL 9's
            # *runtime* libstdc++.so.6 is GCC 11 (so.6.0.29) and does NOT
            # export them; gcc-toolset-13/14 ship those newer symbols in a
            # STATIC libstdc++_nonshared.a instead. g++ from the toolset adds
            # this archive automatically, but here libtool drives the final
            # libpnetcdf.so / ncmpigen link with the C compiler (amdclang),
            # so a bare -lstdc++ resolves to GCC 11/12 libstdc++ and leaves
            # std::ios_base_library_init() UNDEFINED -- the ncmpigen link
            # failure on rocm-7.2.3. Discover the newest gcc-toolset
            # libstdc++_nonshared.a that actually defines the symbol and
            # append it (after -lstdc++) so the C-driver link resolves it.
            _ns_archive=""
            for _d in $(ls -d /opt/rh/gcc-toolset-*/root/usr/lib/gcc/x86_64-redhat-linux/* 2>/dev/null | sort -Vr); do
               _cand="${_d}/libstdc++_nonshared.a"
               # NOTE: grep -c (not grep -q) on purpose. Under `set -eo
               # pipefail`, grep -q closes the pipe on first match -> nm gets
               # SIGPIPE (non-zero) -> the pipeline (and the enclosing &&)
               # evaluates false, so the archive was silently never selected.
               # grep -c reads the whole stream (no early close, no SIGPIPE).
               [ -f "${_cand}" ] || continue
               _ns_cnt=$(nm -C "${_cand}" 2>/dev/null | grep -c "ios_base_library_init" || true)
               if [ "${_ns_cnt:-0}" -gt 0 ]; then
                  _ns_archive="${_cand}"; break
               fi
            done
            unset _ns_cnt
            if [ -n "${_ns_archive}" ]; then
               PNETCDF_CXX_LIBS="-lstdc++ ${_ns_archive}"
               echo "PnetCDF: adding gcc-toolset C++ compat archive ${_ns_archive} (provides std::ios_base_library_init for the ROCm flang runtime)"
            fi
            unset _ns_archive _cand _d
         fi

         # Combine the Fortran-runtime archive(s) and the C++ runtime into a
         # single LIBS string (either may be empty).
         PNETCDF_LIBS_COMBINED="${PNETCDF_FORTRAN_LIBS}"
         if [ -n "${PNETCDF_CXX_LIBS}" ]; then
            PNETCDF_LIBS_COMBINED="${PNETCDF_LIBS_COMBINED:+${PNETCDF_LIBS_COMBINED} }${PNETCDF_CXX_LIBS}"
         fi

         if [ -z "${PNETCDF_FORTRAN_LIBS}" ]; then
            echo "WARNING: could not locate amdflang Fortran runtime under ROCM_PATH=${ROCM_PATH:-<unset>};"
            echo "         libpnetcdf.so may have unresolved Fortran::runtime::* / _FortranA* symbols"
            echo "         and the subsequent netcdf-c utility link will fail."
         else
            echo "PnetCDF: linking amdflang Fortran runtime: ${PNETCDF_FORTRAN_LIBS}"
         fi
         if [ -n "${PNETCDF_LIBS_COMBINED}" ]; then
            ./configure --prefix=${PNETCDF_PATH} MPICC=`which mpicc` MPIF90=`which mpifort` \
                        "${PNETCDF_FORTRAN_PIC_FLAGS[@]}" \
                        "${PNETCDF_AMDFLANG_RPATH_FLAGS[@]}" \
                        LIBS="${PNETCDF_LIBS_COMBINED}"
         else
            ./configure --prefix=${PNETCDF_PATH} MPICC=`which mpicc` MPIF90=`which mpifort` \
                        "${PNETCDF_FORTRAN_PIC_FLAGS[@]}" \
                        "${PNETCDF_AMDFLANG_RPATH_FLAGS[@]}"
         fi
         make -j ${MAKE_JOBS}
         make install
         cd ..
      fi

      if [ "${_pre_existed_netcdf_c}" = "1" ]; then
         echo ""
         echo "[netcdf per-component] netcdf-c-v${NETCDF_C_VERSION} already installed at ${NETCDF_C_PATH}; skipping netcdf-c build."
         echo ""
      else
         echo ""
         echo "================================="
         echo " Installing NETCDF-C"
         echo "================================="
         echo ""

         git clone --branch v${NETCDF_C_VERSION} https://github.com/Unidata/netcdf-c.git
         cd netcdf-c
         # H5FDhttp.c plugin-handle guard. The original patch wrapped the
         # `if (H5FD_HTTP_g)` test with `H5Iis_valid(...) > 0` to avoid
         # touching a stale id on the HDF5 1.14 plugin path (netcdf-c
         # 4.9.x). netcdf-c 4.10.0 refactored libhdf5/H5FDhttp.c for HDF5
         # 2.0.0 compat (PR #3237: H5FD_class_t versioning, H5FD_http_term
         # finalizer), and the original `if (H5FD_HTTP_g)` pattern no longer
         # appears in unaltered form. Apply only when the exact pre-patch
         # line is still present so this is a no-op on 4.10.0+ (rather than
         # silently mangling some other call site).
         if [ -f libhdf5/H5FDhttp.c ] && grep -q 'if (H5FD_HTTP_g)' libhdf5/H5FDhttp.c; then
            sed -i 's/if\ (H5FD_HTTP_g)/if\ (H5FD_HTTP_g\ \&\&\ (H5Iis_valid(H5FD_HTTP_g)\ >\ 0))/g' libhdf5/H5FDhttp.c
            echo "netcdf-c: applied H5FDhttp.c plugin-handle guard patch"
         else
            echo "netcdf-c: H5FDhttp.c plugin-handle guard not applicable (file refactored or pattern absent at netcdf-c v${NETCDF_C_VERSION})"
         fi
         mkdir build && cd build

         # -DCMAKE_INSTALL_LIBDIR=lib: pin the library subdir to lib/ (not
         # lib64/). CMake's GNUInstallDirs picks lib64/ on RHEL-family
         # distros but lib/ on Debian/Ubuntu. The rest of this script (the
         # post-build sanity gate, the modulefile prepend_path lines, and the
         # netcdf-fortran build's discovery of libnetcdf) all assume lib/, so
         # an unpinned RHEL build landed libnetcdf.so in lib64/ and tripped
         # "expected netcdf-c library not found: .../lib/libnetcdf.so". Pinning
         # to lib keeps the layout identical across distros.
         cmake -DCMAKE_INSTALL_PREFIX=${NETCDF_C_PATH} \
   	       -DCMAKE_INSTALL_LIBDIR=lib \
   	       -DNETCDF_ENABLE_HDF5=ON -DNETCDF_ENABLE_DAP=ON \
   	       -DNETCDF_BUILD_UTILITIES=ON -DNETCDF_ENABLE_CDF5=ON \
   	       -DNETCDF_ENABLE_TESTS=OFF -DNETCDF_ENABLE_PARALLEL_TESTS=OFF \
   	       -DZLIB_INCLUDE_DIR=${HDF5_ROOT}/zlib/include \
   	       -DCMAKE_C_FLAGS="-I ${HDF5_ROOT}/include/" \
   	       -DCMAKE_C_COMPILER=${C_COMPILER} \
   	       -DNETCDF_ENABLE_PNETCDF=${ENABLE_PNETCDF} \
   	       -DPNETCDF_LIBRARY=${PNETCDF_PATH}/lib/libpnetcdf.so \
   	       -DPNETCDF_INCLUDE_DIR=${PNETCDF_PATH}/include \
   	       -DNETCDF_ENABLE_FILTER_SZIP=OFF -DNETCDF_ENABLE_NCZARR=OFF ..

         cmake --build . -j ${MAKE_JOBS}
         make install

         cd ../..
         rm -rf netcdf-c
      fi

      # put netcdf-c install path in PATH for netcdf-fortran install.
      # Done unconditionally so a single-component pnetcdf rebuild on
      # top of an existing netcdf-c still has the right PATH for the
      # downstream netcdf-fortran build branch (when that one fires).
      export PATH=${NETCDF_C_PATH}:$PATH
      export HDF5_PLUGIN_PATH=${NETCDF_C_PATH}/hdf5/lib/plugin/

      if [ "${_pre_existed_netcdf_f}" = "1" ]; then
         echo ""
         echo "[netcdf per-component] netcdf-fortran-v${NETCDF_F_VERSION} already installed at ${NETCDF_F_PATH}; skipping netcdf-fortran build."
         echo ""
      else
         echo ""
         echo "======================================="
         echo " Installing NETCDF-FORTRAN"
         echo "======================================="
         echo ""

         git clone --branch v${NETCDF_F_VERSION} https://github.com/Unidata/netcdf-fortran.git
         cd netcdf-fortran

         # netcdf-fortran is looking for nc_def_var_szip even if SZIP is OFF
         LINE=`sed -n '/if (NOT HAVE_DEF_VAR_SZIP)/=' CMakeLists.txt | grep -n ""`
         LINE=`echo ${LINE} | cut -c 3-`
         sed -i ''"${LINE}"'i set(HAVE_DEF_VAR_SZIP TRUE)' CMakeLists.txt

         mkdir build && cd build
         # -DCMAKE_C_COMPILER=${C_COMPILER}: netcdf-fortran's project() also
         # enables C, and without pinning it cmake auto-detects the first
         # `cc` on PATH. On a Cray PE that is the craype `cc` wrapper, which
         # aborts the compiler check with "Unable to determine compiler
         # version ... CRAY_AMD_COMPILER_VERSION is defined" -- that var is
         # never set by the from-source PrgEnv-amd-new (it loads its own
         # ROCm, not the stock Cray `amd` compiler module). netcdf-c above
         # already pins ${C_COMPILER} and builds clean; mirror it here so
         # netcdf-fortran bypasses the craype wrapper too (slurm 8143).
         cmake -DCMAKE_INSTALL_PREFIX=${NETCDF_F_PATH} \
   	       -DCMAKE_INSTALL_LIBDIR=lib \
   	       -DENABLE_TESTS=OFF -DBUILD_EXAMPLES=OFF \
   	       -DCMAKE_C_COMPILER=${C_COMPILER} \
   	       -DCMAKE_Fortran_COMPILER=$F_COMPILER ..

         cmake --build . -j ${MAKE_JOBS}
         make install

         cd ../..
         rm -rf netcdf-fortran
      fi

      # Clean up the PnetCDF source dir (tarball-extracted name varies
      # by release: pnetcdf-${VER} for >=1.11, parallel-netcdf-${VER}
      # for older, or PnetCDF/ for the git-clone fallback). ${PNETCDF_SRCDIR}
      # is set above when the PnetCDF branch fired this run; empty when
      # PnetCDF was pre-existed (skipped) or ENABLE_PNETCDF=OFF.
      [ -n "${PNETCDF_SRCDIR:-}" ] && [ -d "${PNETCDF_SRCDIR}" ] && ${SUDO} rm -rf "${PNETCDF_SRCDIR}"

      # chown / chmod only the components we actually built in this run.
      # Pre-existing installs are already root-owned; skipping them
      # avoids spurious touches that could disrupt other ongoing reads.
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         _built_dirs=()
         [ "${_pre_existed_netcdf_c}" != "1" ] && _built_dirs+=( "${NETCDF_C_PATH}" )
         [ "${_pre_existed_netcdf_f}" != "1" ] && _built_dirs+=( "${NETCDF_F_PATH}" )
         [ "${_pre_existed_pnetcdf}"  != "1" ] && [ "${ENABLE_PNETCDF}" = "ON" ] && _built_dirs+=( "${PNETCDF_PATH}" )
         for D in "${_built_dirs[@]}"; do
            ${SUDO} find ${D} -type f -execdir chown root:root "{}" +
            ${SUDO} find ${D} -type d -execdir chown root:root "{}" +
         done
         unset _built_dirs
      fi

      if [[ "${USER}" != "root" ]]; then
         _chmod_dirs=()
         [ "${_pre_existed_netcdf_c}" != "1" ] && _chmod_dirs+=( "${NETCDF_C_PATH}" )
         [ "${_pre_existed_netcdf_f}" != "1" ] && _chmod_dirs+=( "${NETCDF_F_PATH}" )
         [ "${_pre_existed_pnetcdf}"  != "1" ] && [ "${ENABLE_PNETCDF}" = "ON" ] && _chmod_dirs+=( "${PNETCDF_PATH}" )
         [ ${#_chmod_dirs[@]} -gt 0 ] && ${SUDO} chmod go-w "${_chmod_dirs[@]}"
         unset _chmod_dirs
      fi

   fi

   # Sanity gate: only write modulefiles if the install actually produced
   # the expected libraries. Catches the silent-failure case where
   # PnetCDF / netcdf-c failed mid-build (audit P1 in 7865) but the
   # script still went on to publish broken modulefiles.
   #
   # Scope the check to components this run actually built; a single-
   # component pnetcdf rebuild on top of an existing netcdf-c-v4.9.3
   # shouldn't re-verify netcdf-c libs (they're owned by a prior run
   # that already passed this gate).
   if [ "${_pre_existed_netcdf_c}" != "1" ]; then
      _lib="${NETCDF_C_PATH}/lib/libnetcdf.so"
      if ! { [ -f "${_lib}" ] || [ -f "${_lib}.0" ] || [ -L "${_lib}" ]; }; then
         echo "ERROR: expected netcdf-c library not found: ${_lib}" >&2
         echo "       Refusing to write netcdf-c modulefile." >&2
         exit 1
      fi
   fi
   if [ "${_pre_existed_netcdf_f}" != "1" ]; then
      _lib="${NETCDF_F_PATH}/lib/libnetcdff.so"
      if ! { [ -f "${_lib}" ] || [ -f "${_lib}.0" ] || [ -L "${_lib}" ]; }; then
         echo "ERROR: expected netcdf-fortran library not found: ${_lib}" >&2
         echo "       Refusing to write netcdf-fortran modulefile." >&2
         exit 1
      fi
   fi
   if [ "${ENABLE_PNETCDF}" = "ON" ] && [ "${_pre_existed_pnetcdf}" != "1" ]; then
      if [ ! -f "${PNETCDF_PATH}/lib/libpnetcdf.so" ] \
         && [ ! -f "${PNETCDF_PATH}/lib/libpnetcdf.a" ]; then
         echo "ERROR: PnetCDF was requested (HDF5_ENABLE_PARALLEL=ON) but" >&2
         echo "       ${PNETCDF_PATH}/lib/libpnetcdf.{so,a} is missing." >&2
         echo "       Refusing to write netcdf-c / netcdf-fortran / pnetcdf modulefiles." >&2
         exit 1
      fi
   fi
   unset _lib

   # Modulefile-write sudo decision.
   #
   # History: an early version used `[ ! -w ]` which LIED on a root:root
   # mode-755 NFS module dir (job 8063): the test said writable, then `tee`
   # hit EACCES and the script died rc=1 AFTER a successful build. That was
   # replaced by an unconditional `sudo` for non-root -- which is the
   # opposite failure on a Cray, where the module tree under /shareddata is
   # USER-writable but the compute nodes have NO passwordless sudo, so the
   # forced `sudo tee` died with "sudo: a password is required" (again AFTER
   # a successful build). Use a REAL touch-probe (mktemp) of the nearest
   # existing ancestor of the module dir -- the same reliable technique this
   # script already uses for the install path (it actually writes a file, so
   # it cannot lie the way `[ -w ]` does on NFS/ACL trees). Probe the
   # netcdf-c module dir as representative; all three component module dirs
   # are siblings under the same tree with the same permissions.
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      PKG_SUDO_MOD=""
   else
      _mprobe="${NETCDF_C_MODULE_PATH}"
      while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
      _mtest=$(mktemp --tmpdir="${_mprobe}" .netcdf-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         PKG_SUDO_MOD=""
         echo "netcdf: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         PKG_SUDO_MOD="sudo"
         echo "netcdf: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
      fi
      unset _mprobe _mtest
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
   # when Lmod is absent (this site runs Tcl Environment Modules 3.2.11 on the
   # Cray). Mirrors extras/scripts/hdf5_setup.sh. _MODEXT is appended to each
   # component's modulefile path; the per-component heredocs below branch on
   # _MODFLAVOR to emit Lua or Tcl syntax.
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      _MODFLAVOR="lua"
      _MODEXT=".lua"
   else
      _MODFLAVOR="tcl"
      _MODEXT=""
   fi
   echo "netcdf: modulefile flavor = ${_MODFLAVOR} (ext='${_MODEXT}')"

   # ── pnetcdf modulefile (new, 2026-05-20) ─────────────────────────
   # Emit a first-class pnetcdf/${PNETCDF_VERSION} modulefile when this
   # run actually built PnetCDF. The netcdf-c modulefile heredoc below
   # then loads this module by version pin instead of baking in absolute
   # paths inline -- so pnetcdf becomes a versioned dependency that
   # netcdf-c, netcdf-fortran, and any direct consumer can `module load
   # pnetcdf/<ver>` to get.
   if [ "${ENABLE_PNETCDF}" = "ON" ] && [ "${_pre_existed_pnetcdf}" != "1" ]; then
      ${PKG_SUDO_MOD} mkdir -p ${PNETCDF_MODULE_PATH}
      # The - option suppresses tabs
      if [ "${_MODFLAVOR}" = "lua" ]; then
         cat <<-EOF | ${PKG_SUDO_MOD} tee ${PNETCDF_MODULE_PATH}/${PNETCDF_VERSION}${_MODEXT}
	whatis("Parallel-NetCDF Library")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${PNETCDF_PATH}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("PATH", base)
	setenv("PNETCDF_ROOT", base)
	setenv("PNETCDF_PATH", base)
EOF
      else
         cat <<-EOF | ${PKG_SUDO_MOD} tee ${PNETCDF_MODULE_PATH}/${PNETCDF_VERSION}${_MODEXT}
	#%Module1.0
	module-whatis "Parallel-NetCDF Library"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${PNETCDF_PATH}"
	prepend-path LD_LIBRARY_PATH \$base/lib
	prepend-path LIBRARY_PATH \$base/lib
	prepend-path C_INCLUDE_PATH \$base/include
	prepend-path CPLUS_INCLUDE_PATH \$base/include
	prepend-path PATH \$base/bin
	prepend-path PATH \$base
	setenv PNETCDF_ROOT \$base
	setenv PNETCDF_PATH \$base
EOF
      fi
   fi

   # ── netcdf-c modulefile ──────────────────────────────────────────
   # Only (re)write when this run actually built netcdf-c. Otherwise
   # an existing pre-built install's modulefile would be silently
   # overwritten with potentially-different load() pins -- bad for
   # users who depend on the existing module's exact link chain.
   if [ "${_pre_existed_netcdf_c}" != "1" ]; then
      ${PKG_SUDO_MOD} mkdir -p ${NETCDF_C_MODULE_PATH}

      # Pin the hdf5 modulefile version that this netcdf-c was built
      # against. Without the pin, the netcdf-c modulefile emits a bare
      # `load("hdf5")` which Lmod resolves to whichever hdf5 version is
      # "default" at load time -- a problem once multiple hdf5 versions
      # coexist on the same rocmplus-<v> tree (e.g. 1.14.6 alongside
      # 2.1.1 on rocmplus-7.2.3). Loading netcdf-c 4.10.0 (built against
      # HDF5 2.1.1) under a default-resolved hdf5/1.14.6 would give an
      # ABI mismatch.
      #
      # HDF5_ROOT is set by hdf5_setup.sh's modulefile to
      #   ${HDF5_PATH}/HDF_Group/HDF5/${HDF5_VERSION}
      # (see extras/scripts/hdf5_setup.sh, modulefile heredoc), so the
      # trailing path component is the version we just built against.
      # Defensive fallback to bare `load("hdf5")` if the layout changes.
      HDF5_BUILT_AGAINST=""
      if [ -n "${HDF5_ROOT:-}" ] && [[ "${HDF5_ROOT}" == */HDF_Group/HDF5/* ]]; then
         HDF5_BUILT_AGAINST="${HDF5_ROOT##*/HDF_Group/HDF5/}"
         # Strip any trailing slash component (defensive; HDF5_ROOT should
         # be the leaf dir itself, not a parent).
         HDF5_BUILT_AGAINST="${HDF5_BUILT_AGAINST%%/*}"
      fi
      # Resolve the hdf5 + pnetcdf dependency module tokens (version-pinned
      # where possible), then render them in the active modulefile syntax
      # (Lua load("x") vs Tcl `module load x`).
      _hdf5_dep="${HDF5_MODULE}"
      if [ -n "${HDF5_BUILT_AGAINST}" ]; then
         _hdf5_dep="${HDF5_MODULE}/${HDF5_BUILT_AGAINST}"
         echo "netcdf-c modulefile: pinning hdf5 dependency to ${_hdf5_dep}"
      else
         echo "WARNING: could not extract HDF5 version from HDF5_ROOT='${HDF5_ROOT:-<unset>}'; falling back to unpinned hdf5 load" >&2
      fi
      # PnetCDF load line: when this run links netcdf-c against a PnetCDF
      # build, pin the version so the netcdf-c modulefile pulls in the
      # matching pnetcdf module automatically. ENABLE_PNETCDF=OFF builds
      # leave it empty (no pnetcdf module to load).
      _pnetcdf_dep=""
      if [ "${ENABLE_PNETCDF}" = "ON" ]; then
         _pnetcdf_dep="pnetcdf/${PNETCDF_VERSION}"
         echo "netcdf-c modulefile: pinning pnetcdf dependency to ${_pnetcdf_dep}"
      fi
      if [ "${_MODFLAVOR}" = "lua" ]; then
         NETCDF_C_HDF5_LOAD="load(\"${_hdf5_dep}\")"
         NETCDF_C_PNETCDF_LOAD=""
         [ -n "${_pnetcdf_dep}" ] && NETCDF_C_PNETCDF_LOAD="load(\"${_pnetcdf_dep}\")"
      else
         NETCDF_C_HDF5_LOAD="module load ${_hdf5_dep}"
         NETCDF_C_PNETCDF_LOAD=""
         [ -n "${_pnetcdf_dep}" ] && NETCDF_C_PNETCDF_LOAD="module load ${_pnetcdf_dep}"
      fi
      unset _hdf5_dep _pnetcdf_dep

      # The - option suppresses tabs
      if [ "${_MODFLAVOR}" = "lua" ]; then
         cat <<-EOF | ${PKG_SUDO_MOD} tee ${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}${_MODEXT}
	whatis("Netcdf-c Library")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	${NETCDF_C_HDF5_LOAD}
	${NETCDF_C_PNETCDF_LOAD}
	local base = "${NETCDF_C_PATH}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("FPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("PATH", base)
	setenv("NETCDF_C_ROOT", base)
EOF
      else
         cat <<-EOF | ${PKG_SUDO_MOD} tee ${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}${_MODEXT}
	#%Module1.0
	module-whatis "Netcdf-c Library"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	${NETCDF_C_HDF5_LOAD}
	${NETCDF_C_PNETCDF_LOAD}
	set base "${NETCDF_C_PATH}"
	prepend-path LD_LIBRARY_PATH \$base/lib
	prepend-path LIBRARY_PATH \$base/lib
	prepend-path C_INCLUDE_PATH \$base/include
	prepend-path CPLUS_INCLUDE_PATH \$base/include
	prepend-path CPATH \$base/include
	prepend-path FPATH \$base/include
	prepend-path PATH \$base/bin
	prepend-path PATH \$base
	setenv NETCDF_C_ROOT \$base
EOF
      fi
   fi

   # ── netcdf-fortran modulefile ────────────────────────────────────
   # Same per-component gating as netcdf-c: only (re)write when this
   # run actually built netcdf-fortran. See netcdf-c block above for
   # the PKG_SUDO_MOD rationale.
   if [ "${_pre_existed_netcdf_f}" != "1" ]; then
      ${PKG_SUDO_MOD} mkdir -p ${NETCDF_F_MODULE_PATH}

      # Pin the netcdf-c modulefile version this netcdf-fortran was
      # built against. Without the pin, the netcdf-fortran modulefile
      # emits a bare `load("netcdf-c")` which Lmod resolves to
      # whichever netcdf-c is "default" at load time. Once multiple
      # netcdf-c versions coexist on the tree (e.g. rocmplus-7.2.3
      # has both 4.9.3 and 4.10.0 after the 2026-05-20 rollout), the
      # bare load drifts to the higher version -- which has a
      # DIFFERENT hdf5 SONAME chain (4.9.3 -> libhdf5.so.310,
      # 4.10.0 -> libhdf5.so.320). The netcdf-fortran .so was linked
      # against ONE of those chains at build time; loading the wrong
      # netcdf-c silently breaks ld.so resolution for any consumer.
      # See audit at /home/admin/.cursor/plans/*.plan.md (Part B of
      # the 2026-05-20 netcdf hdf5 test regression fix) for the
      # ldd traces showing exactly this hazard hitting
      # netcdf-fortran/4.6.2 on the live tree.
      # The - option suppresses tabs
      if [ "${_MODFLAVOR}" = "lua" ]; then
         cat <<-EOF | ${PKG_SUDO_MOD} tee ${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}${_MODEXT}
	whatis("Netcdf-fortran Library")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	load("netcdf-c/${NETCDF_C_VERSION}")
	local base = "${NETCDF_F_PATH}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("FPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("PATH", base)
	setenv("NETCDF_F_ROOT", base)
EOF
      else
         cat <<-EOF | ${PKG_SUDO_MOD} tee ${NETCDF_F_MODULE_PATH}/${NETCDF_F_VERSION}${_MODEXT}
	#%Module1.0
	module-whatis "Netcdf-fortran Library"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	module load netcdf-c/${NETCDF_C_VERSION}
	set base "${NETCDF_F_PATH}"
	prepend-path LD_LIBRARY_PATH \$base/lib
	prepend-path LIBRARY_PATH \$base/lib
	prepend-path C_INCLUDE_PATH \$base/include
	prepend-path CPLUS_INCLUDE_PATH \$base/include
	prepend-path CPATH \$base/include
	prepend-path FPATH \$base/include
	prepend-path PATH \$base/bin
	prepend-path PATH \$base
	setenv NETCDF_F_ROOT \$base
EOF
      fi
   fi

fi

