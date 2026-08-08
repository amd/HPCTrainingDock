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
# Google Chrome install + Lmod/Tcl modulefile, in the HPCTrainingDock
# leaf-setup style (mirrors emacs_setup.sh / turbovnc_setup.sh).
#
# WHY THIS EXISTS: the no-VNC XFCE desktop on the AAC6 nodes has no browser,
# so viewing a Perfetto trace (ui.perfetto.dev) for the TAU/ROCm tutorial is
# hard. The apt `firefox`/`chromium-browser` packages on Ubuntu 24.04 are snap
# shims that do not work in this environment, so we install real Google Chrome.
#
# WHY A MODULE ON NFS (not the Warewulf image): like emacs/turbovnc/miniconda3
# this is a ROCm-agnostic tool installed ONCE under the shared NFS apps tree
# (TOP_INSTALL_PATH) with a modulefile -- `module load google-chrome` -- so it
# is shared across every ROCm version and can be updated without rebuilding or
# reimaging the golden node image.
#
# HOW: Chrome's .deb is extracted with `dpkg-deb -x` into the NFS prefix (no
# root, no system apt). Two commands are put on PATH via the module:
#   google-chrome     - Chrome itself (sandbox auto-handled; see below)
#   perfetto-viewer   - opens ui.perfetto.dev in Chrome, tuned for the software-
#                       rendered VNC display (--disable-gpu, per-user profile)
#
# SANDBOX NOTE (Ubuntu 24.04): the extracted chrome-sandbox helper is not
# setuid-root and Ubuntu 24.04 restricts unprivileged user namespaces, so
# Chrome's sandbox cannot initialise from an NFS install. The `google-chrome`
# wrapper therefore adds --no-sandbox when the kernel reports userns is
# restricted. This is an acceptable, documented trade-off for a passwordless
# training cluster whose only use of the browser is viewing LOCAL trace files.
#
# RUNTIME LIBS: the extracted Chrome links system libs (libnss3, libgbm1,
# libasound2, libxkbcommon0, libgtk-3-0, ...). Those come from the NODE image,
# not from NFS. This script only WARNS if any are missing (`ldd ... not found`);
# add missing ones to the node image via
# rocm/scripts/baseospackages_setup.sh /
# infrastructure/warewulf-image-mods/profiler-gui-deps/.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/LinuxPlus/google-chrome
BUILD_GOOGLE_CHROME=1
# Rolling release: "stable" fetches the current google-chrome-stable .deb. The
# label is only used for the install-dir + modulefile name; the ACTUAL Chrome
# version is read from the downloaded .deb and shown in the modulefile whatis.
GOOGLE_CHROME_VERSION=stable
INSTALL_PATH=/opt/google-chrome-v${GOOGLE_CHROME_VERSION}
INSTALL_PATH_INPUT=""
# Direct .deb URL (amd64). "stable" -> the _current_ stable deb.
CHROME_DEB_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
# --replace 1: rm -rf the prior install dir + modulefile BEFORE installing.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so a partial
# install + modulefile are left on disk for post-mortem. (Canonical
# emacs/hypre template pattern.)
REPLACE=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"

if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-google-chrome [ 0|1 ]   default $BUILD_GOOGLE_CHROME"
   echo "  --google-chrome-version [ VER ] label for install dir + modulefile, default $GOOGLE_CHROME_VERSION (only 'stable' is fetchable)"
   echo "  --module-path [ PATH ]          default $MODULE_PATH"
   echo "  --install-path [ PATH ]         PARENT dir; leaf appends google-chrome-v\${GOOGLE_CHROME_VERSION}. default parent of $INSTALL_PATH"
   echo "  --replace [ 0|1 ]               remove prior install + modulefile before installing, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ]  skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
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
      "--build-google-chrome")
          shift
          BUILD_GOOGLE_CHROME=${1}
          reset-last
          ;;
      "--google-chrome-version")
          shift
          GOOGLE_CHROME_VERSION=${1}
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

# Recompute install path now that GOOGLE_CHROME_VERSION may have been
# overridden. --install-path is treated as a PARENT directory: the leaf appends
# google-chrome-v${GOOGLE_CHROME_VERSION} itself, so main_setup.sh can stay
# version-agnostic (same convention as emacs/turbovnc/miniconda3). When
# --install-path is omitted the legacy /opt/google-chrome-v${VER} default is used.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}/google-chrome-v${GOOGLE_CHROME_VERSION}
else
   INSTALL_PATH=/opt/google-chrome-v${GOOGLE_CHROME_VERSION}
fi

echo ""
echo "==================================="
echo "Starting Google Chrome Install with"
echo "BUILD_GOOGLE_CHROME: $BUILD_GOOGLE_CHROME"
echo "GOOGLE_CHROME_VERSION: $GOOGLE_CHROME_VERSION"
echo "INSTALL_PATH: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

# ── BUILD_GOOGLE_CHROME=0 short-circuit: operator opt-out ─────────────
# NOOP_RC=43 so main_setup.sh's run_and_log records this as SKIPPED(no-op)
# rather than OK-bucketing an install that never happened (see emacs_setup.sh).
NOOP_RC=43
if [ "${BUILD_GOOGLE_CHROME}" = "0" ]; then
   echo "[google-chrome BUILD_GOOGLE_CHROME=0] operator opt-out; skipping."
   exit ${NOOP_RC}
fi

# ── Platform guard: Chrome .deb + dpkg-deb are Debian/Ubuntu only ─────
if [ "${DISTRO}" != "ubuntu" ] && [ "${DISTRO}" != "debian" ]; then
   echo "[google-chrome] DISTRO='${DISTRO}' is not Debian/Ubuntu; the .deb install path"
   echo "                does not apply here. Skipping (no-op)."
   exit ${NOOP_RC}
fi
if ! command -v dpkg-deb >/dev/null 2>&1; then
   echo "[google-chrome] dpkg-deb not found; cannot extract the Chrome .deb. Skipping (no-op)."
   exit ${NOOP_RC}
fi

# ── modulefile paths (both flavors tracked for --replace + fail-cleanup) ─
MODULEFILE_LUA="${MODULE_PATH}/${GOOGLE_CHROME_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${GOOGLE_CHROME_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[google-chrome --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if already installed ────────────────────────
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[google-chrome existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                                pass --replace 1 to force a clean reinstall (e.g. to pull a newer Chrome)."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
_gc_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[google-chrome fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[google-chrome fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   if [ -n "${GC_BUILD_ROOT:-}" ] && [ -d "${GC_BUILD_ROOT}" ]; then
      rm -rf "${GC_BUILD_ROOT}"
   fi
   return ${rc}
}
trap _gc_on_exit EXIT

# ── install-path sudo: probe nearest existing ancestor for writability ─
# (mirrors emacs/likwid). EUID 0 needs no sudo regardless.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _iprobe="${INSTALL_PATH}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .gc-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "google-chrome: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "google-chrome: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

${SUDO} mkdir -p ${INSTALL_PATH}
if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod -R a+rwX ${INSTALL_PATH}
fi

echo ""
echo "============================"
echo " Installing Google Chrome (${GOOGLE_CHROME_VERSION})"
echo "============================"
echo ""

if [ "${GOOGLE_CHROME_VERSION}" != "stable" ]; then
   echo "google-chrome: WARNING: only 'stable' is fetchable from Google's direct .deb URL;"
   echo "               '${GOOGLE_CHROME_VERSION}' will still install the current stable .deb."
fi

# Per-job throwaway download dir (cleaned by _gc_on_exit).
GC_BUILD_ROOT=$(mktemp -d -t google-chrome.XXXXXX)
cd "${GC_BUILD_ROOT}"

echo "google-chrome: downloading ${CHROME_DEB_URL}"
wget -q "${CHROME_DEB_URL}" -O google-chrome.deb \
   || { echo "ERROR: download of ${CHROME_DEB_URL} failed (no route to dl.google.com?)"; exit 1; }

# Record the real Chrome version from the .deb control metadata for the whatis.
CHROME_ACTUAL_VERSION="$(dpkg-deb -f google-chrome.deb Version 2>/dev/null || echo unknown)"
echo "google-chrome: .deb Version = ${CHROME_ACTUAL_VERSION}"

# Extract the .deb payload into a USER-OWNED staging dir first, then copy it
# into the (possibly root-owned) NFS prefix with ${SUDO}. dpkg-deb -x sets the
# mode/mtime of its extraction root ('.') to match the archive; extracting
# straight into a root-owned ${INSTALL_PATH} fails with
#   tar: .: Cannot utime / Cannot change mode: Operation not permitted
# (the earlier failure). Staging under the user-owned GC_BUILD_ROOT lets
# dpkg-deb set those bits freely; the elevated copy then only writes files into
# the a+rwX prefix (also correct under NFS root_squash).
echo "google-chrome: extracting into ${INSTALL_PATH}"
GC_STAGE="${GC_BUILD_ROOT}/payload"
mkdir -p "${GC_STAGE}"
dpkg-deb -x google-chrome.deb "${GC_STAGE}"
${SUDO} cp -a "${GC_STAGE}/." "${INSTALL_PATH}/"

# The .deb stages Chrome under <prefix>/opt/google/chrome.
CHROME_DIR="${INSTALL_PATH}/opt/google/chrome"
if [ ! -x "${CHROME_DIR}/chrome" ]; then
   echo "ERROR: expected chrome binary not found at ${CHROME_DIR}/chrome after extract"; exit 1
fi

# ── Runtime-lib check (WARN only; these come from the node image) ─────
echo "google-chrome: checking runtime libraries (ldd)"
MISSING_LIBS="$(ldd "${CHROME_DIR}/chrome" 2>/dev/null | awk '/not found/{print $1}' | sort -u || true)"
if [ -n "${MISSING_LIBS}" ]; then
   echo "google-chrome: WARNING: the following libraries are missing on THIS host:"
   echo "${MISSING_LIBS}" | sed 's/^/    /'
   echo "google-chrome: Chrome will not launch on a node lacking these. Add them to the"
   echo "               node image (baseospackages_setup.sh / profiler-gui-deps). Typical"
   echo "               Chrome deps: libnss3 libgbm1 libasound2t64 libxkbcommon0 libgtk-3-0"
   echo "               libxdamage1 libxcomposite1 libxrandr2 libxfixes3 libcups2t64 libdrm2"
   echo "               (Ubuntu 24.04 renamed libasound2/libcups2 to the *t64 packages; the"
   echo "                .so names libasound.so.2 / libcups.so.2 are unchanged)."
else
   echo "google-chrome: all runtime libraries resolved on this host."
fi

# ── Wrappers on PATH: <prefix>/bin/{google-chrome,perfetto-viewer} ────
BIN_DIR="${INSTALL_PATH}/bin"
${SUDO} mkdir -p "${BIN_DIR}"

# google-chrome: launch the extracted chrome, auto-handling the sandbox. On a
# node where unprivileged user namespaces are restricted (Ubuntu 24.04 default)
# and with no setuid chrome-sandbox (NFS install), the sandbox cannot start, so
# add --no-sandbox in that case only.
${SUDO} tee "${BIN_DIR}/google-chrome" >/dev/null <<GC_EOF
#!/bin/bash
# Wrapper generated by google-chrome_setup.sh. Runs the NFS-extracted Chrome.
CHROME_DIR="${CHROME_DIR}"
SANDBOX_FLAG=""
if [ "\$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
   # Extracted chrome-sandbox is not setuid-root and userns is restricted ->
   # the sandbox cannot initialise; fall back to --no-sandbox (see setup header).
   SANDBOX_FLAG="--no-sandbox"
fi
exec "\${CHROME_DIR}/chrome" \${SANDBOX_FLAG} "\$@"
GC_EOF
${SUDO} chmod 0755 "${BIN_DIR}/google-chrome"

# perfetto-viewer: open the Perfetto UI tuned for the software-rendered VNC
# display. The Perfetto UI is client-side -- once open, use "Open trace file"
# to load a local *.pftrace / TAU trace; nothing is uploaded.
${SUDO} tee "${BIN_DIR}/perfetto-viewer" >/dev/null <<PV_EOF
#!/bin/bash
# Wrapper generated by google-chrome_setup.sh.
#   --user-data-dir : per-user profile (avoids NFS \$HOME singleton-lock clashes)
#   --disable-gpu   : the VNC display has no hardware GL (Xvnc swrast); force
#                     software rendering so the GPU process cannot crash the tab
exec "${BIN_DIR}/google-chrome" \\
  --user-data-dir="\${HOME}/.config/perfetto-chrome" \\
  --disable-gpu \\
  --new-window \\
  "https://ui.perfetto.dev" "\$@"
PV_EOF
${SUDO} chmod 0755 "${BIN_DIR}/perfetto-viewer"

# trap handles cleanup of ${GC_BUILD_ROOT}

# ── Normalize ownership + permissions of the installed tree ───────────
# Ownership: chown to root only when a NON-root installer used elevation
# (${SUDO} non-empty). A root installer, or a user-writable NFS prefix where the
# ancestor probe cleared ${SUDO}, needs no chown (files are already root- or
# user-owned, and chown root:root without sudo would fail anyway).
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
   ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
fi
# Permissions: this MUST run for EVERY install path -- root, non-root+sudo, and
# user-writable-prefix (no sudo) -- not just the elevated non-root one. Chrome's
# .deb stages its top-level dir (opt/google/chrome) as 0750 (rwxr-x---) and
# `cp -a` preserves that, so a DIFFERENT user cannot traverse into
# ${INSTALL_PATH}: `module load google-chrome` prepends <prefix>/bin to PATH but
# `which google-chrome` then finds nothing (observed with workshop users). Force
# the whole tree world-readable + world-traversable (a+rX: read for files, +x
# only on dirs and already-executable files), THEN drop group/other write for
# safety (also clearing the transient a+rwX set on the fresh prefix above). A
# non-recursive `chmod go-w` alone left the 0750 top dir unreadable, and gating
# this behind `${SUDO}`/`USER!=root` skipped it on root and user-writable-prefix
# installs -- both reintroduce the traversal bug. ${SUDO} is an empty no-op when
# the files are already user- or root-owned, so this is correct in every case.
${SUDO} chmod -R a+rX ${INSTALL_PATH}
${SUDO} chmod -R go-w ${INSTALL_PATH}

# ── modulefile ────────────────────────────────────────────────────────
# Modulefile-write sudo: probe the module tree for user-writability so a
# user-owned module tree needs no sudo (mirrors emacs/likwid).
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .gc-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"
      PKG_SUDO_MOD=""
      echo "google-chrome: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
   else
      PKG_SUDO_MOD="sudo"
      echo "google-chrome: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
   fi
   unset _mprobe _mtest
fi
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

# Provenance: capture this leaf script's git state for the modulefile whatis()
# line below. Uses LEAF_SCRIPT_PATH (absolute path captured at the top before
# any cd). Self-contained: falls back to "unknown" when run from a stripped-of-
# .git context (Docker layer, release tarball, no git).
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
	whatis("Google Chrome ${CHROME_ACTUAL_VERSION} (for viewing Perfetto traces)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${INSTALL_PATH}"

	prepend_path("PATH", pathJoin(base, "bin"))

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#####################################################################")
	  LmodMessage("#  Google Chrome ${CHROME_ACTUAL_VERSION}")
	  LmodMessage("#  Run 'perfetto-viewer' to open ui.perfetto.dev, then load a local")
	  LmodMessage("#  *.pftrace / TAU trace via 'Open trace file' (nothing is uploaded).")
	  LmodMessage("#  Sandbox: --no-sandbox is auto-added on nodes with restricted")
	  LmodMessage("#  unprivileged user namespaces (see aac6_tau(7)).")
	  LmodMessage("#####################################################################")
	  LmodMessage("")
	end
EOF
else
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "Google Chrome ${CHROME_ACTUAL_VERSION} (for viewing Perfetto traces)"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${INSTALL_PATH}"

	prepend-path PATH \$base/bin

	if { [module-info mode load] } {
	  puts stderr ""
	  puts stderr "#####################################################################"
	  puts stderr "#  Google Chrome ${CHROME_ACTUAL_VERSION}"
	  puts stderr "#  Run 'perfetto-viewer' to open ui.perfetto.dev, then load a local"
	  puts stderr "#  *.pftrace / TAU trace via 'Open trace file' (nothing is uploaded)."
	  puts stderr "#####################################################################"
	  puts stderr ""
	}
EOF
fi

echo ""
echo "[google-chrome] install complete: ${INSTALL_PATH}"
echo "[google-chrome] chrome:           ${CHROME_DIR}/chrome (version ${CHROME_ACTUAL_VERSION})"
echo "[google-chrome] commands on PATH: google-chrome, perfetto-viewer"
echo "[google-chrome] modulefile:       ${MODULEFILE} (${MODFLAVOR})"
echo ""
