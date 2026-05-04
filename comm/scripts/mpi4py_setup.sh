#!/bin/bash

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
ROCM_VERSION=6.2.0
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mpi4py
BUILD_MPI4PY=0
MPI4PY_VERSION=4.1.0
MPI4PY_PATH=/opt/rocmplus-${ROCM_VERSION}/mpi4py-v${MPI4PY_VERSION}
MPI4PY_PATH_INPUT=""
MPI_PATH="/usr"
MPI_MODULE="openmpi"
SUDO="sudo"
# --replace 1: rm -rf the prior install dir + ${MPI4PY_VERSION}.lua before building.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup on non-zero exit.
# See hypre_setup.sh for the full design rationale (single source of truth
# for install layout, replaces main_setup.sh's `replace_pkg`/`PKG_CLEAN_*`).
REPLACE=0
KEEP_FAILED_INSTALLS=0

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-mpi4py [ BUILD_MPI4PY ] default is $BUILD_MPI4PY"
   echo "  --mpi-module [ MPI_MODULE ] default is $MPI_MODULE "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --install-path [ MPI4PY_PATH_INPUT ] default $MPI4PY_PATH "
   echo "  --mpi4py-version [ MPI4PY_VERSION ] default is $MPI4PY_VERSION "
   echo "  --mpi-path [MPI_PATH] default is from MPI module"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
          ;;
      "--build-mpi4py")
          shift
          BUILD_MPI4PY=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--mpi4py-version")
          shift
          MPI4PY_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          MPI4PY_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--mpi-path")
          shift
          MPI_PATH=${1}
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

if [ "${MPI4PY_PATH_INPUT}" != "" ]; then
   MPI4PY_PATH=${MPI4PY_PATH_INPUT}
else
   # override path in case ROCM_VERSION or MPI4PY_VERSION has been supplied as input
   MPI4PY_PATH=/opt/rocmplus-${ROCM_VERSION}/mpi4py-v${MPI4PY_VERSION}
fi

# ── BUILD_MPI4PY=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_MPI4PY}" = "0" ]; then
   echo "[mpi4py BUILD_MPI4PY=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# ── --replace: remove prior install + modulefile BEFORE building ─────
# Only this version's dir + ${MPI4PY_VERSION}.lua are removed; other
# installed versions are left in place for multi-version coexistence.
if [ "${REPLACE}" = "1" ]; then
   echo "[mpi4py --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${MPI4PY_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${MPI4PY_VERSION}.lua"
   ${SUDO} rm -rf "${MPI4PY_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${MPI4PY_VERSION}.lua"
fi

# ── Existence guard: skip if this version is already installed ───────
# Replaces the [[ ! -d ${ROCMPLUS}/mpi4py-v${MPI4PY_VERSION} ]] clause
# that previously gated this script's invocation in main_setup.sh; see
# the canonical comment block in extras/scripts/hypre_setup.sh for the
# rationale (single source of truth for the install path; multi-version
# coexistence; honors --mpi4py-version overrides; multi-component-aware
# in scripts that have several install dirs). Placed AFTER --replace
# (so --replace 1 wipes first and falls through to a fresh build) and
# BEFORE the EXIT trap install (so NOOP_RC=43 does not look like a
# failed partial install to fail-cleanup).
NOOP_RC=43
if [ -d "${MPI4PY_PATH}" ]; then
   echo ""
   echo "[mpi4py existence-check] ${MPI4PY_PATH} already installed; skipping."
   echo "                         pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: build-dir cleanup + fail-cleanup ──────────────────────
# Always removes the per-job build dir under /tmp (set later as
# MPI4PY_BUILD_DIR by mktemp -d). On non-zero exit ALSO removes any
# partial install + modulefile this script wrote, unless
# --keep-failed-installs 1 was set. Single source of truth for the
# install layout so the cleanup paths cannot drift from the install
# paths. Replaces main_setup.sh's PKG_CLEAN_DIRS/PKG_CLEAN_MODS for
# this package.
_mpi4py_on_exit() {
   local rc=$?
   [ -n "${MPI4PY_BUILD_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${MPI4PY_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[mpi4py fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${MPI4PY_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${MPI4PY_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[mpi4py fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _mpi4py_on_exit EXIT

echo ""
echo "==================================="
echo "Starting MPI4PY Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_MPI4PY: $BUILD_MPI4PY"
echo "MPI4PY_VERSION: $MPI4PY_VERSION"
echo "MPI4PY_PATH: $MPI4PY_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Loading MPI module: $MPI_MODULE"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

if [ "${BUILD_MPI4PY}" = "0" ]; then

   echo "MPI4PY will not be built, according to the specified value of BUILD_MPI4PY"
   echo "BUILD_MPI4PY: $BUILD_MPI4PY"
   exit

else
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/mpi4py-v${MPI4PY_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached MPI4PY"
      echo "============================"
      echo ""

      # Install the cached version. Cache tar must be named
      # mpi4py-v${MPI4PY_VERSION}.tgz and contain a top-level
      # directory mpi4py-v${MPI4PY_VERSION}/ so it lands directly
      # at ${MPI4PY_PATH} when extracted under /opt/rocmplus-X.
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/mpi4py-v${MPI4PY_VERSION}.tgz
      chown -R root:root ${MPI4PY_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/mpi4py-v${MPI4PY_VERSION}.tgz
      fi

   else

      echo ""
      echo "============================"
      echo " Building MPI4PY"
      echo "============================"
      echo ""

      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" "${MPI_MODULE}" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      if [ -d "$MPI4PY_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${MPI4PY_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${MPI4PY_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${MPI4PY_PATH}
      fi

      # Per-job throwaway build dir under /tmp (or $TMPDIR if Slurm
      # set one, e.g. /tmp/admin/<jobid>/). Replaces a clone into
      # ${PWD}/mpi4py which is the shared NFS HPCTrainingDock
      # checkout — concurrent rocm-version jobs would race on that
      # path (matches the spack-clone collision pattern fixed in
      # commit 688fa43). Only `pip install --target=${MPI4PY_PATH}`
      # writes hit NFS. EXIT trap cleans up the build dir and the
      # mpi4py_build_venv it contains.
      MPI4PY_BUILD_DIR=$(mktemp -d -t mpi4py-build.XXXXXX)
      # NOTE: build-dir cleanup is now consolidated into the _mpi4py_on_exit
      # trap installed at the top of this script (after MPI4PY_PATH was
      # finalized) so that the same EXIT handler also does fail-cleanup
      # of any partial install / modulefile.
      cd "${MPI4PY_BUILD_DIR}"

      git clone --branch $MPI4PY_VERSION https://github.com/mpi4py/mpi4py.git
      cd mpi4py

      echo "[model]              = ${MPI_PATH}" >> mpi.cfg
      echo "mpi_dir              = ${MPI_PATH}" >> mpi.cfg
      echo "mpicc                = ${MPI_PATH}/bin/mpicc" >> mpi.cfg
      echo "mpic++               = ${MPI_PATH}/bin/mpic++" >> mpi.cfg
      echo "library_dirs         = %(mpi_dir)s/lib" >> mpi.cfg
      echo "include_dirs         = %(mpi_dir)s/include" >> mpi.cfg

      python3 -m venv mpi4py_build_venv
      source mpi4py_build_venv/bin/activate
      pip install --upgrade pip setuptools wheel cython

      CC=${ROCM_PATH}/bin/amdclang CXX=${ROCM_PATH}/bin/amdclang++ python3 setup.py build --mpi=model
      CC=${ROCM_PATH}/bin/amdclang CXX=${ROCM_PATH}/bin/amdclang++ python3 setup.py bdist_wheel

      pip install -v --target=${MPI4PY_PATH} dist/mpi4py-*.whl

      deactivate

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${MPI4PY_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${MPI4PY_PATH} -type d -execdir chown root:root "{}" +

	 ${SUDO} chmod go-w ${MPI4PY_PATH}
      fi

      # MPI4PY_BUILD_DIR (under /tmp, contains the mpi4py clone and
      # the build venv) is removed by the EXIT trap above.
      module unload rocm/${ROCM_VERSION}
      module unload ${MPI_MODULE}

   fi


   # Create a module file for mpi4py
   #
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${MPI4PY_VERSION}.lua
	whatis(" MPI4PY - provides Python bindings for MPI")
	
	prepend_path("PYTHONPATH", "${MPI4PY_PATH}")
	load("${MPI_MODULE}")
EOF

fi

