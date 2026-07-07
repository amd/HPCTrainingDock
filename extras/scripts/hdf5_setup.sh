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
MODULE_PATH=/etc/lmod/modules/ROCmPlus/hdf5
BUILD_HDF5=0
ROCM_VERSION=6.2.0
ROCM_MODULE="rocm"
C_COMPILER=`which gcc`
C_COMPILER_INPUT=""
CXX_COMPILER=`which g++`
CXX_COMPILER_INPUT=""
F_COMPILER=`which gfortran`
F_COMPILER_INPUT=""
ENABLE_PARALLEL_INPUT=""
HDF5_VERSION=2.1.1
MPI_MODULE="openmpi"
HDF5_PATH=/opt/rocmplus-${ROCM_VERSION}/hdf5-v${HDF5_VERSION}
HDF5_PATH_INPUT=""
# --install-path: parent dir; the script appends hdf5-v${HDF5_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know
# the version. --install-path-no-version (full leaf dir) wins over --install-path
# when both are set, for callers that need exact control of the final install directory.
ROCMPLUS_PATH_INPUT=""
# --replace 1: rm -rf prior install dir + ${HDF5_VERSION}.lua before building.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocm-module [ ROCM_MODULE ] default $ROCM_MODULE"
   echo "  --hdf5-version [ HDF5_VERSION ] default $HDF5_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --enable-parallel [ ENABLE_PARALLEL ], set to ON or OFF, ON by default if MPI is installed"
   echo "  --install-path-no-version [ HDF5_PATH ] default $HDF5_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), HDF5_PATH = ROCMPLUS_PATH/hdf5-v\${HDF5_VERSION}"
   echo "  --c-compiler [ C_COMPILER ] default ${C_COMPILER}"
   echo "  --cxx-compiler [ CXX_COMPILER ] default ${CXX_COMPILER}"
   echo "  --f-compiler [ F_COMPILER ] default ${F_COMPILER}"
   echo "  --build-hdf5 [ BUILD_HDF5 ], set to 1 to build HDF5, default is 0"
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
      "--build-hdf5")
          shift
          BUILD_HDF5=${1}
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
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path-no-version")
          shift
          HDF5_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--enable-parallel")
          shift
          ENABLE_PARALLEL_INPUT=${1}
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
      "--hdf5-version")
          shift
          HDF5_VERSION=${1}
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

if [ "${HDF5_PATH_INPUT}" != "" ]; then
   HDF5_PATH=${HDF5_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   # Orchestrator-friendly: caller passes the rocmplus parent dir;
   # this script appends hdf5-v${HDF5_VERSION} from its own default.
   # Lets main_setup.sh stay version-agnostic for hdf5.
   HDF5_PATH=${ROCMPLUS_PATH_INPUT}/hdf5-v${HDF5_VERSION}
else
   # override path in case HDF5_VERSION has been supplied as input
   HDF5_PATH=/opt/rocmplus-${ROCM_VERSION}/hdf5-v${HDF5_VERSION}
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# ── BUILD_HDF5=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_HDF5}" = "0" ]; then
   echo "[hdf5 BUILD_HDF5=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── Early sudo decision (see mpi4py_setup.sh) ───────────────────────
# Determine whether privilege escalation is needed BEFORE the --replace
# block and EXIT trap (both rm install/module paths via ${SUDO}). When the
# operator owns a writable install tree (e.g. a user-writable
# /shareddata/opt) no sudo is needed -- and forcing it would hit a password
# prompt that fails on a node where the user has no sudo. Probe the nearest
# EXISTING ancestor of HDF5_PATH (the leaf dir does not exist yet). The
# build branch re-affirms this below.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _probe="${HDF5_PATH}"
   while [ ! -e "${_probe}" ]; do _probe="$(dirname "${_probe}")"; done
   # Real write test (mktemp), NOT `[ -w ]`: on NFS `-w` is a LYING probe --
   # it reported "writable" on the compute node for a root:root 0755 tree
   # where actual writes / rm fail (the exact failure mode netcdf_setup.sh
   # warns about). Mirrors the cupy/rocshmem mktemp probe.
   _wtest=$(mktemp --tmpdir="${_probe}" .hdf5-write-probe.XXXXXX 2>/dev/null || true)
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
   echo "[hdf5 --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HDF5_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${HDF5_VERSION}{,.lua}"
   ${SUDO} rm -rf "${HDF5_PATH}"
   # Remove both flavors (Lmod .lua and Tcl no-extension).
   ${SUDO} rm -f  "${MODULE_PATH}/${HDF5_VERSION}.lua" "${MODULE_PATH}/${HDF5_VERSION}"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${HDF5_PATH}" ]; then
   echo ""
   echo "[hdf5 existence-check] ${HDF5_PATH} already installed; skipping."
   echo "                       pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

_hdf5_on_exit() {
   local rc=$?
   # ${SUDO} verbatim (NOT ${SUDO:-sudo}): the early-probe may set SUDO=""
   # for an operator-writable tree, and cleanup must then run WITHOUT sudo.
   # Build-dir cleanup is folded in here (HDF5_BUILD_DIR set under the
   # source-build branch) so a single EXIT trap does both jobs -- the prior
   # separate `trap '... rm HDF5_BUILD_DIR' EXIT` OVERWROTE this handler,
   # disabling fail-cleanup during source builds.
   [ -n "${HDF5_BUILD_DIR:-}" ] && ${SUDO} rm -rf "${HDF5_BUILD_DIR}"
   # attempted-but-failed marker (inventory 'F' glyph): persistent sibling
   # of the install dir that survives the rm -rf below; cleared on success.
   _fail_marker="$(dirname "${HDF5_PATH}")/hdf5.FAILED"
   if [ ${rc} -ne 0 ]; then
      ${SUDO} mkdir -p "$(dirname "${HDF5_PATH}")" 2>/dev/null || true
      ${SUDO} tee "${_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: hdf5
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    hdf5_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_hdf5_*.txt).
MARKER_EOF
   else
      ${SUDO} rm -f "${_fail_marker}"
   fi
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hdf5 fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${HDF5_PATH}"
      ${SUDO} rm -f  "${MODULE_PATH}/${HDF5_VERSION}.lua" "${MODULE_PATH}/${HDF5_VERSION}"
   elif [ ${rc} -ne 0 ]; then
      echo "[hdf5 fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _hdf5_on_exit EXIT

if [ "${BUILD_HDF5}" = "0" ]; then

   echo "HDF5 will not be built, according to the specified value of BUILD_HDF5"
   echo "BUILD_HDF5: $BUILD_HDF5"
   echo "Make sure to set '--build-hdf5 1' when running this install script"
   exit

else

   echo ""
   echo "==============================="
   echo " Installing HDF5"
   echo " Install directory: $HDF5_PATH"
   echo " Module directory: $MODULE_PATH"
   echo " HDF5 Version: $HDF5_VERSION"
   echo " ROCm Version: $ROCM_VERSION"
   echo "==============================="
   echo ""

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

   if [ -f ${CACHE_FILES}/hdf5-v${HDF5_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HDF5"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # hdf5-v${HDF5_VERSION}.tgz and contain a top-level directory
      # hdf5-v${HDF5_VERSION}/ so it lands directly at ${HDF5_PATH}
      # when extracted under /opt/rocmplus-X. (Previous code cd'd into
      # /opt and chown'd /opt/hdf5-v..., which left the install in the
      # wrong place; corrected here as part of the multi-version pass.)
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/hdf5-v${HDF5_VERSION}.tgz
      chown -R root:root ${HDF5_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/hdf5-v${HDF5_VERSION}.tgz
      fi

   else
      echo ""
      echo "==============================="
      echo " Installing HDF5 from source"
      echo "==============================="
      echo ""

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh

      # SUDO was already decided by the early-probe block above (writable
      # ancestor -> ""). Honor it instead of re-probing the not-yet-created
      # leaf dir (which always forced sudo).
      ${SUDO} mkdir -p ${HDF5_PATH}
      ${SUDO} mkdir -p ${HDF5_PATH}/zlib
      if [ -n "${SUDO}" ] && [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${HDF5_PATH}
      fi

      # Build under /tmp (compute-node local disk) so the hdf5
      # source clone, the zlib build, and the main cmake build
      # don't all round-trip through NFS for every .o, .a, .so.
      # Only `make install` writes hit NFS via the absolute
      # CMAKE_INSTALL_PREFIX=${HDF5_PATH}. EXIT trap guarantees
      # cleanup even on build failure (we have set -e). Audit basis:
      # 7950 hdf5 took ~11m50s with build under
      # /home/admin/repos/HPCTrainingDock/hdf5/...
      # NOTE: build-dir cleanup is consolidated into _hdf5_on_exit (set as
      # the EXIT trap above) so it also runs fail-cleanup; do NOT install a
      # second EXIT trap here (that would overwrite _hdf5_on_exit).
      HDF5_BUILD_DIR=$(mktemp -d -t hdf5-build.XXXXXX)
      cd "${HDF5_BUILD_DIR}"

      # --depth=1 to skip ~10 years of history we don't need; the
      # branch tag pins us to the exact release.
      #
      # Tag-name probe: the HDF Group used `hdf5_X.Y.Z` for the 1.14
      # series (e.g. hdf5_1.14.6) but for HDF5 2.1.1 ship the bare
      # numeric tag `2.1.1`. Probe both forms and use whichever
      # exists; fail hard if neither does so we don't silently land
      # on the default branch (which would float past the requested
      # release on every build).
      HDF5_TAG=""
      for _cand in "hdf5_${HDF5_VERSION}" "${HDF5_VERSION}"; do
         if git ls-remote --exit-code --tags https://github.com/HDFGroup/hdf5.git \
               "refs/tags/${_cand}" >/dev/null 2>&1; then
            HDF5_TAG="${_cand}"
            break
         fi
      done
      unset _cand
      if [ -z "${HDF5_TAG}" ]; then
         echo "ERROR: no git tag matching HDF5 ${HDF5_VERSION} (tried 'hdf5_${HDF5_VERSION}' and '${HDF5_VERSION}')." >&2
         exit 1
      fi
      echo "HDF5: using git tag '${HDF5_TAG}'"
      git clone --depth=1 --branch "${HDF5_TAG}" https://github.com/HDFGroup/hdf5.git
      cd hdf5

      # install dependencies

      # get ZLIB
      # -q to drop wget dot-progress noise from the per-package log,
      # matching the precedent in comm/scripts/openmpi_setup.sh and the
      # S6.E fix in tools/scripts/scorep_setup.sh.
      wget -q https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
      tar zxf zlib-1.3.1.tar.gz
      cd zlib-1.3.1
      ./configure --prefix=${HDF5_PATH}/zlib
      # zlib's autotools install target depends on `all`, so a
      # parallel install is equivalent to `make -j && make install`
      # here. Saves ~30s on a 96-core node vs serial.
      make -j $(nproc) install

      # get LIBAEC -- support for szip library is currently broken: https://github.com/HDFGroup/hdf5/issues/4614
      #wget https://github.com/MathisRosenhauer/libaec/releases/download/v1.1.3/libaec-1.1.3.tar.gz
      #tar zxf libaec-1.1.3.tar.gz
      #${SUDO} mkdir -p ${HDF5_PATH}/libaec
      #cd libaec-1.1.3
      #${SUDO} ./configure --prefix=${HDF5_PATH}/libaec
      #${SUDO} make install

      # ── MPI module auto-correct on a Cray PE ─────────────────────────
      # The leaf default MPI_MODULE is "openmpi", but a Cray system ships
      # cray-mpich (no openmpi module exists) -- preflight would fail. If
      # cray-mpich is active and the caller did not override the MPI, switch
      # to cray-mpich so the prereq load and the parallel build use the
      # PrgEnv's own MPI. (main_setup.sh also threads --mpi-module cray-mpich
      # when MPICH_DIR is set; this makes the leaf correct standalone too.)
      if [ "${MPI_MODULE}" = "openmpi" ] \
           && { [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; }; then
         MPI_MODULE="cray-mpich"
         echo "HDF5: Cray MPICH detected; MPI_MODULE -> cray-mpich"
      fi

      # ── mpich-wrappers resolution (new-flang mpi.mod on a Cray) ──────
      # cray-mpich's amd/rocm-compiler mpi.mod is CLASSIC-Flang V34, which
      # the new LLVM Flang (amdflang / ftn on ROCm 7.x) cannot read -- a
      # parallel-Fortran `use mpi` build with cc/CC/ftn fails. The
      # mpich-wrappers leaf builds a standalone MPICH with FC=amdflang
      # (NEW-flang mpi.mod, MPICH-ABI compatible with cray-mpich). When the
      # caller asks for it (main_setup threads --mpi-module mpich-wrappers
      # once that leaf is built), resolve the bare name to the concrete,
      # version-matched modulefile token by scanning MODULEPATH
      # (mpich-wrappers/${ROCM_VERSION} first, then a bare mpich-wrappers).
      # If none is found, fall back to cray-mpich so the build still works
      # (C/C++ parallel; the Fortran-MPI probe below downgrades as needed).
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
            echo "HDF5: using mpich-wrappers module '${_mw_tok}' (new-flang mpi.mod)"
         else
            echo "HDF5: WARNING: --mpi-module mpich-wrappers requested but no mpich-wrappers modulefile found on MODULEPATH; falling back to cray-mpich"
            MPI_MODULE="cray-mpich"
         fi
         unset _mw_tok
      fi

      # default build is serial hdf5
      ENABLE_PARALLEL="OFF"
      REQUIRED_MODULES=( "${ROCM_MODULE_NAME}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── Compiler / MPI wrapper selection ─────────────────────────────
      # The Fortran story is the whole reason a local HDF5 may be needed:
      # an hdf5.mod is only readable by the SAME Fortran compiler + .mod
      # format that produced it. On ROCm 7.x the AMD Fortran compiler
      # (amdflang / Cray `ftn` under PrgEnv-amd) is the NEW LLVM Flang
      # (emits `!mod$ v1` .mod), whereas cray-hdf5's `amd/<v>` variant ships
      # CLASSIC-Flang `V34` .mod files that new flang rejects ("File has
      # invalid checksum"). So we must build with a Fortran compiler whose
      # .mod format matches what users actually compile with, AND link the
      # SAME MPI as the rest of the PrgEnv stack.
      #
      # Preference order:
      #   1. mpich-wrappers mpicc/mpicxx/mpifort -- standalone MPICH built
      #      with FC=amdflang (new-flang mpi.mod, MPICH-ABI compatible with
      #      cray-mpich). This is the ONLY parallel-Fortran path that works
      #      on a Cray with the new LLVM Flang, because cray-mpich's own
      #      amd/rocm-compiler mpi.mod is classic-Flang V34 (unreadable by
      #      new flang). The mpich-wrappers module front-loads its bin so
      #      mpicc/mpifort resolve to it; mpifort drives amdflang.
      #   2. Cray PE wrappers cc/CC/ftn  -- when cray-mpich is active and no
      #      mpich-wrappers exist. C/C++ parallel works; Fortran `use mpi`
      #      works only when ftn is classic Flang or crayftn (PrgEnv-cray).
      #   3. MPI wrappers mpicc/mpicxx/mpifort -- OpenMPI / MVAPICH path.
      #      (rocmplus OpenMPI is configured against amdflang, which on
      #      ROCm 7.x is the new flang too, so .mod is consistent.)
      #   4. serial (no MPI wrapper found).
      if [ "${MPI_MODULE#mpich-wrappers}" != "${MPI_MODULE}" ] \
           && command -v mpicc   >/dev/null 2>&1 \
           && command -v mpifort >/dev/null 2>&1; then
         # mpich-wrappers: MPICH built with amdflang -> new-flang mpi.mod
         # (preflight loaded the module above, front-loading its bin/lib/
         # include). C/C++ use the wrapper's gcc/g++ backends; Fortran uses
         # amdflang, matching what users compile with on ROCm 7.x.
         ENABLE_PARALLEL="ON"
         C_COMPILER=$(command -v mpicc)
         CXX_COMPILER=$(command -v mpicxx)
         F_COMPILER=$(command -v mpifort)
         echo "HDF5: mpich-wrappers MPI -> mpicc/mpicxx/mpifort (new-flang mpi.mod)."
         echo "HDF5: Fortran wrapper mpifort -> $(${F_COMPILER} --version 2>/dev/null | head -1)"
      elif { [ "${MPI_MODULE}" = "cray-mpich" ] || [ -n "${CRAY_MPICH_VERSION:-}" ] || [ -n "${MPICH_DIR:-}" ]; } \
           && command -v ftn >/dev/null 2>&1 \
           && command -v cc  >/dev/null 2>&1 \
           && command -v CC  >/dev/null 2>&1; then
         # Cray PE: use the craype wrappers (cray-mpich + PrgEnv compilers).
         ENABLE_PARALLEL="ON"
         C_COMPILER=$(command -v cc)
         CXX_COMPILER=$(command -v CC)
         F_COMPILER=$(command -v ftn)
         echo "HDF5: Cray PE detected -> cc/CC/ftn wrappers (cray-mpich)."
         echo "HDF5: Fortran wrapper ftn -> $(${F_COMPILER} --version 2>/dev/null | head -1)"
      elif [[ `which mpicc | wc -l` -eq 1 ]]; then
	 # if mpicc is found in the path, build hdf5 parallel
         ENABLE_PARALLEL="ON"
	 C_COMPILER=`which mpicc`
	 CXX_COMPILER=`which mpicxx`
	 F_COMPILER=`which mpifort`

	 # OpenMPI's mpifort/mpicxx have the Fortran/C++ compiler name
	 # baked in at OpenMPI configure-time. On the rocmplus-6.x trees
	 # the openmpi/5.0.10 install was configured against amdflang,
	 # but ROCm 6.3.x SDKs only ship amdflang under ${ROCM_PATH}/llvm/bin/,
	 # which is NOT on PATH after `module load rocm/6.3.x` (the module
	 # prepends ${ROCM_PATH}/bin only). ROCm 6.4.x DOES ship amdflang
	 # under ${ROCM_PATH}/bin/, so it works there.
	 #
	 # Result on 6.3.x: mpifort -> "Open MPI wrapper compiler was
	 # unable to find the specified compiler amdflang in your PATH"
	 # and the HDF5 cmake Fortran-ABI probe fails (sweep 10220-10224,
	 # 2026-05-20). Fix: when amdflang is missing from PATH but the
	 # rocm SDK ships one under llvm/bin, extend PATH so mpifort
	 # finds the SDK's own amdflang. This is the SAME compiler the
	 # openmpi/mpifort wrapper was originally configured against, so
	 # the mpi.mod is in the correct Flang module format and no
	 # OMPI_FC override is needed (which would have introduced a
	 # different incompatibility -- gfortran can't read amdflang-
	 # classic's V34 .mod files; verified slurm 10237, 2026-05-20).
	 #
	 # No-op on ROCm 7.x (amdflang already on PATH) and on 6.4.x
	 # (same).
	 if ! command -v amdflang >/dev/null 2>&1 \
	      && [ -n "${ROCM_PATH:-}" ] \
	      && [ -x "${ROCM_PATH}/llvm/bin/amdflang" ]; then
	    export PATH="${ROCM_PATH}/llvm/bin:${PATH}"
	    echo "HDF5: amdflang not on PATH; prepending ${ROCM_PATH}/llvm/bin (mpifort wrapper depends on it)"
	 fi
      fi

      # override flags with user defined values if present
      if [ "${ENABLE_PARALLEL_INPUT}" != "" ]; then
         ENABLE_PARALLEL=${ENABLE_PARALLEL_INPUT}
      fi
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
      # On a Cray, F_COMPILER resolves to the craype `ftn` wrapper (see the
      # compiler-selection block above). Which Fortran compiler that wrapper
      # actually drives is governed by AMD_COMPILER_TYPE: the amd-new
      # modulefile (loaded by PrgEnv-amd-new/8.7.0-<ver>) sets
      # AMD_COMPILER_TYPE=DEFAULT so ftn/cc/CC drive the NEW LLVM
      # amdflang/amdclang; when it is UNSET the wrappers fall back to
      # flang-CLASSIC (and emit an 'Unrecognized' warning).
      #
      # The rocmplus install path loads only `rocm/<v>` (see
      # bare_system/run_rocmplus_install.sbatch) -- NOT PrgEnv-amd-new --
      # so AMD_COMPILER_TYPE is not set and ftn silently drops to
      # flang-classic. classic links its runtime dynamically (NEEDED
      # libflang.so), whereas flang-new links it statically; the resulting
      # hdf5.mod is also classic 'V34' which new-flang consumers
      # (netcdf-fortran) cannot read. Pin it here so hdf5 builds with
      # flang-new, consistent with PrgEnv-amd-new and with the
      # netcdf_setup.sh companion pin. Respect an operator-set value.
      # No-op off a Cray PE (only the craype AMD wrappers read it).
      if { [ -n "${CRAYPE_VERSION:-}" ] || [ -n "${CRAY_MPICH_VERSION:-}" ] \
             || [ -n "${MPICH_DIR:-}" ] || [ "${MPI_MODULE}" = "cray-mpich" ] \
             || [ "${MPI_MODULE#mpich-wrappers}" != "${MPI_MODULE}" ]; } \
           && command -v ftn >/dev/null 2>&1; then
         export AMD_COMPILER_TYPE="${AMD_COMPILER_TYPE:-DEFAULT}"
         echo "HDF5: Cray PE detected; AMD_COMPILER_TYPE=${AMD_COMPILER_TYPE} (ftn/cc/CC -> flang-new, matches PrgEnv-amd-new)"
      fi

      cd ..
      mkdir build && cd build

      # HDF5 2.x: per HDF5 issue #6019, the rename story we had
      # before was WRONG. HDF5_ENABLE_PARALLEL is STILL the
      # build-time KNOB in 2.x (same as 1.x). HDF5_PROVIDES_PARALLEL
      # is a read-only STATE variable that the HDF5 build SETS for
      # downstream consumers to query -- it does NOT enable parallel
      # when passed in as a -D flag. The 2.x docs (INSTALL_CMake.md)
      # still say `HDF5_ENABLE_PARALLEL` is the option.
      #
      # The 2026-05-20 sweep (slurm 10200) silently produced a
      # SERIAL hdf5/2.1.1 because we passed
      # -DHDF5_PROVIDES_PARALLEL:BOOL=ON (the state var, ignored),
      # and the resulting H5pubconf.h has /* #undef H5_HAVE_PARALLEL */
      # -- meaning H5Pset_dxpl_mpio / H5Pset_fapl_mpio /
      # H5Pset_coll_metadata_write / H5Pset_all_coll_metadata_ops
      # are not declared, downstream parallel-IO consumers fail to
      # compile, and h5perf_serial gets installed instead of h5pcc.
      # See verification under /shared/apps/ubuntu/opt/rocmplus-7.2.3/
      # hdf5-v2.1.1/HDF_Group/HDF5/2.1.1/include/H5pubconf.h.
      #
      # Fix: always pass -DHDF5_ENABLE_PARALLEL:BOOL=ON for both 1.x
      # and 2.x. Also pass HDF5_PROVIDES_PARALLEL defensively for
      # 2.x, in case a future minor release actually does honor it
      # as a build knob (cheap, harmless overlap).
      HDF5_PARALLEL_VAR="HDF5_ENABLE_PARALLEL"
      HDF5_IS_2X=0
      HDF5_PARALLEL_EXTRA_ARGS=()
      if [ "$(printf '%s\n%s\n' "2.0.0" "${HDF5_VERSION}" | sort -V | head -n1)" = "2.0.0" ]; then
         HDF5_IS_2X=1
         # Belt-and-suspenders: also set the state var explicitly
         # so any downstream find_package(HDF5) probe that looks at
         # HDF5_PROVIDES_PARALLEL gets the right answer.
         HDF5_PARALLEL_EXTRA_ARGS+=( "-DHDF5_PROVIDES_PARALLEL:BOOL=${ENABLE_PARALLEL}" )
      fi
      echo "HDF5: parallel CMake var = ${HDF5_PARALLEL_VAR} (HDF5_VERSION=${HDF5_VERSION}, HDF5_IS_2X=${HDF5_IS_2X})"

      # ZLIB enable: HDF5 2.x no longer honors ZLIB_ROOT (CMake
      # "Manually-specified variables were not used" warning, audited
      # in slurm 9711). The 2.x knobs (per the AutotoolsToCMakeOptions
      # migration guide for HDF5 2.0.0 and issue HDFGroup/hdf5#5155):
      #   HDF5_ENABLE_ZLIB_SUPPORT=ON     -- enable zlib filter
      #   ZLIB_USE_EXTERNAL=OFF           -- "OFF" tells HDF5 to use an
      #                                      installed/external zlib
      #                                      rather than build one
      #                                      in-tree
      #   HDF5_ALLOW_EXTERNAL_SUPPORT=NO  -- don't FetchContent zlib
      #   H5_ZLIB_INCLUDE_DIR / H5_ZLIB_LIBRARY -- point at the zlib
      #                                      we just built under
      #                                      ${HDF5_PATH}/zlib/
      # Without H5_HAVE_ZLIB_H landing in H5public.h, netcdf-c 4.10.0
      # configure aborts with "HDF5 was built without zlib." For HDF5
      # 1.x we keep ZLIB_ROOT (which 1.x's FindZLIB.cmake honors).
      HDF5_ZLIB_CMAKE_ARGS=()
      if [ "${HDF5_IS_2X}" = "1" ]; then
         # Prefer the shared library (.so.1.3.1 from our zlib build).
         _h5_zlib_so="$(ls "${HDF5_PATH}/zlib/lib/"libz.so.* 2>/dev/null | head -n1)"
         if [ -z "${_h5_zlib_so}" ] || [ ! -f "${_h5_zlib_so}" ]; then
            _h5_zlib_so="${HDF5_PATH}/zlib/lib/libz.a"
         fi
         HDF5_ZLIB_CMAKE_ARGS=(
            -DHDF5_ENABLE_ZLIB_SUPPORT:BOOL=ON
            -DZLIB_USE_EXTERNAL:BOOL=OFF
            -DHDF5_ALLOW_EXTERNAL_SUPPORT:STRING=NO
            -DH5_ZLIB_INCLUDE_DIR:PATH="${HDF5_PATH}/zlib/include"
            -DH5_ZLIB_LIBRARY:FILEPATH="${_h5_zlib_so}"
            -DZLIB_INCLUDE_DIR:PATH="${HDF5_PATH}/zlib/include"
            -DZLIB_LIBRARY:FILEPATH="${_h5_zlib_so}"
         )
         echo "HDF5: zlib hint = ${_h5_zlib_so}"
         unset _h5_zlib_so
      else
         HDF5_ZLIB_CMAKE_ARGS=( -DZLIB_ROOT="${HDF5_PATH}/zlib" )
      fi

      # -fPIC for the Fortran compile + CMAKE_POSITION_INDEPENDENT_CODE for
      # HDF5's own libs: required because Ubuntu 22.04 ships a PIE-default
      # toolchain (gcc/g++ links executables -fPIE), and on rocm 6.4.x
      # mpifort resolves to amdflang (classic Flang 99.99.1) which does
      # NOT default to PIC. CMake's internal FortranCInterface check
      # compiles VerifyFortran.f -> libVerifyFortran.a (no -fPIC), then
      # tries to link it into a PIE executable VerifyFortranC, which
      # fails with `relocation R_X86_64_32 against .rodata can not be
      # used when making a PIE object; recompile with -fPIE` (slurm 8388
      # / 8391, 2026-05-06). Setting CMAKE_Fortran_FLAGS=-fPIC ensures the
      # FortranCInterface test compile gets PIC; CMAKE_POSITION_INDEPENDENT_CODE
      # ensures HDF5's own Fortran static libs do too.
      # No-op cost on rocm 7.x (amdflang-new defaults to PIC) and on
      # gfortran (also no-op since only used for static libs here).
      cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE:STRING=Release \
  			        -DHDF5_BUILD_TOOLS:BOOL=ON -DCMAKE_INSTALL_PREFIX=${HDF5_PATH} \
                                "${HDF5_ZLIB_CMAKE_ARGS[@]}" \
				-DHDF5_ENABLE_SZIP_SUPPORT:BOOL=OFF \
                                -DCMAKE_CXX_COMPILER=${CXX_COMPILER} \
                                -DCMAKE_C_COMPILER=${C_COMPILER} \
				-DCMAKE_Fortran_COMPILER=${F_COMPILER} \
				-DCMAKE_Fortran_FLAGS="-fPIC" \
				-DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON \
				-DBUILD_TESTING:BOOL=OFF \
				-D${HDF5_PARALLEL_VAR}:BOOL=${ENABLE_PARALLEL} \
				"${HDF5_PARALLEL_EXTRA_ARGS[@]}" \
				-DHDF5_BUILD_FORTRAN:BOOL=ON ..


      # --parallel $(nproc): cmake --build with the "Unix Makefiles"
      # generator does NOT pass -j to make by default, so the build
      # was running serially despite a 96-core node. Audit basis:
      # 7950 hdf5 cmake build dominated the 11m50s total.
      cmake --build . --config Release --parallel $(nproc)

      cpack -C Release CPackConfig.cmake

      ./HDF5-${HDF5_VERSION}-Linux.sh --prefix=${HDF5_PATH} --skip-license

      # HDF5_BUILD_DIR (under /tmp) is removed by the EXIT trap
      # above; no need to rm the source clone explicitly.
      cd ../..

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${HDF5_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${HDF5_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} chmod go-w ${HDF5_PATH}
      fi

   fi

   # Create a module file for hdf5
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
      # Real write test (mktemp), NOT `[ -w ]` -- NFS -w lies (see above).
      _mtest=$(mktemp --tmpdir="${_mprobe}" .hdf5-mod-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
         rm -f "${_mtest}"
         PKG_SUDO_MOD=""
      else
         PKG_SUDO_MOD="sudo"
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
   # Lmod consumes <name>.lua; classic Tcl `environment-modules` consumes an
   # extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
   # when Lmod is absent (this site runs Tcl Environment Modules 3.2.11).
   if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
      _MODFILE="${MODULE_PATH}/${HDF5_VERSION}.lua"
      _MODFLAVOR="lua"
   else
      _MODFILE="${MODULE_PATH}/${HDF5_VERSION}"
      _MODFLAVOR="tcl"
   fi

   # For a parallel build, the HDF5 libs link a specific MPI; load that
   # MPI module so a consumer automatically pulls in the matching MPI
   # (instead of merely erroring when it is absent). Only emitted when
   # parallel and an MPI module name is known.
   _EMIT_MPI_LOAD=0
   if [ "${ENABLE_PARALLEL}" = "ON" ] && [ -n "${MPI_MODULE}" ]; then
      _EMIT_MPI_LOAD=1
   fi

   _HDF5_MOD_BASE="${HDF5_PATH}/HDF_Group/HDF5/${HDF5_VERSION}"

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
         ROCM_PREREQ_TCL="rocm-new/${_RPV} rocm/${_RPV}"
         ROCM_PREREQ_LUA="prereq_any(\"rocm-new/${_RPV}\", \"rocm/${_RPV}\")"
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
	whatis("HDF5 Data Model")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	${ROCM_PREREQ_LUA}
	local base = "${_HDF5_MOD_BASE}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	setenv("HDF5_PATH", base)
	setenv("HDF5_ROOT", base)
	setenv("HDF5_C_COMPILER", "${C_COMPILER}")
	setenv("HDF5_F_COMPILER", "${F_COMPILER}")
	setenv("HDF5_CXX_COMPILER", "${CXX_COMPILER}")
	setenv("HDF5_ENABLE_PARALLEL", "${ENABLE_PARALLEL}")
	setenv("HDF5_MPI_MODULE", "${MPI_MODULE}")
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("PATH", base)
EOF
      if [ "${_EMIT_MPI_LOAD}" = "1" ]; then
         echo "depends_on(\"${MPI_MODULE}\")" | ${PKG_SUDO_MOD} tee -a "${_MODFILE}" >/dev/null
      fi
   else
      cat <<-EOF | ${PKG_SUDO_MOD} tee ${_MODFILE}
	#%Module1.0
	module-whatis "HDF5 Data Model"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_PREREQ_TCL}
	set base "${_HDF5_MOD_BASE}"
	prepend-path LD_LIBRARY_PATH \$base/lib
	prepend-path C_INCLUDE_PATH \$base/include
	prepend-path CPLUS_INCLUDE_PATH \$base/include
	setenv HDF5_PATH \$base
	setenv HDF5_ROOT \$base
	setenv HDF5_C_COMPILER "${C_COMPILER}"
	setenv HDF5_F_COMPILER "${F_COMPILER}"
	setenv HDF5_CXX_COMPILER "${CXX_COMPILER}"
	setenv HDF5_ENABLE_PARALLEL "${ENABLE_PARALLEL}"
	setenv HDF5_MPI_MODULE "${MPI_MODULE}"
	prepend-path PATH \$base/bin
	prepend-path PATH \$base
EOF
      if [ "${_EMIT_MPI_LOAD}" = "1" ]; then
         echo "module load ${MPI_MODULE}" | ${PKG_SUDO_MOD} tee -a "${_MODFILE}" >/dev/null
      fi
   fi
   unset _MODFILE _MODFLAVOR _EMIT_MPI_LOAD _HDF5_MOD_BASE ROCM_PREREQ_TCL ROCM_PREREQ_LUA

fi

