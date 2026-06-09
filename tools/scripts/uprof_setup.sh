#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from a parent -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# This script installs the AMD uProf performance profiler from the
# official .tar.bz2 archive. It is intended to be run MANUALLY (it is not
# yet wired into the orchestration). The simplest use case is:
#   ./uprof_setup.sh --build-uprof 1
#
# WHY THE TARBALL (and not the .deb)?
#   The Debian/RPM packages auto-build and load the AMDPowerProfiler
#   *kernel module* (via DKMS) in their post-install step. On a shared HPC
#   cluster that is undesirable and risky: DKMS rebuilds on every kernel
#   update and can break a node at the next reboot (missing headers,
#   Secure Boot rejection, broken initramfs). The kernel module is ONLY
#   needed for uProf's live Power Profiler feature -- CPU profiling works
#   without it via the kernel perf subsystem (AMDuProfCLI ... --use-linux-perf).
#   The .tar.bz2 archive installs *binaries only* and never touches the
#   kernel; the power driver is a separate, explicit step we expose behind
#   the opt-in --install-power-driver flag (default OFF). See AMD uProf
#   user guide 3.2.4 / 13.4.2.1 (doc 57368).
#
# The archive download from amd.com is gated behind an EULA accept page:
#   * the canonical download.amd.com CDN URL serves the file directly
#     ONLY when a browser User-Agent is sent (a default wget/curl UA is
#     302-redirected to the EULA HTML page).
#   * for 5.x releases the path is versioned as uprof-<MAJOR>-<MINOR>/,
#     e.g. .../developer/eula/uprof/uprof-5-3/AMDuProf_Linux_x64_5.3.518.tar.bz2
# We send a browser UA + Referer and guard against accidentally saving
# the EULA HTML page instead of the archive. If the auto-download does
# not work (CDN layout changed, network blocked), download the .tar.bz2
# by hand from https://www.amd.com/en/developer/uprof.html and re-run with
# --tarball-file <path>.
#
# The archive extracts to a top-level dir AMDuProf_Linux_x64_<MAJOR>.<MINOR>.<BUILD>/
# with the executables (AMDuProf, AMDuProfCLI, ...) under bin/. We extract
# it (strip-components=1) into a versioned install dir,
# /opt/AMDuProf_<MAJOR>.<MINOR>-<BUILD>/, so multiple versions can coexist.
#
# SHARED-TREE INSTALL on this cluster (Ubuntu 22.04 nodes). The exposed
# Lmod category is `base` (NOT LinuxPlus), so the modulefile must land in
# base/<tool>/<version>.lua exactly like the miniconda3 / paraview /
# fp64monitor tool modules:
#   ./uprof_setup.sh --build-uprof 1 \
#       --install-path /shared/apps/ubuntu/opt/AMDuProf_5.3-518 \
#       --module-path  /shared/apps/modules/ubuntu/lmodfiles/base/uprof
# After the 24.04 migration the roots become /nfsapps/opt and
# /nfsapps/modules/base respectively (same flags, different roots).

# Variables controlling setup process
UPROF_VERSION=5.3-518
TARBALL_URL_INPUT=""
TARBALL_FILE_INPUT=""
# INSTALL_PATH_INPUT: full install dir override. Empty -> the local
# default /opt/AMDuProf_<MAJOR.MINOR-BUILD>. On this cluster the shared
# location is /shared/apps/ubuntu/opt/AMDuProf_<ver> for the current
# Ubuntu 22.04 nodes (and /nfsapps/opt/AMDuProf_<ver> after the 24.04
# migration); pass it via --install-path.
INSTALL_PATH_INPUT=""
# Published MD5 for AMDuProf_Linux_x64_5.3.518.tar.bz2. Only meaningful
# for the default version; for any other --uprof-version pass a matching
# --md5checksum or "skip".
MD5CHECKSUM=cde7c32da81181fc6c4c39dbd578f44e
MODULE_PATH=/etc/lmod/modules/ROCmPlus/uprof
# BUILD_UPROF is the master "do this script's work at all" gate. Default
# 1 for a manual run; a parent orchestrator can thread --build-uprof 0 to
# short-circuit early with NOOP_RC=43 (matches the repo-wide opt-out
# convention) once this script is wired in.
BUILD_UPROF=1
# INSTALL_POWER_DRIVER: opt-in (default 0). When 1, after the binaries are
# laid down we run the bundled AMDPowerProfilerDriver.sh to build+load the
# AMDPowerProfiler kernel module (DKMS if present). This is the ONLY part
# of the install that touches the kernel; leave it 0 unless you
# specifically need live power/energy/frequency profiling and accept the
# DKMS maintenance burden on this node. CPU profiling does not need it
# (use AMDuProfCLI's --use-linux-perf collection mode instead).
INSTALL_POWER_DRIVER=0
REPLACE=0
KEEP_FAILED_INSTALLS=0
DRY_RUN=0

# Browser-like fetch headers required to get the file rather than the
# EULA HTML page.
UPROF_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36"
UPROF_REFERER="https://www.amd.com/en/developer/uprof.html"

# Autodetect defaults
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

# pick_sudo_for <target>: return "" if <target> (or its nearest existing
# ancestor) is writable by the current user, else "sudo". Lets the same
# script lay uProf into a root-owned /opt OR an admin-group-writable
# shared tree (e.g. /shared/apps/ubuntu/opt) without a wrong-permission
# failure. Mirrors comm/scripts/openmpi_setup.sh.
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
   local probe="${probe_dir}/.uprof_setup_writeprobe.$$.${RANDOM}"
   if ( umask 077 && : > "${probe}" ) 2>/dev/null; then
      rm -f "${probe}" 2>/dev/null
      echo ""; return
   fi
   echo "sudo"
}

usage()
{
    echo "Usage:"
    echo "  Installs AMD uProf from the official .tar.bz2 archive (binaries only,"
    echo "  no kernel module). CPU profiling works via AMDuProfCLI --use-linux-perf."
    echo "  --build-uprof [ 0|1 ] master gate; 0 = exit NOOP_RC, default $BUILD_UPROF"
    echo "  --uprof-version [ MAJOR.MINOR-BUILD ] default $UPROF_VERSION"
    echo "  --tarball-url [ URL ] override the download URL (default is the versioned download.amd.com CDN URL)"
    echo "  --tarball-file [ PATH ] install a pre-downloaded local .tar.bz2 instead of downloading"
    echo "  --md5checksum [ CHECKSUM ] default for default version, blank or \"skip\" for no check"
    echo "  --install-path [ INSTALL_PATH ] full install dir; default /opt/AMDuProf_<MAJOR.MINOR-BUILD>"
    echo "                                  (shared tree: /shared/apps/ubuntu/opt/AMDuProf_<ver>)"
    echo "                                  module then -> --module-path .../lmodfiles/base/uprof"
    echo "  --install-power-driver [ 0|1 ] OPT-IN: build+load the AMDPowerProfiler DKMS kernel"
    echo "                                  module (only needed for live power profiling), default $INSTALL_POWER_DRIVER"
    echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
    echo "  --replace [ 0|1 ] remove prior install dir + modulefile before installing, default $REPLACE"
    echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of a partial install on failure, default $KEEP_FAILED_INSTALLS"
    echo "  --dry-run default off"
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
      "--build-uprof")
          shift
          BUILD_UPROF=${1}
          reset-last
          ;;
      "--uprof-version")
          shift
          UPROF_VERSION=${1}
          reset-last
          ;;
      "--tarball-url")
          shift
          TARBALL_URL_INPUT=${1}
          reset-last
          ;;
      "--tarball-file")
          shift
          TARBALL_FILE_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--md5checksum")
          shift
          MD5CHECKSUM=${1}
          if [[ "${1}" = "" ]]; then
             MD5CHECKSUM="skip"
          fi
          reset-last
          ;;
      "--install-power-driver")
          shift
          INSTALL_POWER_DRIVER=${1}
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
      "--dry-run")
          DRY_RUN=1
          reset-last
          ;;
      "--help")
          usage
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

# Derive version components:
#   UPROF_VERSION   = MAJOR.MINOR-BUILD  (e.g. 5.3-518)
#   MAJOR_MINOR     = 5.3
#   MM_DASH         = 5-3   (CDN folder segment uprof-<MM_DASH>)
#   BUILD           = 518
#   TARBALL_VERSION = 5.3.518  (dotted, as used in the archive name/topdir)
MAJOR_MINOR="${UPROF_VERSION%-*}"
BUILD="${UPROF_VERSION#*-}"
MM_DASH="${MAJOR_MINOR/./-}"
TARBALL_VERSION="${MAJOR_MINOR}.${BUILD}"
TARBALL_FILE="AMDuProf_Linux_x64_${TARBALL_VERSION}.tar.bz2"
# The archive's single top-level directory; we strip it on extract.
TARBALL_TOPDIR="AMDuProf_Linux_x64_${TARBALL_VERSION}"

if [ "${TARBALL_URL_INPUT}" != "" ]; then
   TARBALL_URL="${TARBALL_URL_INPUT}"
else
   TARBALL_URL="https://download.amd.com/developer/eula/uprof/uprof-${MM_DASH}/${TARBALL_FILE}"
fi

# Versioned install dir so multiple uProf releases can coexist. Unlike the
# .deb (which bakes in /opt/AMDuProf_<ver>), the tarball is relocatable, so
# we choose this path and extract into it with --strip-components=1.
# --install-path overrides the full dir (e.g. a shared/NFS tree).
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH="${INSTALL_PATH_INPUT}"
else
   INSTALL_PATH="/opt/AMDuProf_${MAJOR_MINOR}-${BUILD}"
fi
# Strip any trailing slash so downstream "${INSTALL_PATH}/bin" joins stay
# canonical (no embedded "//") in the modulefile's exported paths.
INSTALL_PATH="${INSTALL_PATH%/}"
MODULE_PATH="${MODULE_PATH%/}"
MODULEFILE="${MODULE_PATH}/${UPROF_VERSION}.lua"
# Path to the bundled power-profiler driver installer once extracted.
DRIVER_SCRIPT="${INSTALL_PATH}/bin/AMDPowerProfilerDriver.sh"
# Tracks whether THIS run installed the kernel driver, so the fail-cleanup
# trap can uninstall it again on a later failure.
POWER_DRIVER_INSTALLED=0

NOOP_RC=43

# ── BUILD_UPROF=0 short-circuit: operator opt-out ────────────────────
if [ "${BUILD_UPROF}" = "0" ]; then
   echo "[uprof BUILD_UPROF=0] operator opt-out; skipping (no download, no install)."
   exit ${NOOP_RC}
fi

# ── Distro gate: prebuilt x86_64 Linux archive; driver needs a real kernel
if [ "${RHEL_COMPATIBLE}" != "1" ] && [ "${DISTRO}" != "ubuntu" ] && [ "${DISTRO}" != "debian" ]; then
   echo "[uprof] Unrecognized DISTRO='${DISTRO}'. The AMD uProf Linux x86_64 archive"
   echo "        is distro-agnostic, but this script has only been exercised on"
   echo "        Ubuntu/Debian and RHEL-compatible hosts. Proceeding is untested here."
fi

# ── Resolve sudo per target dir (install vs modulefile) ──────────────
# A shared tree like /shared/apps/ubuntu/opt is admin-group-writable (no
# sudo needed), whereas /opt is root-owned (sudo needed). Probe each
# independently. Inside Singularity the script-level SUDO was forced
# empty above; keep both empty there.
if [ -z "${SUDO}" ]; then
   SUDO_MOD=""
else
   SUDO=$(pick_sudo_for "${INSTALL_PATH}")
   SUDO_MOD=$(pick_sudo_for "${MODULE_PATH}")
fi

echo ""
echo "============================"
echo " Installing AMD uProf with:"
echo "   UPROF_VERSION: ${UPROF_VERSION}"
echo "   TARBALL_FILE: ${TARBALL_FILE}"
echo "   TARBALL_URL: ${TARBALL_URL}"
echo "   TARBALL_FILE_INPUT: ${TARBALL_FILE_INPUT:-<none, will download>}"
echo "   INSTALL_PATH: ${INSTALL_PATH} (SUDO='${SUDO}')"
echo "   INSTALL_POWER_DRIVER: ${INSTALL_POWER_DRIVER} (1 = build DKMS kernel module)"
echo "   MODULE_PATH: ${MODULE_PATH} (SUDO='${SUDO_MOD}')"
echo "   REPLACE: ${REPLACE}"
echo "   KEEP_FAILED_INSTALLS: ${KEEP_FAILED_INSTALLS}"
echo "============================"
echo ""

# ── --replace: remove prior install + modulefile BEFORE installing ───
if [ "${REPLACE}" = "1" ]; then
   echo "[uprof --replace 1] removing prior install dir + modulefile if present"
   if [[ "${DRY_RUN}" == "0" ]]; then
      # If a prior install registered the power driver, uninstall it first
      # so we don't orphan a DKMS module pointing at a deleted source tree.
      if [ -x "${DRIVER_SCRIPT}" ]; then
         echo "[uprof --replace 1] uninstalling previously-installed power driver (best-effort)"
         ${SUDO} "${DRIVER_SCRIPT}" uninstall || true
      fi
      ${SUDO} rm -rf "${INSTALL_PATH}"
   fi
   ${SUDO_MOD} rm -f "${MODULEFILE}"
fi

# ── Existence guard: skip if this version is already installed ───────
if [ -d "${INSTALL_PATH}/bin" ] && [ "${REPLACE}" != "1" ]; then
   echo ""
   echo "[uprof existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                        pass --replace 1 to force a reinstall."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: download-dir cleanup + fail-cleanup ───────────────────
# The default (binaries-only) path never touches apt/dpkg or the kernel,
# so fail-cleanup is just an rm of the extracted dir + modulefile. If THIS
# run installed the power driver, also unwind that so a failed run does not
# leave a dangling DKMS module.
_uprof_on_exit() {
   local rc=$?
   [ -n "${UPROF_DL_DIR:-}" ] && ${SUDO:-sudo} rm -rf "${UPROF_DL_DIR}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[uprof fail-cleanup] rc=${rc}: removing partial install + modulefile"
      if [ "${POWER_DRIVER_INSTALLED}" = "1" ] && [ -x "${DRIVER_SCRIPT}" ]; then
         echo "[uprof fail-cleanup] uninstalling power driver installed this run"
         ${SUDO:-sudo} "${DRIVER_SCRIPT}" uninstall >/dev/null 2>&1 || true
      fi
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f "${MODULEFILE}"
   elif [ ${rc} -ne 0 ]; then
      echo "[uprof fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _uprof_on_exit EXIT

# ── Acquire the archive ──────────────────────────────────────────────
UPROF_DL_DIR=$(mktemp -d -t uprof-download.XXXXXX)

if [ "${TARBALL_FILE_INPUT}" != "" ]; then
   if [ ! -f "${TARBALL_FILE_INPUT}" ]; then
      echo "Error: --tarball-file '${TARBALL_FILE_INPUT}' does not exist"
      exit 1
   fi
   echo "Using pre-downloaded archive: ${TARBALL_FILE_INPUT}"
   TARBALL_LOCAL="${TARBALL_FILE_INPUT}"
else
   echo "Downloading ${TARBALL_URL}"
   TARBALL_LOCAL="${UPROF_DL_DIR}/${TARBALL_FILE}"
   count=0
   while [ "$count" -lt 3 ]; do
      wget -q --continue --tries=10 \
         --user-agent="${UPROF_UA}" \
         --header="Referer: ${UPROF_REFERER}" \
         -O "${TARBALL_LOCAL}" "${TARBALL_URL}" && break
      count=$((count+1))
   done

   # Guard: a 302 to the EULA page (or any HTML body) means we did NOT
   # get the archive. Detect a missing/tiny file or an HTML payload and
   # fall back to manual-download instructions.
   _bad_download=0
   if [ ! -s "${TARBALL_LOCAL}" ]; then
      _bad_download=1
   else
      # A real archive is a binary bzip2 stream and is hundreds of MB.
      # Reject small files and HTML/text pages.
      _size=$(stat -c%s "${TARBALL_LOCAL}" 2>/dev/null || echo 0)
      _ftype=$(file -b "${TARBALL_LOCAL}" 2>/dev/null || echo unknown)
      if [ "${_size}" -lt 1000000 ] || echo "${_ftype}" | grep -qiE 'html|ascii|text'; then
         _bad_download=1
      fi
   fi
   if [ "${_bad_download}" == "1" ]; then
      echo ""
      echo "=================================================================="
      echo "[uprof] FATAL: the download did not return a valid .tar.bz2 archive."
      echo "        URL: ${TARBALL_URL}"
      echo ""
      echo "  The AMD uProf download is gated behind an EULA accept page and"
      echo "  the CDN path/convention may have changed. Download the archive"
      echo "  manually:"
      echo "    1. Visit https://www.amd.com/en/developer/uprof.html"
      echo "    2. Accept the EULA and download ${TARBALL_FILE}"
      echo "    3. Re-run: ${LEAF_SCRIPT_PATH} --tarball-file /path/to/${TARBALL_FILE}"
      echo ""
      echo "  Or pass the resolved direct URL with --tarball-url <url>."
      echo "=================================================================="
      echo ""
      exit 1
   fi
fi

# ── MD5 verify ───────────────────────────────────────────────────────
if [[ "${MD5CHECKSUM}" =~ "skip" ]] || [ "${MD5CHECKSUM}" = "" ]; then
   echo "MD5SUM check skipped"
else
   MD5SUM_TARBALL=$(md5sum "${TARBALL_LOCAL}" | cut -f1 -d' ')
   if [[ "${MD5SUM_TARBALL}" == "${MD5CHECKSUM}" ]]; then
      echo "MD5SUM is verified: actual ${MD5SUM_TARBALL}, expecting ${MD5CHECKSUM}"
   else
      echo "Error: Wrong MD5Sum for ${TARBALL_FILE}:"
      echo "MD5SUM is ${MD5SUM_TARBALL}, expecting ${MD5CHECKSUM}"
      echo "(If you intentionally changed --uprof-version, pass a matching"
      echo " --md5checksum or --md5checksum skip.)"
      exit 1
   fi
fi

# ── Install (binaries only; no kernel module, no apt/dpkg) ───────────
if [[ "${DRY_RUN}" == "0" ]]; then
   echo "Extracting ${TARBALL_FILE} into ${INSTALL_PATH}"
   ${SUDO} mkdir -p "${INSTALL_PATH}"
   # --strip-components=1 drops the archive's single top-level dir
   # (${TARBALL_TOPDIR}) so bin/ lands directly under ${INSTALL_PATH}.
   ${SUDO} tar -C "${INSTALL_PATH}" --strip-components=1 -xjf "${TARBALL_LOCAL}"
fi

# ── Verify install ───────────────────────────────────────────────────
if [[ "${DRY_RUN}" == "0" ]] && [ ! -x "${INSTALL_PATH}/bin/AMDuProfCLI" ]; then
   echo "AMD uProf installation failed -- missing ${INSTALL_PATH}/bin/AMDuProfCLI"
   ls -l "${INSTALL_PATH}/bin" 2>/dev/null || ls -l "${INSTALL_PATH}" 2>/dev/null || true
   exit 1
fi

# ── Optional: AMDPowerProfiler kernel driver (opt-in, DKMS) ──────────
# This is the ONLY part of the install that touches the kernel. It is
# off by default for the HPC use case (see header). Only run when the
# operator explicitly asks for live power profiling.
if [ "${INSTALL_POWER_DRIVER}" = "1" ] && [[ "${DRY_RUN}" == "0" ]]; then
   echo ""
   echo "[uprof power-driver] --install-power-driver 1: building the AMDPowerProfiler"
   echo "                     kernel module. This uses DKMS (if present) and will"
   echo "                     rebuild on kernel updates -- maintain accordingly."

   # Pre-flight the build prerequisites BEFORE we touch the kernel, so a
   # missing toolchain/headers fails fast with a clear message rather than
   # leaving a half-built module. gcc+make are mandatory; dkms is optional
   # (without it the module is built one-shot for the running kernel only).
   _missing=""
   command -v gcc  >/dev/null 2>&1 || _missing="${_missing} gcc"
   command -v make >/dev/null 2>&1 || _missing="${_missing} make"
   _krel="$(uname -r)"
   if [ ! -d "/lib/modules/${_krel}/build" ]; then
      _missing="${_missing} linux-headers-${_krel}"
   fi
   if [ -n "${_missing}" ]; then
      echo ""
      echo "=================================================================="
      echo "[uprof power-driver] FATAL: missing kernel-build prerequisite(s):"
      echo "    ${_missing}"
      echo ""
      echo "  The uProf binaries are already installed at ${INSTALL_PATH}."
      echo "  Install the prerequisites and re-run with --install-power-driver 1,"
      echo "  or skip the driver entirely (CPU profiling needs only --use-linux-perf):"
      echo "    Ubuntu/Debian: ${SUDO:-sudo} apt-get install build-essential dkms linux-headers-${_krel}"
      echo "    RHEL-family:   ${SUDO:-sudo} dnf install gcc make dkms kernel-devel-${_krel}"
      echo "=================================================================="
      echo ""
      exit 1
   fi

   if [ ! -x "${DRIVER_SCRIPT}" ]; then
      echo "[uprof power-driver] FATAL: ${DRIVER_SCRIPT} not found in the archive."
      exit 1
   fi

   ${SUDO} "${DRIVER_SCRIPT}" install
   POWER_DRIVER_INSTALLED=1
   echo "[uprof power-driver] AMDPowerProfiler kernel module installed."
fi

# ── Create a module file for uProf ───────────────────────────────────
if [[ "${DRY_RUN}" == "0" ]]; then

   # Modulefile-write sudo: SUDO_MOD was resolved from MODULE_PATH
   # writability above (empty for an admin-writable shared tree).
   ${SUDO_MOD} mkdir -p ${MODULE_PATH}

   # Provenance: capture this leaf script's git state for the modulefile
   # whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured
   # at the top of this script before any cd). Self-contained: falls
   # back to "unknown" when run from a stripped-of-.git context.
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

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO_MOD} tee ${MODULEFILE}
	whatis("Name: AMD uProf")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")
	whatis("Version: ${UPROF_VERSION}")
	whatis("Description: AMD uProf performance analysis and profiling tool (binaries only; CPU profiling via --use-linux-perf)")
	whatis("URL: https://www.amd.com/en/developer/uprof.html")
	
	local base = "${INSTALL_PATH}"
	
	setenv("UPROF_PATH", base)
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "bin"))
EOF

fi
