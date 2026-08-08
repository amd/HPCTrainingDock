#!/bin/bash

# TurboVNC server setup for HPC compute nodes.
#
# Builds TurboVNC (server-only) from the tagged source release at a chosen prefix
# so the Xvnc-compiled security-config path points at that prefix (rather than a
# stale hardcoded location), configures a "None"-only security type (remote-desktop
# access is gated UPSTREAM by the nginx TOTP reverse proxy -- cluster accounts are
# SSH-key-only and have no Unix/PAM password, so VeNCrypt/UnixLogin cannot be used),
# disables the in-session XFCE screen lockers that would otherwise trap those
# passwordless users behind an unpassable lightdm greeter, and writes an Lmod
# modulefile.

# Capture this script's absolute path BEFORE any cd, so the inline git-provenance
# block lower down can resolve the script in the repo even after the build has cd'd
# into a temp dir. (BASH_SOURCE[0] is whatever path was used to invoke the script --
# often relative when called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Variables controlling setup process
BUILD_TURBOVNC=1
TURBOVNC_VERSION=3.0.3
INSTALL_PATH=/opt/turbovnc-v${TURBOVNC_VERSION}
INSTALL_PATH_INPUT=""
MODULE_PATH=/etc/lmod/modules/LinuxPlus/turbovnc
SECURITY_TYPES="None"
WM="xfce"
GEOMETRY="1920x1080"

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# PKG_SUDO is independent of the install-path-derived SUDO: apt operates on the
# root-owned /var/lib/{apt,dpkg} regardless of where the package files end up.
PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-turbovnc [ BUILD_TURBOVNC ] default $BUILD_TURBOVNC"
   echo "  --turbovnc-version [ TURBOVNC_VERSION ] default $TURBOVNC_VERSION"
   echo "  --install-path [ PATH ]      PARENT dir; leaf appends turbovnc-v\${TURBOVNC_VERSION}. default parent of $INSTALL_PATH"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --security-types [ SECURITY_TYPES ] default $SECURITY_TYPES (auth is enforced by the nginx TOTP proxy)"
   echo "  --wm [ WM ] default $WM"
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
      "--build-turbovnc")
          shift
          BUILD_TURBOVNC=${1}
          reset-last
          ;;
      "--turbovnc-version")
          shift
          TURBOVNC_VERSION=${1}
          reset-last
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
      "--security-types")
          shift
          SECURITY_TYPES=${1}
          reset-last
          ;;
      "--wm")
          shift
          WM=${1}
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

# --install-path is treated as a PARENT directory: the leaf appends the versioned
# subdir turbovnc-v${TURBOVNC_VERSION} (matches emacs/miniconda3 so main_setup.sh can
# thread the shared TOP_INSTALL_PATH). When --install-path is omitted the legacy
# /opt/turbovnc-v${TURBOVNC_VERSION} default is used.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}/turbovnc-v${TURBOVNC_VERSION}
else
   INSTALL_PATH=/opt/turbovnc-v${TURBOVNC_VERSION}
fi

echo ""
echo "==================================="
echo "Starting TurboVNC Install with"
echo "BUILD_TURBOVNC: $BUILD_TURBOVNC"
echo "TURBOVNC_VERSION: $TURBOVNC_VERSION"
echo "Installing TurboVNC in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "SECURITY_TYPES: $SECURITY_TYPES"
echo "WM: $WM"
echo "==================================="
echo ""

CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}

# NOOP_RC=43 so main_setup.sh's run_and_log records an intentional skip as
# SKIPPED(no-op) rather than a failure (matches emacs/miniconda3).
NOOP_RC=43

if [ "${BUILD_TURBOVNC}" = "0" ]; then

   echo "[turbovnc BUILD_TURBOVNC=0] operator opt-out; skipping (no source build)."
   exit ${NOOP_RC}

else

   # Existence guard: this is a shared, ROCm-agnostic tool -> build once, then
   # existence-skip on every subsequent sweep version. rm -rf the install dir
   # (or bump --turbovnc-version) to force a rebuild.
   if [ -d "${INSTALL_PATH}" ]; then
      echo ""
      echo "[turbovnc existence-check] ${INSTALL_PATH} already installed; skipping."
      echo ""
      exit ${NOOP_RC}
   fi

   # -------------------------------------------------------------------------
   # Dependencies. Build deps are needed to compile Xvnc; the runtime deps are
   # the desktop + browser-bridge pieces a usable VNC session needs (the noVNC
   # HTML client and websockify are proxied by the front-end nginx; xset comes
   # from x11-xserver-utils and is used by the locker-disable step below).
   # apt touches root-owned dbs, so it always uses PKG_SUDO.
   # -------------------------------------------------------------------------
   ${PKG_SUDO} apt-get update
   ${PKG_SUDO} ${DEB_FRONTEND} apt-get install -y --no-install-recommends \
        ca-certificates curl tar python3 \
        build-essential cmake pkg-config \
        libturbojpeg0-dev libpam0g-dev libssl-dev zlib1g-dev \
        x11proto-dev \
        libx11-dev libxext-dev libxdamage-dev libxfixes-dev libxi-dev \
        libxtst-dev libxrandr-dev libxrender-dev libxkbfile-dev libbsd-dev \
        libfontenc-dev
   ${PKG_SUDO} ${DEB_FRONTEND} apt-get install -y --no-install-recommends \
        xfce4 dbus-x11 x11-xserver-utils \
        novnc websockify \
        xfonts-base xfonts-75dpi xfonts-100dpi xfonts-scalable || true

   if [ -f ${CACHE_FILES}/turbovnc.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached TurboVNC"
      echo "============================"
      echo ""

      # cached tree is packed relative to the parent of INSTALL_PATH
      ${SUDO} mkdir -p "$(dirname ${INSTALL_PATH})"
      cd "$(dirname ${INSTALL_PATH})"
      ${SUDO} tar -xpzf ${CACHE_FILES}/turbovnc.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/turbovnc.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building TurboVNC"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      rm -rf turbovnc_source
      mkdir turbovnc_source && cd turbovnc_source

      # Fetch the tagged release. server-only build (no viewer/helper Java bits).
      rm -rf turbovnc-${TURBOVNC_VERSION} src.tar.gz
      curl -fsSL -o src.tar.gz \
         "https://github.com/TurboVNC/turbovnc/archive/refs/tags/${TURBOVNC_VERSION}.tar.gz"
      tar xf src.tar.gz
      test -d "turbovnc-${TURBOVNC_VERSION}" || send-error "source tree turbovnc-${TURBOVNC_VERSION} not found after extract"

      rm -rf build && mkdir build && cd build
      cmake -G"Unix Makefiles" \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_INSTALL_PREFIX="${INSTALL_PATH}" \
         -DTVNC_BUILDVIEWER=0 \
         -DTVNC_BUILDHELPER=0 \
         -DTJPEG_INCLUDE_DIR=/usr/include \
         -DTJPEG_LIBRARY=/usr/lib/x86_64-linux-gnu/libturbojpeg.so \
         "../turbovnc-${TURBOVNC_VERSION}"

      make -j 8

      echo "Installing TurboVNC in: $INSTALL_PATH"
      make install

      cd ../../..
      rm -rf turbovnc_source
   fi

   # -------------------------------------------------------------------------
   # Software DRI driver for Xvnc AIGLX. Xvnc's -dridir (below) points into the
   # install tree and dlopen()s swrast_dri.so to provide software GLX. On these
   # MI300A nodes hardware GL is impossible (gfx942/CDNA3 is compute-only; Mesa
   # radeonsi refuses to "create a graphics context on a compute chip"), so
   # llvmpipe is the ONLY GL path.
   #
   # Modern Mesa (25.x) ships a single unified megadriver, libdril_dri.so, and
   # swrast/kms_swrast are just symlinks to it (it pulls in libgallium + LLVM ->
   # llvmpipe). Copying a lone swrast_dri.so is fragile: a stale copy NEEDs
   # libglapi.so.0 / an old libLLVM that may be absent, and dlopen fails ->
   # "couldn't find RGB GLX visual". So prefer symlinking the install's DRI
   # drivers to the node's libdril_dri.so; fall back to copying a classic
   # swrast_dri.so only on older images that lack the megadriver.
   # -------------------------------------------------------------------------
   SYS_DRIDIR=/usr/lib/x86_64-linux-gnu/dri
   ${SUDO} mkdir -p "${INSTALL_PATH}/lib/dri"
   if [ -e "${SYS_DRIDIR}/libdril_dri.so" ]; then
      for _drv in swrast_dri.so kms_swrast_dri.so; do
         ${SUDO} ln -sfn "${SYS_DRIDIR}/libdril_dri.so" "${INSTALL_PATH}/lib/dri/${_drv}"
      done
      unset _drv
   elif [ ! -f "${INSTALL_PATH}/lib/dri/swrast_dri.so" ] && [ -f "${SYS_DRIDIR}/swrast_dri.so" ]; then
      ${SUDO} cp -a "${SYS_DRIDIR}/swrast_dri.so" "${INSTALL_PATH}/lib/dri/"
   fi

   # -------------------------------------------------------------------------
   # Security config. "None" advertises no VNC-level auth (standard noVNC does
   # not speak TurboVNC's VeNCrypt/TLSPlain, and SSH-key-only accounts have no
   # password for UnixLogin). The nginx TOTP reverse proxy is the access gate.
   # -------------------------------------------------------------------------
   ${SUDO} tee ${INSTALL_PATH}/etc/turbovncserver-security.conf >/dev/null <<-EOF
	# Managed by turbovnc_setup.sh.
	# Cluster accounts are SSH-key-only; access is gated by the nginx TOTP proxy.
	pam-service-name = turbovnc
	permitted-security-types = ${SECURITY_TYPES}
	no-remote-connections
	max-idle-timeout = 3600
	EOF

   ${SUDO} tee ${INSTALL_PATH}/etc/turbovncserver.conf >/dev/null <<-EOF
	# Managed by turbovnc_setup.sh.
	\$geometry = "${GEOMETRY}";
	\$depth = 24;
	\$wm = "${WM}";
	\$useVGL = 0;
	\$autokill = 1;
	\$securityTypes = "${SECURITY_TYPES}";
	\$noVNC = "/usr/share/novnc";
	\$serverArgs = "-dridir ${INSTALL_PATH}/lib/dri";
	EOF

   # -------------------------------------------------------------------------
   # Disable in-session screen lockers. XFCE autostarts light-locker (which
   # draws the lightdm greeter) and xscreensaver from /etc/xdg/autostart; on a
   # passwordless SSH-key account a locked screen is unpassable and traps the
   # user. Splice a per-user suppression + X-blanking disable into the shared
   # xstartup so every VNC session is covered. Idempotent via the marker.
   # -------------------------------------------------------------------------
   XSTARTUP="${INSTALL_PATH}/bin/xstartup.turbovnc"
   if [ -f "${XSTARTUP}" ] && ! grep -q "AAC6 cluster customization" "${XSTARTUP}"; then
      NOLOCK_BLOCK=$(mktemp)
      cat > "${NOLOCK_BLOCK}" <<'NOLOCK_EOF'
# --- AAC6 cluster customization: disable in-session screen lockers.
# Cluster accounts are SSH-key-only and have no Unix/PAM password, so a locked
# screen (light-locker, which draws the lightdm greeter, or xscreensaver) is
# unpassable and traps the user on an "XFCE login" prompt. Access is already
# gated upstream by the nginx TOTP reverse proxy, so an in-session lock adds no
# security here, only a lockout. Suppress those XDG autostart entries per-user
# (xfce4-session honors ~/.config/autostart Hidden=true) and stop X blanking/DPMS.
mkdir -p "$HOME/.config/autostart" 2>/dev/null
for _tvnc_lock in light-locker xscreensaver xfce4-screensaver; do
  cat > "$HOME/.config/autostart/$_tvnc_lock.desktop" 2>/dev/null <<__TVNC_NOLOCK__
[Desktop Entry]
Type=Application
Name=$_tvnc_lock
Exec=/bin/true
Hidden=true
X-GNOME-Autostart-enabled=false
__TVNC_NOLOCK__
done
unset _tvnc_lock
if [ -n "$DISPLAY" ] && command -v xset >/dev/null 2>&1; then
  xset s off 2>/dev/null
  xset s noblank 2>/dev/null
  xset -dpms 2>/dev/null
fi
# Software OpenGL: MI300A (gfx942/CDNA3) GPUs are compute-only and Mesa radeonsi
# refuses to "create a graphics context on a compute chip", so force llvmpipe.
# GLX itself is served by Xvnc AIGLX via -dridir (repointed at libdril_dri.so).
# These exports propagate to the WM session and all in-session GL clients
# (glxinfo/glxgears, roc-optiq, paraprof), rendering in software on the CPU.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
# --- end AAC6 cluster customization ---

NOLOCK_EOF
      TMP_XSTARTUP=$(mktemp)
      awk -v blockfile="${NOLOCK_BLOCK}" '
         /^if \[ "\$TVNC_WM" != "" \]; then$/ && !done {
            while ((getline line < blockfile) > 0) print line
            close(blockfile)
            done=1
         }
         { print }
      ' "${XSTARTUP}" > "${TMP_XSTARTUP}"
      if grep -q "AAC6 cluster customization" "${TMP_XSTARTUP}"; then
         ${SUDO} cp "${TMP_XSTARTUP}" "${XSTARTUP}"
         ${SUDO} chmod 755 "${XSTARTUP}"
         echo "xstartup.turbovnc: screen-locker suppression applied"
      else
         echo "WARNING: could not find the xstartup anchor; screen-locker suppression NOT applied"
      fi
      rm -f "${NOLOCK_BLOCK}" "${TMP_XSTARTUP}"
   fi

   # Lock down ownership/permissions of the installed tree (mirrors the other
   # setup scripts: root-owned, group/other read-only).
   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
   fi
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod -R go-w ${INSTALL_PATH}
   fi

   # -------------------------------------------------------------------------
   # Modulefile
   # -------------------------------------------------------------------------
   # Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
   # see netcdf_setup.sh for the lying-probe failure mode this replaces).
   PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
   ${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

   # Provenance: capture this leaf script's git state for the modulefile
   # whatis() line below. Uses LEAF_SCRIPT_PATH (absolute path captured at the
   # top of this script before any cd) so this works even after the script has
   # cd'd into a temp build dir. Self-contained: falls back to "unknown" when
   # run from a stripped-of-.git context (Docker layer, tarball, or no git).
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

   # The - option suppresses leading tabs
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${TURBOVNC_VERSION}.lua
	whatis("turbovnc (version ${TURBOVNC_VERSION})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY}); server-only, ${SECURITY_TYPES} security type")
	help([[Loads TurboVNC v${TURBOVNC_VERSION} (remote-desktop server for compute nodes). Access is gated by the nginx TOTP proxy.]])

	local base = "${INSTALL_PATH}"

	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", "/usr/lib/x86_64-linux-gnu")
	setenv("TURBOVNC_ROOT", base)
	EOF

fi
