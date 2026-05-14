#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Variables controlling setup process
: ${ROCM_VERSION:="6.0"}
# Delta-release support: when set, the named ROCm version is installed FIRST and
# then ${ROCM_VERSION} is layered on top, merged into /opt/rocm-${ROCM_VERSION}.
# See: ROCm 7.2.2 release notes (https://github.com/ROCm/ROCm/releases/tag/rocm-7.2.2)
# for the canonical example of a "delta release" that ships only a few packages
# and is intended to overlay an existing base install.
: ${BASE_ROCM_VERSION:=""}
# When set, a tombstone modulefile is emitted at rocm/${SUPERSEDES_VERSION}.lua
# that prints a deprecation LmodMessage and load()s rocm/${ROCM_VERSION}.
: ${SUPERSEDES_VERSION:=""}
REPLACE=0
MODULE_PATH=/etc/lmod/modules/ROCm
#if [[ ! "${MODULEPATH}" == *"/etc/lmod/modules/ROCm"* ]]; then
#   MODULE_PATH=/etc/lmod/modules
#fi

INCLUDE_TOOLS=0
# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_CODENAME=`cat /etc/os-release | grep '^VERSION_CODENAME' | sed -e 's/VERSION_CODENAME=//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# PKG_SUDO is independent of the install-path-derived SUDO: apt/dnf
# operate on root-owned /var/lib/{apt,dpkg,rpm} regardless of where the
# package files end up. See openmpi_setup.sh / audit_2026_05_01.md
# Issue 2.
PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")


usage()
{
   echo "Usage:"
   echo "  --replace default off"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --base-rocm-version [ VER ] for delta releases: install <VER> first, then merge $ROCM_VERSION on top (default: '')"
   echo "  --supersedes [ VER ] write a tombstone rocm/<VER>.lua that redirects to rocm/$ROCM_VERSION (default: '')"
   echo "  --python-version [ PYTHON_VERSION ] Python3 minor version, default not set"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --include-tools [INCLUDE_TOOLS] default $INCLUDE_TOOLS "
   echo "  --help: this usage information"
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
      "--help")
         usage
	 ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--replace")
          REPLACE=1
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--base-rocm-version")
          shift
          BASE_ROCM_VERSION=${1}
          reset-last
          ;;
      "--supersedes")
          shift
          SUPERSEDES_VERSION=${1}
          reset-last
          ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
          reset-last
          ;;
      "--include-tools")
          shift
          INCLUDE_TOOLS=${1}
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

version-set()
{
   VERSION_MAJOR=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $1}')
   VERSION_MINOR=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $2}')
   VERSION_PATCH=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $3}')

   ROCM_MAJOR=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $1}')
   ROCM_MINOR=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $2}')
   ROCM_PATCH=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $3}')
   if [ -n "${ROCM_PATCH}" ]; then
       ROCM_VERSN=$(( (${ROCM_MAJOR}*10000)+(${ROCM_MINOR}*100)+(${ROCM_PATCH}) ))
       ROCM_SEP="."
   else
       ROCM_VERSN=$(( (${ROCM_MAJOR}*10000)+(${ROCM_MINOR}*100) ))
       ROCM_SEP=""
   fi

   if [ "x${ROCM_PATCH}" == "x" ]; then
      AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}00-1
      AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}
   elif [ "${ROCM_PATCH}" == "0" ]; then
      AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
      AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}
   else
      if [[ "${ROCM_MAJOR}" == "6" ]]; then
         AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
      else
         AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_PATCH}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
      fi
      AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_PATCH}
   fi
}

# Resolve the path to the delta-release registry file (checked into the repo
# at bare_system/rocm_delta_releases.conf). LEAF_SCRIPT_PATH is captured at
# the top of this file, so this works whether rocm_setup.sh is invoked from
# the host or from inside the build container (which has the repo ADDed at
# /home/sysadmin/{bare_system,rocm,...}).
DELTA_RELEASES_CONF="$(cd "$(dirname "${LEAF_SCRIPT_PATH}")/../../bare_system" 2>/dev/null && pwd)/rocm_delta_releases.conf"

# Look up a ROCm version in the delta-release registry. Echoes the cached base
# version on stdout if the version is known; returns non-zero otherwise.
delta-release-lookup()
{
   local _ver="$1"
   [ -f "${DELTA_RELEASES_CONF}" ] || return 1
   awk -F= -v v="${_ver}" '
      /^[[:space:]]*#/ {next}
      /^[[:space:]]*$/ {next}
      $1 == v {print $2; found=1; exit}
      END {exit !found}
   ' "${DELTA_RELEASES_CONF}"
}

# Informational check: count how many leaf packages AMD's meta-packages would
# pull for ${ROCM_VERSION}. Full releases land at ~90; delta releases at ~4.
# Threshold of 20 separates them with a wide safety margin.
#
# Reads bare_system/rocm_delta_releases.conf FIRST to avoid an apt query for
# already-registered versions. When a delta is detected for an unregistered
# version, prints the exact line to append to the conf file so the next run
# skips this work.
#
# Effects: log lines only. Does not modify build behavior -- the build is
# driven by --base-rocm-version / --supersedes passed by the caller (the
# sweep, run_rocm_build.sh, or a human).
detect_release_type()
{
   local _ver="${1:-${ROCM_VERSION}}"
   local _cached
   if _cached="$(delta-release-lookup "${_ver}")"; then
      echo "[rocm_setup] release-type: ${_ver} is a known delta release (base=${_cached}, cached in ${DELTA_RELEASES_CONF})"
      return 0
   fi

   # Not in registry; run apt's resolver to count what would actually install.
   # Only meaningful when apt is configured AND the ${_ver} repo is reachable.
   if ! command -v apt-get >/dev/null 2>&1; then
      echo "[rocm_setup] release-type: apt-get not present; skipping resolver check for ${_ver}"
      return 0
   fi
   local _metas=(rocm rocm-dev rocm-hip-sdk rocm-hip-libraries \
                 rocm-developer-tools rocm-ml-sdk rocm-openmp-sdk \
                 rocm-opencl-sdk rocm-language-runtime)
   local _args=()
   for _m in "${_metas[@]}"; do
      apt-cache show "${_m}${_ver}" >/dev/null 2>&1 && _args+=("${_m}${_ver}")
   done
   if [ ${#_args[@]} -eq 0 ]; then
      echo "[rocm_setup] release-type: no meta packages found in apt cache for ${_ver}; skipping resolver check"
      return 0
   fi
   local _count
   _count=$(${PKG_SUDO} apt-get install -s -y "${_args[@]}" 2>/dev/null \
            | grep -cE "^Inst [^ ]+${_ver}( |\.)")
   echo "[rocm_setup] release-type: apt resolver would install ${_count} package(s) tagged ${_ver}"
   if [ "${_count}" -lt 20 ] && [ "${_count}" -gt 0 ]; then
      # Heuristic for the base: prior patch in the same MAJOR.MINOR series.
      local _maj _min _pat _base="?"
      _maj=$(echo "${_ver}" | awk -F. '{print $1}')
      _min=$(echo "${_ver}" | awk -F. '{print $2}')
      _pat=$(echo "${_ver}" | awk -F. '{print $3}')
      if [ -n "${_pat}" ] && [ "${_pat}" -gt 0 ] 2>/dev/null; then
         _base="${_maj}.${_min}.$((_pat - 1))"
      fi
      echo "[rocm_setup] NOTICE: ROCm ${_ver} appears to be a delta release (resolver returned ${_count} packages)."
      echo "[rocm_setup] To cache this finding, add the following line to bare_system/rocm_delta_releases.conf:"
      echo "[rocm_setup]     ${_ver}=${_base}"
      echo "[rocm_setup] Future builds will then skip this detection step."
   fi
   return 0
}

rocm-repo-dist-set()
{
   if [ "${DISTRO}" = "ubuntu" ]; then
       DISTRO_CODENAME=`cat /etc/os-release | grep '^VERSION_CODENAME' | sed -e 's/VERSION_CODENAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
       ROCM_REPO_DIST=${DISTRO_CODENAME}
   elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
       rhel-set
   elif [ "${DISTRO}" = "opensuse" ]; then
       opensuse-set
   fi
}

rhel-set()
{
   if [ -z "${VERSION_MINOR}" ]; then
       send-error "Please provide a major and minor version of the OS. Supported: >= 8.7, <= 9.1"
   fi

   # Components used to create the sub-URL below
   #   set <OS-DISTRO_VERSION> in amdgpu-install/<ROCM-VERSION>/rhel/<OS-DISTRO_VERSION>
   RPM_PATH=${VERSION_MAJOR}.${VERSION_MINOR}
   RPM_TAG=".el${VERSION_MAJOR}"

   # set the sub-URL in https://repo.radeon.com/amdgpu-install/<sub-URL>
   case "${ROCM_VERSION}" in
       5.4 | 5.4.*)
           ROCM_RPM=${ROCM_VERSION}/rhel/${RPM_PATH}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1${RPM_TAG}.noarch.rpm
           ;;
       5.3 | 5.3.*)
           ROCM_RPM=${ROCM_VERSION}/rhel/${RPM_PATH}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1${RPM_TAG}.noarch.rpm
           ;;
       5.2 | 5.2.* | 5.1 | 5.1.* | 5.0 | 5.0.* | 4.*)
           send-error "Invalid ROCm version ${ROCM_VERSION}. Supported: >= 5.3.0, <= 5.4.x"
           ;;
       0.0)
           ;;
       *)
           send-error "Unsupported combination :: ${DISTRO}-${DISTRO_VERSION} + ROCm ${ROCM_VERSION}"
           ;;
   esac

   # use Rocky Linux as a base image for RHEL builds
   DISTRO_BASE_IMAGE=rockylinux

}

opensuse-set()
{
   case "${DISTRO_VERSION}" in
       15.*)
           DISTRO_IMAGE="opensuse/leap"
           echo "DISTRO_IMAGE: ${DISTRO_IMAGE}"
           ;;
       *)
           send-error "Invalid opensuse version ${DISTRO_VERSION}. Supported: 15.x"
           ;;
   esac
   case "${ROCM_VERSION}" in
       5.4 | 5.4.*)
           ROCM_RPM=${ROCM_VERSION}/sle/${DISTRO_VERSION}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       5.3 | 5.3.*)
           ROCM_RPM=${ROCM_VERSION}/sle/${DISTRO_VERSION}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       5.2 | 5.2.*)
           ROCM_RPM=22.20${ROCM_SEP}${ROCM_PATCH}/sle/${DISTRO_VERSION}/amdgpu-install-22.20.${ROCM_VERSN}-1.noarch.rpm
           ;;
       5.1 | 5.1.*)
           ROCM_RPM=22.10${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-22.10${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       5.0 | 5.0.*)
           ROCM_RPM=21.50${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-21.50${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       4.5 | 4.5.*)
           ROCM_RPM=21.40${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-21.40${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       0.0)
           ;;
       *)
           send-error "Unsupported combination :: ${DISTRO}-${DISTRO_VERSION} + ROCm ${ROCM_VERSION}"
       ;;
   esac
   PERL_REPO="SLE_${VERSION_MAJOR}_SP${VERSION_MINOR}"
}

if [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   ROCM_REPO_DIST=${DISTRO_VERSION}
else
   ROCM_REPO_DIST=`lsb_release -c | cut -f2`
fi

#echo "After autodetection"
#echo "DISTRO is $DISTRO"
#echo "DISTRO_VERSION is $DISTRO_VERSION"
#echo ""

#echo "ROCM_VERSION is $ROCM_VERSION"
#echo ""
#echo "ROCM_REPO_DIST is $ROCM_REPO_DIST"
#echo ""

# This sets variations of the ROCM_VERSION needed by installers
# AMDGPU_ROCM_VERSION
# AMDGPU_INSTALL_VERSION
version-set

# If the caller did not specify --base-rocm-version, consult the registry.
# This makes the conf file the single source of truth: a sweep that calls
# rocm_setup.sh directly (without going through run_rocm_build_sweep.sh) still
# gets delta-release handling for any version listed in the conf.
if [ -z "${BASE_ROCM_VERSION}" ]; then
   if _cached_base="$(delta-release-lookup "${ROCM_VERSION}" 2>/dev/null)"; then
      echo "[rocm_setup] delta-release auto-config: ROCM_VERSION=${ROCM_VERSION} found in ${DELTA_RELEASES_CONF}; setting BASE_ROCM_VERSION=${_cached_base} SUPERSEDES_VERSION=${_cached_base}"
      BASE_ROCM_VERSION="${_cached_base}"
      [ -z "${SUPERSEDES_VERSION}" ] && SUPERSEDES_VERSION="${_cached_base}"
   fi
fi

echo ""
echo "=================================="
echo "Starting ROCm Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_REPO_DIST: $ROCM_REPO_DIST"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_ROCM_VERSION: $AMDGPU_ROCM_VERSION"
echo "AMDGPU_INSTALL_VERSION: $AMDGPU_INSTALL_VERSION"
echo "BASE_ROCM_VERSION: ${BASE_ROCM_VERSION:-<none>}"
echo "SUPERSEDES_VERSION: ${SUPERSEDES_VERSION:-<none>}"
echo "=================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [[ -d "/opt/rocm-${ROCM_VERSION}" ]] && [[ "${REPLACE}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
   exit
fi

INSTALL_PATH=/opt/rocm-${ROCM_VERSION}

   if [[ -d "${INSTALL_PATH}" ]] && [[ "${REPLACE}" != "0" ]] ; then
      ${SUDO} rm -rf ${INSTALL_PATH}
   fi

   # Delta-release mode bypasses the cache: a cached tarball at
   # ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz may be a previous build that
   # predates the base+delta merge logic (e.g. ROCm 7.2.2's broken ~8GB
   # delta-only install), so always go through the fresh amdgpu-install +
   # merge path when --base-rocm-version is set. Also nuke the stale tarball
   # so deploy_package.sh rewrites it from the merged tree.
   if [[ -n "${BASE_ROCM_VERSION}" ]] && [[ -f ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz ]]; then
      echo "[rocm_setup] delta-release mode: removing stale cached tarball ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz to force a fresh base+delta+merge build"
      ${SUDO} rm -f "${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz"
   fi

   if [[ -z "${BASE_ROCM_VERSION}" ]] && [[ -f ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached ROCm"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz"
      cd /opt
      ${SUDO} tar -xzf ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz
      ${SUDO} chown -R root:root ${INSTALL_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz
      fi
      ROCM_ALTERNATIVES_BIN_LIST="amd-smi clinfo hipcc hipcc.bin hipcc_cmake_linker_helper hipcc.pl hipconfig hipconfig.bin hipconfig.pl hipconvertinplace-perl.sh hipconvertinplace.sh hipdemangleatp hipexamine-perl.sh hipexamine.sh hipify-clang hipify-perl roccoremerge rocgdb rocm_agent_enumerator rocminfo rocm-smi roc-obj roc-obj-extract roc-obj-ls rocprof rocprofv2 rocsys"
      for file in $ROCM_ALTERNATIVES_BIN_LIST
      do
         ${SUDO} update-alternatives --install /usr/bin/$file $file /opt/rocm-${ROCM_VERSION}/bin/$file 100
      done
      ${SUDO} update-alternatives --install /opt/rocm rocm /opt/rocm-${ROCM_VERSION} 100

   else

# if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
# if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" ]]; then # ROCM_VERSION >= 6.2
         INCLUDE_TOOLS=1
      fi

      if [ "${DISTRO}" == "ubuntu" ]; then
         ${PKG_SUDO} apt-get update

         # KNOWN ENV LEAK: amdgpu-install (invoked below) internally calls
         # `sudo apt-get install`, and the inner sudo strips DEBIAN_FRONTEND
         # from the outer process even when we wrap with
         # `DEBIAN_FRONTEND=... sudo amdgpu-install ...`. tzdata gets pulled
         # in as a transitive dep of ROCm packages (or of x11-common, libpq5,
         # etc. in the same install txn) and triggers an interactive
         # "Geographic area:" prompt that hangs the build forever. Pre-install
         # + pre-configure tzdata up front so dpkg never has to ask.
         #
         # Required for both delta-release and full-release builds: full
         # releases (e.g. ROCm 7.2.3) hit this on the first `amdgpu-install
         # --rocmrelease=<ver>` call below; delta releases (e.g. 7.2.2 -> 7.2.1
         # base) hit it on the base install in the BASE_ROCM_VERSION branch.
         # Doing it once here covers both paths.
         echo "[rocm_setup] pre-configuring tzdata to defeat interactive prompt during ROCm install"
         echo "Etc/UTC" | ${SUDO} tee /etc/timezone > /dev/null
         ${SUDO} ln -fs /usr/share/zoneinfo/Etc/UTC /etc/localtime
         ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y tzdata
         ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive dpkg-reconfigure --frontend=noninteractive tzdata

         ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y libdrm-dev logrotate

         #mkdir --parents --mode=0755 /etc/apt/keyrings
         #${SUDO} mkdir --parents --mode=0755 /etc/apt/keyrings

         # The installation below makes use of an AMD provided install script

         result1=`echo $ROCM_VERSION | awk '$1>6.3.0'` && echo "result at line 300 is ",$result1
         result2=`echo $ROCM_VERSION | awk '$1>6.3.5'` && echo "result at line 301 is ",$result2
         if [[ "${result1}" != "$ROCM_VERSION" ]] && [[ "${result2}" ]]; then # ROCM_VERSION < 6.3.0 and > 6.3.5
            # Get the key for the ROCm software
            wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | ${SUDO} tee /etc/apt/keyrings/rocm.gpg > /dev/null
         fi

         # Update package list
         ${PKG_SUDO} apt-get update

         # Get the amdgpu-install script
         wget -q https://repo.radeon.com/amdgpu-install/${AMDGPU_ROCM_VERSION}/${DISTRO}/${ROCM_REPO_DIST}/amdgpu-install_${AMDGPU_INSTALL_VERSION}_all.deb

         # Run the amdgpu-install script. We have already installed the kernel driver, so use we use --no-dkms
         ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y --allow-downgrades ./amdgpu-install_${AMDGPU_INSTALL_VERSION}_all.deb

         # Delta-release support: install the base version FIRST so the delta
         # (rocm-llvm + rocm-core + rocm-device-libs only, for the 7.2.2 case)
         # has a real ROCm tree to layer onto when merged below. amdgpu-install
         # with --rocmrelease registers the corresponding apt source on the fly.
         #
         # KNOWN AMD BUG: The amdgpu-install package for ROCm 7.2.2 adds an
         # apt source for repo.radeon.com/graphics/7.2.2/ubuntu that returns
         # 404 (AMD never published a graphics driver tagged "7.2.2"; the
         # graphics tree is keyed off the AMDGPU driver version like "30.30.2"
         # instead). This makes every subsequent apt-get update -- including
         # the one amdgpu-install runs internally during --rocmrelease=<base>
         # -- fail and abort the install. Disable any broken graphics/<v>
         # source before running the base install. Safe to leave disabled
         # since we don't install graphics drivers in this build path.
         if [ -n "${BASE_ROCM_VERSION}" ]; then
            # KNOWN AMD BUG #1: The amdgpu-install package for ROCm 7.2.2 adds
            # an apt source for repo.radeon.com/graphics/7.2.2/ubuntu that
            # returns 404 (AMD never published a graphics driver tagged "7.2.2";
            # the graphics tree is keyed off the AMDGPU driver version like
            # "30.30.2" instead). This makes every subsequent apt-get update
            # fail. Disable any broken graphics/<v> source. Safe to leave
            # disabled since we don't install graphics drivers in this path.
            echo "[rocm_setup] delta-release mode: disabling broken repo.radeon.com/graphics/<v>/ubuntu apt sources before base install"
            for _src in /etc/apt/sources.list.d/*.list; do
               [ -f "${_src}" ] || continue
               if grep -qE 'repo\.radeon\.com/graphics/[^/]+/ubuntu' "${_src}"; then
                  ${SUDO} sed -i.delta-bak -E \
                     's|^(deb.*repo\.radeon\.com/graphics/[^/]+/ubuntu.*)$|# disabled by rocm_setup delta-release path: \1|' \
                     "${_src}"
                  echo "[rocm_setup]   disabled graphics source in ${_src}"
               fi
            done
            unset _src

            # KNOWN AMD BUG #2: `amdgpu-install --rocmrelease=<base>` does NOT
            # dynamically add the apt source for <base>. Only the installer's
            # own tagged version (the DELTA, e.g. 7.2.2) has a configured
            # source after `apt install amdgpu-install_<delta>.deb`. So we
            # add the BASE rocm apt source manually before the base install.
            # The GPG keyring at /etc/apt/keyrings/rocm.gpg was set up by an
            # earlier block (or by the delta amdgpu-install .deb).
            echo "[rocm_setup] delta-release mode: adding rocm/apt/${BASE_ROCM_VERSION} apt source for base install"
            if [ ! -f /etc/apt/keyrings/rocm.gpg ]; then
               ${SUDO} mkdir -p /etc/apt/keyrings
               wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | ${SUDO} tee /etc/apt/keyrings/rocm.gpg > /dev/null
            fi
            echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${BASE_ROCM_VERSION} ${ROCM_REPO_DIST} main" \
               | ${SUDO} tee /etc/apt/sources.list.d/rocm-${BASE_ROCM_VERSION}.list > /dev/null
            ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get update

            # tzdata pre-configuration to defeat the interactive
            # "Geographic area:" prompt during the base amdgpu-install is
            # done unconditionally near the top of this Ubuntu branch (see
            # the "KNOWN ENV LEAK" block earlier). No per-branch fix needed
            # here.

            echo "[rocm_setup] delta-release mode: pre-installing base ROCm ${BASE_ROCM_VERSION} before ${ROCM_VERSION}"
            ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive amdgpu-install -q -y \
               --usecase=hiplibsdk,rocmdev,rocmdevtools,lrt,openclsdk,openmpsdk,mlsdk \
               --no-dkms --rocmrelease=${BASE_ROCM_VERSION}
            if [ ! -d "/opt/rocm-${BASE_ROCM_VERSION}" ]; then
               send-error "Base ROCm install failed: /opt/rocm-${BASE_ROCM_VERSION} not present after amdgpu-install"
            fi
         fi
      elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
	 ${PKG_SUDO} dnf config-manager --set-enabled crb
         ${PKG_SUDO} dnf install -y python3-setuptools python3-wheel python3-devel
#	 ${PKG_SUDO} dnf --enablerepo=crb install python3-wheel -y
#	 ${PKG_SUDO} dnf install python3-setuptools python3-wheel -y

	 ${SUDO} touch /etc/yum.repos.d/rocm.repo
	 ${SUDO} chmod a+w /etc/yum.repos.d/rocm.repo

	 cat <<-EOF | ${SUDO} tee -a /etc/yum.repos.d/rocm.repo
	[ROCm-${AMDGPU_ROCM_VERSION}]
	name=ROCm${AMDGPU_ROCM_VERSION}
	baseurl=https://repo.radeon.com/rocm/rhel9/${AMDGPU_ROCM_VERSION}/main
	enabled=1
	priority=50
	gpgcheck=1
	gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
EOF
         cat /etc/yum.repos.d/rocm.repo

	 echo "${PKG_SUDO} dnf install -y https://repo.radeon.com/amdgpu-install/${AMDGPU_ROCM_VERSION}/rhel/${DISTRO_VERSION}/amdgpu-install-${AMDGPU_INSTALL_VERSION}.el9.noarch.rpm"
	 ${PKG_SUDO} dnf install -y https://repo.radeon.com/amdgpu-install/${AMDGPU_ROCM_VERSION}/rhel/${DISTRO_VERSION}/amdgpu-install-${AMDGPU_INSTALL_VERSION}.el9.noarch.rpm

         # Delta-release support (RHEL-compatible path): see Ubuntu branch above.
         if [ -n "${BASE_ROCM_VERSION}" ]; then
            echo "[rocm_setup] delta-release mode: pre-installing base ROCm ${BASE_ROCM_VERSION} before ${ROCM_VERSION}"
            ${PKG_SUDO} amdgpu-install -q -y \
               --usecase=hiplibsdk,rocmdev,rocmdevtools,lrt,openclsdk,openmpsdk,mlsdk \
               --no-dkms --rocmrelease=${BASE_ROCM_VERSION}
            if [ ! -d "/opt/rocm-${BASE_ROCM_VERSION}" ]; then
               send-error "Base ROCm install failed: /opt/rocm-${BASE_ROCM_VERSION} not present after amdgpu-install"
            fi
         fi
      fi
# if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
# if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" ]]; then # ROCM_VERSION >= 6.2
         result=`echo $DISTRO_VERSION | awk '$1>24.00'` && echo $result
         if [[ "${result}" ]]; then
            # rocm-asan not available in Ubuntu 24.04
            amdgpu-install -q -y --usecase=hiplibsdk,rocmdev,rocmdevtools,lrt,openclsdk,openmpsdk,mlsdk --no-dkms --rocmrelease=${ROCM_VERSION}
	 else
            # removing asan to reduce image size
            #amdgpu-install -q -y --usecase=hiplibsdk,rocmdev,lrt,openclsdk,openmpsdk,mlsdk,asan --no-dkms
            amdgpu-install -q -y --usecase=hiplibsdk,rocmdev,rocmdevtools,lrt,openclsdk,openmpsdk,mlsdk --no-dkms --rocmrelease=${ROCM_VERSION}
            #${PKG_SUDO} apt-get install rocm_bandwidth_test
	 fi
         if [ "${DISTRO}" == "ubuntu" ]; then
            ${PKG_SUDO} apt-get install -y rocm-llvm-dev${ROCM_VERSION} rocm-device-libs${ROCM_VERSION} rocm-core${ROCM_VERSION} rocm-llvm${ROCM_VERSION}
         #elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
            # error message that rocm-llvm-dev does not exist
            #${PKG_SUDO} dnf install -y rocm-llvm-dev
	 fi
      else # ROCM_VERSION < 6.2
         amdgpu-install -q -y --usecase=hiplibsdk,rocm --no-dkms --rocmrelease=${ROCM_VERSION}
      fi

#      if [[ ! -f /opt/rocm-${ROCM_VERSION}/.info/version-dev ]]; then
#         # Required by DeepSpeed
#	 # Exists in Ubuntu 24.04 and not 22.04
#         ${SUDO} ln -s /opt/rocm-${ROCM_VERSION}/.info/version /opt/rocm-${ROCM_VERSION}/.info/version-dev
#      fi

      rm -rf amdgpu-install_${AMDGPU_INSTALL_VERSION}_all.deb
   fi
   amdgpu-install -q -y --usecase=rocm,hip,hiplibsdk --no-dkms --rocmrelease=${ROCM_VERSION}

   # Delta-release merge: when --base-rocm-version was supplied, the base was
   # installed at /opt/rocm-${BASE_ROCM_VERSION} above and the delta packages
   # have landed at /opt/rocm-${ROCM_VERSION}. Merge the base into the delta
   # tree with the delta taking precedence (rsync --ignore-existing), then
   # remove the base tree so deploy_package.sh tarballs only the merged tree.
   if [ -n "${BASE_ROCM_VERSION}" ] && [ -d "/opt/rocm-${BASE_ROCM_VERSION}" ]; then
      echo ""
      echo "================================================"
      echo " Merging base ROCm ${BASE_ROCM_VERSION} into ${ROCM_VERSION}"
      echo "================================================"
      echo ""
      if ! command -v rsync >/dev/null 2>&1; then
         if [ "${DISTRO}" == "ubuntu" ]; then
            ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y rsync
         elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
            ${PKG_SUDO} dnf install -y rsync
         fi
      fi
      # --ignore-existing: delta files at /opt/rocm-${ROCM_VERSION} win over
      # base files of the same relative path. -a preserves perms/symlinks.
      ${SUDO} rsync -a --ignore-existing \
         "/opt/rocm-${BASE_ROCM_VERSION}/" \
         "/opt/rocm-${ROCM_VERSION}/"
      echo "[rocm_setup] removing base tree /opt/rocm-${BASE_ROCM_VERSION} (now merged into /opt/rocm-${ROCM_VERSION})"
      ${SUDO} rm -rf "/opt/rocm-${BASE_ROCM_VERSION}"

      # Delta-merge orphan-shared-lib cleanup. ONLY fires in this
      # delta-release branch (gated by --base-rocm-version).
      #
      # Why this is needed: `rsync --ignore-existing` only suppresses
      # overwrites of IDENTICALLY NAMED paths. When the base and the
      # delta SDKs ship the same library at different patch versions --
      # e.g. ${BASE_ROCM_VERSION}=7.2.1 contributes
      #   librocm_smi64.so.1.0.70201
      # and ${ROCM_VERSION}=7.2.2 contributes
      #   librocm_smi64.so.1.0.70202
      # -- BOTH versioned files end up side-by-side in the merged lib
      # dir. The SONAME symlink (librocm_smi64.so.1) resolves to the
      # DELTA file because the symlink existed in BOTH trees and
      # --ignore-existing kept delta's. Bazel's rocm_configure glob
      # then aborts the tensorflow build with
      #   Error in fail: attribute srcs: Trying to link twice a library
      #     with the same identifier '.../librocm_smi64.so.1.0',files:
      #     .../librocm_smi64.so.1.0.70202 and
      #     .../librocm_smi64.so.1.0.70201
      # (slurm-9002 / log_tensorflow_05_11_2026.txt:504 from the
      # 2026-05-11 sweep).
      #
      # Walk each canonical ROCm lib dir, follow every SONAME symlink
      # (form: lib*.so.MAJOR, single integer after .so.) to its real
      # file, and rm any sibling versioned file (lib*.so.MAJOR.*) that
      # is NOT the resolved target. Conservative: only files with the
      # exact same lib-prefix as a live SONAME symlink are considered,
      # and only real (non-symlink) files are removed.
      echo ""
      echo "================================================"
      echo " Delta-merge orphan-shared-lib cleanup"
      echo "================================================"
      stale_total=0
      for LIB_DIR in \
         "/opt/rocm-${ROCM_VERSION}/lib" \
         "/opt/rocm-${ROCM_VERSION}/lib64" \
         "/opt/rocm-${ROCM_VERSION}/llvm/lib" ; do
         [ -d "${LIB_DIR}" ] || continue
         [ -L "${LIB_DIR}" ] && continue   # skip e.g. lib64 -> lib symlink
         for soname in "${LIB_DIR}"/*.so.*; do
            [ -L "${soname}" ] || continue
            bn="$(basename "${soname}")"
            after_so="${bn#*.so.}"
            case "${after_so}" in
               *.*) continue ;;            # multi-component .so.X.Y.* -- not a SONAME symlink
            esac
            [[ "${after_so}" =~ ^[0-9]+$ ]] || continue
            tgt="$(readlink "${soname}")"
            [ "${tgt:0:1}" = "/" ] || tgt="${LIB_DIR}/${tgt}"
            _hops=0
            while [ -L "${tgt}" ] && [ ${_hops} -lt 10 ]; do
               next="$(readlink "${tgt}")"
               if [ "${next:0:1}" = "/" ]; then
                  tgt="${next}"
               else
                  tgt="$(dirname "${tgt}")/${next}"
               fi
               _hops=$((_hops + 1))
            done
            keep="$(basename "${tgt}")"
            for sib in "${soname}".*; do
               [ -f "${sib}" ] && [ ! -L "${sib}" ] || continue
               sibname="$(basename "${sib}")"
               [ "${sibname}" = "${keep}" ] && continue
               # Safety filter: only remove pure-numeric-version-suffix
               # siblings (e.g. librocm_smi64.so.1.0.70201). Skip files
               # with non-numeric suffixes such as `.orig` (rocm_patches.sh
               # swap_sdk_lib_symlink rollback backups), `.debug`, etc.
               suffix="${sib#${soname}.}"
               [[ "${suffix}" =~ ^[0-9.]+$ ]] || continue
               echo "[rocm_setup] delta-merge cleanup: rm ${sib}"
               echo "                                  (SONAME ${bn} -> ${keep})"
               ${SUDO} rm -f "${sib}"
               stale_total=$((stale_total + 1))
            done
         done
      done
      echo "[rocm_setup] delta-merge cleanup: removed ${stale_total} orphan versioned shared-lib file(s)"

      echo "[rocm_setup] merged tree size:"
      ${SUDO} du -sh "/opt/rocm-${ROCM_VERSION}" || true
   fi
#else
#   echo "DISTRO version ${DISTRO} not recognized or supported"
#   exit
#fi

# rocm-validation-suite is optional
#apt-get install -qy rocm-validation-suite

# Uncomment the appropriate one for your system if you want
# to hardwire the code generation
#RUN echo "gfx90a" > /opt/rocm/bin/target.lst
#RUN echo "gfx908" >>/opt/rocm/bin/target.lst
#RUN echo "gfx906" >>/opt/rocm/bin/target.lst
#RUN echo "gfx1030" >>/opt/rocm/bin/target.lst

#ENV ROCM_TARGET_LST=/opt/rocm/bin/target.lst

#RUN mkdir -p rocinfo \
#    && cd rocinfo \
#    && git clone  https://github.com/RadeonOpenCompute/rocminfo.git \
#    && cd rocminfo  \
#    && ls -lsa  \
#    && mkdir -p build \
#    && cd build  \
#    && cmake -DCMAKE_PREFIX_PATH=/opt/rocm .. \
#    && make install

#RUN if [ "${ROCM_VERSION}" != "0.0" ]; then \
#        if [ -d /etc/apt/trusted.gpg.d ]; then \
#            wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/trusted.gpg.d/rocm.gpg; \
#        else \
#            wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | apt-key add -; \
#        fi && \
#        echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/${ROCM_REPO_VERSION}/ ${ROCM_REPO_DIST} main" | tee /etc/apt/sources.list.d/rocm.list && \
#        apt-get update && \
#        apt-get dist-upgrade -y && \
#        apt-get install -y hsa-amd-aqlprofile hsa-rocr-dev hsakmt-roct-dev && \
#        apt-get install -y hip-base hip-runtime-amd hip-dev && \
#        apt-get install -y rocm-llvm rocm-core rocm-smi-lib rocm-device-libs && \
#        apt-get install -y roctracer-dev rocprofiler-dev rccl-dev ${EXTRA_PACKAGES} && \
#        apt-get install -y rocfft  hipfft  rocm-libs rocsolver rocblas && \
#        apt-get install -y rocminfo rocm-bandwidth-test  && \
#        if [ "$(echo ${ROCM_VERSION} | awk -F '.' '{print $1}')" -lt "5" ]; then apt-get install -y rocm-dev; fi && \
#        apt-get autoclean; \
#    fi

# Derive ROCM_MODULE_NAME from the actual ROCM_PATH basename so RC
# trees (rocm-therock-*, rocm-afar-*) match their loaded module name
# instead of the SDK numeric. Falls back to the rocm/<version> form
# (e.g. fresh-install path where ROCM_PATH is unset and this script
# is the one materializing the modulefile being prereq'd).
if [[ -n "${ROCM_PATH:-}" ]]; then
   _rp_bn="${ROCM_PATH##*/}"
   ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
   unset _rp_bn
else
   ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
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

# set up up module files

# Create a module file for rocm sdk
MODULE_PATH=${MODULE_PATH}/rocm

${SUDO} mkdir -p ${MODULE_PATH}

# autodetecting default version for distro and getting available gcc version list
GCC_BASE_VERSION=`ls /usr/bin/gcc-* | cut -f2 -d'-' | grep '^[[:digit:]]' | head -1`

if [ "${DISTRO}" == "ubuntu" ]; then
# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ROCm")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("ROCm")
	whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")

	local base = "/opt/rocm-${ROCM_VERSION}"
	local mbase = " /etc/lmod/modules/ROCm/rocm"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	setenv("HSA_NO_SCRATCH_RECLAIM","1")
	setenv("HIPCC_COMPILE_FLAGS_APPEND","--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/${GCC_BASE_VERSION}")
	setenv("HIPCC_LINK_FLAGS_APPEND","--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/${GCC_BASE_VERSION}")
	prepend_path("MODULEPATH", pathJoin(mbase, "rocm-${ROCM_VERSION}"))
	prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-${ROCM_VERSION}"))
	setenv("ROCM_PATH", base)
	family("GPUSDK")
EOF
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ROCm")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("ROCm")
	whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")

	local base = "/opt/rocm-${ROCM_VERSION}"
	local mbase = " /etc/lmod/modules/ROCm/rocm"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	prepend_path("MODULEPATH", pathJoin(mbase, "rocm-${ROCM_VERSION}"))
	prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-${ROCM_VERSION}"))
	setenv("ROCM_PATH", base)
	family("GPUSDK")
EOF
fi

# Delta-release tombstone: when --supersedes is set, write a deprecation
# modulefile at rocm/<SUPERSEDES_VERSION>.lua that redirects to the merged
# tree provided by this build. Overwrites any prior rocm/<SUPERSEDES_VERSION>.lua
# on the host when the modules tarball is extracted. The tombstone has NO
# family() call -- load("rocm/${ROCM_VERSION}") inherits family("GPUSDK")
# from the target module, avoiding family-collision errors.
if [ -n "${SUPERSEDES_VERSION}" ] && [ "${SUPERSEDES_VERSION}" != "${ROCM_VERSION}" ]; then
   echo "[rocm_setup] writing tombstone modulefile: rocm/${SUPERSEDES_VERSION} -> rocm/${ROCM_VERSION}"
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${SUPERSEDES_VERSION}.lua
	whatis("Name: ROCm (DEPRECATED)")
	whatis("Version: ${SUPERSEDES_VERSION} [superseded by ${ROCM_VERSION}]")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Category: AMD")
	whatis("ROCm ${SUPERSEDES_VERSION} is superseded by ${ROCM_VERSION}")
	whatis("Reason: see https://github.com/ROCm/ROCm/releases/tag/rocm-${ROCM_VERSION}")

	LmodMessage("[NOTICE] rocm/${SUPERSEDES_VERSION} is superseded by rocm/${ROCM_VERSION}; loading rocm/${ROCM_VERSION} instead.")
	load("rocm/${ROCM_VERSION}")
EOF
fi

# Create a module file for amdclang compiler
export MODULE_PATH=/etc/lmod/modules/ROCm/amdclang

${SUDO} mkdir -p ${MODULE_PATH}
AMDCLANG_VERSION=`/opt/rocm-${ROCM_VERSION}/llvm/bin/amdclang --version |head -1 | cut -f 4 -d' ' | tr -d -c '[:digit:]\.'`

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${AMDCLANG_VERSION}-${ROCM_VERSION}.lua
	whatis("Name: AMDCLANG")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("AMDCLANG")

	local base = "/opt/rocm-${ROCM_VERSION}/llvm"
	local rocm_base = "/opt/rocm-${ROCM_VERSION}"
	local mbase = "/etc/lmod/modules/ROCm/amdclang"

	setenv("CC", pathJoin(base, "bin/amdclang"))
	setenv("CXX", pathJoin(base, "bin/amdclang++"))
	setenv("FC", pathJoin(base, "bin/amdflang"))
	setenv("OMPI_CC", pathJoin(base, "bin/amdclang"))
	setenv("OMPI_CXX", pathJoin(base, "bin/amdclang++"))
	setenv("OMPI_FC", pathJoin(base, "bin/amdflang"))
	setenv("F77", pathJoin(base, "bin/amdflang"))
	setenv("F90", pathJoin(base, "bin/amdflang"))
	setenv("STDPAR_PATH", pathJoin(rocm_base, "include/thrust/system/hip/hipstdpar"))
	setenv("STDPAR_CXX", pathJoin(base, "bin/amdclang++"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_RUN_PATH", pathJoin(base, "lib"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prereq("${ROCM_MODULE_NAME}")
	family("compiler")
EOF

# Create a module file for hipfort package
export MODULE_PATH=/etc/lmod/modules/ROCm/hipfort

${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ROCm HIPFort")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${ROCM_VERSION}")
	load("amdclang")
	local base = "/opt/rocm-${ROCM_VERSION}"
	append_path("LD_LIBRARY_PATH", pathJoin(base, "/lib"))
	setenv("LIBS", "-L" .. pathJoin(base, "/lib") .. " -lhipfort-amdgcn.a")
	setenv("HIPFORT_LIB", pathJoin(base, "/lib"))
	setenv("HIPFORT_INC", pathJoin(base, "/include/hipfort"))
EOF

# Create a module file for opencl compiler
export MODULE_PATH=/etc/lmod/modules/ROCm/opencl

${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ROCm OpenCL")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("ROCm OpenCL")

	local base = "/opt/rocm-${ROCM_VERSION}/opencl"
	local mbase = " /etc/lmod/modules/ROCm/opencl"

	prepend_path("PATH", pathJoin(base, "bin"))
	family("OpenCL")
EOF

echo "DEBUG INCLUDE_TOOLS is ${INCLUDE_TOOLS}"

if [ "${INCLUDE_TOOLS}" = "1" ]; then

   # if ROCM_VERSION is greater than equal to 7.1.0, the sort by version will give the smaller ROCM_VERSION number
   if [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" != "7.1.0" ]; then

      TOOL_NAME=omnitrace
      TOOL_EXEC_NAME=omnitrace
      TOOL_NAME_MC=Omnitrace
      TOOL_NAME_UC=OMNITRACE
      # if ROCM_VERSION is greater than 6.2.9, the awk command will give the ROCM_VERSION number
      result=`echo ${ROCM_VERSION} | awk '$1>6.2.9'` && echo $result
      if [[ "${result}" ]]; then
         TOOL_NAME=rocprofiler-systems
         TOOL_EXEC_NAME=rocprof-sys-avail
         TOOL_NAME_MC=Rocprofiler-systems
         TOOL_NAME_UC=ROCPROFILER_SYSTEMS
      fi

      echo ""
      echo "=================================="
      echo "Starting ROCm ${TOOL_NAME_MC} Install with"
      echo "DISTRO: $DISTRO"
      echo "DISTRO_VERSION: $DISTRO_VERSION"
      echo "ROCM_VERSION: $ROCM_VERSION"
      echo "AMDGPU_ROCM_VERSION: $AMDGPU_ROCM_VERSION"
      echo "AMDGPU_INSTALL_VERSION: $AMDGPU_INSTALL_VERSION"
      echo "=================================="
      echo ""

      # if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
      # if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" == "" ]]; then
         echo "ROCm built-in ${TOOL_NAME_MC} version cannot be installed on ROCm versions before 6.2.0"
         exit
      fi
      if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
         echo "ROCm built-in ${TOOL_NAME_MC} already installed"
      else
         if [ "${DISTRO}" == "ubuntu" ]; then
            ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y ${TOOL_NAME}
         fi
      fi

      # if ROCM_VERSION is greater than equal to 7.1.0, the sort by version will give the smaller ROCM_VERSION number
      if [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" != "7.1.0" ]; then
         if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
            export MODULE_PATH=/etc/lmod/modules/ROCm/${TOOL_NAME}
            ${SUDO} mkdir -p ${MODULE_PATH}
            # The - option suppresses tabs
         cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ${TOOL_NAME}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("${TOOL_NAME}")

        -- Export environmental variables
        local topDir="/opt/rocm-${ROCM_VERSION}"
        local binDir="/opt/rocm-${ROCM_VERSION}/bin"
        local shareDir="/opt/rocm-${ROCM_VERSION}/share/${TOOL_NAME}"

        setenv("${TOOL_NAME_UC}_DIR",topDir)
        setenv("${TOOL_NAME_UC}_BIN",binDir)
        setenv("${TOOL_NAME_UC}_SHARE",shareDir)
        prepend_path("PATH", pathJoin(shareDir, "bin"))

	prereq("${ROCM_MODULE_NAME}")
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
EOF

         fi
      fi
   fi

   TOOL_NAME=omniperf
   TOOL_EXEC_NAME=omniperf
   TOOL_NAME_MC=Omniperf
   TOOL_NAME_UC=OMNIPERF
   # if ROCM_VERSION is greater than 6.2.9, the awk command will give the ROCM_VERSION number
   result=`echo ${ROCM_VERSION} | awk '$1>6.2.9'` && echo $result
   if [[ "${result}" ]]; then
      TOOL_NAME=rocprofiler-compute
      TOOL_EXEC_NAME=rocprof-compute
      TOOL_NAME_MC=Rocprofiler-compute
      TOOL_NAME_UC=ROCPROFILER_COMPUTE
   fi

   echo ""
   echo "=================================="
   echo "Starting ROCm ${TOOL_NAME_MC} Install with"
   echo "DISTRO: $DISTRO"
   echo "DISTRO_VERSION: $DISTRO_VERSION"
   echo "ROCM_VERSION: $ROCM_VERSION"
   echo "=================================="
   echo ""

   # ROCm 7.1.0+: the rocprof-compute nuitka onefile build that used to
   # live inline here has been moved to rocm/scripts/rocm_patches.sh
   # (rocm/sources/rocm-patches/rocprof-compute/{build,install}.sh).
   # That overlay both builds the nuitka onefile and prepends its bin/
   # to PATH in the rocm/X.Y.Z module, so there is nothing for
   # rocm_setup.sh to do here -- the SDK already ships the Python
   # wrapper at ${ROCM_PATH}/bin/rocprof-compute via amdgpu-install,
   # and rocm_patches.sh's overlay supersedes it via PATH ordering.
   # See rocm_patches.sh's rocm_version_to_patches() for the dispatch
   # table.
   if [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" = "7.1.0" ]; then
      echo "[rocm_setup] rocprof-compute build for ROCm ${ROCM_VERSION} is handled by rocm_patches.sh; skipping inline nuitka build"

   else

      # if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
      # if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" == "" ]]; then
         echo "ROCm built-in ${TOOL_NAME_MC} version cannot be installed on ROCm versions before 6.2.0"
         exit
      fi
      if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
         echo "ROCm built-in ${TOOL_NAME_MC} already installed"
      else
         if [ "${DISTRO}" == "ubuntu" ]; then
            ${PKG_SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y ${TOOL_NAME}
         fi
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w /opt/rocm-${ROCM_VERSION}
      fi

      PYTHON=python3
      if [ "${PYTHON_VERSION}" != "" ]; then
         PYTHON=python3.${PYTHON_VERSION}
      fi

      ${PYTHON} -m pip install -t /opt/rocm-${ROCM_VERSION}/libexec/${TOOL_NAME}/python-libs -r /opt/rocm-${ROCM_VERSION}/libexec/${TOOL_NAME}/requirements.txt

#     if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then

#        python3 -m venv rocprof-compute-exec
#        source rocprof-compute-exec/bin/activate
#        pip install pyinstaller
#        pip install -r /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/requirements.txt

#        if [[ -f /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/VERSION.sha ]]; then
#           pyinstaller --onefile /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/rocprof-compute \
#             --add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/utils:utils" \
#             --add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/VERSION:." \
#             --add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/VERSION.sha:." \
#             --distpath rocprof-compute-exec/dist
#        else
#           pyinstaller --onefile /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/rocprof-compute \
#             --add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute:." \
#             --distpath rocprof-compute-exec/dist
#             #--add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/utils:utils" \
#             #--add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/rocprof_compute_soc:rocprof_compute_soc" \
#        fi

#        ls -RC rocprof-compute-exec/dist/
#        rocprof-compute-exec/dist/rocprof-compute --version
#        ${SUDO} cp rocprof-compute-exec/dist/rocprof-compute /opt/rocm-${ROCM_VERSION}/bin/rocprof-compute.exe
#        #${SUDO} rm -f /opt/rocm-${ROCM_VERSION}/bin/rocprof-compute
#        #cd /opt/rocm-${ROCM_VERSION}/bin && ${SUDO} ln -s rocprof-compute.exe rocprof-compute && cd -
#        rocprof-compute --version
#        deactivate
#        rm -rf rocprof-compute-exec

#        # Restore original version
#        #${SUDO} rm -f /opt/rocm-${ROCM_VERSION}/bin/rocprof-compute
#        #cd /opt/rocm-${ROCM_VERSION}/bin && ${SUDO} ln -s ../libexec/rocprofiler-compute rocprof-compute && cd -
#     fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w /opt/rocm-${ROCM_VERSION}
      fi

      # if ROCM_VERSION is greater than or equal to 7.1.0, the sort by version will give the smaller ROCM_VERSION number
      if [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" != "7.1.0" ]; then
         if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
            export MODULE_PATH=/etc/lmod/modules/ROCm/${TOOL_NAME}
            ${SUDO} mkdir -p ${MODULE_PATH}
            # The - option suppresses tabs
         cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	local help_message = [[

	${TOOL_NAME_MC} is an open-source performance analysis tool for profiling
	machine learning/HPC workloads running on AMD MI GPUs.

	Version ${ROCM_VERSION}
	]]

	help(help_message,"\n")

	whatis("Name: ${TOOL_NAME}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Keywords: Profiling, Performance, GPU")
	whatis("Description: tool for GPU performance profiling")
	whatis("URL: https://github.com/ROCm/${TOOL_NAME}")

	-- Export environmental variables
	local topDir="/opt/rocm-${ROCM_VERSION}"
	local binDir="/opt/rocm-${ROCM_VERSION}/bin"
	local shareDir="/opt/rocm-${ROCM_VERSION}/share/${TOOL_NAME}"
	local pythonDeps="/opt/rocm-${ROCM_VERSION}/libexec/${TOOL_NAME}/python-libs"
	-- no need to set: local roofline="${ROOFLINE_BIN}"

	setenv("${TOOL_NAME_UC}_DIR",topDir)
	setenv("${TOOL_NAME_UC}_BIN",binDir)
	setenv("${TOOL_NAME_UC}_SHARE",shareDir)
	-- no need to set: setenv("ROOFLINE_BIN",roofline)

	-- Update relevant PATH variables
	prepend_path("PATH",binDir)
	if ( pythonDeps  ~= "" ) then
	prepend_path("PYTHONPATH",pythonDeps)
	end

	-- Site-specific additions
	-- depends_on "python"
	-- depends_on "rocm"
	prereq(atleast("rocm","${ROCM_VERSION}"))
	--  prereq("mongodb-tools")
	local home = os.getenv("HOME")
	setenv("MPLCONFIGDIR",pathJoin(home,".matplotlib"))

EOF
         fi
      fi
   fi
fi
