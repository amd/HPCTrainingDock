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
ROCM_VERSION=6.4.3
BUILD_ROC_OPTIQ=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AMDResearchTools/roc-optiq
# Skip rocminfo autodetect if --amdgpu-gfxmodel was supplied. Under
# `set -eo pipefail`, an unguarded rocminfo can kill the script when
# the SDK is built against a newer glibc than the host (ROCm 7.2.3
# binaries need GLIBC_2.38; jammy has 2.35). Audited in 7.2.3 sweep.
if [[ " $* " == *" --amdgpu-gfxmodel "* ]]; then
   AMDGPU_GFXMODEL=""
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
ROC_OPTIQ_PATH=""     # default derived below from ROC_OPTIQ_VERSION
ROC_OPTIQ_PATH_INPUT=""
# --install-path: parent dir; the script appends roc-optiq-v${ROC_OPTIQ_VERSION}
# itself. Used by main_setup.sh so the orchestrator never has to know the
# version (mirrors mdb_setup.sh / likwid_setup.sh path convention).
# --install-path-no-version (full leaf dir, no version appended) wins over
# --install-path when both are set, for callers that need exact control of
# the final install directory.
ROCMPLUS_PATH_INPUT=""
# roc-optiq upstream release tag. Upstream tags stable releases as
# v<version>-optiq (https://github.com/ROCm/roc-optiq/tags). Pin to the
# latest stable release so the modulefile name and the install dir reflect
# a real, reproducible version. Pass --roc-optiq-version main to build from
# the current main branch instead. The checkout logic below tries the
# v<version>-optiq tag first, then a few common fallbacks.
ROC_OPTIQ_VERSION="0.5.0"
# --replace 1: rm -rf prior install dir + ${ROC_OPTIQ_VERSION}.lua before build.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-roc-optiq [ BUILD_ROC_OPTIQ ] master gate; 0 = exit NOOP_RC, default $BUILD_ROC_OPTIQ"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path-no-version [ ROC_OPTIQ_PATH ] default $ROC_OPTIQ_PATH"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set (and --install-path-no-version is not), ROC_OPTIQ_PATH = ROCMPLUS_PATH/roc-optiq-v\${ROC_OPTIQ_VERSION}"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --roc-optiq-version [ ROC_OPTIQ_VERSION ] git tag/branch/commit to check out after clone (default: $ROC_OPTIQ_VERSION)"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
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
          reset-last
          ;;
      "--build-roc-optiq")
          shift
          BUILD_ROC_OPTIQ=${1}
          reset-last
          ;;
      "--roc-optiq-version")
          shift
          ROC_OPTIQ_VERSION=${1}
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
          ROC_OPTIQ_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
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

# Resolve ROC_OPTIQ_PATH: explicit no-version > parent dir + appended version
# > /opt/rocmplus-${ROCM_VERSION}/roc-optiq-v${ROC_OPTIQ_VERSION} default.
# Matches the same priority order as mdb_setup.sh / likwid_setup.sh.
if [ "${ROC_OPTIQ_PATH_INPUT}" != "" ]; then
   ROC_OPTIQ_PATH=${ROC_OPTIQ_PATH_INPUT}
elif [ "${ROCMPLUS_PATH_INPUT}" != "" ]; then
   ROC_OPTIQ_PATH=${ROCMPLUS_PATH_INPUT}/roc-optiq-v${ROC_OPTIQ_VERSION}
else
   ROC_OPTIQ_PATH=/opt/rocmplus-${ROCM_VERSION}/roc-optiq-v${ROC_OPTIQ_VERSION}
fi

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# Modulefile name is ${ROC_OPTIQ_VERSION}.lua to match the
# `tee ${MODULE_PATH}/${ROC_OPTIQ_VERSION}.lua` write below.
# ── BUILD_ROC_OPTIQ=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_ROC_OPTIQ}" = "0" ]; then
   echo "[roc-optiq BUILD_ROC_OPTIQ=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

# Two modulefile flavors: Lmod consumes <ver>.lua, classic Tcl Environment
# Modules consumes an extensionless Tcl file. Track both so --replace and
# the fail-cleanup trap remove whichever was written previously (and so a
# Tcl site -- e.g. this Cray -- gets a loadable modulefile; see the
# flavor-detection block at modulefile creation below).
MODULEFILE_LUA="${MODULE_PATH}/${ROC_OPTIQ_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${ROC_OPTIQ_VERSION}"

# Install-path sudo (EARLY): probe the nearest existing ancestor of
# ROC_OPTIQ_PATH for user-writability and set SUDO accordingly BEFORE anything
# that uses ${SUDO} -- the --replace rm below and the _roc_optiq_on_exit trap's
# fail-cleanup. The default SUDO=sudo (set above) otherwise makes
# `--replace 1` hit a password prompt on a user-writable tree that has no
# passwordless sudo (this Cray), failing the whole leaf before the build
# branch's own probe (further below) ever runs. Mirrors that probe and is
# idempotent with it.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _iprobe="${ROC_OPTIQ_PATH}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .roc-optiq-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "roc-optiq: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo"
   else
      SUDO="sudo"
      echo "roc-optiq: install ancestor ${_iprobe} not user-writable (probe failed); using sudo"
   fi
   unset _iprobe _itest
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[roc-optiq --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${ROC_OPTIQ_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${ROC_OPTIQ_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${ROC_OPTIQ_PATH}" ]; then
   echo ""
   echo "[roc-optiq existence-check] ${ROC_OPTIQ_PATH} already installed; skipping."
   echo "                            pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: build-dir cleanup (ROC_OPTIQ_BUILD_ROOT, set under
# BUILD_ROC_OPTIQ=1) PLUS fail-cleanup of partial install + modulefile.
_roc_optiq_on_exit() {
   local rc=$?
   [ -n "${ROC_OPTIQ_BUILD_ROOT:-}" ] && ${SUDO} rm -rf "${ROC_OPTIQ_BUILD_ROOT}"
   # attempted-but-failed marker (inventory 'F' glyph): persistent sibling
   # of the install dir that survives the rm -rf below; cleared on success.
   _fail_marker="$(dirname "${ROC_OPTIQ_PATH}")/roc-optiq.FAILED"
   if [ ${rc} -ne 0 ]; then
      ${SUDO} mkdir -p "$(dirname "${ROC_OPTIQ_PATH}")" 2>/dev/null || true
      ${SUDO} tee "${_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: roc-optiq
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    roc-optiq_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_roc-optiq_*.txt).
MARKER_EOF
   else
      ${SUDO} rm -f "${_fail_marker}"
   fi
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[roc-optiq fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${ROC_OPTIQ_PATH}"
      ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[roc-optiq fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _roc_optiq_on_exit EXIT

echo ""
echo "==================================="
echo "Starting roc-optiq Install with"
echo "ROCM_VERSION:      $ROCM_VERSION"
echo "AMDGPU_GFXMODEL:   $AMDGPU_GFXMODEL"
echo "BUILD_ROC_OPTIQ:   $BUILD_ROC_OPTIQ"
echo "ROC_OPTIQ_VERSION: $ROC_OPTIQ_VERSION"
echo "ROC_OPTIQ_PATH:    $ROC_OPTIQ_PATH"
echo "MODULE_PATH:       $MODULE_PATH"
echo "==================================="
echo ""

# Per-job throwaway build dir; replaces a fixed `cd /tmp` that would race
# with any other concurrent roc-optiq build on the same node. NOTE:
# build-dir cleanup is consolidated into the _roc_optiq_on_exit trap
# installed above (so the same EXIT handler also does fail-cleanup of any
# partial install / modulefile).
ROC_OPTIQ_BUILD_ROOT=$(mktemp -d -t roc-optiq-build.XXXXXX)
cd "${ROC_OPTIQ_BUILD_ROOT}"

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
if [ -f "${CACHE_FILES}/roc-optiq-v${ROC_OPTIQ_VERSION}.tgz" ]; then
   echo ""
   echo "============================"
   echo " Installing Cached roc-optiq"
   echo "============================"
   echo ""

   # Install the cached version. Cache tar must be named
   # roc-optiq-v${ROC_OPTIQ_VERSION}.tgz and contain a top-level directory
   # roc-optiq-v${ROC_OPTIQ_VERSION}/ so it lands directly at
   # ${ROC_OPTIQ_PATH} when extracted under /opt/rocmplus-X.
   ${SUDO} mkdir -p ${ROC_OPTIQ_PATH}
   cd /opt/rocmplus-${ROCM_VERSION}
   ${SUDO} tar -xzpf ${CACHE_FILES}/roc-optiq-v${ROC_OPTIQ_VERSION}.tgz
   chown -R root:root ${ROC_OPTIQ_PATH}
   if [ "${USER}" != "sysadmin" ]; then
      ${SUDO} rm ${CACHE_FILES}/roc-optiq-v${ROC_OPTIQ_VERSION}.tgz
   fi
else
   echo ""
   echo "============================"
   echo " Building roc-optiq"
   echo "============================"
   echo ""

   # roc-optiq is a C++/CMake visualizer (GLFW/Dear ImGui/Vulkan/OpenGL).
   # Install the build-time system dependencies it needs to configure and
   # link: Vulkan headers + loader, OpenGL/Mesa dev, and X11/Wayland dev for
   # GLFW. Best-effort under sudo; on a user-writable tree with no sudo we
   # assume the toolchain is already present (or provided by a module).
   if [ -n "${SUDO}" ] || [ "${EUID:-$(id -u)}" -eq 0 ]; then
      if [ "${DISTRO}" == "ubuntu" ]; then
         ${SUDO} apt-get update
         ${SUDO} apt-get install -y \
            cmake git build-essential pkg-config \
            libvulkan-dev vulkan-tools \
            libgl1-mesa-dev libglu1-mesa-dev \
            libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
            libwayland-dev libxkbcommon-dev \
            libdbus-1-dev || true
      elif [[ "${DISTRO}" == *"red hat"* ]] || [[ "${DISTRO}" == *"rocky"* ]] || [[ "${DISTRO}" == *"almalinux"* ]] || [[ "${DISTRO}" == *"centos"* ]]; then
         ${SUDO} yum install -y \
            cmake git gcc gcc-c++ make pkgconfig \
            vulkan-loader-devel vulkan-headers \
            mesa-libGL-devel mesa-libGLU-devel \
            libX11-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel \
            wayland-devel libxkbcommon-devel \
            dbus-devel || true
      fi
   fi

   # Install-path sudo: probe the nearest existing ancestor of
   # ROC_OPTIQ_PATH for user-writability (mirrors the EARLY probe above so
   # this branch is self-contained). EUID==0 needs no sudo regardless.
   if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      SUDO=""
   else
      _iprobe="${ROC_OPTIQ_PATH}"
      while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
      _itest=$(mktemp --tmpdir="${_iprobe}" .roc-optiq-inst-probe.XXXXXX 2>/dev/null || true)
      if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
         rm -f "${_itest}"
         SUDO=""
         echo "roc-optiq: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
      else
         SUDO="sudo"
         echo "roc-optiq: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
      fi
      unset _iprobe _itest
   fi

   ${SUDO} mkdir -p ${ROC_OPTIQ_PATH}
   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} chmod a+w ${ROC_OPTIQ_PATH}
   fi

   # Clone the requested tag/branch (recursively for the bundled thirdparty
   # submodules: glfw, imgui, implot, jsoncpp, ImGuiFileDialog, ...).
   git clone --recurse-submodules https://github.com/ROCm/roc-optiq.git roc-optiq-src
   if [ -n "${ROC_OPTIQ_VERSION}" ] && [ "${ROC_OPTIQ_VERSION}" != "main" ]; then
      # Upstream stable releases are tagged v<version>-optiq (e.g.
      # v0.5.0-optiq). Try that form first, then a couple of common
      # fallbacks, then the bare ref, before updating submodules.
      echo "Checking out roc-optiq ref for version: ${ROC_OPTIQ_VERSION}"
      ( cd roc-optiq-src && \
         ( git checkout "v${ROC_OPTIQ_VERSION}-optiq" 2>/dev/null || \
           git checkout "v${ROC_OPTIQ_VERSION}-optiq-beta" 2>/dev/null || \
           git checkout "v${ROC_OPTIQ_VERSION}" 2>/dev/null || \
           git checkout "${ROC_OPTIQ_VERSION}" ) && \
         git submodule update --init --recursive )
   fi
   cd roc-optiq-src

   # Configure + build + install. BUILD_TESTING=OFF and the in-development
   # profiler/remote features stay at their upstream OFF defaults so the
   # release build excludes the libssh2/mbedtls stack. The install rule
   # ships the roc-optiq binary into ${CMAKE_INSTALL_PREFIX}/bin.
   cmake -S . -B build \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX=${ROC_OPTIQ_PATH} \
         -DBUILD_TESTING=OFF
   cmake --build build --parallel 16
   ${SUDO} cmake --install build

   cd /

   # Normalize ownership to root only when we installed with elevation
   # (SUDO non-empty). On a user-owned tree the files are already correctly
   # owned and a non-sudo `chown root:root` would fail.
   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find ${ROC_OPTIQ_PATH} -type f -execdir chown root:root "{}" +
      ${SUDO} find ${ROC_OPTIQ_PATH} -type d -execdir chown root:root "{}" +
      ${SUDO} chmod go-w ${ROC_OPTIQ_PATH}
   fi

   # cleanup: trap handles ${ROC_OPTIQ_BUILD_ROOT}
fi

# Create a module file for roc-optiq
#
# Modulefile-write sudo: probe the module tree for user-writability so a
# user-owned module tree (a Cray $HOME deployment or a standalone run)
# needs no sudo, and forcing it would hit a password prompt that fails
# where the user has no sudo. Mirrors mdb/likwid/netcdf_setup.sh.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .roc-optiq-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"
      PKG_SUDO_MOD=""
      echo "roc-optiq: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
   else
      PKG_SUDO_MOD="sudo"
      echo "roc-optiq: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
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
# Lmod consumes <ver>.lua; classic Tcl `environment-modules` consumes an
# extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
# when Lmod is absent (this Cray runs Tcl Environment Modules). Without
# this the .lua file is invisible to a Tcl `module` and `module load
# roc-optiq/...` fails. Mirrors hdf5/netcdf/mdb/likwid.
if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
   MODULEFILE="${MODULEFILE_LUA}"; MODFLAVOR="lua"
else
   MODULEFILE="${MODULEFILE_TCL}"; MODFLAVOR="tcl"
fi

# The - option suppresses leading tabs.
if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("roc-optiq: a visualizer for the ROCm Profiler Tools (ROCm Systems Profiler / ROCm Compute Profiler)")
	whatis("Upstream: https://github.com/ROCm/roc-optiq")
	whatis("Version:  ${ROC_OPTIQ_VERSION}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${ROC_OPTIQ_PATH}"
	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("ROC_OPTIQ_HOME", base)
EOF
else
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "roc-optiq: a visualizer for the ROCm Profiler Tools (ROCm Systems Profiler / ROCm Compute Profiler)"
	module-whatis "Upstream: https://github.com/ROCm/roc-optiq"
	module-whatis "Version:  ${ROC_OPTIQ_VERSION}"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${ROC_OPTIQ_PATH}"
	prepend-path PATH \$base/bin
	setenv ROC_OPTIQ_HOME "${ROC_OPTIQ_PATH}"
EOF
fi
