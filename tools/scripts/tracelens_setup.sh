#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# TraceLens (AMD-AGI/TraceLens) -- automated performance analysis of
# training/inference workloads from profiler traces (PyTorch, JAX,
# rocprofv3). Packaged as a self-contained Python venv + modulefile in the
# HPCTrainingDock leaf style: the pip-venv/bin-symlink model of
# hyperloom_setup.sh, with the tools-layer module conventions of
# roc-optiq_setup.sh (versioned modulefile, Lua/Tcl flavor detection).
#
# WHAT THIS MODULE IS:
#   * Installs the `TraceLens` wheel into an isolated venv and exposes ONLY
#     its `TraceLens_*` CLI tools on PATH (via bin symlinks), so it never
#     shadows the system python the pytorch/framework modules rely on.
#   * Arch-agnostic: TraceLens reads trace files; it needs no GPU and is not
#     bound to torch/ROCm. The orchestrator's --amdgpu-gfxmodel is ignored.
#
# Install layout (keyed on the ROCm version, like the rocmplus tree):
#   venv        : ${TRACELENS_PATH}/venv
#   bin         : ${TRACELENS_PATH}/bin/TraceLens_*  (symlinks to venv scripts)
#   modulefile  : ${MODULE_PATH}/${TRACELENS_VERSION}.lua  (module tracelens/<ver>)
# The modulefile lands in the ROCmPlus-AMDResearchTools overlay the rocm
# module adds to MODULEPATH (same overlay as roc-optiq), so tracelens/<ver>
# is only visible once rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
ROCM_VERSION=7.2.4
BUILD_TRACELENS=1
# Version LABEL for the module name + install dir. TRACELENS_REF is the git
# ref actually installed; keep the two in sync. Upstream publishes release tags
# (v0.1.0 .. v1.1.0), so pin the latest release rather than tracking the moving
# main branch (mirrors primus pinning a released wheel).
TRACELENS_VERSION=1.1.0
TRACELENS_REPO="https://github.com/AMD-AGI/TraceLens.git"
TRACELENS_REF="v1.1.0"
# pip distribution name (used for the extras spec: TraceLens[<extras>]).
TRACELENS_PKG="TraceLens"
# Default extras: kernel_source is light and torch-free (itanium-demangler).
# jax/comparative/dev/all pull heavy deps (xprof/protobuf, LLM clients); make
# them opt-in via --tracelens-extras "all" (or a comma list, no brackets).
TRACELENS_EXTRAS="kernel_source"
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AMDResearchTools/tracelens
# ${TRACELENS_PATH} finalized after TRACELENS_VERSION/ROCM_VERSION are known.
TRACELENS_PATH=""
TRACELENS_PATH_INPUT=""
ROCMPLUS_PATH_INPUT=""
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
   echo "  --build-tracelens [ 0|1 ]        default $BUILD_TRACELENS"
   echo "  --tracelens-version [ VER ]      version LABEL (keys install dir + module); default $TRACELENS_VERSION"
   echo "  --tracelens-ref [ REF ]          git tag/branch/commit to install; default $TRACELENS_REF"
   echo "  --tracelens-repo [ URL ]         git repo; default $TRACELENS_REPO"
   echo "  --tracelens-extras [ NAME ]      pip extras (comma-sep, no brackets; e.g. 'all' or 'jax,kernel_source'); empty for none; default $TRACELENS_EXTRAS"
   echo "  --tracelens-pkg [ NAME ]         pip distribution name; default $TRACELENS_PKG"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION (keys the install dir /opt/rocmplus-<ver>)"
   echo "  --module-path [ PATH ]           default $MODULE_PATH"
   echo "  --install-path [ PATH ]          parent dir; install goes to \${PATH}/tracelens-v\${TRACELENS_VERSION}"
   echo "  --install-path-no-version [ DIR ] full leaf install dir (wins over --install-path)"
   echo "  --amdgpu-gfxmodel [ GFX ]        accepted and ignored (TraceLens is arch-agnostic)"
   echo "  --replace [ 0|1 ]                remove prior install + modulefile before installing, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ]   skip EXIT-trap cleanup of partial install on failure, default $KEEP_FAILED_INSTALLS"
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
      "--build-tracelens")
          shift; BUILD_TRACELENS=${1}; reset-last ;;
      "--tracelens-version")
          shift; TRACELENS_VERSION=${1}; reset-last ;;
      "--tracelens-ref")
          shift; TRACELENS_REF=${1}; reset-last ;;
      "--tracelens-repo")
          shift; TRACELENS_REPO=${1}; reset-last ;;
      "--tracelens-extras")
          shift; TRACELENS_EXTRAS=${1}; reset-last ;;
      "--tracelens-pkg")
          shift; TRACELENS_PKG=${1}; reset-last ;;
      "--rocm-version")
          shift; ROCM_VERSION=${1}; reset-last ;;
      "--module-path")
          shift; MODULE_PATH=${1}; reset-last ;;
      "--install-path")
          shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version")
          shift; TRACELENS_PATH_INPUT=${1}; reset-last ;;
      # Accept-and-ignore the COMMON_OPTIONS main_setup.sh threads to
      # ROCm-aware leaves; TraceLens is arch-agnostic.
      "--amdgpu-gfxmodel")
          shift; reset-last ;;
      "--replace")
          shift; REPLACE=${1}; reset-last ;;
      "--keep-failed-installs")
          shift; KEEP_FAILED_INSTALLS=${1}; reset-last ;;
      "--help")
          usage ;;
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}" ;;
      *)
         last ${1} ;;
   esac
   n=$((${n} + 1))
   shift
done

# ── BUILD_TRACELENS=0 short-circuit: operator opt-out ─────────────────
NOOP_RC=43
if [ "${BUILD_TRACELENS}" = "0" ]; then
   echo "[tracelens BUILD_TRACELENS=0] operator opt-out; skipping (no install)."
   echo "  Use --build-tracelens 1 to install TraceLens."
   exit ${NOOP_RC}
fi

# Finalize install path now that versions are known.
TRACELENS_DIRNAME="tracelens-v${TRACELENS_VERSION}"
if [ -n "${TRACELENS_PATH_INPUT}" ]; then
   TRACELENS_PATH="${TRACELENS_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   TRACELENS_PATH="${ROCMPLUS_PATH_INPUT}/${TRACELENS_DIRNAME}"
else
   TRACELENS_PATH="/opt/rocmplus-${ROCM_VERSION}/${TRACELENS_DIRNAME}"
fi

# Derive the rocm modulefile token for the modulefile's prereq line (same
# resolution order as hyperloom_setup.sh).
ROCM_MODULE_NAME=""
if [[ -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      case "${_m}" in rocm/*) ROCM_MODULE_NAME="${_m}"; break ;; esac
   done
   IFS="${_OLD_IFS}"; unset _OLD_IFS _m
fi
if [[ -z "${ROCM_MODULE_NAME}" ]]; then
   if [[ -n "${ROCM_PATH:-}" ]]; then
      _rp_bn="${ROCM_PATH##*/}"; ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"; unset _rp_bn
   else
      ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
   fi
fi

# Extras spec for the pip URL: TraceLens[<extras>] @ git+...
TRACELENS_EXTRAS_SPEC=""
[ -n "${TRACELENS_EXTRAS}" ] && TRACELENS_EXTRAS_SPEC="[${TRACELENS_EXTRAS}]"
_tl_ref_spec="${TRACELENS_REPO}"
[ -n "${TRACELENS_REF}" ] && _tl_ref_spec="${TRACELENS_REPO}@${TRACELENS_REF}"
TRACELENS_PIP_SPEC="${TRACELENS_PKG}${TRACELENS_EXTRAS_SPEC} @ git+${_tl_ref_spec}"
unset _tl_ref_spec

echo ""
echo "====================================="
echo " Installing TraceLens"
echo " TraceLens version: $TRACELENS_VERSION (ref ${TRACELENS_REF})"
echo " Extras:            ${TRACELENS_EXTRAS:-(none)}"
echo " Install directory: $TRACELENS_PATH"
echo " Module directory:  $MODULE_PATH"
echo " Module name:       tracelens/$TRACELENS_VERSION"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo "====================================="
echo ""

# ── Install-path sudo: probe nearest existing ancestor for writability ─
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${TRACELENS_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .tracelens-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "tracelens: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "tracelens: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
MODULEFILE_LUA="${MODULE_PATH}/${TRACELENS_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${TRACELENS_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[tracelens --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${TRACELENS_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi
if [ -d "${TRACELENS_PATH}" ]; then
   echo ""
   echo "[tracelens existence-check] ${TRACELENS_PATH} already installed; skipping."
   echo "  pass --replace 1 to reinstall."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
_tracelens_on_exit() {
   local rc=$?
   [ -n "${TRACELENS_BUILD_ROOT:-}" ] && rm -rf "${TRACELENS_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[tracelens fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${TRACELENS_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[tracelens fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _tracelens_on_exit EXIT

# Resolve a base Python >= 3.8 for the venv (TraceLens advertises 3.6+, but
# xprof/protobuf/LLM-client extras need a modern interpreter).
PYTHON_BASE="$(command -v python3 || true)"
[ -z "${PYTHON_BASE}" ] && send-error "no python3 on PATH to create the TraceLens venv."
PY_MM="$(${PYTHON_BASE} -c 'import sys; print("%d.%d"%sys.version_info[:2])')"
case "${PY_MM}" in
   3.8|3.9|3.10|3.11|3.12|3.13) : ;;
   *) send-error "TraceLens venv needs Python >= 3.8; base python3 is ${PY_MM}." ;;
esac
echo "tracelens: base python ${PYTHON_BASE} (${PY_MM})"

# Create the install tree.
if ! ${SUDO} mkdir -p "${TRACELENS_PATH}/bin"; then
   send-error "could not create install dir ${TRACELENS_PATH} (SUDO='${SUDO}')."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+rwX "${TRACELENS_PATH}"
fi

TRACELENS_BUILD_ROOT=$(mktemp -d -t tracelens-build.XXXXXX)

# ── Create the venv and install the wheel ─────────────────────────────
# Harden pip against a polluted global/user pip config on shared NFS HOME
# (mirrors hyperloom_setup.sh): neutralize config files and pin canonical PyPI.
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"

VENV="${TRACELENS_PATH}/venv"
echo "tracelens: creating venv at ${VENV}"
${SUDO} ${PYTHON_BASE} -m venv "${VENV}"
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+rwX "${TRACELENS_PATH}"
fi
"${VENV}/bin/python" -m pip install --upgrade pip wheel setuptools \
   || send-error "could not upgrade pip/wheel/setuptools in the venv."
echo "tracelens: installing '${TRACELENS_PIP_SPEC}' into the venv"
"${VENV}/bin/python" -m pip install "${TRACELENS_PIP_SPEC}" \
   || send-error "pip install of TraceLens failed; see log above."

# Expose ONLY the TraceLens_* console scripts on PATH (never the venv
# python/pip), so a user's system python stays authoritative for the
# pytorch/framework modules. Symlink every venv/bin entry that is not a
# python/pip/venv housekeeping script.
_linked=0
shopt -s nullglob
for _exe in "${VENV}/bin"/*; do
   _b="$(basename "${_exe}")"
   case "${_b}" in
      python|python[0-9]*|pip|pip[0-9]*|wheel|activate|activate.*|Activate.ps1|easy_install|easy_install-*|__pycache__) continue ;;
   esac
   [ -f "${_exe}" ] || continue
   ${SUDO} ln -sf "${_exe}" "${TRACELENS_PATH}/bin/${_b}"
   _linked=$((_linked + 1))
done
shopt -u nullglob
echo "tracelens: exposed ${_linked} console script(s) under ${TRACELENS_PATH}/bin"
if [ "${_linked}" -eq 0 ]; then
   echo "tracelens: WARNING no console scripts found in the venv; the package may expose none."
fi
unset _linked _exe _b

# Normalize ownership/permissions like the sibling leaves.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${TRACELENS_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${TRACELENS_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} chmod -R go-w "${TRACELENS_PATH}"
fi

echo "tracelens: installed into ${TRACELENS_PATH}"

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .tracelens-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "tracelens: module ancestor ${_mprobe} is user-writable; not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "tracelens: module ancestor ${_mprobe} not user-writable; using sudo for modulefile"
   fi
   unset _mprobe _mtest
fi
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

# Provenance for the modulefile whatis() line.
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

# Lmod consumes <ver>.lua; classic Tcl `environment-modules` consumes an
# extensionless Tcl file. Detect Lmod via its env markers; default to Tcl
# when Lmod is absent (mirrors roc-optiq/hdf5/netcdf).
if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
   MODULEFILE="${MODULEFILE_LUA}"; MODFLAVOR="lua"
else
   MODULEFILE="${MODULEFILE_TCL}"; MODFLAVOR="tcl"
fi

if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("TraceLens ${TRACELENS_VERSION} -- automated performance analysis from PyTorch/JAX/rocprofv3 traces (venv)")
	whatis("Upstream: ${TRACELENS_REPO} (ref ${TRACELENS_REF}); extras: ${TRACELENS_EXTRAS:-none}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")

	local base = "${TRACELENS_PATH}"
	-- Expose ONLY the TraceLens_* CLIs; do NOT put the venv python on PATH, so
	-- the system python stays authoritative for the pytorch/framework modules.
	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("TRACELENS_HOME", base)
	setenv("TRACELENS_VENV", pathJoin(base, "venv"))

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#  TraceLens ${TRACELENS_VERSION}: analyze a profiler trace, e.g.")
	  LmodMessage("#    TraceLens_generate_perf_report_pytorch --profile_json_path <trace.json>")
	  LmodMessage("#  See 'TraceLens_generate_perf_report_pytorch --help' for options.")
	  LmodMessage("")
	end
EOF
else
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "TraceLens ${TRACELENS_VERSION} -- automated performance analysis from PyTorch/JAX/rocprofv3 traces (venv)"
	module-whatis "Upstream: ${TRACELENS_REPO} (ref ${TRACELENS_REF}); extras: ${TRACELENS_EXTRAS:-none}"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_MODULE_NAME}

	set base "${TRACELENS_PATH}"
	prepend-path PATH \$base/bin
	setenv TRACELENS_HOME \$base
	setenv TRACELENS_VENV \$base/venv

	if { [module-info mode load] } {
	  puts stderr ""
	  puts stderr "#  TraceLens ${TRACELENS_VERSION}: TraceLens_generate_perf_report_pytorch --profile_json_path <trace.json>"
	  puts stderr ""
	}
EOF
fi

# ── Refresh the Lmod spider cache timestamp (mirrors hyperloom_setup.sh) ─
# Guard on `module` existing: TraceLens is arch-agnostic and may be installed
# on a host without Lmod, where `module --config` would 127 and (under set -e)
# wipe an otherwise-successful install via the EXIT trap.
LMOD_TS_FILE=""
if command -v module >/dev/null 2>&1; then
   LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
fi
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   if ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null; then
      echo "[tracelens] bumped Lmod cache timestamp; tracelens/${TRACELENS_VERSION} is loadable now."
   else
      echo "[tracelens] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load tracelens/${TRACELENS_VERSION}"
   fi
else
   echo "[tracelens] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load tracelens/${TRACELENS_VERSION}"
fi

echo ""
echo "[tracelens] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} tracelens/${TRACELENS_VERSION}"
echo "[tracelens] modulefile: ${MODULEFILE} (${MODFLAVOR})"
echo ""
