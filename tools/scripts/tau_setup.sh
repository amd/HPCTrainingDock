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
MODULE_PATH=/etc/lmod/modules/ROCmPlus/tau
BUILD_TAU=0
ROCM_VERSION=6.2.0
TAU_PATH=/opt/rocmplus-${ROCM_VERSION}/tau
PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
TAU_PATH_INPUT=""
C_COMPILER=amdclang
CXX_COMPILER=amdclang++
F_COMPILER=amdflang
# MPI module to load for TAU's -mpi support. Default "openmpi" matches the
# Ubuntu/CI image; a Cray PrgEnv-amd-new ships no openmpi module, so
# main_setup.sh threads --mpi-module mpich-wrappers (the PrgEnv MPI, whose
# mpif90 wraps the new amdflang -> amdflang-format mpi.mod). Resolved to a
# concrete modulefile token in the build branch below.
MPI_MODULE="openmpi"
PDT_PATH_INPUT=""
GIT_COMMIT="fb4abfffa6683dd82a2b6ffddbfc497e6e1f5d60"
# TAU's modulefile is currently named dev.lua (no version baked in).
# PDT is a build-time-only dep shared with scorep, so we expose a
# separate --replace-pdt flag (analogous to scorep_setup.sh).
# --replace cleans tau + dev.lua; --replace-pdt cleans the shared PDT.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
REPLACE_PDT=0
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
 echo "  WARNING: when specifying --tau-install-path, --pdt-install-path  and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-tau: default $BUILD_TAU"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --tau-install-path [ TAU_PATH_INPUT ] default $TAU_PATH"
   echo "  --c-compiler [ C_COMPILER ] default $C_COMPILER"
   echo "  --f-compiler [ F_COMPILER ] default $F_COMPILER"
   echo "  --cxx-compiler [ CXX_COMPILER ] default $CXX_COMPILER"
   echo "  --mpi-module [ MPI_MODULE ] module to load for TAU -mpi support, default $MPI_MODULE"
   echo "  --pdt-install-path [ PDT_PATH_INPUT ] default $PDT_PATH"
   echo "  --git-commit [ GIT_COMMIT ] specify what commit hash you want to build from, default is $GIT_COMMIT"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL_INPUT ] default autodetected"
   echo "  --replace [ 0|1 ] remove prior tau install + modulefile before building, default $REPLACE (PDT NOT removed)"
   echo "  --replace-pdt [ 0|1 ] also remove and rebuild the shared PDT install, default $REPLACE_PDT"
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
      "--build-tau")
          shift
          BUILD_TAU=${1}
          reset-last
          ;;
      "--git-commit")
          shift
          GIT_COMMIT=${1}
          reset-last
          ;;
      "--c-compiler")
          shift
          C_COMPILER=${1}
          reset-last
          ;;
      "--f-compiler")
          shift
          F_COMPILER=${1}
          reset-last
          ;;
      "--cxx-compiler")
          shift
          CXX_COMPILER=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
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
      "--tau-install-path")
          shift
          TAU_PATH_INPUT=${1}
          reset-last
          ;;
      "--pdt-install-path")
          shift
          PDT_PATH_INPUT=${1}
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
      "--replace-pdt")
          shift
          REPLACE_PDT=${1}
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

TAU_PATH=/opt/rocmplus-${ROCM_VERSION}/tau
if [ "${TAU_PATH_INPUT}" != "" ]; then
   TAU_PATH=${TAU_PATH_INPUT}
fi

PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
if [ "${PDT_PATH_INPUT}" != "" ]; then
   PDT_PATH=${PDT_PATH_INPUT}
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   # Stderr-silenced + `|| true`: rocminfo can fail when the SDK is built
   # against a newer glibc than the host (ROCm 7.2.3 binaries need
   # GLIBC_2.38; jammy has 2.35) and under pipefail would kill the script.
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi

# ── Install-path sudo (computed EARLY, before afar-skip/--replace) ────
# The afar-skip and --replace blocks below rm -rf the install dirs +
# modulefile with ${SUDO}. The leaf default is SUDO=sudo, which on a
# cluster with no passwordless sudo and a user-owned install tree (this
# Cray) makes --replace / afar-skip die on a password prompt before the
# build even starts. Probe the nearest existing ancestor of the tau
# install dir for user-writability and drop sudo when we own it. Mirrors
# the magma/kokkos/hypre writability probe. The same SUDO then governs
# the tau + pdt install dirs + chowns in the build branch below.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :  # already cleared (e.g. Singularity)
else
   _iprobe="$(dirname "${TAU_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .tau-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "tau: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "tau: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# TAU modulefile is dev.lua; PDT is shared (see scorep_setup.sh).
# ── BUILD_TAU=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_TAU}" = "0" ]; then
   echo "[tau BUILD_TAU=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── afar SDK incompatibility detection ───────────────────────────────
# AMD's pre-release "AFAR" ROCm drops (rocm-afar-22.x, rocm-afar-7.0.5)
# are runtime-only / partial SDKs. Verified empirically on this cluster
# (audit_2026_05_06, jobs 8489 + 8490, log_tau_05_06_2026.txt:3274):
#
#   afar-22.{1,2}.0  $ find <ROCM_PATH> -path '*/clang/Basic/SourceManager.h'
#                    -> 0 matches
#   rocm-7.2.1       $ same probe
#                    -> .../lib/llvm/include/clang/Basic/SourceManager.h
#
# tau's plugins/llvm vendored CMake build always #includes
# <clang/Basic/SourceManager.h> (Instrument.cpp:53). The plugin cannot
# be built without the clang dev tree, and afar SDKs intentionally
# omit it. Skipping here turns 8489/8490-style FAILED(2) tau(rc=2)
# into the correct SKIPPED(no-op) bucket and saves ~6 min of CPU per
# afar sweep on a build that has no chance.
#
# Probe shape: gated on `${ROCM_PATH}` matching `*afar*` AND the
# missing clang header. The header check exists so this block
# self-corrects if AMD ships a more complete afar drop later (matches
# the rocm-bundled hipfort policy in extras/scripts/hipfort_setup.sh).
# We probe BOTH SDK layouts (THEROCK lib/llvm/include and STANDARD
# llvm/include) -- both exist on afar SDKs but neither contains
# clang/Basic/.
if [[ "${ROCM_PATH:-}" == *afar* ]]; then
   if [[ -z "${ROCM_PATH:-}" ]] && type module >/dev/null 2>&1; then
      module load "rocm/${ROCM_VERSION}" 2>/dev/null || true
   fi
   if [ ! -f "${ROCM_PATH}/lib/llvm/include/clang/Basic/SourceManager.h" ] \
      && [ ! -f "${ROCM_PATH}/llvm/include/clang/Basic/SourceManager.h" ]; then
      echo ""
      echo "[tau afar-skip] ROCM_PATH=${ROCM_PATH} is an AMD AFAR partial SDK"
      echo "                missing : <ROCM_PATH>/{lib/llvm,llvm}/include/clang/Basic/SourceManager.h"
      echo "                tau plugins/llvm requires the clang dev tree; cannot build on afar SDK."
      echo "                Skipping (no source build, no cache restore)."
      echo ""
      if [ -d "${TAU_PATH}" ]; then
         echo "[tau afar-skip] removing stale from-source install: ${TAU_PATH}"
         ${SUDO} rm -rf "${TAU_PATH}"
      fi
      if [ -f "${MODULE_PATH}/dev.lua" ] || [ -f "${MODULE_PATH}/dev" ]; then
         echo "[tau afar-skip] removing stale modulefile: ${MODULE_PATH}/dev{.lua,}"
         ${SUDO} rm -f "${MODULE_PATH}/dev.lua" "${MODULE_PATH}/dev"
      fi
      # ── Drop a SKIPPED marker so the inventory tool can distinguish ──
      # "skipped on this SDK" from "absent / failed". See
      # bare_system/inventory_packages.py ('N' symbol -- Not possible to build on this SDK).
      _SKIP_MARKER_DIR="$(dirname "${TAU_PATH}")"
      ${SUDO} mkdir -p "${_SKIP_MARKER_DIR}" 2>/dev/null || true
      if [ -d "${_SKIP_MARKER_DIR}" ]; then
         ${SUDO} tee "${_SKIP_MARKER_DIR}/tau.SKIPPED" >/dev/null 2>/dev/null <<MARKER_EOF || true
SKIPPED package: tau
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    tau_setup.sh (afar-skip guard)
Reason:          AFAR SDK is missing the clang dev tree
                 (<ROCM_PATH>/{lib/llvm,llvm}/include/clang/Basic/SourceManager.h).
                 tau plugins/llvm requires <clang/Basic/SourceManager.h>
                 (Instrument.cpp:53); cannot build on this SDK.
                 Self-corrects on the next sweep if AMD ships a more
                 complete AFAR drop.
MARKER_EOF
      fi
      unset _SKIP_MARKER_DIR
      exit ${NOOP_RC}
   fi
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[tau --replace 1] removing prior tau install + modulefile if present"
   echo "  install dir: ${TAU_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/dev{.lua,}"
   ${SUDO} rm -rf "${TAU_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/dev.lua" "${MODULE_PATH}/dev"
fi
if [ "${REPLACE_PDT}" = "1" ]; then
   echo "[tau --replace-pdt 1] removing prior PDT install"
   echo "  install dir: ${PDT_PATH}"
   ${SUDO} rm -rf "${PDT_PATH}"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Only the tau half is checked. PDT is shared with scorep and is
# intentionally preserved across re-installs; see scorep_setup.sh's
# existence-check comment block for the full rationale.
NOOP_RC=43
if [ -d "${TAU_PATH}" ]; then
   echo ""
   echo "[tau existence-check] ${TAU_PATH} already installed; skipping."
   echo "                      pass --replace 1 to force a clean rebuild."
   echo "                      (PDT existence not part of this check; see tau_setup.sh comments.)"
   echo ""
   exit ${NOOP_RC}
fi

_tau_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[tau fail-cleanup] rc=${rc}: removing partial tau install + modulefile (PDT preserved)"
      # Use the probed ${SUDO} (NOT ${SUDO:-sudo}): on a user-writable install
      # tree SUDO is intentionally empty, and forcing sudo here would prompt
      # for a password under srun and hang/fail the cleanup.
      ${SUDO} rm -rf "${TAU_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/dev.lua" "${MODULE_PATH}/dev"
   elif [ ${rc} -ne 0 ]; then
      echo "[tau fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Always clean the local /tmp scratch (build dir + spack user-scope dirs),
   # set in the build branch below. Plain rm: these are user-owned under /tmp.
   [ -n "${TAU_BUILD_DIR:-}" ] && rm -rf "${TAU_BUILD_DIR}"
   [ -n "${SPACK_USER_CONFIG_PATH:-}" ] && rm -rf "${SPACK_USER_CONFIG_PATH}"
   [ -n "${SPACK_USER_CACHE_PATH:-}" ] && rm -rf "${SPACK_USER_CACHE_PATH}"
   return ${rc}
}
trap _tau_on_exit EXIT

echo ""
echo "==================================="
echo "Starting TAU Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_TAU: $BUILD_TAU"
echo "TAU_PATH: $TAU_PATH"
echo "PDT_PATH: $PDT_PATH"
echo "Building TAU off of this commit: $GIT_COMMIT"
echo "==================================="
echo ""


if [ "${BUILD_TAU}" = "0" ]; then

   echo "TAU will not be build, according to the specified value of BUILD_TAU"
   echo "BUILD_TAU: $BUILD_TAU"
   exit

else
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

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

   if [ -f ${CACHE_FILES}/pdt.tgz ] && [ -f ${CACHE_FILES}/tau.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached TAU"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/pdt.tgz
      tar -xpzf ${CACHE_FILES}/tau.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/pdt.tgz ${CACHE_FILES}/tau.tgz
      fi

   else

      echo ""
      echo "============================"
      echo " Building TAU"
      echo "============================"
      echo ""

      # ── MPI module auto-correct on a Cray PE (see hypre/hdf5/netcdf) ──
      # TAU's -mpi support needs mpicc/mpif90 on PATH. The leaf default
      # MPI_MODULE is "openmpi", but a Cray system ships cray-mpich (no
      # openmpi module exists) -- preflight would SKIP the whole build. If
      # cray-mpich is active and the caller did not override the MPI,
      # switch to cray-mpich. main_setup.sh also threads --mpi-module
      # mpich-wrappers / cray-mpich; this makes the leaf correct standalone.
      if [ "${MPI_MODULE}" = "openmpi" ] \
           && { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; }; then
         MPI_MODULE="cray-mpich"
         echo "tau: Cray MPICH detected; MPI_MODULE -> cray-mpich"
      fi

      # ── mpich-wrappers resolution (PrgEnv MPI + new-flang mpi.mod) ─────
      # cray-mpich drives the build through cc/CC/ftn wrappers and does not
      # put mpicc/mpif90 on PATH, so TAU's -mpi autodetect cannot find it.
      # The from-source mpich-wrappers leaf ships mpicc/mpicxx/mpif90
      # (MPICH-ABI compatible with cray-mpich, built with the new LLVM
      # Flang amdflang -> amdflang-format mpi.mod) -- exactly what TAU's
      # MPI Fortran wrappers need on ROCm 7.x. When the caller asks for it
      # (main_setup threads --mpi-module mpich-wrappers), resolve the bare
      # name to the concrete, version-matched modulefile token by scanning
      # MODULEPATH. If none is found, fall back to cray-mpich.
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
            echo "tau: using mpich-wrappers module '${_mw_tok}' (PrgEnv MPI; ships mpicc/mpicxx/mpif90, new-flang mpi.mod)"
         else
            echo "tau: WARNING: --mpi-module mpich-wrappers requested but no mpich-wrappers modulefile found on MODULEPATH; falling back to cray-mpich"
            MPI_MODULE="cray-mpich"
         fi
         unset _mw_tok
      fi

      # rocm + MPI are required at build time. Pre-flighting here surfaces a
      # missing dep early rather than after a multi-minute PDT/spack download.
      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── Pin amdclang/amdflang/amdclang++ to the requested ROCm SDK ────
      # On a Cray PrgEnv-amd-new shell several rocm/* are loaded at once and
      # `amdclang`/`amdflang` on PATH can resolve to a DIFFERENT SDK than
      # ROCM_PATH (observed: amdflang -> /opt/rocm-7.0.3 while
      # ROCM_PATH=/shareddata/opt/rocm-7.2.3). TAU's -cc/-c++/-fortran take
      # bare compiler names and would then build against a mismatched SDK.
      # Prepend ${ROCM_PATH}/bin so the operator-requested SDK's compilers
      # win -- in particular the new amdflang (22.0.0git, roc-7.2.3) that
      # matches the mpich-wrappers mpi.mod. No-op when amdclang already
      # resolves to ${ROCM_PATH}.
      if [ -n "${ROCM_PATH:-}" ] && [ -x "${ROCM_PATH}/bin/amdflang" ]; then
         case ":${PATH}:" in
            *":${ROCM_PATH}/bin:"*) : ;;
            *) export PATH="${ROCM_PATH}/bin:${PATH}" ;;
         esac
         echo "tau: pinned compilers to ${ROCM_PATH}/bin (amdflang -> $(amdflang --version 2>/dev/null | head -1))"
      fi

     # don't use sudo if user has write access to both install paths
      if [ -d "$TAU_PATH" ]; then
         if [ -d "$PDT_PATH" ]; then
            # don't use sudo if user has write access to both install paths
            if [ -w ${TAU_PATH} ]; then
               if [ -w ${PDT_PATH} ]; then
                  SUDO=""
                  echo "WARNING: not using sudo since user has write access to install path, some dependencies may fail to get installed without sudo"
               else
                  echo "WARNING: using install paths that require sudo"
               fi
            fi
         fi
      else
         # if install paths do not both exist yet
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      export TAU_LIB_DIR=${TAU_PATH}/x86_64/lib
      ${SUDO} mkdir -p ${TAU_PATH}
      ${SUDO} mkdir -p ${PDT_PATH}

      # Build everything (spack clone + PDT install scratch +
      # tau2 source + 8 build flavors of compile artifacts) under
      # /tmp on compute-node local disk to avoid NFS round-trips.
      # Only `spack install pdt` and `make install` writes hit NFS,
      # via the absolute install paths in --prefix / install_tree.
      # Combined EXIT trap covers TAU_BUILD_DIR plus the two spack
      # user-scope isolation dirs created below. Audit basis: 7950
      # tau took 39m11s with build under
      # /home/admin/repos/HPCTrainingDock/tau2/...
      TAU_BUILD_DIR=$(mktemp -d -t tau-build.XXXXXX)

      # Spack user-scope isolation: redirect ~/.spack to per-job
      # throwaway dirs so `spack external find --all` and the
      # `spack config add "config:install_tree:root:..."` below
      # write to those throwaway dirs instead of polluting
      # ~/.spack/{packages,config}.yaml across rocm versions. Without
      # this, the user-scope install_tree.root from a prior build
      # makes `spack location -i pdt` return another rocm tree's path
      # (observed cross-contamination in rocmplus-7.0.1 scorep
      # modulefile pointing at /nfsapps/opt/rocmplus-7.0.2/pdt/...).
      SPACK_USER_CONFIG_PATH=$(mktemp -d -t spack-user-config.XXXXXX)
      SPACK_USER_CACHE_PATH=$(mktemp -d -t spack-user-cache.XXXXXX)
      export SPACK_USER_CONFIG_PATH SPACK_USER_CACHE_PATH
      # NOTE: cleanup of TAU_BUILD_DIR + these spack user-scope dirs is handled
      # by the single _tau_on_exit EXIT trap (installed before the build
      # branch), which also rolls back a partial install on failure. We do NOT
      # install a second EXIT trap here (the old code did, with ${SUDO:-sudo},
      # which both clobbered the install-rollback trap AND forced a sudo
      # password prompt under srun on a user-writable tree).

      cd "${TAU_BUILD_DIR}"
      git clone --depth 1 https://github.com/spack/spack.git

      # load spack environment
      source spack/share/spack/setup-env.sh

      # find already installed libs for spack
      spack external find --all

      # change spack install dir for PDT
      # With SPACK_USER_CONFIG_PATH set above, this writes to the
      # per-job throwaway user config dir, isolated from other builds.
      spack config add "config:install_tree:root:${PDT_PATH}"

      # open permissions to use spack to install PDT
      if [[ "${USER}" != "root" ]]; then
	 ${SUDO} chmod -R a+rwX $PDT_PATH
	 ${SUDO} chmod -R a+rwX $TAU_PATH
      fi

      # install PDT with spack
      spack install pdt

      # get PDT install dir created by spack
      PDT_PATH_ORIGINAL=$PDT_PATH
      PDT_PATH=$(spack location -i pdt)
      export PDTDIR=$PDT_PATH

      # We are already in ${TAU_BUILD_DIR} from the spack section
      # above; tau2 will be cloned into ${TAU_BUILD_DIR}/tau2.
      #
      # Partial clone (--filter=blob:none) skips downloading blobs
      # for history we don't need; the subsequent `git checkout
      # $GIT_COMMIT` lazily fetches just the blobs for that commit.
      # Reduces clone wall-time and disk by ~5-10x vs full clone
      # while still supporting checkout of any specific commit
      # (unlike --depth 1, which only gives the tip of the default
      # branch).
      git clone --filter=blob:none https://github.com/UO-OACISS/tau2.git || { echo "ERROR: git clone of tau2 failed"; exit 1; }
      cd tau2
      git checkout $GIT_COMMIT || { echo "ERROR: git checkout $GIT_COMMIT failed"; exit 1; }

      # Patch tau's vendored plugins/llvm/Makefile to (a) embed the
      # ROCm LLVM include dir into CMAKE_CXX_FLAGS, and (b) split
      # `make install` into separate build/install passes via cmake.
      #
      # Background (audit_2026_05_01.md, jobs 7974 and 7975
      # log_tau_05_01_2026.txt):
      # The TAU plugins/llvm CMake setup is intermittent about how it
      # computes LLVM_INCLUDE_DIRS. In job 7974 the first compile pass
      # succeeded with -I${ROCM_PATH}/lib/llvm/include on the command
      # line, then `make install` triggered a cmake re-stat that
      # rebuilt with that -I dropped, failing at "clang/Basic/
      # SourceManager.h: No such file" at log line 3459. The first
      # mitigation (commit 8ff591b's tau_setup.sh) replaced
      #   && make VERBOSE=1 -j install
      # with
      #   && cmake --build . --parallel && cmake --install .
      # but in job 7975 the FIRST compile pass already drops the -I
      # (log:3457) before the install pass even runs, so the cmake-
      # split alone is insufficient.
      #
      # The robust fix is to embed -I${ROCM_PATH}/lib/llvm/include into
      # CMAKE_CXX_FLAGS via the cmake invocation itself. CMAKE_CXX_FLAGS
      # is appended to every g++ compile by cmake's generated rules and
      # SURVIVES any reconfigure (it's stored in CMakeCache.txt and
      # regenerated identically), unlike LLVM_INCLUDE_DIRS which is
      # auto-detected per cmake run from -DLLVM_DIR's CMake config and
      # CAN be lost on a re-stat. The clang headers exist at
      #   ${ROCM_PATH}/lib/llvm/include/clang/Basic/SourceManager.h
      # for every ROCm 7.x; making the include path part of the compile
      # flag itself bypasses the LLVM_INCLUDE_DIRS code path entirely.
      #
      # Single sed replacing the trailing
      #   -DCMAKE_BUILD_TYPE=Debug && make VERBOSE=1 -j install
      # with
      #   -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS=-I${ROCM_PATH}/lib/llvm/include
      #     && cmake --build . --parallel && cmake --install .
      # Double-quoted so ${ROCM_PATH} expands at sed time; cmake-3.15+
      # provides --install, which is available in the bundled
      # /usr/local/bin/cmake (Python pip cmake) that tau's
      # plugins/llvm/Makefile invokes (job 7974/7975 log line 3215/3433).
      # ── Detect the clang dev tree + LLVM CMake config for the plugin ──
      # TAU's compiler-instrumentation plugin (plugins/llvm, enabled by the
      # -llvm_src configure flag below) #includes <clang/Basic/SourceManager.h>
      # and needs ${ROCM_PATH}/llvm/lib/cmake/llvm. Some ROCm 7.x SDK layouts
      # (e.g. the /shareddata/opt/rocm-7.2.3 SDK on this Cray) ship the flang/
      # offload headers but NOT the clang dev tree, and have no llvm CMake
      # config dir -- so the plugin simply cannot build here. Probe both the
      # THEROCK (lib/llvm/include) and STANDARD (llvm/include) layouts; when
      # the clang headers + llvm cmake dir are present, build the plugin
      # (embedding the include dir into CMAKE_CXX_FLAGS, see the long comment
      # above); when absent, skip the plugin entirely (drop -llvm_src below)
      # rather than failing the whole TAU build on a single optional feature.
      TAU_LLVM_CLANG_INC=""
      if [ -f "${ROCM_PATH}/lib/llvm/include/clang/Basic/SourceManager.h" ]; then
         TAU_LLVM_CLANG_INC="${ROCM_PATH}/lib/llvm/include"
      elif [ -f "${ROCM_PATH}/llvm/include/clang/Basic/SourceManager.h" ]; then
         TAU_LLVM_CLANG_INC="${ROCM_PATH}/llvm/include"
      fi
      if [ -n "${TAU_LLVM_CLANG_INC}" ] && [ -d "${ROCM_PATH}/llvm/lib/cmake/llvm" ]; then
         echo "tau: clang dev tree found (${TAU_LLVM_CLANG_INC}); LLVM instrumentation plugin will be built"
         if [ -f plugins/llvm/Makefile ]; then
            sed -i "s|-DCMAKE_BUILD_TYPE=Debug && make VERBOSE=1 -j install|-DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS=-I${TAU_LLVM_CLANG_INC} \\&\\& cmake --build . --parallel \\&\\& cmake --install .|" plugins/llvm/Makefile
         fi
      else
         echo "tau: clang dev tree / llvm CMake config absent under ${ROCM_PATH}; skipping LLVM instrumentation plugin (dropping -llvm_src)"
      fi

      # install third party dependencies
      # -q to drop wget dot-progress noise from the per-package log,
      # matching the precedent in comm/scripts/openmpi_setup.sh and the
      # S6.E fix in tools/scripts/scorep_setup.sh.
      wget -q http://tau.uoregon.edu/ext.tgz

      tar zxf ext.tgz

      # PKG_SUDO: apt needs root regardless of the install-path-derived
      # SUDO. The previous code passed ${SUDO} to apt directly, so a
      # build to an admin-writable install path (SUDO='') would have
      # tried `apt-get update` without sudo and failed with
      # /var/lib/apt/lists/lock Permission denied. See openmpi_setup.sh
      # / audit_2026_05_01.md Issue 2 for the original case.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")

      # apt is Debian/Ubuntu only. On a Cray RHEL9 host there is no apt-get;
      # MPI comes from the (mpich-wrappers/cray-mpich) module loaded by
      # preflight and java is provided by the base image, so the apt steps
      # below are simply skipped. Guarding (rather than calling apt blindly)
      # avoids a `apt-get: command not found` abort under `set -e`.
      if command -v apt-get >/dev/null 2>&1; then
         # install OpenMPI if not in the system already
         # (the MPI module loaded by preflight already puts mpicc on PATH)
         if [[ `which mpicc | wc -l` -eq 0 ]]; then
            ${PKG_SUDO} apt-get update
            ${PKG_SUDO} apt-get install -q -y libopenmpi-dev
         fi

         # install java to use paraprof
         ${PKG_SUDO} apt-get update
         ${PKG_SUDO} apt install -q -y default-jre
      else
         echo "tau: apt-get not present (non-Debian host); relying on module MPI ($(command -v mpicc || echo 'mpicc MISSING')) and system java ($(command -v java || echo 'java MISSING'))"
      fi

      # ROCm integration flags. -llvm_src enables the optional plugins/llvm
      # compiler-instrumentation plugin; only pass it when the clang dev tree
      # + llvm CMake config were detected above (TAU_LLVM_CLANG_INC set),
      # otherwise the plugin's find_package(LLVM)/clang headers are missing
      # and the whole build would fail on this single optional feature.
      ROCM_FLAGS="-rocm=${ROCM_PATH} -hip=${ROCM_PATH} -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -rocprofiler=${ROCM_PATH}"
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" ]]; then # ROCM_VERSION >= 6.2
         ROCM_FLAGS="-rocm=${ROCM_PATH} -hip=${ROCM_PATH} -rocmsmi=${ROCM_PATH} -rocprofsdk=${ROCM_PATH}"
         if [ -n "${TAU_LLVM_CLANG_INC}" ] && [ -d "${ROCM_PATH}/llvm/lib/cmake/llvm" ]; then
            ROCM_FLAGS="${ROCM_FLAGS} -llvm_src=${ROCM_PATH}/llvm/lib/cmake/llvm"
         fi
      fi

      # ── plugins/llvm gate for the `make -j` build pass ────────────────
      # TAU's top-level Makefile.skel has `all: install`, so each `make -j`
      # below ALSO descends into plugins/llvm (it's in $(SUBDIR) by default,
      # independent of -llvm_src). On an SDK without the clang dev tree /
      # llvm CMake config (detected above), that subdir's cmake fails with
      # "Could not find LLVM" and aborts the whole TAU build. Setting
      # LLVM_PLUGIN= on the make command line drops plugins/llvm from
      # $(SUBDIR) for the build pass too, so TAU still builds (just without
      # the optional compiler-instrumentation plugin). When the clang tree
      # IS present, leave this empty so `make -j` builds the plugin as admin
      # (the install pass already passes LLVM_PLUGIN= to avoid a root rebuild).
      if [ -n "${TAU_LLVM_CLANG_INC}" ] && [ -d "${ROCM_PATH}/llvm/lib/cmake/llvm" ]; then
         TAU_BUILD_LLVM_OPT=""
      else
         TAU_BUILD_LLVM_OPT="LLVM_PLUGIN="
      fi

      # ── -fPIC for ALL objects (HPE/Cray PE only) ─────────────────────
      # Mirrors the FFTW fix: on an HPE/Cray PE the cc/CC wrappers drive the
      # ROCm clang, whose ld.lld links executables -pie by default. TAU's
      # static libs (libTAU*.a) and the helper/wrapper objects are otherwise
      # compiled without -fPIC, so the final PIE link fails with "relocation
      # R_X86_64_32 ... recompile with -fPIC". -useropt threads -fPIC onto
      # every compile so every object (and the .a archives) is position-
      # independent. Gate on Cray markers so a stock OpenMPI/gcc build (GNU
      # ld, non-strict) is left exactly as-is.
      TAU_PIC_OPT=""
      if [ -n "${CRAYPE_VERSION:-}" ] || [ -n "${PE_ENV:-}" ] \
         || [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ] \
         || [ -d /opt/cray/pe ]; then
         TAU_PIC_OPT="-useropt=-fPIC"
         echo "tau: HPE/Cray PE detected -> adding -fPIC via -useropt (PIE-default ROCm clang/ld.lld)"
      fi

      # configure with: MPI OMPT OPENMP PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -ompt -openmp -pdt=${PDT_PATH} -iowrapper ${TAU_PIC_OPT}

      # LLVM_PLUGIN= on every `${SUDO} ... make install` line below skips
      # plugins/llvm in the root install pass. Why: TAU's top-level
      # Makefile.skel has `all: install` and `install: .clean`, so `make -j`
      # above already runs the plugins/llvm install recipe AS ADMIN (cmake
      # configure + cmake --build + cmake --install), and it succeeds because
      # ${TAU_PATH} was set chmod -R a+rwX above. The subsequent
      # `${SUDO} make install` would otherwise re-run that same recipe AS
      # ROOT (after first `rm -Rf build` via the .clean prereq), producing
      # root-owned files in plugins/llvm/build/ that break the next cycle's
      # `make clean` recursion (Permission denied / Error 1 in sweep logs).
      # Setting LLVM_PLUGIN= on the make command line overrides the plain
      # `LLVM_PLUGIN=plugins/llvm` assignment in the configure-generated
      # Makefile, so plugins/llvm is dropped from $(SUBDIR) for both the
      # .clean and install recursions in the root pass. Net effect: cmake
      # --build and cmake --install only ever run as admin (least
      # privilege), build/ stays admin-owned across cycles, and one
      # plugin rebuild per cycle is saved.
      make -j $(nproc) ${TAU_BUILD_LLVM_OPT}
      ${SUDO} env PATH=$PATH make install LLVM_PLUGIN=

      # configure with: MPI PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -pdt=${PDT_PATH} -iowrapper ${TAU_PIC_OPT}

      make -j $(nproc) ${TAU_BUILD_LLVM_OPT}
      ${SUDO} env PATH=$PATH make install LLVM_PLUGIN=

      # configure with: OMPT OPENMP PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -ompt -openmp -pdt=${PDT_PATH} -iowrapper ${TAU_PIC_OPT}

      make -j $(nproc) ${TAU_BUILD_LLVM_OPT}
      ${SUDO} env PATH=$PATH make install LLVM_PLUGIN=

      # configure with: PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -pdt=${PDT_PATH} -iowrapper ${TAU_PIC_OPT}

      make -j $(nproc) ${TAU_BUILD_LLVM_OPT}
      ${SUDO} env PATH=$PATH make install LLVM_PLUGIN=

      # configure with: ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -iowrapper ${TAU_PIC_OPT}

      make -j $(nproc) ${TAU_BUILD_LLVM_OPT}
      ${SUDO} env PATH=$PATH make install LLVM_PLUGIN=

      # configure with: OMPT OPENMP ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -ompt -openmp -iowrapper ${TAU_PIC_OPT}

      make -j $(nproc) ${TAU_BUILD_LLVM_OPT}
      ${SUDO} env PATH=$PATH make install LLVM_PLUGIN=

      # configure with: MPI ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -mpi -iowrapper ${TAU_PIC_OPT}

      make -j $(nproc) ${TAU_BUILD_LLVM_OPT}
      ${SUDO} env PATH=$PATH make install LLVM_PLUGIN=

      # configure with: MPI OMPT OPENMP ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -ompt -openmp -iowrapper ${TAU_PIC_OPT}

      make -j $(nproc) ${TAU_BUILD_LLVM_OPT}
      ${SUDO} env PATH=$PATH make install LLVM_PLUGIN=

      # ── Detect the TAU arch subdir (x86_64 vs craycnl) ───────────────
      # TAU names its install subdir after the detected machine arch. On a
      # generic x86_64 host that is "x86_64"; on a Cray (TAU detects the
      # Cray PE -> -DTAU_CRAYCNL) it is "craycnl". Hardcoding x86_64 breaks
      # the pthread-wrapper cleanup below and the modulefile PATH/lib on a
      # Cray. Derive it from whichever <arch>/bin TAU actually created.
      TAU_ARCH="$(basename "$(dirname "$(ls -d ${TAU_PATH}/*/bin 2>/dev/null | head -1)")")"
      [ -z "${TAU_ARCH}" ] && TAU_ARCH="x86_64"
      TAU_LIB_DIR="${TAU_PATH}/${TAU_ARCH}/lib"
      export TAU_LIB_DIR
      echo "tau: detected arch subdir '${TAU_ARCH}' (TAU_LIB_DIR=${TAU_LIB_DIR})"

      # the configure flag -no_pthread_create
      # still creates linking options for the pthread wrapper
      # that are breaking the instrumentation tests in C and C++
      ${SUDO} rm -f ${TAU_LIB_DIR}/wrappers/pthread_wrapper/link_options.tau

      # TAU_BUILD_DIR (under /tmp, contains tau2/ and the spack clone)
      # is removed by the EXIT trap above. No need to rm -rf tau2 or
      # spack explicitly here.

      # chown to root only when we actually installed with elevation
      # (SUDO non-empty). On a user-owned install tree (SUDO="") the files
      # are already correctly owned and `chown root:root` would fail with
      # "Operation not permitted" and abort under set -e.
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find $PDT_PATH_ORIGINAL -type f -execdir chown root:root "{}" +
         ${SUDO} find $PDT_PATH_ORIGINAL -type d -execdir chown root:root "{}" +
         ${SUDO} find $TAU_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $TAU_PATH -type d -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} chmod go-w $PDT_PATH_ORIGINAL
         ${SUDO} chmod go-w $TAU_PATH
      fi

      # Unload the dependent (MPI) BEFORE its dependency (rocm): the openmpi
      # modulefile prereqs rocm/<ver>, so unloading rocm first while openmpi
      # is still loaded trips Lmod ("Cannot load module openmpi without
      # rocm/<ver>"). `|| true` already tolerates absence; ordering avoids the
      # spurious error. Mirrors petsc_setup.sh / hypre_setup.sh.
      module unload ${MPI_MODULE} || true
      module unload ${ROCM_MODULE_NAME} || true

   fi

   # Arch-subdir fallback for the modulefile: the build branch sets TAU_ARCH
   # + TAU_LIB_DIR after detecting x86_64 vs craycnl, but the cached-install
   # branch above does not, so derive them here when unset (idempotent).
   if [ -z "${TAU_ARCH:-}" ]; then
      TAU_ARCH="$(basename "$(dirname "$(ls -d ${TAU_PATH}/*/bin 2>/dev/null | head -1)")")"
      [ -z "${TAU_ARCH}" ] && TAU_ARCH="x86_64"
      TAU_LIB_DIR="${TAU_PATH}/${TAU_ARCH}/lib"
   fi

   # Create a module file for TAU
   #
   # Module-tree sudo + flavor: pick Lua (.lua) for Lmod, classic Tcl
   # (no ext) otherwise, and probe the module tree for user-writability so
   # a user-owned modulepath (this Cray) does not trigger a sudo password
   # prompt. Mirrors the magma/kokkos/hypre modulefile probe.
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      MODFLAVOR="lua"; MODEXT=".lua"
   else
      MODFLAVOR="tcl"; MODEXT=""
   fi
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      MOD_SUDO=""
   else
      _mprobe="${MODULE_PATH}"
      while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
      _mtest=$(mktemp --tmpdir="${_mprobe}" .tau-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         MOD_SUDO=""
         echo "tau: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         MOD_SUDO="sudo"
         echo "tau: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
      fi
      unset _mprobe _mtest
   fi
   ${MOD_SUDO} mkdir -p ${MODULE_PATH}

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

   # The - option suppresses tabs. Dual flavor: Lua for Lmod, classic Tcl
   # otherwise. Both prereq the rocm SDK module and load the (resolved) MPI
   # module so TAU's MPI wrappers (tau_cc.sh -mpi, etc.) find mpicc/mpif90
   # from the same PrgEnv MPI the library was built against.
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

   TAU_MODULEFILE="${MODULE_PATH}/dev${MODEXT}"
   if [ "${MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${MOD_SUDO} tee ${TAU_MODULEFILE}
	whatis(" TAU - portable profiling and tracing toolkit ")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	${ROCM_PREREQ_LUA}
	load("${MPI_MODULE}")
	prepend_path("PATH","${TAU_PATH}/${TAU_ARCH}/bin")
	prepend_path("PATH","${PDT_PATH}/bin")
	setenv("TAU_LIB_DIR","${TAU_LIB_DIR}")
EOF
   else
      cat <<-EOF | ${MOD_SUDO} tee ${TAU_MODULEFILE}
	#%Module1.0
	module-whatis "TAU - portable profiling and tracing toolkit"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_PREREQ_TCL}
	if { ![ is-loaded ${MPI_MODULE} ] } { module load ${MPI_MODULE} }
	prepend-path PATH "${TAU_PATH}/${TAU_ARCH}/bin"
	prepend-path PATH "${PDT_PATH}/bin"
	setenv TAU_LIB_DIR "${TAU_LIB_DIR}"
EOF
   fi

fi
