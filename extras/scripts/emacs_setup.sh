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

# ─────────────────────────────────────────────────────────────────────
# GNU Emacs source build + Lmod/Tcl modulefile, in the HPCTrainingDock
# leaf-setup style (mirrors boost_setup.sh / likwid_setup.sh).
#
# NATIVE COMPILATION is DISABLED by default (--native-comp 0) -- READ THIS:
#   Emacs native-comp (--with-native-compilation) JIT-compiles elisp with
#   libgccjit. On Ubuntu 24.04 (noble) the OS default gcc is 13, BUT the
#   only libgccjit0 RUNTIME package in the archive is the gcc-14 build, and
#   it hard-depends on libgcc-14-dev. Even `libgccjit-13-dev` resolves its
#   `libgccjit0 (>= 13)` dep with that gcc-14 runtime. So enabling native-comp
#   necessarily installs libgcc-14-dev and recreates /usr/lib/gcc/<triple>/14.
#
#   We deliberately do NOT "complete" that gcc-14 dir with libstdc++-14-dev.
#   Doing so would make ROCm's clang PREFER the gcc-14 dir (it auto-selects the
#   highest-numbered COMPLETE toolchain), silently changing the libstdc++ used
#   by every OTHER package build on the host -- a toolchain mix we do not want,
#   and a behavioural difference depending on whether libstdc++-*-dev happens
#   to be present. (A libgcc-14-dev-only half install is what broke the openmpi
#   build, slurm-13278; adding libstdc++-14-dev "fixes" that only by moving
#   everything onto gcc-14.)
#
#   Net policy:
#     * default (--native-comp 0): --without-native-compilation, byte-compiled
#       emacs, built with the OS default gcc (CC=gcc -> 13). Pulls NO gcc-14
#       packages; portable to every node; does not perturb the toolchain.
#     * --native-comp 1: opt-in only. Installs libgccjit (=> libgcc-14-dev) and
#       builds --with-native-compilation. This host then carries gcc-14 dev
#       bits; on a host that also runs ROCm clang builds this can break/shift
#       the toolchain. libstdc++-14-dev is NOT auto-installed -- if you accept
#       native-comp you own the toolchain consequences.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/LinuxPlus/emacs
BUILD_EMACS=1
EMACS_VERSION=30.1
INSTALL_PATH=/opt/emacs-v${EMACS_VERSION}
INSTALL_PATH_INPUT=""
# native-comp (see header policy): 0 = --without-native-compilation
# (byte-compiled; pulls NO gcc-14 packages; portable; toolchain untouched) --
# the DEFAULT. 1 = --with-native-compilation=aot, which installs libgccjit and
# therefore libgcc-14-dev; libstdc++-14-dev is intentionally NOT installed.
NATIVE_COMP=0
# HPC login/compute nodes are typically headless; default to a no-X
# terminal build. --with-x 1 switches to a GTK3 GUI build (heavier deps).
WITH_X=0
# --replace 1: rm -rf the prior install dir + modulefile BEFORE building.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so a partial
# install + modulefile are left on disk for post-mortem. (Canonical
# hypre/likwid template pattern.)
REPLACE=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-emacs [ 0|1 ]        default $BUILD_EMACS"
   echo "  --emacs-version [ VER ]      default $EMACS_VERSION"
   echo "  --module-path [ PATH ]       default $MODULE_PATH"
   echo "  --install-path [ PATH ]      PARENT dir; leaf appends emacs-v\${EMACS_VERSION}. default parent of $INSTALL_PATH"
   echo "  --native-comp [ 0|1 ]        default $NATIVE_COMP (0 = byte-comp, no gcc-14; 1 pulls libgccjit/libgcc-14-dev, see header note)"
   echo "  --with-x [ 0|1 ]             default $WITH_X (1 = GTK3 GUI build)"
   echo "  --replace [ 0|1 ]            remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
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
      "--build-emacs")
          shift
          BUILD_EMACS=${1}
          reset-last
          ;;
      "--emacs-version")
          shift
          EMACS_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--native-comp")
          shift
          NATIVE_COMP=${1}
          reset-last
          ;;
      "--with-x")
          shift
          WITH_X=${1}
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

# Recompute install path now that EMACS_VERSION may have been overridden.
# --install-path is treated as a PARENT directory: the leaf appends
# emacs-v${EMACS_VERSION} itself, so main_setup.sh can stay version-agnostic
# (same convention as the migrated extras leaves / miniconda3_setup.sh). When
# --install-path is omitted the legacy /opt/emacs-v${EMACS_VERSION} default is
# used verbatim.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}/emacs-v${EMACS_VERSION}
else
   INSTALL_PATH=/opt/emacs-v${EMACS_VERSION}
fi

echo ""
echo "==================================="
echo "Starting EMACS Install with"
echo "BUILD_EMACS: $BUILD_EMACS"
echo "EMACS_VERSION: $EMACS_VERSION"
echo "INSTALL_PATH: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "NATIVE_COMP: $NATIVE_COMP"
echo "WITH_X: $WITH_X"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

# ── BUILD_EMACS=0 short-circuit: operator opt-out ─────────────────────
# NOOP_RC=43 so main_setup.sh's run_and_log records this as SKIPPED(no-op)
# rather than OK-bucketing a build that never happened (see likwid_setup.sh).
NOOP_RC=43
if [ "${BUILD_EMACS}" = "0" ]; then
   echo "[emacs BUILD_EMACS=0] operator opt-out; skipping (no source build)."
   exit ${NOOP_RC}
fi

# ── modulefile paths (both flavors tracked for --replace + fail-cleanup) ─
# Lmod consumes <ver>.lua, classic Tcl Environment Modules consumes an
# extensionless Tcl file. Track both so --replace and the fail-cleanup trap
# remove whichever was written previously.
MODULEFILE_LUA="${MODULE_PATH}/${EMACS_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${EMACS_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[emacs --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if this version is already installed ─────────
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[emacs existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                        pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
# On a non-zero exit remove partial artifacts so the next sweep starts
# clean. Skipped when --keep-failed-installs 1. Build-dir rm is folded in
# here (reads ${EMACS_BUILD_ROOT} lazily) so we do NOT register a second
# EXIT trap that would silently replace this one (likwid/hpctoolkit audit).
_emacs_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[emacs fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[emacs fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   if [ -n "${EMACS_BUILD_ROOT:-}" ] && [ -d "${EMACS_BUILD_ROOT}" ]; then
      ${SUDO:-sudo} rm -rf "${EMACS_BUILD_ROOT}"
   fi
   return ${rc}
}
trap _emacs_on_exit EXIT

# ── build dependencies ────────────────────────────────────────────────
# OS default gcc major version -- used both as the emacs CC and to pick the
# matching libgccjit-<ver>-dev for native-comp.
GCC_VER=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
TRIPLE=$(gcc -dumpmachine 2>/dev/null)
: ${GCC_VER:=13}
: ${TRIPLE:=x86_64-linux-gnu}

if [ "${DISTRO}" = "ubuntu" ]; then
   EMACS_DEPS="build-essential autoconf automake texinfo pkg-config \
               libgnutls28-dev libncurses-dev libjansson-dev \
               libtree-sitter-dev zlib1g-dev xz-utils wget"

   if [ "${WITH_X}" = "1" ]; then
      EMACS_DEPS="${EMACS_DEPS} libgtk-3-dev libgif-dev libtiff-dev \
                  libjpeg-dev libpng-dev librsvg2-dev libxpm-dev"
   fi

   if [ "${NATIVE_COMP}" = "1" ]; then
      # libgccjit for the OS default gcc. NOTE (see header policy): on noble
      # this resolves the libgccjit0 runtime to the gcc-14 build and pulls
      # libgcc-14-dev, recreating /usr/lib/gcc/${TRIPLE}/14. We deliberately do
      # NOT install libstdc++-14-dev to "complete" that dir -- doing so would
      # make ROCm clang prefer gcc-14 and shift the toolchain for other builds.
      echo "[emacs] WARNING: --native-comp 1 pulls libgccjit -> libgcc-14-dev on this host;"
      echo "        /usr/lib/gcc/${TRIPLE}/14 will reappear. libstdc++-14-dev is intentionally"
      echo "        NOT installed, so on a host that also builds with ROCm clang this can"
      echo "        reproduce the cmath/cstdlib failure (slurm-13278). Prefer --native-comp 0."
      EMACS_DEPS="${EMACS_DEPS} libgccjit-${GCC_VER}-dev"
   fi

   echo "[emacs] installing build deps (gcc ${GCC_VER}, triple ${TRIPLE}) ..."
   ${SUDO} ${DEB_FRONTEND} apt-get update -q -y || true
   ${SUDO} ${DEB_FRONTEND} apt-get install -q -y ${EMACS_DEPS}
else
   echo "[emacs] WARNING: automatic build-dep install is only wired up for Ubuntu."
   echo "        DISTRO='${DISTRO}' detected -- assuming a C toolchain, texinfo, gnutls,"
   echo "        ncurses, jansson, tree-sitter (and libgccjit for native-comp) are present."
fi

# ── install-path sudo: probe nearest existing ancestor for writability ─
# (mirrors likwid/petsc). EUID 0 needs no sudo regardless.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _iprobe="${INSTALL_PATH}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .emacs-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "emacs: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "emacs: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

${SUDO} mkdir -p ${INSTALL_PATH}
if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod -R a+rwX ${INSTALL_PATH}
fi

echo ""
echo "============================"
echo " Building EMACS ${EMACS_VERSION}"
echo "============================"
echo ""

# Per-job throwaway build dir (cleaned by _emacs_on_exit; do NOT add a
# second EXIT trap here -- it would disable the fail-cleanup above).
EMACS_BUILD_ROOT=$(mktemp -d -t emacs-build.XXXXXX)
cd "${EMACS_BUILD_ROOT}"
wget -q https://ftp.gnu.org/gnu/emacs/emacs-${EMACS_VERSION}.tar.xz
tar -xf emacs-${EMACS_VERSION}.tar.xz
cd emacs-${EMACS_VERSION}

# Build the C sources with the OS default gcc.
export CC=gcc
export CXX=g++

# Assemble configure flags.
CONFIGURE_FLAGS="--prefix=${INSTALL_PATH} --with-gnutls --with-json --with-tree-sitter --with-modules"
if [ "${WITH_X}" = "1" ]; then
   CONFIGURE_FLAGS="${CONFIGURE_FLAGS} --with-x-toolkit=gtk3"
else
   CONFIGURE_FLAGS="${CONFIGURE_FLAGS} --without-x --without-ns"
fi
if [ "${NATIVE_COMP}" = "1" ]; then
   # aot: ahead-of-time native-compile all bundled elisp at build time, so
   # the shared module is fully native-compiled once (no per-user JIT churn).
   CONFIGURE_FLAGS="${CONFIGURE_FLAGS} --with-native-compilation=aot"
else
   CONFIGURE_FLAGS="${CONFIGURE_FLAGS} --without-native-compilation"
fi

echo "[emacs] ./configure ${CONFIGURE_FLAGS}"
./configure ${CONFIGURE_FLAGS}
make -j"$(nproc)"
${SUDO} make install

# trap handles cleanup of ${EMACS_BUILD_ROOT}

# Normalize ownership to root only when we installed with elevation.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
   ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
   ${SUDO} chmod go-w ${INSTALL_PATH}
fi

# ── modulefile ────────────────────────────────────────────────────────
# Modulefile-write sudo: probe the module tree for user-writability so a
# user-owned module tree needs no sudo (mirrors likwid/petsc).
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .emacs-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"
      PKG_SUDO_MOD=""
      echo "emacs: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
   else
      PKG_SUDO_MOD="sudo"
      echo "emacs: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
   fi
   unset _mprobe _mtest
fi
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

# Provenance: capture this leaf script's git state for the modulefile
# whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured at the
# top before any cd). Self-contained: falls back to "unknown" when run from
# a stripped-of-.git context (Docker layer, release tarball, no git).
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

# native-comp banner state for the modulefile load message.
if [ "${NATIVE_COMP}" = "1" ]; then
   EMACS_NC_TAG="native-comp"
   EMACS_NC_MSG="Native compilation ENABLED (built with gcc ${GCC_VER}; libgccjit JIT backend). Requires libgccjit0 present at runtime on this node."
else
   EMACS_NC_TAG="byte-comp"
   EMACS_NC_MSG="Native compilation DISABLED (byte-compiled). No libgccjit/gcc-14 runtime dependency."
fi

# ── Modulefile flavor: Lua (Lmod) vs Tcl (classic Environment Modules) ─
if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
   MODULEFILE="${MODULEFILE_LUA}"; MODFLAVOR="lua"
else
   MODULEFILE="${MODULEFILE_TCL}"; MODFLAVOR="tcl"
fi

# The - option suppresses leading tabs.
if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("GNU Emacs ${EMACS_VERSION} (${EMACS_NC_TAG})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${INSTALL_PATH}"

	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("MANPATH", pathJoin(base, "share/man"))
	prepend_path("INFOPATH", pathJoin(base, "share/info"))

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#####################################################################")
	  LmodMessage("#  GNU Emacs ${EMACS_VERSION}  (${EMACS_NC_TAG})")
	  LmodMessage("#  ${EMACS_NC_MSG}")
	  LmodMessage("#####################################################################")
	  LmodMessage("")
	end
EOF
else
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "GNU Emacs ${EMACS_VERSION} (${EMACS_NC_TAG})"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${INSTALL_PATH}"

	prepend-path PATH \$base/bin
	prepend-path MANPATH \$base/share/man
	prepend-path INFOPATH \$base/share/info

	if { [module-info mode load] } {
	  puts stderr ""
	  puts stderr "#####################################################################"
	  puts stderr "#  GNU Emacs ${EMACS_VERSION}  (${EMACS_NC_TAG})"
	  puts stderr "#  ${EMACS_NC_MSG}"
	  puts stderr "#####################################################################"
	  puts stderr ""
	}
EOF
fi

echo ""
echo "[emacs] install complete: ${INSTALL_PATH}"
echo "[emacs] modulefile:       ${MODULEFILE} (${MODFLAVOR})"
echo ""
