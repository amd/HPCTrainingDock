#!/bin/bash

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

if [ "${REPLACE}" = "1" ]; then
   echo "[hipifly --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${HIPIFLY_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/dev.lua"
   ${SUDO} rm -rf "${HIPIFLY_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/dev.lua"
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
   [ -n "${HIPIFLY_BUILD_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${HIPIFLY_BUILD_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hipifly fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HIPIFLY_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/dev.lua"
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

      # don't use sudo if user has write access to hipifly path
      if [ -d "$HIPIFLY_PATH" ]; then
         # don't use sudo if user has write access to hipifly path
         if [ -w ${HIPIFLY_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using a hipifly path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

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

      # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
      # see netcdf_setup.sh for the lying-probe failure mode this replaces).
      PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
      ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/dev.lua
	whatis(" Hipifly header file ")
	prereq("rocm/${ROCM_VERSION}")
	setenv("HIPIFLY_PATH","${HIPIFLY_PATH}")
EOF

fi

