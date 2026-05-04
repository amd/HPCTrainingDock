#!/bin/bash

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mvapich
ROCM_VERSION=6.2.0
ROCM_PATH=/opt/rocm-${ROCM_VERSION}
# --replace 1: rm -rf prior install dir + mvapich modulefile before
# install. NOTE: mvapich modulefile name is currently fixed (no
# version), so the .lua to remove is mvapich.lua under MODULE_PATH.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
# (Pre-existing REPLACE=0 was a flag-style stub that the script body
# never actually used; promoted here to a value-style flag consistent
# with the rest of the setup scripts so main_setup.sh can thread
# --replace ${REPLACE_EXISTING}.)
REPLACE=0
KEEP_FAILED_INSTALLS=0
DRY_RUN=0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# PKG_SUDO is independent of the install-path-derived SUDO: apt operates
# on root-owned /var/lib/{apt,dpkg} regardless of where the package files
# end up. See openmpi_setup.sh / audit_2026_05_01.md Issue 2.
PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")


# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --dry-run default off"
   echo "  --install-path [ INSTALL_PATH ] default /opt/rocmplus-<ROCM_VERSION>/mvapich"
   echo "  --module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-MPI/mvapich"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before installing, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --rocm-path [ ROCM_PATH ] default /opt/rocm-$ROCM_VERSION"
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
      "--dry-run")
          DRY_RUN=1
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
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
      "--rocm-path")
          shift
          ROCM_PATH_INPUT=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          # Accepted for compatibility with COMMON_OPTIONS in
          # main_setup.sh; mvapich install path doesn't actually use it.
          shift
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/mvapich
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# The mvapich modulefile is currently written as MODULE_PATH/mvapich.lua
# (no version in the name). If a versioned modulefile scheme is added
# later, update both branches below.
if [ "${REPLACE}" = "1" ]; then
   echo "[mvapich --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/mvapich.lua"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/mvapich.lua"
fi
# Consolidated EXIT trap: build-dir cleanup (MVAPICH_BUILD_ROOT, set
# later under the rhel-compatible branch) AND fail-cleanup. Replaces
# the inline `trap '... rm MVAPICH_BUILD_ROOT ...' EXIT`.
_mvapich_on_exit() {
   local rc=$?
   [ -n "${MVAPICH_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${MVAPICH_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[mvapich fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/mvapich.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[mvapich fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _mvapich_on_exit EXIT

echo ""
echo "============================"
echo " Installing MVAPICH with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "============================"
echo ""

#
# Install mvapich
#

MVAPICH_RPM_NAME=mvapich-plus-rocm5.6.0.multiarch.ucx.gnu8.5.0-3.0-1.el8.x86_64.rpm
MVAPICH_DOWNLOAD_URL=https://mvapich.cse.ohio-state.edu/download/mvapich/plus/3.0/rocm/UCX/mofed5.0

if [ "${DISTRO}" = "ubuntu" ]; then
   echo "Mvapich install on Ubuntu not working yet"
   # Sentinel rc=43 (NOOP_RC) tells main_setup.sh's run_and_log to
   # classify this as SKIPPED(no-op), not FAILED. Kept in sync by
   # convention with bare_system/main_setup.sh.
   exit 43
   ${PKG_SUDO} ${DEB_FRONTEND} apt-get -qqy install alien
   ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/mvapich

   # install the GPU aware version of mvapich using an rpm (MVPlus3.0)
   ${SUDO} wget -q ${MVAPICH_DOWNLOAD_URL}/${MVAPICH_RPM_NAME}
   ls -l ${MVAPICH_RPM_NAME}
   ${PKG_SUDO} ${DEB_FRONTEND} apt-get install -y alien ${MVAPICH_RPM_NAME}
   /opt/rocmplus-${ROCM_VERSION}/mvapich/bin/mpicc --show
   rm -rf ${MVAPICH_RPM_NAME}
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/mvapich

   # Per-job throwaway build dir; replaces a fixed `cd /tmp` that
   # would race with any other concurrent mvapich build on the same
   # node. The trap cleans up the rpm download.
   MVAPICH_BUILD_ROOT=$(mktemp -d -t mvapich-build.XXXXXX)
   # NOTE: build-dir cleanup is consolidated into _mvapich_on_exit
   # installed above (so the same EXIT handler also does fail-cleanup
   # of any partial install / modulefile).
   cd "${MVAPICH_BUILD_ROOT}"
   # install the GPU aware version of mvapich using an rpm (MVPlus3.0)
   wget -q ${MVAPICH_DOWNLOAD_URL}/${MVAPICH_RPM_NAME}
   if [[ "${DRY_RUN}" == "0" ]]; then
      ${SUDO} rpm --prefix ${INSTALL_PATH} -Uvh --nodeps ${MVAPICH_RPM_NAME}
      ${INSTALL_PATH}/mvapich/bin/mpicc -show
   fi
   # trap handles cleanup of ${MVAPICH_BUILD_ROOT}/${MVAPICH_RPM_NAME}
elif [ "${DISTRO}" = "opensuse leap" ]; then
   echo "Mvapich install on Suse not working yet"
   exit 43
else
   echo "DISTRO version ${DISTRO} not recognized or supported"
   exit 43
fi

# Create a module file for Mvapich
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mvapich

${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/3.0.lua
	whatis("Name: GPU-aware mvapich")
	whatis("Version: 3.0.0")
	whatis("Description: An open source Message Passing Interface implementation")
	whatis(" This is a GPU-aware version of Mvapich3")

	local base = "/opt/rocmplus-${ROCM_VERSION}/mvapich/"
	local mbase = "/etc/lmod/modules/ROCmPlus-MPI"

	setenv("MV2_PATH", base)
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib64"))
	prepend_path("C_INCLUDE_PATH",pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH",pathJoin(base, "include"))
	prepend_path("PATH",pathJoin(base, "bin"))
	prereq("rocm/${ROCM_VERSION}")
	family("MPI")
EOF
