#!/bin/bash

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/misc/hipifly
HIPIFLY_MODULE=0
HIPIFLY_HEADER_PATH=`pwd`
ROCM_VERSION=6.2.0
HIPIFLY_PATH=/opt/rocmplus-${ROCM_VERSION}/hipifly
HIPIFLY_PATH_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --hipifly-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hipifly-module [ HIPIFLY_MODULE ], set to 1 to create hipifly, default is $HIPIFLY_MODULE"
   echo "  --hipifly-path [ HIPIFLY_PATH ], default is $HIPIFLY_PATH"
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
      trap '[ -n "${HIPIFLY_BUILD_DIR:-}" ] && rm -rf "${HIPIFLY_BUILD_DIR}"' EXIT
      cd "${HIPIFLY_BUILD_DIR}"
      wget -q https://raw.githubusercontent.com/amd/HPCTrainingDock/main/extras/sources/hipifly/hipifly.h
      ${SUDO} cp ./hipifly.h ${HIPIFLY_PATH}
      # HIPIFLY_BUILD_DIR (under /tmp) is removed by the EXIT trap.

      if [ -d "$MODULE_PATH" ]; then
         # use sudo if user does not have write access to module path
         if [ ! -w ${MODULE_PATH} ]; then
            SUDO="sudo"
         else
            echo "WARNING: not using sudo since user has write access to module path"
         fi
      else
         # if module path dir does not exist yet, the check on write access will fail
         SUDO="sudo"
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/dev.lua
	whatis(" Hipifly header file ")
	prereq("rocm/${ROCM_VERSION}")
	setenv("HIPIFLY_PATH","${HIPIFLY_PATH}")
EOF

fi

