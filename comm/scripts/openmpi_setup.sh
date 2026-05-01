#!/bin/bash

# Fail fast on errors and surface failures inside pipes. Without this,
# audited xpmem/ucx Permission-denied failures returned rc=0 to the
# caller and main_setup.sh reported success. Not using -u (nounset)
# because some conditional code paths rely on unset variables.
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

# This script installs OpenMPI along with the XPEM, UCX and UCC libraries. The simplest use case is:
#   ./openmpi_setup.sh --rocm-version <ROCM_VERSION>
# Most of the needed information for the install is autodetected. Others are set to the latest
# available versions. Cross-compiling for a different GPU model can be done by specifying
# the --amdgpu-gfxmodel <AMDGPU-GFXMODEL> option
#

# Variables controlling setup process
ROCM_VERSION=
ROCM_PATH=
REPLACE=0
REPLACE_XPMEM=0
REPLACE_UCX=0
REPLACE_UCC=0
REPLACE_OPENMPI=0
DRY_RUN=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/openmpi
INSTALL_PATH_INPUT=""
XPMEM_PATH_INPUT=""
BUILD_XPMEM="1"
UCX_PATH_INPUT=""
UCC_PATH_INPUT=""
OPENMPI_PATH_INPUT=""
USE_CACHE_BUILD=1
UCX_VERSION=1.19.1
UCX_MD5CHECKSUM=684414d2fcb96ded0cbaad33d88ea56d
UCC_VERSION=1.6.0
UCC_MD5CHECKSUM=b339803d144b9d66669b0eaedf6ac208
XPMEM_VERSION=2.7.4
XPMEM_MD5CHECKSUM=fba34a0af58ab0c722d3b28fc08c2800
OPENMPI_VERSION=5.0.10
OPENMPI_MD5CHECKSUM=157481649ad73ec78dbb669e7e9f159b
C_COMPILER=gcc
CXX_COMPILER=g++
FC_COMPILER=amdflang

# Autodetect defaults
AMDGPU_GFXMODEL=
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# pick_sudo_for <path>: prints "sudo" if writing to <path> requires elevation
# for the current user, "" otherwise. If <path> does not exist yet, walks up
# to the nearest existing ancestor and tests that. Used per component so a
# writable parent does not falsely waive sudo for a root-owned subdir, and a
# root-owned parent does not force sudo on a subdir the user already owns.
#
# IMPORTANT: must NOT use `[ -w ]` -- the bash test is implemented on top of
# the NFS client's cached mode/uid view, which can disagree with the
# server's actual permission decision (observed on this cluster: client
# said writable, server returned EACCES on the very next mkdir). Instead,
# do a real probe -- atomically create+remove a tempfile -- which exercises
# the same NFS code path as the subsequent install operations.
pick_sudo_for()
{
   local target="$1"
   local probe_dir
   if [ -d "${target}" ]; then
      probe_dir="${target}"
   else
      probe_dir="${target%/*}"
      while [ -n "${probe_dir}" ] && [ ! -d "${probe_dir}" ]; do
         probe_dir="${probe_dir%/*}"
      done
      [ -z "${probe_dir}" ] && probe_dir="/"
   fi
   local probe="${probe_dir}/.openmpi_setup_writeprobe.$$.${RANDOM}"
   # Use ( : > "${probe}" ) so the truncate/create happens in a subshell
   # whose stderr is silenced; avoids set -e ambiguity at the call site.
   if ( umask 077 && : > "${probe}" ) 2>/dev/null; then
      rm -f "${probe}" 2>/dev/null
      echo ""; return
   fi
   echo "sudo"
}

usage()
{
    echo "Usage:"
    echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
    echo "  --build-xpmem [ BUILD_XPMEM ] default 1-yes"
    echo "  --c-compiler [ CC ] default $C_COMPILER"
    echo "  --cxx-compiler [ CXX ] default $CXX_COMPILER"
    echo "  --dry-run default off"
    echo "  --fc-compiler [ FC ] default $FC_COMPILER"
    echo "  --install-path [ INSTALL_PATH ] default /opt/rocmplus-$ROCM_VERSION/openmpi (ucx, and ucc)"
    echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
    echo "  --openmpi-path [OPENMPI_PATH] default $INSTALL_PATH/openmpi-$OPENMPI_VERSION-ucc-$UCC_VERSION-ucx-$UCX_VERSION-xpmem-$XPMEM_VERSION"
    echo "  --openmpi-version [VERSION] default $OPENMPI_VERSION"
    echo "  --openmpi-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "  --replace default off"
    echo "  --replace-xpmem default off"
    echo "  --replace-ucx default off"
    echo "  --replace-ucc default off"
    echo "  --replace-openmpi default off"
    echo "  --rocm-version [ ROCM_VERSION ] default none"
    echo "  --rocm-path [ ROCM_PATH ] default none"
    echo "  --ucc-path default $INSTALL_PATH/ucc-$UCC_VERSION-ucx-$UCX_VERSION-xpmem-$XPMEM_VERSION"
    echo "  --ucc-version [VERSION] default $UCC_VERSION"
    echo "  --ucc-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "  --ucx-path default $INSTALL_PATH/ucx-$UCX_VERSION-xpmem-$XPMEM_VERSION"
    echo "  --ucx-version [VERSION] default $UCX_VERSION"
    echo "  --ucx-md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "  --xpmem-path default ${INSTALL_PATH}/xpmem-${XPMEM_VERSION}"
    echo "  --xpmem-version [VERSION] default $XPMEM_VERSION"
    echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
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
      "--build-xpmem")
          shift
          BUILD_XPMEM=${1}
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
      "--dry-run")
          DRY_RUN=1
          reset-last
          ;;
      "--fc-compiler")
          shift
          FC_COMPILER=${1}
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
      "--openmpi-path")
          shift
          OPENMPI_PATH_INPUT=${1}
          reset-last
          ;;
      "--openmpi-version")
          shift
          OPENMPI_VERSION=${1}
          reset-last
          ;;
      "--openmpi-md5checksum")
          shift
          OPENMPI_MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             OPENMPI_MD5CHECKSUM="skip"
          fi
          reset-last
          ;;
      "--replace")
          REPLACE=1
          reset-last
          ;;
      "--replace-xpmem")
          REPLACE_XPMEM=1
          reset-last
          ;;
      "--replace-ucc")
          REPLACE_UCC=1
          reset-last
          ;;
      "--replace-ucx")
          REPLACE_UCX=1
          reset-last
          ;;
      "--replace-openmpi")
          REPLACE_OPENMPI=1
          reset-last
          ;;
      "--rocm-path")
          shift
          ROCM_PATH=${1}
	  ROCM_VERSION=`cat ${ROCM_PATH}/.info/version | cut -f1 -d'-' `
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--ucc-path")
          shift
          UCC_PATH_INPUT=${1}
          reset-last
          ;;
      "--ucc-version")
          shift
          UCC_VERSION=${1}
          reset-last
          ;;
      "--ucc-md5checksum")
          shift
          UCC_MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             UCC_MD5CHECKSUM="skip"
          fi
          reset-last
          ;;
      "--ucx-path")
          shift
          UCX_PATH_INPUT=${1}
          reset-last
          ;;
      "--ucx-version")
          shift
          UCX_VERSION=${1}
          reset-last
          ;;
      "--ucx-md5checksum")
          shift
          UCX_MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             UCX_MD5CHECKSUM="skip"
          fi
          reset-last
          ;;
      "--xpmem-path")
          shift
          XPMEM_PATH_INPUT=${1}
          reset-last
          ;;
      "--xpmem-version")
          shift
          XPMEM_VERSION=${1}
          reset-last
          ;;
      "--xpmem-md5checksum")
          shift
          XPMEM_MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             XPMEM_MD5CHECKSUM="skip"
          fi
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

# Preflight + load required modules. preflight_modules exits the script
# with rc=42 (MISSING_PREREQ) on the first module that doesn't resolve;
# main_setup.sh's run_and_log treats that as SKIPPED rather than FAILED.
# This is the SINGLE place where openmpi's module prerequisites are
# declared -- no central PKG_DEPS table to keep in sync.
REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" )
preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

echo ""
echo "============================"
echo " Installing OpenMPI with:"
echo "   ROCM_VERSION: $ROCM_VERSION"
echo "   ROCM_PATH: ${ROCM_PATH}"
echo "============================"
echo ""

IS_DOCKER=0
if [ -f "/.dockerenv" ]; then
  IS_DOCKER=1
fi
if [ "${IS_DOCKER}" == "1" ]; then
   BUILD_XPMEM=0
fi

if [ "${BUILD_XPMEM}" == "1" ]; then
   XPMEM_STRING=-xpmem-${XPMEM_VERSION}
fi

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT}"
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}
fi

if [ "${XPMEM_PATH_INPUT}" != "" ]; then
   XPMEM_PATH="${XPMEM_PATH_INPUT}"
else
   XPMEM_PATH="${INSTALL_PATH}"/xpmem-${XPMEM_VERSION}
fi

if [ "${UCX_PATH_INPUT}" != "" ]; then
   UCX_PATH="${UCX_PATH_INPUT}"
else
   UCX_PATH="${INSTALL_PATH}"/ucx-${UCX_VERSION}${XPMEM_STRING}
fi

if [ "${UCC_PATH_INPUT}" != "" ]; then
   UCC_PATH="${UCC_PATH_INPUT}"
else
   UCC_PATH="${INSTALL_PATH}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}
fi

if [ "${OPENMPI_PATH_INPUT}" != "" ]; then
   OPENMPI_PATH="${OPENMPI_PATH_INPUT}"
else
   OPENMPI_PATH="${INSTALL_PATH}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}
fi

if [ "${REPLACE}" == "1" ]; then
   REPLACE_XPMEM=1
   REPLACE_UCX=1
   REPLACE_UCC=1
   REPLACE_OPENMPI=1
fi

# ── Per-component sudo detection ──────────────────────────────────────
# Each component (xpmem, ucx, ucc, openmpi) lives in its OWN subdir of
# ${INSTALL_PATH}, e.g. ${INSTALL_PATH}/xpmem-2.7.4. A previous version
# of this script computed a single SUDO based on whether ${INSTALL_PATH}
# itself was writable; that produced silent failures when
# ${INSTALL_PATH} was admin-writable but the component subdirs were
# root-owned (or vice versa). Decide per-component instead.
#
# Inside Singularity (or any other context where the script-level SUDO
# was forced empty above), keep all per-component SUDOs empty too —
# pick_sudo_for would also return "" for root, but be explicit.
if [ -z "${SUDO}" ]; then
   SUDO_XPMEM=""
   SUDO_UCX=""
   SUDO_UCC=""
   SUDO_OPENMPI=""
else
   SUDO_XPMEM=$(pick_sudo_for "${XPMEM_PATH}")
   SUDO_UCX=$(pick_sudo_for "${UCX_PATH}")
   SUDO_UCC=$(pick_sudo_for "${UCC_PATH}")
   SUDO_OPENMPI=$(pick_sudo_for "${OPENMPI_PATH}")
   # Top-level SUDO drives the apt/dnf step and `mkdir -p ${INSTALL_PATH}`
   # below; base it on the parent install path the same way.
   SUDO=$(pick_sudo_for "${INSTALL_PATH}")
   [ -z "${SUDO}" ] && \
      echo "NOTE: ${INSTALL_PATH} is writable by ${USER}; not using sudo for top-level steps"
fi

echo "Resolved sudo modes:"
printf "  %-14s install_path=%-60s SUDO='%s'\n" "top-level"  "${INSTALL_PATH}"   "${SUDO}"
printf "  %-14s install_path=%-60s SUDO='%s'\n" "xpmem"      "${XPMEM_PATH}"     "${SUDO_XPMEM}"
printf "  %-14s install_path=%-60s SUDO='%s'\n" "ucx"        "${UCX_PATH}"       "${SUDO_UCX}"
printf "  %-14s install_path=%-60s SUDO='%s'\n" "ucc"        "${UCC_PATH}"       "${SUDO_UCC}"
printf "  %-14s install_path=%-60s SUDO='%s'\n" "openmpi"    "${OPENMPI_PATH}"   "${SUDO_OPENMPI}"

# PKG_SUDO is independent of the install-path-writability-derived SUDO
# above. apt-get / yum operate on /var/lib/{apt,dpkg,rpm}, which are
# always root-owned; the only condition under which they should run
# without sudo is when the script itself is already root (EUID==0).
# Previously these used the top-level ${SUDO}, which gets set to ''
# whenever ${INSTALL_PATH} happens to be writable by the script user.
# That broke jobs 7960/7961 in the 2026-04-30 chain (Issue 2 in
# audit_2026_05_01.md): /shared/apps/ubuntu/opt/rocmplus-7.{2.0,1.1}/
# was admin-writable, SUDO='', apt-get ran as admin, lock file
# Permission denied, openmpi rc=100, 12 dependent packages cascaded
# to missing-prereq SKIPPED.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO=""
else
   PKG_SUDO="sudo"
fi

if [ "${DISTRO}" = "ubuntu" ]; then
   echo "Install of libpmix-dev libhwloc-dev libevent-dev libfuse3-dev librdmacm-dev libtcmalloc-minimal4 doxygen packages"
   if [[ "${DRY_RUN}" == "0" ]]; then
      # these are for openmpi :  libpmix-dev  libhwloc-dev  libevent-dev
      ${PKG_SUDO} apt-get update
      ${PKG_SUDO} apt-get install -y libpmix-dev libhwloc-dev libevent-dev \
         libfuse3-dev librdmacm-dev libtcmalloc-minimal4 doxygen
      if [ "${IS_DOCKER}" != "1" ]; then
         ${PKG_SUDO} apt-get install -y linux-headers-$(uname -r)
      fi
   fi
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   echo "Install of pmix and hwloc packages"
   if [[ "${DRY_RUN}" == "0" ]]; then
      # these are for openmpi :  libpmix-dev  libhwloc-dev  libevent-dev
      ${PKG_SUDO} yum update -y
      ${PKG_SUDO} yum install -y pmix hwloc
   fi
else
   echo "DISTRO version ${DISTRO} not recognized or supported"
   exit
fi

if [[ "${DRY_RUN}" == "0" ]] && [[ ! -d ${INSTALL_PATH} ]] ; then
   ${SUDO} mkdir -p "${INSTALL_PATH}"
fi
cd "${INSTALL_PATH}"

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

#
# Install XPMEM
#

if [ "${BUILD_XPMEM}" == "1" ]; then
   if [[ -d "${XPMEM_PATH}" ]] && [[ "${REPLACE_XPMEM}" == "0" ]] ; then
      echo "There is a previous installation and the replace flag is false"
      echo "  use --replace to request replacing the current installation"
   else
      if [[ -d "${XPMEM_PATH}" ]] && [[ "${REPLACE_XPMEM}" != "0" ]] ; then
         ${SUDO_XPMEM} rm -rf "${XPMEM_PATH}"
      fi
      if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f ${CACHE_FILES}/xpmem-${XPMEM_VERSION}.tgz ]]; then
         echo ""
         echo "============================"
         echo " Installing Cached XPMEM"
         echo "============================"
         echo ""

         #install the cached version
         echo "cached file is ${CACHE_FILES}/xpmem-${XPMEM_VERSION}.tgz"
         ${SUDO_XPMEM} mkdir -p ${XPMEM_PATH}
         cd ${INSTALL_PATH}
         ${SUDO_XPMEM} tar -xzpf ${CACHE_FILES}/xpmem-${XPMEM_VERSION}.tgz
         if [ "${USER}" != "root" ]; then
            ${SUDO_XPMEM} find ${XPMEM_PATH} -type f -execdir chown root:root "{}" +
            ${SUDO_XPMEM} find ${XPMEM_PATH} -type d -execdir chown root:root "{}" +
         fi
         if [ "${USER}" != "sysadmin" ]; then
            ${SUDO} rm "${CACHE_FILES}"/xpmem-${XPMEM_VERSION}.tgz
         fi
      else

         echo ""
         echo "============================"
         echo " Building XPMEM"
         echo "============================"
         echo ""

         cd /tmp

         XPMEM_DOWNLOAD_URL=https://github.com/openucx/xpmem/archive/refs/tags/v${XPMEM_VERSION}.tar.gz
         count=0
         while [ "$count" -lt 3 ]; do
            wget -q --continue --tries=10 ${XPMEM_DOWNLOAD_URL} && break
            count=$((count+1))
         done
         if [ ! -f v${XPMEM_VERSION}.tar.gz ]; then
            echo "Failed to download v${XPMEM_VERSION}.tar.gz package from: "
            echo "    ${XPMEM_DOWNLOAD_URL} ... exiting"
            exit 1
         else
            MD5SUM_XPMEM=`md5sum v${XPMEM_VERSION}.tar.gz | cut -f1 -d' ' `
            if [[ "${XPMEM_MD5CHECKSUM}" =~ "skip" ]]; then
               echo "MD5SUM is ${MD5SUM_XPMEM}, no check requested"
            elif [[ "${MD5SUM_XPMEM}" == "${XPMEM_MD5CHECKSUM}" ]]; then
               echo "MD5SUM is verified: actual ${MD5SUM_XPMEM}, expecting ${XPMEM_MD5CHECKSUM}"
            else
               echo "Error: Wrong MD5Sum for v${XPMEM_VERSION}.tar.gz:"
               echo "MD5SUM is ${MD5SUM_XPMEM}, expecting ${XPMEM_MD5CHECKSUM}"
               exit 1
            fi
         fi
         tar xzf v${XPMEM_VERSION}.tar.gz
         cd xpmem-${XPMEM_VERSION}

         ./autogen.sh
         ./configure --prefix=${XPMEM_PATH}

         # S7.A: scale parallel build to all allocated cores instead of a
         # hardcoded 16 on a 48-core compute node. Audited as S7.A in
         # slurm-7935-rocmplus-7.0.1.out. `make install` kept serial --
         # mostly file copies, no measurable benefit from -j.
         make -j $(nproc)
         if [[ "${DRY_RUN}" == "0" ]]; then
            if [ -n "${SUDO_XPMEM}" ]; then
               ${SUDO_XPMEM} -E env "PATH=$PATH" make install
            else
               make install
            fi
         fi

      cd ..
      rm -rf xpmem-${XPMEM_VERSION} v${XPMEM_VERSION}.tar.gz
   fi

   if [[ ! -d ${XPMEM_PATH}/lib ]] ; then
         echo "XPMEM (OpenMPI) installation failed -- missing installation directories"
         echo " XPMEM Installation path is ${XPMEM_PATH}"
         ls -l "${XPMEM_PATH}"
         exit 1
      fi
   fi
fi

#
# Install UCX
#

if [[ -d "${UCX_PATH}" ]] && [[ "${REPLACE_UCX}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${UCX_PATH}" ]] && [[ "${REPLACE_UCX}" != "0" ]] ; then
      ${SUDO_UCX} rm -rf "${UCX_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f ${CACHE_FILES}/ucx-${UCX_VERSION}${XPMEM_STRING}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached UCX"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${CACHE_FILES}/ucx-${UCX_VERSION}${XPMEM_STRING}.tgz"
      ${SUDO_UCX} mkdir -p ${UCX_PATH}
      cd ${INSTALL_PATH}
      ${SUDO_UCX} tar -xzpf ${CACHE_FILES}/ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      if [ "${USER}" != "root" ]; then
         ${SUDO_UCX} find ${UCX_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO_UCX} find ${UCX_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm "${CACHE_FILES}"/ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      fi
   else

      echo ""
      echo "============================"
      echo " Building UCX"
      echo "============================"
      echo ""

      cd /tmp

      UCX_DOWNLOAD_URL=https://github.com/openucx/ucx/releases/download/v${UCX_VERSION}/ucx-${UCX_VERSION}.tar.gz
      count=0
      while [ "$count" -lt 3 ]; do
         wget -q --continue --tries=10 ${UCX_DOWNLOAD_URL} && break
         count=$((count+1))
      done
      if [ ! -f ucx-${UCX_VERSION}.tar.gz ]; then
         echo "Failed to download ucx-${UCX_VERSION}.tar.gz package from: "
         echo "    ${UCX_DOWNLOAD_URL} ... exiting"
         exit 1
      else
         MD5SUM_UCX=`md5sum ucx-${UCX_VERSION}.tar.gz | cut -f1 -d' ' `
         if [[ "${UCX_MD5CHECKSUM}" =~ "skip" ]]; then
            echo "MD5SUM is ${MD5SUM_UCX}, no check requested"
         elif [[ "${MD5SUM_UCX}" == "${UCX_MD5CHECKSUM}" ]]; then
            echo "MD5SUM is verified: actual ${MD5SUM_UCX}, expecting ${UCX_MD5CHECKSUM}"
         else
            echo "Error: Wrong MD5Sum for ucx-${UCX_VERSION}.tar.gz:"
            echo "MD5SUM is ${MD5SUM_UCX}, expecting ${UCX_MD5CHECKSUM}"
            exit 1
         fi
      fi
      tar xzf ucx-${UCX_VERSION}.tar.gz
      cd ucx-${UCX_VERSION}
      mkdir build && cd build

if [ "${BUILD_XPMEM}" == "1" ]; then
      UCX_CONFIGURE_COMMAND="../contrib/configure-release \
         --prefix=${UCX_PATH} \
         --with-rocm=${ROCM_PATH} \
         --with-xpmem=${XPMEM_PATH} \
         --without-cuda \
         --enable-mt \
         --enable-optimizations \
         --disable-logging \
         --disable-debug \
         --enable-assertions \
         --enable-params-check \
         --enable-examples"
else
      UCX_CONFIGURE_COMMAND="../contrib/configure-release \
         --prefix=${UCX_PATH} \
         --with-rocm=${ROCM_PATH} \
         --without-cuda \
         --enable-mt \
         --enable-optimizations \
         --disable-logging \
         --disable-debug \
         --enable-assertions \
         --enable-params-check \
         --enable-examples"
fi

      echo ""
      echo "UCX_CONFIGURE_COMMAND: "
      echo "${UCX_CONFIGURE_COMMAND}" | sed 's/\s\+/ \\\n   /g'
      echo ""

      ${UCX_CONFIGURE_COMMAND}

      # S7.A: scale parallel build to all allocated cores instead of a
      # hardcoded 16 on a 48-core compute node. Audited as S7.A in
      # slurm-7935-rocmplus-7.0.1.out.
      make -j $(nproc)
      if [[ "${DRY_RUN}" == "0" ]]; then
         if [ -n "${SUDO_UCX}" ]; then
            ${SUDO_UCX} -E env "PATH=$PATH" make install
         else
            make install
         fi
      fi

      cd ../..
      rm -rf ucx-${UCX_VERSION} ucx-${UCX_VERSION}.tar.gz
   fi

   if [[ ! -d ${UCX_PATH}/lib ]] ; then
      echo "UCX (OpenMPI) installation failed -- missing installation directories"
      echo " UCX Installation path is ${UCX_PATH}"
      ls -l "${UCX_PATH}"
      exit 1
   fi
fi

#
# Install UCC
#

if [[ -d "${UCC_PATH}" ]] && [[ "${REPLACE_UCC}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${UCC_PATH}" ]] && [[ "${REPLACE_UCC}" != "0" ]] ; then
      ${SUDO_UCC} rm -rf "${UCC_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f "${CACHE_FILES}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached UCC"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${CACHE_FILES}/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz"
      ${SUDO_UCC} mkdir -p ${UCC_PATH}
      cd "${INSTALL_PATH}"
      ${SUDO_UCC} tar -xzpf "${CACHE_FILES}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      if [ "${USER}" != "root" ]; then
         ${SUDO_UCC} find ${UCC_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO_UCC} find ${UCC_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm "${CACHE_FILES}"/ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      fi
   else

      echo ""
      echo "============================"
      echo " Building UCC"
      echo "============================"
      echo ""

      count=0
      while [ "$count" -lt 3 ]; do
         wget -q --continue --tries=10 https://github.com/openucx/ucc/archive/refs/tags/v${UCC_VERSION}.tar.gz && break
         count=$((count+1))
      done
      if [ ! -f v${UCC_VERSION}.tar.gz ]; then
         echo "Failed to download ucc v${UCC_VERSION}.tar.gz package ... exiting"
         exit 1
      else
         MD5SUM_UCC=`md5sum v${UCC_VERSION}.tar.gz | cut -f1 -d' ' `
         if [[ "${UCC_MD5CHECKSUM}" =~ "skip" ]]; then
            echo "MD5SUM is ${MD5SUM_UCC}, no check requested"
         elif [[ "${MD5SUM_UCC}" == "${UCC_MD5CHECKSUM}" ]]; then
            echo "MD5SUM is verified: actual ${MD5SUM_UCC}, expecting ${UCC_MD5CHECKSUM}"
         else
            echo "Error: Wrong MD5Sum for v${UCC_VERSION}.tar.gz:"
            echo "MD5SUM is ${MD5SUM_UCC}, expecting ${UCC_MD5CHECKSUM}"
            exit 1
         fi
      fi
      tar xzf v${UCC_VERSION}.tar.gz
      cd ucc-${UCC_VERSION}

      ./autogen.sh

#      export AMDGPU_GFXMODEL_UCC=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/ --offload-arch=/g'`
#      AMDGPU_GFXMODEL_UCC="--offload-arch=${AMDGPU_GFXMODEL_UCC}"
#     AMDGPU_GFXMODEL_LIST=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/ --with-rocm-arch=--offload-arch=/g' -e 's/^/--with-rocm-arch=--offload-arch=/'`
#     echo "AMDGPU_GFXMODEL_LIST ${AMDGPU_GFXMODEL_LIST}"
      #AMDGPU_GFXMODEL_LIST=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/,/g' `

# giving the --with-rocm-arch option with all-arch-no-native removes the native architecture from the gfx list. Native does not always work.
#   remove --offload-arch=native from list (failing in Docker when compiling as root)
#	--with-rocm-arch=all-arch-no-native \
#   for a single gfx model, the following works
#	--with-rocm-arch=--offload-arch=${AMDGPU_GFXMODEL} \
#   for a multiple gfx models, the following should work
#	--with-rocm-arch="--offload-arch=gfx90a --offload-arch=gfx942" \

      if [[ "${ROCM_VERSION}" == 7* ]]; then
         sed -i -e '7,7a#include <stdbool.h>' src/components/ec/rocm/ec_rocm_executor_interruptible.c
      fi
      UCC_CONFIGURE_COMMAND="./configure \
        --prefix=${UCC_PATH} \
        --with-rocm=${ROCM_PATH} \
        --with-rocm-arch=all-arch-no-native \
        --with-ucx=${UCX_PATH}"

      echo ""
      echo "UCC_CONFIGURE_COMMAND: "
      echo "${UCC_CONFIGURE_COMMAND}" | sed 's/\s\+/ \\\n   /g'
      echo ""

      ${UCC_CONFIGURE_COMMAND}

      # S7.A: scale parallel build to all allocated cores instead of a
      # hardcoded 16 on a 48-core compute node. Audited as S7.A in
      # slurm-7935-rocmplus-7.0.1.out.
      make -j $(nproc)

      if [[ "${DRY_RUN}" == "0" ]]; then
         if [ -n "${SUDO_UCC}" ]; then
            ${SUDO_UCC} -E env "PATH=$PATH" make install
         else
            make install
         fi
      fi

      cd ..
      rm -rf ucc-${UCC_VERSION} v${UCC_VERSION}.tar.gz
   fi

   if [[ ! -d "${UCC_PATH}"/lib ]] ; then
      echo "UCC (OpenMPI) installation failed -- missing installation directories"
      echo " UCC Installation path is ${UCC_PATH}"
      ls -l "${UCC_PATH}"
      exit 1
   fi
fi

#
# Install OpenMPI
#

if [[ -d "${OPENMPI_PATH}" ]] && [[ "${REPLACE_OPENMPI}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
else
   if [[ -d "${OPENMPI_PATH}" ]] && [[ "${REPLACE_OPENMPI}" != "0" ]] ; then
      ${SUDO_OPENMPI} rm -rf "${OPENMPI_PATH}"
   fi
   if [[ "$USE_CACHE_BUILD" == "1" ]] && [[ -f "${CACHE_FILES}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached OpenMPI"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${CACHE_FILES}/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz"
      ${SUDO_OPENMPI} mkdir -p ${OPENMPI_PATH}
      cd "${INSTALL_PATH}"
      ${SUDO_OPENMPI} tar -xzpf "${CACHE_FILES}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      if [ "${USER}" != "root" ]; then
         ${SUDO_OPENMPI} find ${OPENMPI_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO_OPENMPI} find ${OPENMPI_PATH} -type d -execdir chown root:root "{}" +
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm "${CACHE_FILES}"/openmpi-${OPENMPI_VERSION}-ucc-${UCC_VERSION}-ucx-${UCX_VERSION}${XPMEM_STRING}.tgz
      fi
   else

      echo ""
      echo "============================"
      echo " Building OpenMPI"
      echo "============================"
      echo ""

      # no cached version, so build it

      export OMPI_ALLOW_RUN_AS_ROOT=1
      export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1



      # dad 3/25/3023 removed --enable-mpi-f90 --enable-mpi-c as they apparently are not options
      # dad 3/30/2023 remove --with-pmix

      # S7.B: build OpenMPI under /tmp (compute-node local disk) instead
      # of $HOME (NFS). Previously a bare `cd` (= cd $HOME) sent the
      # ~30MB tarball, the configure write storm, and the thousands of
      # .o intermediates through NFS. Only `make install` writes hit NFS
      # via the absolute --prefix=${OPENMPI_PATH}. EXIT trap guarantees
      # the temp build dir is cleaned up even on failure (set -e).
      # Audited as S7.B in slurm-7935-rocmplus-7.0.1.out; mirrors the
      # scorep S6.C pattern in tools/scripts/scorep_setup.sh.
      OPENMPI_BUILD_DIR=$(mktemp -d -t openmpi-build.XXXXXX)
      trap '[ -n "${OPENMPI_BUILD_DIR:-}" ] && rm -rf "${OPENMPI_BUILD_DIR}"' EXIT
      cd "${OPENMPI_BUILD_DIR}"

      OPENMPI_SHORT_VERSION=`echo ${OPENMPI_VERSION} | cut -f1-2 -d'.' `
      count=0
      while [ "$count" -lt 3 ]; do
         wget -q --continue --tries=10 https://download.open-mpi.org/release/open-mpi/v${OPENMPI_SHORT_VERSION}/openmpi-${OPENMPI_VERSION}.tar.bz2 && break
         count=$((count+1))
      done
      if [ ! -f openmpi-${OPENMPI_VERSION}.tar.bz2 ]; then
         echo "Failed to download openmpi-${OPENMPI_VERSION}.tar.bz2 package ... exiting"
         exit 1
      else
         MD5SUM_OPENMPI=`md5sum openmpi-${OPENMPI_VERSION}.tar.bz2 | cut -f1 -d' ' `
         if [[ "${OPENMPI_MD5CHECKSUM}" =~ "skip" ]]; then
            echo "MD5SUM is ${MD5SUM_OPENMPI}, no check requested"
         elif [[ "${MD5SUM_OPENMPI}" == "${OPENMPI_MD5CHECKSUM}" ]]; then
            echo "MD5SUM is verified: actual ${MD5SUM_OPENMPI}, expecting ${OPENMPI_MD5CHECKSUM}"
         else
            echo "Error: Wrong MD5Sum for openmpi-${OPENMPI_VERSION}.tar.bz2:"
            echo "MD5SUM is ${MD5SUM_OPENMPI}, expecting ${OPENMPI_MD5CHECKSUM}"
            exit 1
         fi
      fi
      tar -xjf openmpi-${OPENMPI_VERSION}.tar.bz2
      cd openmpi-${OPENMPI_VERSION}
      mkdir build && cd build

      OPENMPI_CONFIGURE_COMMAND="../configure \
         --prefix=${OPENMPI_PATH} \
         --with-rocm=${ROCM_PATH} \
         --with-ucx=${UCX_PATH} \
         --with-ucc=${UCC_PATH} \
         --enable-mca-no-build=btl-uct \
         --enable-mpi \
	 --enable-mpi-fortran \
         --disable-debug \
       	 CC=${C_COMPILER} CXX=${CXX_COMPILER} FC=${FC_COMPILER}"

      if [ "${BUILD_XPMEM}" == "1" ]; then
         OPENMPI_CONFIGURE_COMMAND="${OPENMPI_CONFIGURE_COMMAND} --with-xpmem=${XPMEM_PATH}"
      fi

      echo ""
      echo "OPENMPI_CONFIGURE_COMMAND: "
      echo "${OPENMPI_CONFIGURE_COMMAND}" | sed 's/\s\+/ \\\n   /g'
      echo ""

      ${OPENMPI_CONFIGURE_COMMAND}

      # S7.A: scale parallel build to all allocated cores instead of a
      # hardcoded 16 on a 48-core compute node. Audited as S7.A in
      # slurm-7935-rocmplus-7.0.1.out.
      make -j $(nproc)

      if [[ "${DRY_RUN}" == "0" ]]; then
         if [ -n "${SUDO_OPENMPI}" ]; then
            ${SUDO_OPENMPI} -E env "PATH=$PATH" make install
         else
            make install
         fi
         # S7.C: single gzip invocation across all man1 pages instead of
         # one sudo+gzip fork per file. With ~hundreds of man pages and
         # sudo's per-call overhead on NFS, the prior loop dominated the
         # tail of the install phase. Audited as S7.C in
         # slurm-7935-rocmplus-7.0.1.out.
         ${SUDO_OPENMPI} gzip ${OPENMPI_PATH}/share/man/man1/*
      fi
      # make ucx the default point-to-point
      echo "pml = ucx" | ${SUDO_OPENMPI} tee -a "${OPENMPI_PATH}"/etc/openmpi-mca-params.conf
      echo "osc = ucx" | ${SUDO_OPENMPI} tee -a "${OPENMPI_PATH}"/etc/openmpi-mca-params.conf
      echo "coll_ucc_enable = 1" | ${SUDO_OPENMPI} tee -a "${OPENMPI_PATH}"/etc/openmpi-mca-params.conf
      echo "coll_ucc_priority = 100" | ${SUDO_OPENMPI} tee -a "${OPENMPI_PATH}"/etc/openmpi-mca-params.conf
      cd ../..
      rm -rf openmpi-${OPENMPI_VERSION} openmpi-${OPENMPI_VERSION}.tar.bz2
   fi

   if [[ ! -d ${OPENMPI_PATH}/lib ]] ; then
      echo "OpenMPI installation failed -- missing installation directories"
      echo " OpenMPI Installation path is ${OPENMPI_PATH}"
      ls -l "${OPENMPI_PATH}"
      exit 1
   fi
fi

#sudo update-alternatives \
#   --install /usr/bin/mpirun    mpirun  ${OPENMPI_PATH}/bin/mpirun 80 \
#   --slave   /usr/bin/mpiexec   mpiexec ${OPENMPI_PATH}/bin/mpiexec \
#   --slave   /usr/share/man/man1/mpirun.1.gz   mpirun.1.gz ${OPENMPI_PATH}/share/man/man1/mpirun.1.gz
#
#sudo update-alternatives \
#   --install /usr/bin/mpi       mpi     ${OPENMPI_PATH}/bin/mpicc  80 \
#   --slave   /usr/bin/mpicc     mpicc   ${OPENMPI_PATH}/bin/mpicc     \
#   --slave   /usr/bin/mpic++    mpic++  ${OPENMPI_PATH}/bin/mpic++    \
#   --slave   /usr/bin/mpiCC     mpiCC   ${OPENMPI_PATH}/bin/mpiCC     \
#   --slave   /usr/bin/mpicxx    mpicxx  ${OPENMPI_PATH}/bin/mpicxx    \
#   --slave   /usr/bin/mpif77    mpif77  ${OPENMPI_PATH}/bin/mpif77    \
#   --slave   /usr/bin/mpif90    mpif90  ${OPENMPI_PATH}/bin/mpif90    \
#   --slave   /usr/bin/mpifort   mpifort ${OPENMPI_PATH}/bin/mpifort   \
#   --slave   /usr/share/man/man1/mpic++.1.gz   mpic++.1.gz ${OPENMPI_PATH}/share/man/man1/mpic++.1.gz    \
#   --slave   /usr/share/man/man1/mpicc.1.gz    mpicc.1.gz ${OPENMPI_PATH}/share/man/man1/mpicc.1.gz      \
#   --slave   /usr/share/man/man1/mpicxx.1.gz   mpicxx.1.gz ${OPENMPI_PATH}/share/man/man1/mpicxx.1.gz    \
#   --slave   /usr/share/man/man1/mpif77.1.gz   mpif77.1.gz ${OPENMPI_PATH}/share/man/man1/mpif77.1.gz    \
#   --slave   /usr/share/man/man1/mpif90.1.gz   mpif90.1.gz ${OPENMPI_PATH}/share/man/man1/mpif90.1.gz    \
#   --slave   /usr/share/man/man1/mpifort.1.gz  mpifort.1.gz ${OPENMPI_PATH}/share/man/man1/mpifort.1.gz

module unload rocm/${ROCM_VERSION}

# In either case of Cache or Build from source, create a module file for OpenMPI

if [[ "${DRY_RUN}" == "0" ]]; then

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
   if [[ "${ROCM_VERSION}" == "7.1.0" ]]; then
     # Need the legacy mode enabled as a workaround for a bcast bug

     cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${OPENMPI_VERSION}-ucc${UCC_VERSION}-ucx${UCX_VERSION}${XPMEM_STRING}.lua
	whatis("Name: GPU-aware openmpi")
	whatis("Version: openmpi-${OPENMPI_VERSION}-ucc${UCC_VERSION}-ucx${UCX_VERSION}${XPMEM_STRING}")
	whatis("Description: An open source Message Passing Interface implementation")
	whatis(" This is a GPU-Aware version of OpenMPI")
	whatis("URL: https://github.com/open-mpi/ompi.git")
	
	local base = "${OPENMPI_PATH}"
	
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("MPI_PATH","${OPENMPI_PATH}")
	setenv("MPICC","${OPENMPI_PATH}/bin/mpicc")
	setenv("MPICXX","${OPENMPI_PATH}/bin/mpicxx")
	setenv("MPIFORT","${OPENMPI_PATH}/bin/mpifort")
	setenv("HSA_ENABLE_IPC_MODE_LEGACY","1")
	prereq("rocm/${ROCM_VERSION}")
	family("MPI")
EOF
   else

     cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${OPENMPI_VERSION}-ucc${UCC_VERSION}-ucx${UCX_VERSION}${XPMEM_STRING}.lua
	whatis("Name: GPU-aware openmpi")
	whatis("Version: openmpi-${OPENMPI_VERSION}-ucc${UCC_VERSION}-ucx${UCX_VERSION}${XPMEM_STRING}")
	whatis("Description: An open source Message Passing Interface implementation")
	whatis(" This is a GPU-Aware version of OpenMPI")
	whatis("URL: https://github.com/open-mpi/ompi.git")
	
	local base = "${OPENMPI_PATH}"
	
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("MPI_PATH","${OPENMPI_PATH}")
	setenv("MPICC","${OPENMPI_PATH}/bin/mpicc")
	setenv("MPICXX","${OPENMPI_PATH}/bin/mpicxx")
	setenv("MPIFORT","${OPENMPI_PATH}/bin/mpifort")
	prereq("rocm/${ROCM_VERSION}")
	family("MPI")
EOF

   fi

fi

#git clone https://github.com/amd/HPCTrainingExamples
#cd HPCTrainingExamples/MPI-examples
#export OMPI_CXX=hipcc
#
#mpicxx -o ./pt2pt ./pt2pt.cpp
#mpirun -n 2 ./pt2pt
