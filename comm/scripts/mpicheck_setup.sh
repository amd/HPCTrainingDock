#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the sidecar payload
# and the inline git-provenance block lower down resolve against the repo
# even when main_setup.sh invoked us by a relative path.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# Fail fast on errors and surface failures inside pipes. Not using -u
# (nounset) because some conditional code paths rely on unset variables.
set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# mpicheck: the MPI oversubscription launch wrapper, installed as a
# ROCm-agnostic base module (mirrors roofline_extractor_setup.sh).
#
# What this does:
#   1. Copy the sidecar payload mpicheck/mpirun_check.sh (next to this
#      script) into INSTALL_PATH/bin/mpirun_check.
#   2. Add the srun_check alias as a symlink -- the wrapper picks the
#      launcher it wraps from its own $0 basename.
#   3. GENERATE the Lmod/Tcl modulefile (PATH + MANPATH).
#   4. Refresh the cluster Lmod spider cache so `module load` sees it.
#
# The wrapper reads the kernel fusion driver (KFD) topology to size the
# amdgpu runlist budget for the GPU family in front of it, so one install
# serves every ROCm version -- hence the base module tree rather than a
# per-ROCm rocmplus-<v> tree.
#
# NOT handled by this script (by design, matching roofline-extractor):
#   * The man page aac6_mpi_oversubscribed(7). It is AAC6-specific and is
#     deployed separately under SHARED_MAN_DIR; the modulefile only puts
#     that directory on MANPATH.
#
# No prereq("rocm") in the modulefile, unlike the other base tools: the
# wrapper is pure bash/awk and is meant to be loadable on its own so a
# launch line can be checked before anything else is loaded. Without
# rocm-smi it falls back to a compute-unit-count heuristic for detecting
# a partitioned (CPX) GPU rather than failing.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
BUILD_MPICHECK=1
MPICHECK_VERSION=dev
# INSTALL_PATH is the leaf; --install-path is treated as the PARENT dir
# (leaf appends mpicheck), matching the extras convention so
# main_setup.sh can stay path-agnostic.
INSTALL_PATH=/nfsapps/ubuntu-24.04/opt/mpicheck
INSTALL_PATH_INPUT=""
MODULE_PATH=/nfsapps/ubuntu-24.04/modules/base/mpicheck
# Deployed man dir is on the default MANPATH on 24.04 login nodes but not
# always on compute nodes; the modulefile prepends it so
# `man aac6_mpi_oversubscribed` works everywhere.
SHARED_MAN_DIR=/shared/apps/ubuntu/man
# --replace 1: rm -rf the prior install dir + modulefile BEFORE installing.
# --keep-failed-installs 1: skip the EXIT-trap fail-cleanup so a partial
# install + modulefile are left on disk for post-mortem.
REPLACE=0
KEEP_FAILED_INSTALLS=0
SUDO="sudo"

if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the PARENT directories must already exist (the script probes them for write permission)"
   echo "  --build-mpicheck [ 0|1 ]       default $BUILD_MPICHECK"
   echo "  --mpicheck-version [ VER ]     modulefile name stem, default $MPICHECK_VERSION"
   echo "  --install-path [ PATH ]        PARENT dir; leaf appends mpicheck. default parent of $INSTALL_PATH"
   echo "  --module-path [ PATH ]         modulefile dir, default $MODULE_PATH"
   echo "  --replace [ 0|1 ]              remove prior install + modulefile before installing, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: this usage information"
   exit 1
}

# Error first, then usage: usage() exits, so the message has to be printed
# ahead of it or the reason for the failure never reaches the log.
send-error()
{
    echo -e "\nError: ${@}\n" >&2
    usage
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--build-mpicheck")
          shift
          BUILD_MPICHECK=${1}
          reset-last
          ;;
      "--mpicheck-version")
          shift
          MPICHECK_VERSION=${1}
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

# --install-path is a PARENT dir: the leaf appends mpicheck, so
# main_setup.sh can stay version-agnostic. When omitted the default leaf
# is used verbatim.
if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}/mpicheck
fi

# Lmod spider-cache refresh script: bumps the cache so clients see the new
# modulefile without --ignore_cache. Derived from the module tree we are
# writing into (<root>/moduleData/) rather than hard-coded, because a cluster
# can carry several independent trees -- /nfsapps/ubuntu-24.04 and
# /nfsapps/ubuntu-24.04-MI250 each have their own -- and refreshing one tree's
# cache after installing into another leaves the module invisible. Trees with
# no refresh script, and non-/nfsapps layouts such as the container's
# /etc/lmod, fall through to the skip below.
MODULE_CACHE_REFRESH="${MODULE_PATH%%/modules/*}/moduleData/refresh_module_cache.sh"

echo ""
echo "==================================="
echo "Starting mpicheck Install with"
echo "BUILD_MPICHECK: $BUILD_MPICHECK"
echo "MPICHECK_VERSION: $MPICHECK_VERSION"
echo "INSTALL_PATH: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "REPLACE: $REPLACE"
echo "KEEP_FAILED_INSTALLS: $KEEP_FAILED_INSTALLS"
echo "==================================="
echo ""

# ── BUILD_MPICHECK=0 short-circuit: operator opt-out ──────────────────
# NOOP_RC=43 so main_setup.sh's run_and_log records this as SKIPPED(no-op)
# rather than OK-bucketing an install that never happened.
NOOP_RC=43
if [ "${BUILD_MPICHECK}" = "0" ]; then
   echo "[mpicheck BUILD_MPICHECK=0] operator opt-out; skipping (no install)."
   exit ${NOOP_RC}
fi

# ── the payload ───────────────────────────────────────────────────────
# Sidecar next to this script, resolved via LEAF_SCRIPT_PATH. Fail loud if
# it is missing: a Dockerfile COPY that lands the leaf without its sidecar
# would otherwise install an empty module. Checked up here, ahead of
# --replace, so a bad COPY cannot delete a good prior install.
MPICHECK_PAYLOAD="$(dirname "${LEAF_SCRIPT_PATH}")/mpicheck/mpirun_check.sh"
[ -f "${MPICHECK_PAYLOAD}" ] || send-error "expected sidecar payload not found: ${MPICHECK_PAYLOAD}"

# Runtime dependencies. The wrapper is bash + awk only; both come from the
# base OS layer (rocm/scripts/baseospackages_setup.sh) on every supported
# distro, so this leaf just fail-loud verifies them.
command -v awk >/dev/null 2>&1 || send-error "awk not found on PATH (expected from baseospackages_setup.sh)"

# ── install-path sudo: probe nearest existing ancestor for writability ─
# Probed BEFORE --replace, which removes files and so needs the right
# answer already: a user-writable tree (the no-sudo systems) must not be
# asked for a password just to clear a prior install.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
else
   _iprobe="${INSTALL_PATH}"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .mpicheck-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "mpicheck: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "mpicheck: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── modulefile-write sudo: same probe against the module tree ─────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .mpicheck-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"
      PKG_SUDO_MOD=""
      echo "mpicheck: module tree ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile writes"
   else
      PKG_SUDO_MOD="sudo"
      echo "mpicheck: module tree ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile writes"
   fi
   unset _mprobe _mtest
fi

# ── modulefile paths (both flavors tracked for --replace + fail-cleanup) ─
# Lmod consumes <ver>.lua, classic Tcl Environment Modules consumes an
# extensionless Tcl file. Track both so --replace and the fail-cleanup trap
# remove whichever was written previously.
MODULEFILE_LUA="${MODULE_PATH}/${MPICHECK_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${MPICHECK_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[mpicheck --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${INSTALL_PATH}"
   echo "  modulefile:  ${MODULEFILE_LUA} (+ Tcl flavor)"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${PKG_SUDO_MOD} rm -f "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi

# ── Existence guard: skip if already installed ────────────────────────
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[mpicheck existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                           pass --replace 1 to force a clean reinstall."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
# On a non-zero exit remove partial artifacts so the next sweep starts
# clean. Skipped when --keep-failed-installs 1.
_mpicheck_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[mpicheck fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO} rm -rf "${INSTALL_PATH}"
      ${PKG_SUDO_MOD} rm -f "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[mpicheck fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _mpicheck_on_exit EXIT

echo ""
echo "============================"
echo " Installing mpicheck (${MPICHECK_VERSION})"
echo "============================"
echo ""

# ── 1. + 2. payload + the srun_check alias ────────────────────────────
# The wrapper selects the launcher it wraps from its own $0 basename, so
# the alias is a plain symlink in the same dir -- relative, so the install
# tree stays relocatable.
${SUDO} mkdir -p "${INSTALL_PATH}/bin"
${SUDO} cp "${MPICHECK_PAYLOAD}" "${INSTALL_PATH}/bin/mpirun_check"
${SUDO} ln -sf mpirun_check "${INSTALL_PATH}/bin/srun_check"
${SUDO} chmod 0755 "${INSTALL_PATH}/bin/mpirun_check"

# ── normalize ownership/perms when installed with elevation ───────────
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chown -R root:root "${INSTALL_PATH}"
fi
# World-readable payload; executable wrappers (needed over NFS by all users).
${SUDO} chmod -R a+rX "${INSTALL_PATH}"

# ── 3. modulefile ─────────────────────────────────────────────────────
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
whatis("MPI oversubscription launch check: mpirun_check / srun_check")
whatis("Warns when MPI ranks per GPU exceed the amdgpu runlist budgets")
whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

-- No prereq("rocm"): the wrapper is bash/awk only and is meant to be
-- loadable on its own so a launch line can be checked first. It reads the
-- KFD topology directly and only uses rocm-smi, when present, to tell a
-- CPX slice from a full GPU.

local root = "${INSTALL_PATH}"

prepend_path("PATH", pathJoin(root, "bin"))

-- ${SHARED_MAN_DIR} holds the deployed aac6_mpi_oversubscribed.7 and is on
-- the default MANPATH on login nodes but not always on compute nodes;
-- prepend it so \`man aac6_mpi_oversubscribed\` works everywhere.
prepend_path("MANPATH", "${SHARED_MAN_DIR}")
EOF
else
   cat <<EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE} >/dev/null
#%Module1.0
module-whatis "MPI oversubscription launch check: mpirun_check / srun_check"
module-whatis "Warns when MPI ranks per GPU exceed the amdgpu runlist budgets"
module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

set root "${INSTALL_PATH}"

prepend-path PATH \$root/bin
prepend-path MANPATH "${SHARED_MAN_DIR}"
EOF
fi

# ── 4. refresh the Lmod spider cache so `module load` sees it ──────────
# Without this the new modulefile is only visible via --ignore_cache until
# the cluster's periodic refresh runs.
if [ -x "${MODULE_CACHE_REFRESH}" ]; then
   echo "[mpicheck] refreshing Lmod spider cache via ${MODULE_CACHE_REFRESH} ..."
   ${PKG_SUDO_MOD:-sudo} "${MODULE_CACHE_REFRESH}" --force || \
      echo "[mpicheck] WARNING: cache refresh failed; users may need 'module --ignore_cache load mpicheck'"
else
   echo "[mpicheck] NOTE: ${MODULE_CACHE_REFRESH} not found; skipping cache refresh."
   echo "                 Users may need 'module --ignore_cache load mpicheck' until the next refresh."
fi

echo ""
echo "[mpicheck] install complete: ${INSTALL_PATH}"
echo "[mpicheck] commands:         mpirun_check, srun_check"
echo "[mpicheck] modulefile:       ${MODULEFILE} (${MODFLAVOR})"
echo "[mpicheck] NOTE: the man page aac6_mpi_oversubscribed(7) is intentionally NOT"
echo "                 handled by this script; it is deployed separately."
echo ""
