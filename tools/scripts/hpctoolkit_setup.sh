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
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
MODULE_PATH=/etc/lmod/modules/ROCmPlus/hpctoolkit
BUILD_HPCTOOLKIT=0
HPCTOOLKIT_VERSION=2025.1.2
# Spack-resolved upstream version of hpcviewer. Pinned (vs. left as
# spack's default "latest") so the install dir name + cache tar name
# + modulefile path + replace-cleanup all agree on the same concrete
# string across runs. Job 8063 audit: spack actually emits a clean
# semver in the install dir (.../hpcviewer-2026.0.0-<spackhash>/),
# which contradicted the prior "no clean upstream version" comment
# that justified leaving hpcviewer unversioned. Override with
# `--hpcviewer-version X.Y.Z` (or HPCVIEWER_VERSION=... env) when a
# new spack-known release is needed.
HPCVIEWER_VERSION=2026.0.0
ROCM_VERSION=6.2.0
# MPI module to load so meson's dependency('MPI') finds mpicc/mpicxx and
# builds hpcprof-mpi. Default "openmpi" matches the Ubuntu/CI image; a Cray
# PrgEnv-amd-new ships no openmpi module, so main_setup.sh threads
# --mpi-module mpich-wrappers (the PrgEnv MPI). Resolved to a concrete
# modulefile token in the build branch below.
MPI_MODULE="openmpi"
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
# Versioned hpctoolkit + hpcviewer install dirs let multiple releases
# coexist under one ROCm tree (matches the convention used by every
# other versioned package: magma-v*, openblas-v*, fftw-v*, etc.).
# hpcviewer was previously unversioned on the (incorrect) belief that
# spack didn't expose a clean upstream version; job 8063 disk audit
# showed otherwise -- spack puts hpcviewer-${VERSION}-<hash> right
# in the install path -- so we now extract that ${VERSION} via the
# HPCVIEWER_VERSION pin above and write to a parallel versioned dir.
HPCTOOLKIT_PATH=/opt/rocmplus-${ROCM_VERSION}/hpctoolkit-v${HPCTOOLKIT_VERSION}
HPCVIEWER_PATH=/opt/rocmplus-${ROCM_VERSION}/hpcviewer-v${HPCVIEWER_VERSION}
HPCTOOLKIT_PATH_INPUT=""
HPCVIEWER_PATH_INPUT=""
# --install-path: parent dir; the script appends both
# hpctoolkit-v${HPCTOOLKIT_VERSION} and hpcviewer-v${HPCVIEWER_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# either version. Per-component --hpctoolkit-install-path-no-version /
# --hpcviewer-install-path-no-version (full leaf dirs) still win when set.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf both hpctoolkit and hpcviewer install dirs +
# ${HPCTOOLKIT_VERSION}.lua before building. They're versioned together
# under the single hpctoolkit modulefile so we treat them as one unit.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0


if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --hpctoolkit-install-path-no-version, --hpcviewer-install-path-no-version  and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --hpctoolkit-version [ HPCTOOLKIT_VERSION ] default $HPCTOOLKIT_VERSION"
   echo "  --hpcviewer-version [ HPCVIEWER_VERSION ] spack-resolved upstream version, default $HPCVIEWER_VERSION"
   echo "  --hpctoolkit-install-path-no-version [ HPCTOOLKIT_PATH_INPUT ] default $HPCTOOLKIT_PATH "
   echo "  --hpcviewer-install-path-no-version [ HPCVIEWER_PATH_INPUT ] default $HPCVIEWER_PATH "
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set, fills both component install paths from \${ROCMPLUS_PATH}/{hpctoolkit-v\${HPCTOOLKIT_VERSION},hpcviewer-v\${HPCVIEWER_VERSION}}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --mpi-module [ MPI_MODULE ] module to load so hpcprof-mpi finds MPI, default $MPI_MODULE"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --build-hpctoolkit [ BUILD_HPCTOOLKIT ] default is 0"
   echo "  --replace [ 0|1 ] remove prior hpctoolkit + hpcviewer installs and modulefile before building, default $REPLACE"
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--build-hpctoolkit")
          shift
          BUILD_HPCTOOLKIT=${1}
          reset-last
          ;;
      "--hpctoolkit-install-path-no-version")
          shift
          HPCTOOLKIT_PATH_INPUT=${1}
          reset-last
          ;;
      "--hpctoolkit-version")
          shift
          HPCTOOLKIT_VERSION=${1}
          reset-last
          ;;
      "--hpcviewer-version")
          shift
          HPCVIEWER_VERSION=${1}
          reset-last
          ;;
      "--hpcviewer-install-path-no-version")
          shift
          HPCVIEWER_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
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
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
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

# Recompute install paths now that ROCM_VERSION / HPCTOOLKIT_VERSION /
# HPCVIEWER_VERSION may have been overridden by --rocm-version /
# --hpctoolkit-version / --hpcviewer-version.
# Precedence: per-component --hpctoolkit-install-path-no-version /
# --hpcviewer-install-path-no-version (full leaf dirs) win, then
# --install-path (parent dir; we append the version-suffixed leaf
# names from this script's defaults), then the legacy /opt/rocmplus-X
# default. This lets main_setup.sh stay version-agnostic for hpctoolkit
# while still allowing operators to pin one component without rebuilding
# the other.
HPCTOOLKIT_PATH=/opt/rocmplus-${ROCM_VERSION}/hpctoolkit-v${HPCTOOLKIT_VERSION}
HPCVIEWER_PATH=/opt/rocmplus-${ROCM_VERSION}/hpcviewer-v${HPCVIEWER_VERSION}
if [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   HPCTOOLKIT_PATH=${ROCMPLUS_PATH_INPUT}/hpctoolkit-v${HPCTOOLKIT_VERSION}
   HPCVIEWER_PATH=${ROCMPLUS_PATH_INPUT}/hpcviewer-v${HPCVIEWER_VERSION}
fi
if [ "${HPCTOOLKIT_PATH_INPUT}" != "" ]; then
   HPCTOOLKIT_PATH=${HPCTOOLKIT_PATH_INPUT}
fi
if [ "${HPCVIEWER_PATH_INPUT}" != "" ]; then
   HPCVIEWER_PATH=${HPCVIEWER_PATH_INPUT}
fi

# HPCVIEWER_TOP: the versioned top-level install dir we own and that
# every "is hpcviewer there?" / "remove hpcviewer" / "lock down
# hpcviewer perms" question is asked against. It is captured here,
# BEFORE the spack section below reassigns HPCVIEWER_PATH to spack's
# `spack location -i hpcviewer` deep-hash subdir (see line ~410 area)
# for use in the modulefile's PATH prepend. Job 8063 audit: that
# reassignment is what caused the post-install chmod/chown to only
# affect the spack hash subdir and leave the top dir at 777 -- the
# top vs spack-hash distinction is exactly what HPCVIEWER_TOP locks
# in, so every "operate on the install" path uses HPCVIEWER_TOP and
# only the modulefile gets the spack-hash subdir.
HPCVIEWER_TOP="${HPCVIEWER_PATH}"

# ── Install-path sudo (computed EARLY, before --replace / EXIT trap) ──
# The --replace block, the EXIT fail-cleanup trap, and the build branch
# all rm -rf / mkdir the install dirs + modulefile with ${SUDO}. The leaf
# default is SUDO=sudo, which on a cluster with no passwordless sudo and a
# user-owned install tree (this Cray) makes --replace / fail-cleanup die on
# a password prompt. Probe the nearest existing ancestor of the hpctoolkit
# install dir for user-writability and drop sudo when we own it. Mirrors
# the tau/hypre/magma writability probe; this SUDO then governs the
# hpctoolkit + hpcviewer install dirs in every section below.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :  # already cleared (e.g. Singularity)
else
   _iprobe="$(dirname "${HPCTOOLKIT_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .hpctk-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "hpctoolkit: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "hpctoolkit: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# ── BUILD_HPCTOOLKIT=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_HPCTOOLKIT}" = "0" ]; then
   echo "[hpctoolkit BUILD_HPCTOOLKIT=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[hpctoolkit --replace 1] removing prior installs + modulefile if present"
   echo "  hpctoolkit dir: ${HPCTOOLKIT_PATH}"
   echo "  hpcviewer dir:  ${HPCVIEWER_TOP}"
   echo "  modulefile:     ${MODULE_PATH}/${HPCTOOLKIT_VERSION}.lua"
   ${SUDO} rm -rf "${HPCTOOLKIT_PATH}" "${HPCVIEWER_TOP}"
   ${SUDO} rm -f  "${MODULE_PATH}/${HPCTOOLKIT_VERSION}.lua"
fi

# ── Existence guard (see hypre_setup.sh) ─────────────────────────────
# Multi-component: skip ONLY if BOTH hpctoolkit-v${VER} AND hpcviewer-
# v${HPCVIEWER_VERSION} are present. If either is missing the modulefile
# would prereq a path that does not exist, so we proceed to (re)build.
# Checks the versioned top dir HPCVIEWER_TOP (not the spack-hash
# subdir) so a spack-side rename of the leaf hash doesn't false-
# positive this guard; main_setup.sh's old `[[ ! -d hpctoolkit-v${VER}
# ]]` guard knew about the hpctoolkit half only.
NOOP_RC=43
if [ -d "${HPCTOOLKIT_PATH}" ] && [ -d "${HPCVIEWER_TOP}" ]; then
   echo ""
   echo "[hpctoolkit existence-check] both components already installed; skipping."
   echo "  hpctoolkit dir: ${HPCTOOLKIT_PATH}"
   echo "  hpcviewer dir:  ${HPCVIEWER_TOP}"
   echo "  pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── Combined EXIT trap: install fail-cleanup + build-dir cleanup ─────
# Job 8063 audit: previously _hpctoolkit_on_exit (registered here) was
# silently OVERWRITTEN by a second `trap '...' EXIT` in the spack
# section, which cleaned the build-tmpdirs but not the partial
# install dirs/modulefile -- a hpcviewer build failure then left
# /opt/rocmplus-X/{hpctoolkit-v*,hpcviewer-v*} on disk and the next
# sweep's existence-guard above false-positively skipped the rebuild.
# Combined trap below fires once on EXIT and does both: install
# cleanup (gated by KEEP_FAILED_INSTALLS) THEN build-tmpdir cleanup
# (always, whether success or fail). The build-tmpdir vars are not
# yet set at this point, so the trap parameter-expands them lazily
# from the EXIT context (the `:-/nonexistent` defaults make rm a
# no-op when a section never reached its mktemp).
_hpctoolkit_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hpctoolkit fail-cleanup] rc=${rc}: removing partial hpctoolkit + hpcviewer installs + modulefile"
      # Use the probed ${SUDO} (NOT ${SUDO:-sudo}): on a user-writable install
      # tree SUDO is intentionally empty, and forcing sudo here would prompt
      # for a password under srun and hang/fail the cleanup.
      ${SUDO} rm -rf "${HPCTOOLKIT_PATH}" "${HPCVIEWER_TOP}"
      ${SUDO} rm -f  "${MODULE_PATH}/${HPCTOOLKIT_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[hpctoolkit fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Build-tmpdir cleanup (always, regardless of rc): each var is
   # initialized later in the build path; defaulting to /nonexistent
   # makes the rm a no-op for sections that never ran (e.g. cache-
   # restore branch which sets neither).
   ${SUDO} rm -rf \
      "${HPCTOOLKIT_BUILD_DIR:-/nonexistent}" \
      "${HPCVIEWER_BUILD_DIR:-/nonexistent}" \
      "${SPACK_USER_CONFIG_PATH:-/nonexistent}" \
      "${SPACK_USER_CACHE_PATH:-/nonexistent}"
   return ${rc}
}
trap _hpctoolkit_on_exit EXIT

echo ""
echo "==================================="
echo "Starting HPCToolkit Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HPCTOOLKIT: $BUILD_HPCTOOLKIT"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_HPCTOOLKIT}" = "0" ]; then

   echo "HPCToolkit will not be built, according to the specified value of BUILD_HPCTOOLKIT"
   echo "BUILD_HPCTOOLKIT: $BUILD_HPCTOOLKIT"
   exit

else
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
   # rocm/7.0.3 AND rocm/7.2.3); taking the first match would key the
   # build + modulefile on the wrong SDK.
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

   if [ -f ${CACHE_FILES}/hpctoolkit-v${HPCTOOLKIT_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HPCToolkit v${HPCTOOLKIT_VERSION}"
      echo "============================"
      echo ""

      # install the cached version. Tarball top-level dir is
      # hpctoolkit-v${HPCTOOLKIT_VERSION}/ -- matches the versioned
      # HPCTOOLKIT_PATH layout used by the from-source branch.
      # hpcviewer is bundled as a SEPARATE tar (different upstream
      # release cadence than hpctoolkit) and is now versioned to
      # hpcviewer-v${HPCVIEWER_VERSION}.tgz so multiple hpcviewer
      # releases can coexist in the cache and on disk (job 8063
      # audit; the prior unversioned hpcviewer.tgz had a 1:1 mapping
      # to whatever spack picked at cache-bake time, which was opaque
      # to the operator). Pre-existing unversioned hpcviewer.tgz
      # files in the cache are now stale and should be re-baked.
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xpzf ${CACHE_FILES}/hpctoolkit-v${HPCTOOLKIT_VERSION}.tgz
      ${SUDO} chown -R root:root ${HPCTOOLKIT_PATH}
      if [ -f ${CACHE_FILES}/hpcviewer-v${HPCVIEWER_VERSION}.tgz ]; then
         ${SUDO} tar -xpzf ${CACHE_FILES}/hpcviewer-v${HPCVIEWER_VERSION}.tgz
         ${SUDO} chown -R root:root ${HPCVIEWER_TOP}
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/hpctoolkit-v${HPCTOOLKIT_VERSION}.tgz
         ${SUDO} rm -f ${CACHE_FILES}/hpcviewer-v${HPCVIEWER_VERSION}.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building HPCToolkit"
      echo "============================"
      echo ""

      # ── MPI module auto-correct on a Cray PE (see tau/hypre/hdf5) ─────
      # hpcprof-mpi is built when meson's dependency('MPI') finds mpicc/
      # mpicxx. The leaf default MPI_MODULE is "openmpi", but a Cray system
      # ships cray-mpich (no openmpi module) -- preflight would SKIP the
      # whole build. If cray-mpich is active and the caller did not override
      # the MPI, switch to cray-mpich. main_setup.sh also threads
      # --mpi-module mpich-wrappers; this makes the leaf correct standalone.
      if [ "${MPI_MODULE}" = "openmpi" ] \
           && { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; }; then
         MPI_MODULE="cray-mpich"
         echo "hpctoolkit: Cray MPICH detected; MPI_MODULE -> cray-mpich"
      fi

      # ── mpich-wrappers resolution (PrgEnv MPI; ships mpicc/mpicxx) ─────
      # cray-mpich drives the build through cc/CC/ftn wrappers and does not
      # put mpicc/mpicxx on PATH, so meson's dependency('MPI') cannot find
      # it. The from-source mpich-wrappers leaf ships mpicc/mpicxx (MPICH-ABI
      # compatible with cray-mpich) -- exactly what hpcprof-mpi needs. When
      # the caller asks for it (main_setup threads --mpi-module mpich-
      # wrappers), resolve the bare name to a concrete, version-matched
      # modulefile token by scanning MODULEPATH. If none is found, fall
      # back to cray-mpich.
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
            echo "hpctoolkit: using mpich-wrappers module '${_mw_tok}' (PrgEnv MPI; ships mpicc/mpicxx)"
         else
            echo "hpctoolkit: WARNING: --mpi-module mpich-wrappers requested but no mpich-wrappers modulefile found on MODULEPATH; falling back to cray-mpich"
            MPI_MODULE="cray-mpich"
         fi
         unset _mw_tok
      fi

      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── Point meson's dependency('MPI') at the PrgEnv MPI wrappers ─────
      # meson's MPI dep honours the MPICC/MPICXX env vars (and otherwise
      # probes mpicc/mpicxx on PATH). The mpich-wrappers module puts
      # mpicc/mpicxx on PATH; export them explicitly so meson uses this
      # exact MPI for hpcprof-mpi rather than any stray system mpicc.
      if command -v mpicxx >/dev/null 2>&1; then
         export MPICXX="$(command -v mpicxx)"
      fi
      if command -v mpicc >/dev/null 2>&1; then
         export MPICC="$(command -v mpicc)"
      fi
      echo "hpctoolkit: MPI wrappers -> MPICC=${MPICC:-unset} MPICXX=${MPICXX:-unset}"

      # ── System build dependencies ─────────────────────────────────────
      # hpctoolkit's meson build wraps ALL deps (boost, liblzma, libunwind,
      # tbb, elfutils, dyninst, xerces-c, yaml-cpp, ...) as subprojects, so
      # it can build them from source when not found on the system. On
      # Debian/Ubuntu we apt-install a few (boost/lzma/gtk) to use faster
      # system copies + pipx for meson. On a Cray RHEL9 host there is no
      # apt-get: system boost/lzma/gtk are already present (gtk only needed
      # by the hpcviewer GUI at runtime) and meson/ninja are provided via
      # pip below, so the apt step is skipped. meson needs >=1.6.0 for this
      # hpctoolkit release.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
      if command -v apt-get >/dev/null 2>&1; then
         ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y pipx libboost-all-dev liblzma-dev libgtk-3-dev
      else
         echo "hpctoolkit: apt-get not present (non-Debian host); relying on system boost/lzma/gtk and pip-installed meson/ninja"
      fi

      # Per-job throwaway build dir for the hpctoolkit clone.
      # Replaces a fixed `cd /tmp; rm -rf /tmp/hpctoolkit` pattern
      # that would race between two concurrent rocm-version jobs on
      # the same compute node. The hpcviewer spack section below
      # creates its own HPCVIEWER_BUILD_DIR (kept separate so the
      # spack clone can be cleaned independently of the hpctoolkit
      # source tree).
      HPCTOOLKIT_BUILD_DIR=$(mktemp -d -t hpctoolkit-build.XXXXXX)
      cd "${HPCTOOLKIT_BUILD_DIR}"

      ${SUDO} mkdir -p ${HPCTOOLKIT_PATH}
      ${SUDO} mkdir -p ${HPCVIEWER_TOP}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${HPCTOOLKIT_PATH}
         ${SUDO} chmod a+w ${HPCVIEWER_TOP}
      fi

      # ------------ Installing HPCToolkit

      # meson + ninja backend. This hpctoolkit release requires
      # meson_version >= 1.6.0 (meson.build). On Debian/Ubuntu pipx is
      # apt-installed above and ninja-build is on the base image; on a Cray
      # RHEL9 host neither pipx nor ninja exist, so fall back to a pip
      # --user install of both. Both land in $HOME/.local/bin (added to PATH).
      if command -v pipx >/dev/null 2>&1; then
         pipx install 'meson>=1.6.0'
      else
         echo "hpctoolkit: pipx absent; pip-installing meson(>=1.6.0)+ninja to ~/.local"
         python3 -m pip install --user --upgrade 'meson>=1.6.0' ninja
      fi
      export PATH=$HOME/.local/bin:$PATH
      git clone -b ${HPCTOOLKIT_VERSION} https://gitlab.com/hpctoolkit/hpctoolkit.git
      cd hpctoolkit
      export CMAKE_PREFIX_PATH=$ROCM_PATH:$CMAKE_PREFIX_PATH

      # ── Pin a consistent plain GNU toolchain for the meson build ──────
      # On a Cray PrgEnv-amd shell, meson auto-detects the C compiler as the
      # Cray craype `cc` wrapper (amdclang) while C++ stays as plain
      # /usr/bin/c++ (g++). That split is fatal at link time: the `cc`
      # wrapper silently injects the Cray HPC libs (-lamdhip64 -lsci_amd
      # -lsci_amd_mpi -lmpi_amd -lmpi_gtl_hsa) into every C object, but the
      # shared libs are linked with plain g++ which has none of the Cray -L
      # search paths, so e.g. the xerces-c subproject fails with
      # "/usr/bin/ld: cannot find -lamdhip64". hpctoolkit is a host profiler:
      # it does NOT need the Cray compiler wrappers -- ROCm is found via
      # CMAKE_PREFIX_PATH=$ROCM_PATH (proper -L$ROCM_PATH/lib) and MPI via the
      # mpich-wrappers MPICC/MPICXX exported above. Forcing CC=gcc/CXX=g++
      # (only when the detected cc is the Cray wrapper) gives one toolchain
      # for every (sub)project and drops the auto-injected, unfindable libs.
      # No-op on a non-Cray host where cc is already gcc.
      if command -v gcc >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 \
         && command -v cc >/dev/null 2>&1 \
         && readlink -f "$(command -v cc)" 2>/dev/null | grep -q "craype"; then
         export CC=gcc CXX=g++
         echo "hpctoolkit: Cray craype cc wrapper detected; pinning CC=gcc CXX=g++ for the meson build (ROCm via CMAKE_PREFIX_PATH, MPI via MPICC/MPICXX)"
      fi

      # Force subproject headers to use -I instead of -isystem so they take
      # priority over the system libunwind-dev 1.3.2 headers at /usr/include/.
      # Debian/Ubuntu ONLY: this is a workaround for the system libunwind-dev
      # headers that ship in the apt base image. On a Cray RHEL9 host there is
      # no system libunwind-dev (libunwind is built as a meson subproject), so
      # the workaround is unnecessary -- and HARMFUL: flipping libelf_dep /
      # libdw_dep from include_type:'system' (-isystem) to 'non-system' (-I)
      # moves the bundled Elfutils include dir (which exports '.' and 'lib/',
      # and elfutils' lib/md5.h declares a *different* md5 API -- struct
      # md5_ctx / md5_init_ctx) ahead of hpctoolkit's own md5 subproject on
      # the quote-include search path, so src/common/lean/crypto-hash.c
      # (#include "md5.h") picks up elfutils' md5.h and fails with
      # "struct md5_context incomplete / md5_init undeclared". Guarding the
      # sed to apt hosts keeps the Ubuntu fix while letting the Cray build use
      # the default -isystem ordering (hpctoolkit's md5.h wins).
      if command -v apt-get >/dev/null 2>&1; then
         sed -i "s/include_type: 'system'/include_type: 'non-system'/g" meson.build
      else
         echo "hpctoolkit: non-Debian host; keeping default include_type (skip libunwind -isystem->-I workaround to avoid elfutils md5.h shadowing)"
      fi

      meson setup -Drocm=enabled -Dopencl=disabled --prefix=${HPCTOOLKIT_PATH} --libdir=${HPCTOOLKIT_PATH}/lib build
      cd build
      meson compile || { echo "ERROR: meson compile failed"; exit 1; }
      meson install

      # chown to root only when we installed with elevation (SUDO non-empty).
      # On a user-owned tree (SUDO="") files are already correctly owned and
      # chown root:root would fail with "Operation not permitted" under set -e.
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${HPCTOOLKIT_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${HPCTOOLKIT_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${HPCTOOLKIT_PATH}
      fi

      cd ../..
      rm -rf hpctoolkit

      # ------------ Installing HPCViewer

      # Spack user-scope isolation: see scorep_setup.sh for the full
      # rationale. Per-job throwaway dirs prevent ~/.spack/{packages,
      # config}.yaml from accumulating state across rocm versions and
      # prevent a stale user-scope install_tree.root from over-riding
      # the per-clone defaults edit below.
      SPACK_USER_CONFIG_PATH=$(mktemp -d -t spack-user-config.XXXXXX)
      SPACK_USER_CACHE_PATH=$(mktemp -d -t spack-user-cache.XXXXXX)
      export SPACK_USER_CONFIG_PATH SPACK_USER_CACHE_PATH

      # Spack clone goes under /tmp (compute-node local disk) so
      # concurrent rocm-version builds don't race on ${PWD}/spack in
      # the shared HPCTrainingDock checkout. EXIT cleanup of this
      # build dir is handled by the combined _hpctoolkit_on_exit
      # trap registered above (job 8063 audit: a second `trap '...'
      # EXIT` here used to silently overwrite the install fail-
      # cleanup trap; that pattern is gone now -- both concerns
      # live in _hpctoolkit_on_exit).
      HPCVIEWER_BUILD_DIR=$(mktemp -d -t hpcviewer-build.XXXXXX)
      cd "${HPCVIEWER_BUILD_DIR}"

      git clone --depth 1 https://github.com/spack/spack.git

      # load spack environment
      source spack/share/spack/setup-env.sh

      # find already installed libs for spack
      spack external find --all

      # change spack install dir for hpcviewer
      ${SUDO} sed -i 's|$spack/opt/spack|'"${HPCVIEWER_TOP}"'|g' spack/etc/spack/defaults/base/config.yaml

      # open permissions to use spack to install hpcviewer
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+rwX ${HPCVIEWER_TOP}
      fi

      # install hpcviewer with spack -- pinned to ${HPCVIEWER_VERSION}
      # so the install dir name matches the versioned HPCVIEWER_TOP we
      # advertised above and, more importantly, so the cache tar name
      # (hpcviewer-v${HPCVIEWER_VERSION}.tgz) and the on-disk version
      # always agree across runs. Without the @version pin spack would
      # silently pick "latest" and a cache baked today would mismatch
      # an install rebuilt next quarter.
      spack install hpcviewer@${HPCVIEWER_VERSION}

      # get hpcviewer install dir created by spack -- this is the deep
      # spack-hash subdir (e.g. ${HPCVIEWER_TOP}/linux-zen4/hpcviewer-
      # ${HPCVIEWER_VERSION}-<spackhash>). Reassigning HPCVIEWER_PATH
      # here is INTENTIONAL: only the modulefile's PATH prepend below
      # needs the spack-hash bin/ dir. Every "operate on the install"
      # action (chown, chmod, fail-cleanup, --replace, existence
      # guard) uses HPCVIEWER_TOP so it walks the whole versioned
      # tree, not just the spack-hash subdir (job 8063 audit: prior
      # code used the post-reassignment HPCVIEWER_PATH for the
      # post-install chmod, leaving HPCVIEWER_TOP at 777 root:root).
      HPCVIEWER_PATH=$(spack location -i hpcviewer)

      # HPCVIEWER_BUILD_DIR (under /tmp, contains the spack clone) +
      # the spack user-scope dirs are removed by the combined
      # _hpctoolkit_on_exit trap.

      # Lock down ALL of HPCVIEWER_TOP (top + spack-hash subdir +
      # bin views + .spack-db) -- not just the spack-hash dir as
      # before. Recursive chown + recursive go-w is the only way to
      # undo the `chmod -R a+rwX HPCVIEWER_TOP` we did above to let
      # spack write under it as a non-root user.
      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${HPCVIEWER_TOP} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${HPCVIEWER_TOP} -type d -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R go-w ${HPCVIEWER_TOP}
      fi

      module unload ${ROCM_MODULE_NAME} || true
      module unload ${MPI_MODULE} || true

   fi

   # Create a module file for hpctoolkit
   #
   # Module-tree sudo + flavor: pick Lua (.lua) for Lmod, classic Tcl
   # (no ext) otherwise, and probe the module tree for user-writability so
   # a user-owned modulepath (this Cray) does not trigger a sudo password
   # prompt. Mirrors the tau/hypre modulefile probe.
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
      _mtest=$(mktemp --tmpdir="${_mprobe}" .hpctk-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         MOD_SUDO=""
         echo "hpctoolkit: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
      else
         MOD_SUDO="sudo"
         echo "hpctoolkit: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
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
   # module so hpcprof-mpi finds the same PrgEnv MPI it was linked against.
   HPCTOOLKIT_MODULEFILE="${MODULE_PATH}/${HPCTOOLKIT_VERSION}${MODEXT}"
   if [ "${MODFLAVOR}" = "lua" ]; then
      cat <<-EOF | ${MOD_SUDO} tee ${HPCTOOLKIT_MODULEFILE}
	whatis("HPCToolkit - integrated suite of tools for measurement and analysis of program performance")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${HPCTOOLKIT_PATH}"

	prereq("${ROCM_MODULE_NAME}")
	load("${MPI_MODULE}")
	setenv("HPCTOOLKIT_PATH", base)
	prepend_path("PATH",pathJoin(base, "bin"))
	prepend_path("PATH","${HPCVIEWER_PATH}/bin")
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH","/usr/lib")
EOF
   else
      cat <<-EOF | ${MOD_SUDO} tee ${HPCTOOLKIT_MODULEFILE}
	#%Module1.0
	module-whatis "HPCToolkit - integrated suite of tools for measurement and analysis of program performance"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${HPCTOOLKIT_PATH}"

	prereq ${ROCM_MODULE_NAME}
	if { ![ is-loaded ${MPI_MODULE} ] } { module load ${MPI_MODULE} }
	setenv HPCTOOLKIT_PATH "\$base"
	prepend-path PATH "\$base/bin"
	prepend-path PATH "${HPCVIEWER_PATH}/bin"
	prepend-path LD_LIBRARY_PATH "\$base/lib"
	prepend-path LD_LIBRARY_PATH "/usr/lib"
EOF
   fi

fi

