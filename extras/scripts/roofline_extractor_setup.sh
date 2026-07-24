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
# AMD Roofline Extractor install + Lmod/Tcl modulefile, in the extras
# leaf-setup style (mirrors emacs_setup.sh / miniforge3_setup.sh).
#
# What this does (the Ubuntu 24.04 migration install):
#   1. git clone the (PUBLIC) roofline-extractor repo -> tool payload
#      (rooflineExtractor.py, profile_app.py,
#       convert-counters-collection-format.py, config/ (cache_bandwidths.csv,
#       benchWarmer.csv, mi*_alpha_summary.csv), roof-counters-gfx*.txt,
#       d3.min.js, METRICS_*.md, requirements.txt, README.md, LICENSE.md).
#   1b. Apply the sidecar patch (roofline_extractor.patch) to the fresh
#      clone: the CWD-relative --output-dir fix in profile_app.py (avoids
#      PermissionError writing under the install dir, and drops the implicit
#      ./data/ prefix) plus the richer --help text for both wrapper entry
#      points. Idempotent + fail-loud.
#   2. Copy that payload into INSTALL_PATH.
#   3. GENERATE the two bin wrappers (roofline-extractor-extract /
#      -profile) -- these are deployment artifacts, NOT in the repo.
#   4. pip install the vendored Python deps into INSTALL_PATH/python_deps,
#      PINNED to the validated versions and rebuilt as cp312 wheels for
#      Python 3.12 (24.04). numexpr + bottleneck are vendored so pandas
#      does NOT fall back to 24.04's system numpy-1.x builds in
#      /usr/lib/python3/dist-packages (which emit a NumPy 1.x/2.x ABI
#      traceback on import).
#   5. GENERATE the Lmod/Tcl modulefile (prereq rocm; PYTHONPATH + PATH;
#      MANPATH for the shared man dir).
#   6. Refresh the cluster Lmod spider cache so `module load` sees it.
#
# NOT handled by this script (by design):
#   * The man page (share/man/man1/roofline-extractor.1). It is not in the
#     repo and is managed separately; this script does not install it.
#
# NOTE: the repo is PUBLIC, so the default HTTPS clone needs no credentials.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
BUILD_ROOFLINE=1
ROOFLINE_VERSION=dev
# Public repo -- anonymous HTTPS clone, no deploy key or token required.
ROOFLINE_REPO="https://github.com/AMD-HPC/rooflineExtractor.git"
ROOFLINE_REF=main
# INSTALL_PATH is the leaf; --install-path is treated as the PARENT dir
# (leaf appends rooflineExtractor), matching the extras convention so
# main_setup.sh can stay path-agnostic.
INSTALL_PATH=/nfsapps/ubuntu-24.04/opt/rooflineExtractor
INSTALL_PATH_INPUT=""
MODULE_PATH=/nfsapps/ubuntu-24.04/modules/base/roofline-extractor
# Cluster Lmod spider-cache refresh script (bumps the cache so clients
# see the new modulefile without --ignore_cache). Skipped if absent.
MODULE_CACHE_REFRESH=/nfsapps/ubuntu-24.04/moduleData/refresh_module_cache.sh
# Deployed man dir is on the default MANPATH on 24.04; the modulefile
# prepends it so `man roofline-extractor` also works on compute nodes.
SHARED_MAN_DIR=/shared/apps/ubuntu/man
# --replace 1: rm -rf the prior install dir + modulefile BEFORE installing.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so a partial
# install + modulefile are left on disk for post-mortem.
REPLACE=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

# Python deps, PINNED to the validated stack (rebuilt cp312 for 3.12).
# numexpr/bottleneck are vendored deliberately (see header). Keep in sync
# with INSTALL_PATH/requirements.txt.
ROOFLINE_PIP_PINS=(
   matplotlib==3.10.9
   numpy==2.2.6
   pandas==2.3.3
   scipy==1.15.3
   tabulate==0.10.0
   requests==2.33.1
   numexpr==2.14.1
   bottleneck==1.6.0
)

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
   echo "  --build-roofline [ 0|1 ]       default $BUILD_ROOFLINE"
   echo "  --roofline-version [ VER ]     modulefile name stem, default $ROOFLINE_VERSION"
   echo "  --repo [ URL ]                 git repo to clone, default $ROOFLINE_REPO"
   echo "  --ref [ BRANCH|TAG|SHA ]       git ref to check out, default $ROOFLINE_REF"
   echo "  --install-path [ PATH ]        PARENT dir; leaf appends rooflineExtractor. default parent of $INSTALL_PATH"
   echo "  --module-path [ PATH ]         modulefile dir, default $MODULE_PATH"
   echo "  --replace [ 0|1 ]              remove prior install + modulefile before installing, default $REPLACE"
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
      "--build-roofline")
          shift
          BUILD_ROOFLINE=${1}
          reset-last
          ;;
      "--roofline-version")
          shift
          ROOFLINE_VERSION=${1}
          reset-last
          ;;
      "--repo")
          shift
          ROOFLINE_REPO=${1}
          reset-last
          ;;
      "--ref")
          shift
          ROOFLINE_REF=${1}
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

# --install-path is a PARENT dir: the leaf appends rooflineExtractor, so
# main_setup.sh can stay version-agnostic. When omitted the default leaf
# is used verbatim.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}/rooflineExtractor
fi

echo ""
echo "==================================="
echo "Starting Roofline Extractor Install with"
echo "BUILD_ROOFLINE: $BUILD_ROOFLINE"
echo "ROOFLINE_VERSION: $ROOFLINE_VERSION"
echo "ROOFLINE_REPO: $ROOFLINE_REPO"
echo "ROOFLINE_REF: $ROOFLINE_REF"
echo "INSTALL_PATH: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

# ── BUILD_ROOFLINE=0 short-circuit: operator opt-out ──────────────────
# NOOP_RC=43 so main_setup.sh's run_and_log records this as SKIPPED(no-op)
# rather than OK-bucketing an install that never happened.
NOOP_RC=43
if [ "${BUILD_ROOFLINE}" = "0" ]; then
   echo "[roofline BUILD_ROOFLINE=0] operator opt-out; skipping (no install)."
   exit ${NOOP_RC}
fi

# ── modulefile paths (both flavors tracked for --replace + fail-cleanup) ─
# Lmod consumes <ver>.lua, classic Tcl Environment Modules consumes an
# extensionless Tcl file. Track both so --replace and the fail-cleanup trap
# remove whichever was written previously.
MODULEFILE_LUA="${MODULE_PATH}/${ROOFLINE_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${ROOFLINE_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[roofline --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if already installed ────────────────────────
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[roofline existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                          pass --replace 1 to force a clean reinstall."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
# On a non-zero exit remove partial artifacts so the next sweep starts
# clean. Skipped when --keep-failed-installs 1. Clone-dir rm is folded in
# here (reads ${ROOFLINE_CLONE_ROOT} lazily) so we do NOT register a
# second EXIT trap that would silently replace this one.
_roofline_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[roofline fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[roofline fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   if [ -n "${ROOFLINE_CLONE_ROOT:-}" ] && [ -d "${ROOFLINE_CLONE_ROOT}" ]; then
      rm -rf "${ROOFLINE_CLONE_ROOT}"
   fi
   return ${rc}
}
trap _roofline_on_exit EXIT

# ── build/runtime dependencies ────────────────────────────────────────
# git to clone the repo; python3 + pip to vendor the deps.
if [ "${DISTRO}" = "ubuntu" ]; then
   echo "[roofline] ensuring git + python3 + pip are present ..."
   ${SUDO} ${DEB_FRONTEND} apt-get update -q -y || true
   ${SUDO} ${DEB_FRONTEND} apt-get install -q -y git python3 python3-pip
else
   echo "[roofline] WARNING: automatic dep install is only wired up for Ubuntu."
   echo "        DISTRO='${DISTRO}' detected -- assuming git, python3, and pip are present."
fi

command -v git     >/dev/null 2>&1 || send-error "git not found on PATH"
command -v python3 >/dev/null 2>&1 || send-error "python3 not found on PATH"

# ── install-path sudo: probe nearest existing ancestor for writability ─
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _iprobe="${INSTALL_PATH}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .roofline-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "roofline: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "roofline: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

echo ""
echo "============================"
echo " Installing Roofline Extractor (${ROOFLINE_VERSION})"
echo "============================"
echo ""

# ── 1. clone the (public) repo into a per-job throwaway dir ────────────
# Cleaned by _roofline_on_exit (do NOT add a second EXIT trap here).
ROOFLINE_CLONE_ROOT=$(mktemp -d -t roofline-clone.XXXXXX)
echo "[roofline] cloning ${ROOFLINE_REPO} (ref ${ROOFLINE_REF}) ..."
git clone --depth 1 --branch "${ROOFLINE_REF}" "${ROOFLINE_REPO}" "${ROOFLINE_CLONE_ROOT}/src"

# ── 1b. apply the local deployment patches to the fresh clone ──────────
# The repo does NOT carry two fixes we require:
#   * profile_app.py: resolve a relative --output-dir against the user's
#     CWD (not the install dir) so unprivileged users don't hit
#     PermissionError writing under ${INSTALL_PATH}; also drops the
#     implicit ./data/ prefix that was silently prepended to --output-dir.
#   * profile_app.py + rooflineExtractor.py: richer --help (prog name,
#     description, usage examples) for the roofline-extractor-{profile,
#     extract} wrapper entry points.
# Shipped as a sidecar unified diff next to this script and applied to the
# clone BEFORE it is copied into place (so no sudo is needed to patch).
# Idempotent + fail-loud: if the fixes are already upstream the patch
# reverse-applies and we skip; if it neither applies nor reverse-applies
# (the repo drifted at the patched hunks) we ABORT rather than silently
# ship an install missing the CWD fix -- regenerate the patch and re-run.
ROOFLINE_PATCH="$(dirname "${LEAF_SCRIPT_PATH}")/roofline_extractor.patch"
[ -f "${ROOFLINE_PATCH}" ] || send-error "expected sidecar patch not found: ${ROOFLINE_PATCH}"
echo "[roofline] applying local patches: ${ROOFLINE_PATCH}"
if git -C "${ROOFLINE_CLONE_ROOT}/src" apply --check "${ROOFLINE_PATCH}" 2>/dev/null; then
   git -C "${ROOFLINE_CLONE_ROOT}/src" apply "${ROOFLINE_PATCH}"
   echo "[roofline]   patches applied."
elif git -C "${ROOFLINE_CLONE_ROOT}/src" apply --reverse --check "${ROOFLINE_PATCH}" 2>/dev/null; then
   echo "[roofline]   patches already present in ref '${ROOFLINE_REF}'; skipping."
else
   send-error "roofline_extractor.patch does not apply to ref '${ROOFLINE_REF}' (repo drifted at the patched hunks). Regenerate the patch against the current source, then re-run."
fi

# ── 2. copy payload into INSTALL_PATH (drop VCS bookkeeping) ───────────
${SUDO} mkdir -p "${INSTALL_PATH}"
${SUDO} cp -a "${ROOFLINE_CLONE_ROOT}/src/." "${INSTALL_PATH}/"
${SUDO} rm -rf "${INSTALL_PATH}/.git" "${INSTALL_PATH}/.gitignore"

# ── 3. generate the bin wrappers (deployment artifacts; not in repo) ──
# Both resolve their own location via readlink so they are install-path
# independent and set PYTHONPATH so they work with or without the module.
${SUDO} mkdir -p "${INSTALL_PATH}/bin"

cat <<'WRAPPER_EOF' | ${SUDO} tee "${INSTALL_PATH}/bin/roofline-extractor-extract" >/dev/null
#!/usr/bin/env bash
# Wrapper for rooflineExtractor.py — invoked as `roofline-extractor-extract`.
# Resolves its own location so it works whether or not the module is loaded.
set -e

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"

export PYTHONPATH="$ROOT:$ROOT/python_deps${PYTHONPATH:+:$PYTHONPATH}"

exec python3 "$ROOT/rooflineExtractor.py" "$@"
WRAPPER_EOF

cat <<'WRAPPER_EOF' | ${SUDO} tee "${INSTALL_PATH}/bin/roofline-extractor-profile" >/dev/null
#!/usr/bin/env bash
# Wrapper for profile_app.py — invoked as `roofline-extractor-profile`.
# Resolves its own location so it works whether or not the module is loaded.
set -e

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$HERE")"

export PYTHONPATH="$ROOT:$ROOT/python_deps${PYTHONPATH:+:$PYTHONPATH}"

exec python3 "$ROOT/profile_app.py" "$@"
WRAPPER_EOF

${SUDO} chmod 0755 "${INSTALL_PATH}/bin/roofline-extractor-extract" \
                   "${INSTALL_PATH}/bin/roofline-extractor-profile"

# ── 4. vendor the pinned Python deps into python_deps (cp312) ─────────
# --target keeps everything self-contained under the install; the wrappers
# and modulefile put it on PYTHONPATH ahead of the system dist-packages.
echo "[roofline] pip install (pinned) into ${INSTALL_PATH}/python_deps ..."
${SUDO} python3 -m pip install --target "${INSTALL_PATH}/python_deps" "${ROOFLINE_PIP_PINS[@]}"

# Keep the install's requirements.txt in sync with the pinned set actually
# vendored (the repo copy is unpinned), so future reinstalls are reproducible.
cat <<-EOF | ${SUDO} tee "${INSTALL_PATH}/requirements.txt" >/dev/null
	# Pinned to the validated stack, rebuilt as cp312 wheels for Python 3.12.
	# numexpr + bottleneck are vendored so pandas imports THESE (numpy-2.x
	# compatible) instead of Ubuntu 24.04's system numpy-1.x builds in
	# /usr/lib/python3/dist-packages, which emit a NumPy 1.x/2.x ABI
	# traceback on import.
	$(printf '%s\n' "${ROOFLINE_PIP_PINS[@]}")
EOF

# ── normalize ownership/perms when installed with elevation ───────────
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chown -R root:root "${INSTALL_PATH}"
fi
# World-readable payload; executable wrappers (needed over NFS by all users).
${SUDO} chmod -R a+rX "${INSTALL_PATH}"

# ── 5. modulefile ─────────────────────────────────────────────────────
# Modulefile-write sudo: probe the module tree for user-writability so a
# user-owned module tree needs no sudo.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .roofline-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"
      PKG_SUDO_MOD=""
      echo "roofline: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
   else
      PKG_SUDO_MOD="sudo"
      echo "roofline: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
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

if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE} >/dev/null
whatis("AMD Roofline Extractor Tool")
whatis("by Andrew Chisolm and Noah Wolfe")
whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

prereq("rocm")

local root = "${INSTALL_PATH}"

prepend_path("PYTHONPATH", pathJoin(root, "python_deps"))
prepend_path("PYTHONPATH", root)
prepend_path("PATH",       pathJoin(root, "bin"))

-- ${SHARED_MAN_DIR} holds the deployed roofline-extractor.1 and is on the
-- default MANPATH on login nodes but not always on compute nodes; prepend
-- it so \`man roofline-extractor\` works everywhere (mirrors the rocbudai module).
prepend_path("MANPATH", "${SHARED_MAN_DIR}")
EOF
else
   cat <<EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE} >/dev/null
#%Module1.0
module-whatis "AMD Roofline Extractor Tool"
module-whatis "by Andrew Chisolm and Noah Wolfe"
module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

prereq rocm

set root "${INSTALL_PATH}"

prepend-path PYTHONPATH \$root/python_deps
prepend-path PYTHONPATH \$root
prepend-path PATH \$root/bin
prepend-path MANPATH "${SHARED_MAN_DIR}"
EOF
fi

# ── 6. refresh the Lmod spider cache so `module load` sees it ──────────
# Without this the new modulefile is only visible via --ignore_cache until
# the cluster's periodic refresh runs.
if [ -x "${MODULE_CACHE_REFRESH}" ]; then
   echo "[roofline] refreshing Lmod spider cache via ${MODULE_CACHE_REFRESH} ..."
   ${PKG_SUDO_MOD:-sudo} "${MODULE_CACHE_REFRESH}" --force || \
      echo "[roofline] WARNING: cache refresh failed; users may need 'module --ignore_cache load roofline-extractor'"
else
   echo "[roofline] NOTE: ${MODULE_CACHE_REFRESH} not found; skipping cache refresh."
   echo "                 Users may need 'module --ignore_cache load roofline-extractor' until the next refresh."
fi

echo ""
echo "[roofline] install complete: ${INSTALL_PATH}"
echo "[roofline] modulefile:       ${MODULEFILE} (${MODFLAVOR})"
echo "[roofline] NOTE: the man page (roofline-extractor.1) is intentionally NOT"
echo "                 handled by this script; it is managed separately."
echo ""
