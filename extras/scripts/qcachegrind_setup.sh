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
# QCachegrind install + Lmod/Tcl modulefile, in the extras leaf-setup
# style (mirrors google-chrome_setup.sh / roofline_extractor_setup.sh).
#
# WHY THIS EXISTS: QCachegrind is the Qt-only GUI viewer for callgrind
# (valgrind --tool=callgrind / cachegrind) profile files. It is a read-only
# viewer of NFS *.out / callgrind.out.* files, not a compute tool, so a
# single versioned module visible from every node's graphical session is
# the right packaging -- no per-node root, and it survives node reimaging
# (per-node apt drifts and is wiped on reimage).
#
# WHY BUILD FROM SOURCE: Ubuntu 24.04 has NO 'qcachegrind' package -- the
# kcachegrind source package builds only 'kcachegrind' (the heavier KDE-
# runtime GUI) + 'kcachegrind-converters'. QCachegrind (Qt-only, no KDE
# runtime) is a separate build target inside the same KDE source tree
# ('qmake qcg.pro') that the .deb does not ship. We build it here.
#
# WHY A SELF-CONTAINED NFS BUNDLE: like the CubeGUI viewer on this cluster
# (tools/scripts/scorep_setup.sh), the module vendors its OWN Qt5 runtime +
# graphviz onto NFS and points LD_LIBRARY_PATH / the Qt plugin path / the
# graphviz plugin dir at them via generated wrappers. The node image only
# has to provide libxcb-cursor0 + the base X libs (already baked in via
# rocm/scripts/baseospackages_setup.sh / profiler-gui-deps). So NO image
# rebuild / reimage is needed and the module is ROCm-agnostic (no prereq).
#
# BUNDLED graphviz: QCachegrind shells out to `dot` for its call-graph pane;
# without it that pane is blank. The module ships its own `dot` + graphviz
# plugins so the call-graph view works regardless of what is on the node.
#
# RUNTIME (the GUI needs a display): load the module inside the AAC6
# VNC/noVNC/X11 desktop session, then `qcachegrind callgrind.out.<pid>`.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
BUILD_QCACHEGRIND=1
# Module name stem + install-dir label. Defaults to the KDE kcachegrind
# release we build (matches the noble source package version) for
# traceability; override with --qcachegrind-version (e.g. 0.8) if you
# prefer QCachegrind's own internal version string.
QCACHEGRIND_VERSION=23.08.5
# Git ref (tag/branch/SHA) of the KDE kcachegrind source to build.
QCACHEGRIND_REF=v23.08.5
# Public KDE repo -- anonymous HTTPS clone, no credentials required.
QCACHEGRIND_REPO="https://invent.kde.org/sdk/kcachegrind.git"
# INSTALL_PATH is the leaf; --install-path is treated as the PARENT dir
# (leaf appends qcachegrind-v${QCACHEGRIND_VERSION}), matching the extras
# convention so main_setup.sh can stay version-agnostic.
INSTALL_PATH=/nfsapps/ubuntu-24.04/opt/qcachegrind-v${QCACHEGRIND_VERSION}
INSTALL_PATH_INPUT=""
MODULE_PATH=/nfsapps/ubuntu-24.04/modules/base/qcachegrind
# Cluster Lmod spider-cache refresh script (bumps the cache so clients
# see the new modulefile without --ignore_cache). Skipped if absent.
MODULE_CACHE_REFRESH=/nfsapps/ubuntu-24.04/moduleData/refresh_module_cache.sh
# --replace 1: rm -rf the prior install dir + modulefile BEFORE installing.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so a partial
# install + modulefile are left on disk for post-mortem.
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
   echo "  WARNING: when specifying --install-path and --module-path, the PARENT directories must already exist (the script probes them for write permission)"
   echo "  --build-qcachegrind [ 0|1 ]     default $BUILD_QCACHEGRIND"
   echo "  --qcachegrind-version [ VER ]   module name stem + install-dir label, default $QCACHEGRIND_VERSION"
   echo "  --qcachegrind-ref [ REF ]       git ref (tag/branch/SHA) of the KDE kcachegrind source to build, default $QCACHEGRIND_REF"
   echo "  --repo [ URL ]                  git repo to clone, default $QCACHEGRIND_REPO"
   echo "  --install-path [ PATH ]         PARENT dir; leaf appends qcachegrind-v\${QCACHEGRIND_VERSION}. default parent of $INSTALL_PATH"
   echo "  --module-path [ PATH ]          modulefile dir, default $MODULE_PATH"
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
      "--build-qcachegrind")
          shift
          BUILD_QCACHEGRIND=${1}
          reset-last
          ;;
      "--qcachegrind-version")
          shift
          QCACHEGRIND_VERSION=${1}
          reset-last
          ;;
      "--qcachegrind-ref")
          shift
          QCACHEGRIND_REF=${1}
          reset-last
          ;;
      "--repo")
          shift
          QCACHEGRIND_REPO=${1}
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

# Recompute install path now that QCACHEGRIND_VERSION may have been
# overridden. --install-path is treated as a PARENT directory: the leaf
# appends qcachegrind-v${QCACHEGRIND_VERSION} itself, so main_setup.sh can
# stay version-agnostic (same convention as emacs/turbovnc/google-chrome).
# When --install-path is omitted the legacy /nfsapps default is used.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}/qcachegrind-v${QCACHEGRIND_VERSION}
else
   INSTALL_PATH=/nfsapps/ubuntu-24.04/opt/qcachegrind-v${QCACHEGRIND_VERSION}
fi

echo ""
echo "==================================="
echo "Starting QCachegrind Install with"
echo "BUILD_QCACHEGRIND: $BUILD_QCACHEGRIND"
echo "QCACHEGRIND_VERSION: $QCACHEGRIND_VERSION"
echo "QCACHEGRIND_REF: $QCACHEGRIND_REF"
echo "QCACHEGRIND_REPO: $QCACHEGRIND_REPO"
echo "INSTALL_PATH: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

# ── BUILD_QCACHEGRIND=0 short-circuit: operator opt-out ───────────────
# NOOP_RC=43 so main_setup.sh's run_and_log records this as SKIPPED(no-op)
# rather than OK-bucketing an install that never happened.
NOOP_RC=43
if [ "${BUILD_QCACHEGRIND}" = "0" ]; then
   echo "[qcachegrind BUILD_QCACHEGRIND=0] operator opt-out; skipping (no install)."
   exit ${NOOP_RC}
fi

# ── Platform guard: the from-source build uses apt for the Qt5 toolchain ─
# On non-Debian hosts we cannot apt-get the qt5 dev packages; degrade to a
# no-op (SKIPPED) rather than failing the sweep.
if [ "${DISTRO}" != "ubuntu" ] && [ "${DISTRO}" != "debian" ]; then
   echo "[qcachegrind] DISTRO='${DISTRO}' is not Debian/Ubuntu; the apt-based Qt5"
   echo "              build path does not apply here. Skipping (no-op)."
   exit ${NOOP_RC}
fi

# ── modulefile paths (both flavors tracked for --replace + fail-cleanup) ─
# Lmod consumes <ver>.lua, classic Tcl Environment Modules consumes an
# extensionless Tcl file. Track both so --replace and the fail-cleanup trap
# remove whichever was written previously.
MODULEFILE_LUA="${MODULE_PATH}/${QCACHEGRIND_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${QCACHEGRIND_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[qcachegrind --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if already installed ────────────────────────
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[qcachegrind existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                             pass --replace 1 to force a clean reinstall."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
# On a non-zero exit remove partial artifacts so the next sweep starts
# clean. Skipped when --keep-failed-installs 1. Build-dir rm is folded in
# here (reads ${QCG_BUILD_ROOT} lazily) so we do NOT register a second EXIT
# trap that would silently replace this one.
_qcg_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[qcachegrind fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[qcachegrind fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   if [ -n "${QCG_BUILD_ROOT:-}" ] && [ -d "${QCG_BUILD_ROOT}" ]; then
      rm -rf "${QCG_BUILD_ROOT}"
   fi
   return ${rc}
}
trap _qcg_on_exit EXIT

# ── build/runtime dependencies ────────────────────────────────────────
# git + a C++ toolchain to build; qtbase5-dev/qttools5-dev supply the Qt5
# headers, qmake, AND the Qt5 runtime libs we vendor; graphviz supplies
# `dot` + its plugins/libs we vendor.
if [ "${DISTRO}" = "ubuntu" ] || [ "${DISTRO}" = "debian" ]; then
   echo "[qcachegrind] ensuring git + g++/make + Qt5 dev + graphviz are present ..."
   ${SUDO} ${DEB_FRONTEND} apt-get update -q -y || true
   ${SUDO} ${DEB_FRONTEND} apt-get install -q -y \
      git build-essential make \
      qtbase5-dev qttools5-dev qtbase5-dev-tools qt5-qmake qtchooser \
      graphviz
else
   echo "[qcachegrind] WARNING: automatic dep install is only wired up for Ubuntu/Debian."
   echo "              DISTRO='${DISTRO}' detected -- assuming git, g++, qmake (Qt5), and graphviz are present."
fi

command -v git >/dev/null 2>&1 || send-error "git not found on PATH"
command -v make >/dev/null 2>&1 || send-error "make not found on PATH"
{ command -v g++ >/dev/null 2>&1 || command -v c++ >/dev/null 2>&1; } || send-error "no C++ compiler (g++/c++) found on PATH"
command -v dot >/dev/null 2>&1 || send-error "graphviz 'dot' not found on PATH (needed to bundle the call-graph renderer)"

# Locate a Qt5 qmake. Prefer an explicit qt5 qmake so we do not accidentally
# drive the build with a system Qt6 qmake; fall back to qtchooser's QT_SELECT.
export QT_SELECT=qt5
if [ -x /usr/lib/qt5/bin/qmake ]; then
   QMAKE=/usr/lib/qt5/bin/qmake
elif command -v qmake-qt5 >/dev/null 2>&1; then
   QMAKE=qmake-qt5
elif command -v qmake >/dev/null 2>&1; then
   QMAKE=qmake
else
   send-error "qmake (Qt5) not found on PATH (install qtbase5-dev / qt5-qmake)"
fi
echo "[qcachegrind] using qmake: ${QMAKE} (QT_SELECT=${QT_SELECT})"

# ── install-path sudo: probe nearest existing ancestor for writability ─
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _iprobe="${INSTALL_PATH}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .qcg-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "qcachegrind: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "qcachegrind: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

echo ""
echo "============================"
echo " Installing QCachegrind (${QCACHEGRIND_VERSION})"
echo "============================"
echo ""

# ── 1. clone the (public) KDE source into a per-job throwaway dir ──────
# Cleaned by _qcg_on_exit (do NOT add a second EXIT trap here).
QCG_BUILD_ROOT=$(mktemp -d -t qcachegrind.XXXXXX)
QCG_SRC="${QCG_BUILD_ROOT}/src"
echo "[qcachegrind] cloning ${QCACHEGRIND_REPO} (ref ${QCACHEGRIND_REF}) ..."
git clone --depth 1 --branch "${QCACHEGRIND_REF}" "${QCACHEGRIND_REPO}" "${QCG_SRC}"

# ── 2. build QCachegrind (Qt-only target) with qmake ──────────────────
# qcg.pro at the repo root builds the Qt-only 'qcachegrind' and the CLI
# 'cgview' (in-source build; binaries land in their subdirs).
echo "[qcachegrind] building with qmake + make -j$(nproc) ..."
( cd "${QCG_SRC}" && "${QMAKE}" qcg.pro && make -j"$(nproc)" )

# Locate the freshly built binaries (prefer the canonical subdir paths,
# fall back to a search in case the layout shifts across refs).
QCG_BIN="${QCG_SRC}/qcachegrind/qcachegrind"
[ -x "${QCG_BIN}" ] || QCG_BIN="$(find "${QCG_SRC}" -maxdepth 3 -type f -name qcachegrind -perm -u+x 2>/dev/null | head -n1)"
[ -n "${QCG_BIN}" ] && [ -x "${QCG_BIN}" ] || send-error "qcachegrind binary not found after build"
CGVIEW_BIN="${QCG_SRC}/cgview/cgview"
[ -x "${CGVIEW_BIN}" ] || CGVIEW_BIN="$(find "${QCG_SRC}" -maxdepth 3 -type f -name cgview -perm -u+x 2>/dev/null | head -n1)"
DOT_BIN="$(command -v dot)"
echo "[qcachegrind] built:  ${QCG_BIN}"
[ -n "${CGVIEW_BIN}" ] && echo "[qcachegrind] built:  ${CGVIEW_BIN}"
echo "[qcachegrind] system: ${DOT_BIN} (graphviz)"

# ── 3. lay out the self-contained NFS prefix ──────────────────────────
#   libexec/  real binaries (qcachegrind, cgview, dot)
#   lib/      vendored Qt5 + graphviz .so closure, Qt/graphviz plugins
#   bin/      generated wrappers that point LD_LIBRARY_PATH/plugin paths
#             at lib/ and exec the libexec/ binary
BIN_DIR="${INSTALL_PATH}/bin"
LIB_DIR="${INSTALL_PATH}/lib"
LIBEXEC_DIR="${INSTALL_PATH}/libexec"
${SUDO} mkdir -p "${BIN_DIR}" "${LIB_DIR}" "${LIBEXEC_DIR}" \
                 "${LIB_DIR}/qt5/plugins" "${LIB_DIR}/graphviz"
# Make the fresh prefix writable so the (possibly non-sudo) bundling below
# can drop files in; perms are tightened at the end.
if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod -R a+rwX "${INSTALL_PATH}"
fi

${SUDO} cp -f "${QCG_BIN}" "${LIBEXEC_DIR}/qcachegrind"
[ -n "${CGVIEW_BIN}" ] && [ -x "${CGVIEW_BIN}" ] && ${SUDO} cp -f "${CGVIEW_BIN}" "${LIBEXEC_DIR}/cgview"
${SUDO} cp -f "${DOT_BIN}" "${LIBEXEC_DIR}/dot"
${SUDO} chmod 0755 "${LIBEXEC_DIR}"/*

# ── 4. vendor the shared-library closure into lib/ ────────────────────
# Copy every resolved .so an object needs (ldd is recursive, so one pass per
# object captures its whole closure) EXCEPT a denylist of core system /
# graphics-stack libs that MUST come from the node image (glibc, libstdc++/
# libgcc_s, the X11/xcb/GL/DRM/wayland/xkbcommon stack). This is the standard
# AppImage-style "bundle everything but the host base" technique and mirrors
# how CubeGUI ships its Qt libs on this cluster.
bundle_deps() {
   # $1 = ELF object (binary or .so) to read deps from
   local obj="$1"
   ldd "$obj" 2>/dev/null | awk '/=>/ && $3 ~ /^\// {print $1"\t"$3}' | \
   while IFS=$'\t' read -r soname path; do
      case "${soname}" in
         ld-linux*|linux-vdso*|libc.so*|libm.so*|libdl.so*|librt.so*|libpthread.so*|libresolv.so*) continue ;;
         libstdc++.so*|libgcc_s.so*) continue ;;
         libX11.so*|libX11-xcb.so*|libxcb*|libXext.so*|libXrender.so*|libXi.so*|libXfixes.so*) continue ;;
         libXrandr.so*|libXcursor.so*|libXdamage.so*|libXcomposite.so*|libXtst.so*|libXau.so*|libXdmcp.so*) continue ;;
         libSM.so*|libICE.so*|libGL.so*|libGLX.so*|libGLdispatch.so*|libOpenGL.so*|libEGL.so*|libgbm.so*|libdrm.so*) continue ;;
         libwayland*|libxkbcommon*) continue ;;
      esac
      if [ ! -e "${LIB_DIR}/${soname}" ]; then
         ${SUDO} cp -Lf "${path}" "${LIB_DIR}/${soname}"
      fi
   done
}

echo "[qcachegrind] vendoring shared-library closure into ${LIB_DIR} ..."
bundle_deps "${LIBEXEC_DIR}/qcachegrind"
[ -x "${LIBEXEC_DIR}/cgview" ] && bundle_deps "${LIBEXEC_DIR}/cgview"
bundle_deps "${LIBEXEC_DIR}/dot"

# ── 5. vendor the Qt5 + graphviz PLUGINS (dlopen'd, not in the ldd of the
# binaries) and bundle THEIR deps too ─────────────────────────────────
# Qt's xcb platform plugin (libqxcb.so) and image/icon-engine plugins are
# loaded at runtime; graphviz's renderers/layout engines likewise. Copy the
# plugin dirs, then run bundle_deps over each copied plugin .so so libs only
# the plugins pull in (libQt5XcbQpa, libQt5DBus, libgvplugin_* deps, ...) are
# vendored as well.
QT_PLUGIN_SRC=""
for _cand in /usr/lib/x86_64-linux-gnu/qt5/plugins /usr/lib/qt5/plugins; do
   [ -d "${_cand}" ] && { QT_PLUGIN_SRC="${_cand}"; break; }
done
if [ -n "${QT_PLUGIN_SRC}" ]; then
   for _sub in platforms imageformats iconengines platforminputcontexts xcbglintegrations; do
      [ -d "${QT_PLUGIN_SRC}/${_sub}" ] && ${SUDO} cp -a "${QT_PLUGIN_SRC}/${_sub}" "${LIB_DIR}/qt5/plugins/"
   done
else
   echo "[qcachegrind] WARNING: Qt5 plugin dir not found; the xcb platform plugin may be missing at runtime."
fi

GV_PLUGIN_SRC=""
for _cand in /usr/lib/x86_64-linux-gnu/graphviz /usr/lib/graphviz; do
   [ -d "${_cand}" ] && { GV_PLUGIN_SRC="${_cand}"; break; }
done
if [ -n "${GV_PLUGIN_SRC}" ]; then
   ${SUDO} cp -a "${GV_PLUGIN_SRC}/." "${LIB_DIR}/graphviz/"
else
   echo "[qcachegrind] WARNING: graphviz plugin dir not found; the call-graph pane may be blank."
fi

# Bundle the plugins' own dependency closures.
while IFS= read -r _plugin; do
   [ -n "${_plugin}" ] && bundle_deps "${_plugin}"
done < <(find "${LIB_DIR}/qt5/plugins" "${LIB_DIR}/graphviz" -type f -name '*.so*' 2>/dev/null)

# Regenerate the graphviz plugin config against the BUNDLED plugin dir so
# `dot` resolves its renderers from ${LIB_DIR}/graphviz (writes config6).
echo "[qcachegrind] regenerating graphviz plugin config (dot -c) against the bundled plugins ..."
${SUDO} env LD_LIBRARY_PATH="${LIB_DIR}" GVBINDIR="${LIB_DIR}/graphviz" "${LIBEXEC_DIR}/dot" -c \
   || echo "[qcachegrind] WARNING: 'dot -c' failed; the bundled config6 may be stale (call-graph pane could be blank)."

# ── 6. generate the bin/ wrappers (deployment artifacts; not in repo) ──
# Each wrapper resolves its own location, points LD_LIBRARY_PATH + the Qt /
# graphviz plugin paths at the vendored lib/, prepends bin/ so qcachegrind
# finds the bundled `dot`, and execs the real libexec/ binary.
gen_wrapper() {
   local name="$1" qt="$2"
   local qtlines=""
   if [ "${qt}" = "1" ]; then
      qtlines='export QT_PLUGIN_PATH="$ROOT/lib/qt5/plugins${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
export QT_QPA_PLATFORM_PLUGIN_PATH="$ROOT/lib/qt5/plugins/platforms"'
   fi
   ${SUDO} tee "${BIN_DIR}/${name}" >/dev/null <<EOF
#!/bin/bash
# Wrapper generated by qcachegrind_setup.sh -- runs the NFS-bundled '${name}'
# with LD_LIBRARY_PATH + Qt/graphviz plugin paths pointed at the vendored lib/.
HERE="\$(cd "\$(dirname "\$(readlink -f "\${BASH_SOURCE[0]}")")" && pwd)"
ROOT="\$(dirname "\$HERE")"
export LD_LIBRARY_PATH="\$ROOT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export GVBINDIR="\$ROOT/lib/graphviz"
export PATH="\$ROOT/bin:\$PATH"
${qtlines}
exec "\$ROOT/libexec/${name}" "\$@"
EOF
   ${SUDO} chmod 0755 "${BIN_DIR}/${name}"
}

gen_wrapper qcachegrind 1
[ -x "${LIBEXEC_DIR}/cgview" ] && gen_wrapper cgview 1
gen_wrapper dot 0

# ── 7. runtime-lib check (WARN only; base libs come from the node image) ─
echo "[qcachegrind] checking runtime libraries (ldd against the bundled lib/) ..."
MISSING_LIBS="$(LD_LIBRARY_PATH="${LIB_DIR}" ldd "${LIBEXEC_DIR}/qcachegrind" 2>/dev/null | awk '/not found/{print $1}' | sort -u || true)"
if [ -n "${MISSING_LIBS}" ]; then
   echo "[qcachegrind] WARNING: the following libraries are unresolved on THIS host:"
   echo "${MISSING_LIBS}" | sed 's/^/    /'
   echo "[qcachegrind] These must be provided by the node image. The base X stack +"
   echo "              libxcb-cursor0 are baked in via baseospackages_setup.sh /"
   echo "              profiler-gui-deps; add any others there if a node lacks them."
else
   echo "[qcachegrind] all runtime libraries resolved against the bundled lib/ + host base libs."
fi

# ── normalize ownership + permissions of the installed tree ───────────
# chown to root only when a NON-root installer used elevation (${SUDO}
# non-empty). Then force the tree world-readable/traversable (needed over
# NFS by all users) and drop group/other write (also clears the transient
# a+rwX set on the fresh prefix above).
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chown -R root:root "${INSTALL_PATH}"
fi
${SUDO} chmod -R a+rX "${INSTALL_PATH}"
${SUDO} chmod -R go-w "${INSTALL_PATH}"

# ── 8. modulefile ─────────────────────────────────────────────────────
# Modulefile-write sudo: probe the module tree for user-writability so a
# user-owned module tree needs no sudo.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .qcg-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"
      PKG_SUDO_MOD=""
      echo "qcachegrind: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
   else
      PKG_SUDO_MOD="sudo"
      echo "qcachegrind: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
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

# QCachegrind is ROCm-agnostic (like google-chrome), so NO prereq("rocm").
# The wrappers carry the LD_LIBRARY_PATH / plugin-path logic, so the module
# only needs to put bin/ on PATH.
if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("QCachegrind ${QCACHEGRIND_VERSION} (Qt-only callgrind/cachegrind profile viewer, bundles graphviz)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	local base = "${INSTALL_PATH}"

	prepend_path("PATH", pathJoin(base, "bin"))

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#####################################################################")
	  LmodMessage("#  QCachegrind ${QCACHEGRIND_VERSION}")
	  LmodMessage("#  Run 'qcachegrind callgrind.out.<pid>' to view a callgrind profile.")
	  LmodMessage("#  The call-graph pane uses the bundled graphviz 'dot'.")
	  LmodMessage("#  This is a GUI: load it inside the AAC6 VNC/noVNC/X11 desktop.")
	  LmodMessage("#####################################################################")
	  LmodMessage("")
	end
EOF
else
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "QCachegrind ${QCACHEGRIND_VERSION} (Qt-only callgrind/cachegrind profile viewer, bundles graphviz)"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	set base "${INSTALL_PATH}"

	prepend-path PATH \$base/bin

	if { [module-info mode load] } {
	  puts stderr ""
	  puts stderr "#####################################################################"
	  puts stderr "#  QCachegrind ${QCACHEGRIND_VERSION}"
	  puts stderr "#  Run 'qcachegrind callgrind.out.<pid>' to view a callgrind profile."
	  puts stderr "#  The call-graph pane uses the bundled graphviz 'dot'."
	  puts stderr "#  This is a GUI: load it inside the AAC6 VNC/noVNC/X11 desktop."
	  puts stderr "#####################################################################"
	  puts stderr ""
	}
EOF
fi

# ── 9. refresh the Lmod spider cache so `module load` sees it ──────────
# Without this the new modulefile is only visible via --ignore_cache until
# the cluster's periodic refresh runs.
if [ -x "${MODULE_CACHE_REFRESH}" ]; then
   echo "[qcachegrind] refreshing Lmod spider cache via ${MODULE_CACHE_REFRESH} ..."
   ${PKG_SUDO_MOD:-sudo} "${MODULE_CACHE_REFRESH}" --force || \
      echo "[qcachegrind] WARNING: cache refresh failed; users may need 'module --ignore_cache load qcachegrind'"
else
   echo "[qcachegrind] NOTE: ${MODULE_CACHE_REFRESH} not found; skipping cache refresh."
   echo "                    Users may need 'module --ignore_cache load qcachegrind' until the next refresh."
fi

echo ""
echo "[qcachegrind] install complete: ${INSTALL_PATH}"
echo "[qcachegrind] commands on PATH: qcachegrind$([ -x "${LIBEXEC_DIR}/cgview" ] && echo ', cgview'), dot (bundled)"
echo "[qcachegrind] modulefile:       ${MODULEFILE} (${MODFLAVOR})"
echo ""
