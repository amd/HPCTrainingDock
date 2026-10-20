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
# Zellij terminal multiplexer: prebuilt static-musl binary + Lmod/Tcl
# modulefile, in the HPCTrainingDock leaf-setup style (mirrors
# emacs_setup.sh / google-chrome_setup.sh -- a ROCm-agnostic base tool).
#
# Zellij ships a single statically linked musl binary per release
# (zellij-<arch>-unknown-linux-musl.tar.gz), so there is NO source build
# and NO apt build-deps: we download, extract the one binary, and write a
# PATH-only modulefile. The binary is distro-agnostic, so the same install
# serves the 24.04 login node and any 22.04 compute node.
#
# Deliberately provisioned as an OPT-IN module only: no /etc/profile.d
# auto-attach wrapper (that would break non-interactive SSH -- scp, rsync,
# git-over-ssh, and the *-cursor-batch riders all run `bash -lc`) and no
# web_server exposure (keep everything inside the existing SSH + 2FA path
# on the single fe1 NIC). Users run: module load zellij && zellij attach -c <name>
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/LinuxPlus/zellij
BUILD_ZELLIJ=1
ZELLIJ_VERSION=0.45.1
INSTALL_PATH=/opt/zellij-v${ZELLIJ_VERSION}
INSTALL_PATH_INPUT=""
# --replace 1: rm -rf the prior install dir + modulefile BEFORE installing.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so a partial
# install + modulefile are left on disk for post-mortem. (Canonical
# emacs/likwid template pattern.)
REPLACE=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"

if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-zellij [ 0|1 ]       default $BUILD_ZELLIJ"
   echo "  --zellij-version [ VER ]     default $ZELLIJ_VERSION"
   echo "  --module-path [ PATH ]       default $MODULE_PATH"
   echo "  --install-path [ PATH ]      PARENT dir; leaf appends zellij-v\${ZELLIJ_VERSION}. default parent of $INSTALL_PATH"
   echo "  --replace [ 0|1 ]            remove prior install + modulefile before installing, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --rocm-version [ VER ]       accepted and ignored (ROCm-agnostic tool)"
   echo "  --amdgpu-gfxmodel [ GFX ]    accepted and ignored (ROCm-agnostic tool)"
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
      "--build-zellij")
          shift
          BUILD_ZELLIJ=${1}
          reset-last
          ;;
      "--zellij-version")
          shift
          ZELLIJ_VERSION=${1}
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
      # Accept-and-ignore the COMMON_OPTIONS that main_setup.sh threads to
      # ROCm-aware leaves; Zellij is ROCm-agnostic so they are no-ops here.
      "--rocm-version")
          shift
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
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

# Recompute install path now that ZELLIJ_VERSION may have been overridden.
# --install-path is treated as a PARENT directory: the leaf appends
# zellij-v${ZELLIJ_VERSION} itself, so main_setup.sh can stay version-agnostic
# (same convention as emacs_setup.sh / miniconda3_setup.sh). When
# --install-path is omitted the legacy /opt/zellij-v${ZELLIJ_VERSION} default
# is used verbatim.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}/zellij-v${ZELLIJ_VERSION}
else
   INSTALL_PATH=/opt/zellij-v${ZELLIJ_VERSION}
fi

# Map the host arch to Zellij's release target triple.
UNAME_M=$(uname -m)
case "${UNAME_M}" in
   x86_64)  ZELLIJ_TARGET="x86_64-unknown-linux-musl" ;;
   aarch64) ZELLIJ_TARGET="aarch64-unknown-linux-musl" ;;
   *)       send-error "Unsupported architecture '${UNAME_M}' (Zellij publishes x86_64 and aarch64 musl builds)" ;;
esac
ZELLIJ_TARBALL="zellij-${ZELLIJ_TARGET}.tar.gz"
ZELLIJ_URL="https://github.com/zellij-org/zellij/releases/download/v${ZELLIJ_VERSION}/${ZELLIJ_TARBALL}"

echo ""
echo "==================================="
echo "Starting ZELLIJ Install with"
echo "BUILD_ZELLIJ: $BUILD_ZELLIJ"
echo "ZELLIJ_VERSION: $ZELLIJ_VERSION"
echo "ZELLIJ_TARGET: $ZELLIJ_TARGET"
echo "INSTALL_PATH: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

# ── BUILD_ZELLIJ=0 short-circuit: operator opt-out ────────────────────
# NOOP_RC=43 so main_setup.sh's run_and_log records this as SKIPPED(no-op)
# rather than OK-bucketing an install that never happened (see emacs_setup.sh).
NOOP_RC=43
if [ "${BUILD_ZELLIJ}" = "0" ]; then
   echo "[zellij BUILD_ZELLIJ=0] operator opt-out; skipping (no install)."
   exit ${NOOP_RC}
fi

# ── modulefile paths (both flavors tracked for --replace + fail-cleanup) ─
# Lmod consumes <ver>.lua, classic Tcl Environment Modules consumes an
# extensionless Tcl file. Track both so --replace and the fail-cleanup trap
# remove whichever was written previously.
MODULEFILE_LUA="${MODULE_PATH}/${ZELLIJ_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${ZELLIJ_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[zellij --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if this version is already installed ─────────
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[zellij existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                         pass --replace 1 to force a clean reinstall of this version."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
# On a non-zero exit remove partial artifacts so the next sweep starts
# clean. Skipped when --keep-failed-installs 1. Build-dir rm is folded in
# here (reads ${ZELLIJ_BUILD_ROOT} lazily) so we do NOT register a second
# EXIT trap that would silently replace this one (emacs/likwid audit).
_zellij_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[zellij fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[zellij fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   if [ -n "${ZELLIJ_BUILD_ROOT:-}" ] && [ -d "${ZELLIJ_BUILD_ROOT}" ]; then
      rm -rf "${ZELLIJ_BUILD_ROOT}"
   fi
   return ${rc}
}
trap _zellij_on_exit EXIT

# ── install-path sudo: probe nearest existing ancestor for writability ─
# (mirrors emacs/likwid/petsc). EUID 0 needs no sudo regardless. The outbound
# HTTP(S) proxy, when needed, is inherited from the environment (the sweep
# preamble derives it and rejects loopback proxies before this leaf runs).
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _iprobe="${INSTALL_PATH}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .zellij-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "zellij: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "zellij: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

${SUDO} mkdir -p ${INSTALL_PATH}/bin ${INSTALL_PATH}/share/zellij
if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod -R a+rwX ${INSTALL_PATH}
fi

echo ""
echo "============================"
echo " Installing ZELLIJ ${ZELLIJ_VERSION}"
echo "============================"
echo ""

# Per-job throwaway download/extract dir (cleaned by _zellij_on_exit; do NOT
# add a second EXIT trap here -- it would disable the fail-cleanup above).
ZELLIJ_BUILD_ROOT=$(mktemp -d -t zellij-dl.XXXXXX)
cd "${ZELLIJ_BUILD_ROOT}"

echo "[zellij] downloading ${ZELLIJ_URL}"
wget -q "${ZELLIJ_URL}" -O "${ZELLIJ_TARBALL}"
tar -xf "${ZELLIJ_TARBALL}"
if [ ! -f zellij ]; then
   send-error "expected a 'zellij' binary in ${ZELLIJ_TARBALL} but none was extracted"
fi
chmod +x zellij

# Sanity-check the extracted binary reports the expected version before we
# commit it to the shared tree (also proves it runs on this host arch/libc).
EXTRACTED_VER="$(./zellij --version 2>/dev/null | awk '{print $NF}')"
echo "[zellij] extracted binary reports version: ${EXTRACTED_VER:-unknown}"
if [ -n "${EXTRACTED_VER}" ] && [ "${EXTRACTED_VER}" != "${ZELLIJ_VERSION}" ]; then
   send-error "version mismatch: binary is ${EXTRACTED_VER}, expected ${ZELLIJ_VERSION}"
fi

${SUDO} cp zellij ${INSTALL_PATH}/bin/zellij
${SUDO} chmod 755 ${INSTALL_PATH}/bin/zellij

# Ship an OPT-IN example config (not auto-loaded). Users copy it to
# ~/.config/zellij/config.kdl if they want these cluster-friendly defaults:
# detach (not kill) on force-close so sessions survive drops; mouse on for
# easy tab/scroll; a bounded scrollback to protect the shared fe1 memory
# footprint when many users keep sessions alive.
_cfg="${ZELLIJ_BUILD_ROOT}/example-config.kdl"
cat > "${_cfg}" <<'KDL'
// Example Zellij config for AAC6 -- OPT-IN.
// Copy to ~/.config/zellij/config.kdl (or `module load zellij` and run
// `zellij setup --dump-config > ~/.config/zellij/config.kdl` to start from
// the full upstream default) and edit to taste.

// Detach (keep the session alive on the login node) instead of killing it
// when the last client force-closes -- this is what makes a session survive
// an SSH/Wi-Fi drop so you can `zellij attach <name>` again later.
on_force_close "detach"

// Mouse support for scrolling and clicking tabs/panes.
mouse_mode true

// Bound the per-session scrollback so many concurrent sessions do not grow
// the login-node memory footprint without limit.
scroll_buffer_size 10000

// NOTE: the built-in web_server is intentionally left OFF on AAC6. Attach
// over the normal SSH + 2FA path instead.
KDL
${SUDO} cp "${_cfg}" ${INSTALL_PATH}/share/zellij/example-config.kdl

# trap handles cleanup of ${ZELLIJ_BUILD_ROOT}

# Normalize ownership to root only when we installed with elevation.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
   ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
   ${SUDO} chmod -R go-w ${INSTALL_PATH}
fi

# ── modulefile ────────────────────────────────────────────────────────
# Modulefile-write sudo: probe the module tree for user-writability so a
# user-owned module tree needs no sudo (mirrors emacs/likwid/petsc).
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .zellij-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"
      PKG_SUDO_MOD=""
      echo "zellij: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
   else
      PKG_SUDO_MOD="sudo"
      echo "zellij: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
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

# ── Modulefile flavor: Lua (Lmod) vs Tcl (classic Environment Modules) ─
if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
   MODULEFILE="${MODULEFILE_LUA}"; MODFLAVOR="lua"
else
   MODULEFILE="${MODULEFILE_TCL}"; MODFLAVOR="tcl"
fi

# The - option suppresses leading tabs.
if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("Zellij terminal multiplexer ${ZELLIJ_VERSION} (static musl binary)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${INSTALL_PATH}"

	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("ZELLIJ_EXAMPLE_CONFIG", pathJoin(base, "share/zellij/example-config.kdl"))

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#####################################################################")
	  LmodMessage("#  Zellij ${ZELLIJ_VERSION} -- dropout-resilient terminal multiplexer")
	  LmodMessage("#  Start/resume a session:  zellij attach -c <name>")
	  LmodMessage("#  Detach without killing:  Ctrl-o d   (reconnect, then re-attach)")
	  LmodMessage("#  Example config:          \$ZELLIJ_EXAMPLE_CONFIG")
	  LmodMessage("#    -> copy to ~/.config/zellij/config.kdl to opt in")
	  LmodMessage("#####################################################################")
	  LmodMessage("")
	end
EOF
else
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "Zellij terminal multiplexer ${ZELLIJ_VERSION} (static musl binary)"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${INSTALL_PATH}"

	prepend-path PATH \$base/bin
	setenv ZELLIJ_EXAMPLE_CONFIG \$base/share/zellij/example-config.kdl

	if { [module-info mode load] } {
	  puts stderr ""
	  puts stderr "#####################################################################"
	  puts stderr "#  Zellij ${ZELLIJ_VERSION} -- dropout-resilient terminal multiplexer"
	  puts stderr "#  Start/resume a session:  zellij attach -c <name>"
	  puts stderr "#  Detach without killing:  Ctrl-o d   (reconnect, then re-attach)"
	  puts stderr "#  Example config:          \$base/share/zellij/example-config.kdl"
	  puts stderr "#    -> copy to ~/.config/zellij/config.kdl to opt in"
	  puts stderr "#####################################################################"
	  puts stderr ""
	}
EOF
fi

echo ""
echo "[zellij] install complete: ${INSTALL_PATH}"
echo "[zellij] modulefile:       ${MODULEFILE} (${MODFLAVOR})"
echo ""
