#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# ONNX Runtime (ROCm) -- inference accelerator using the AMD MIGraphX
# execution provider. Packaged in the HPCTrainingDock leaf style, modeled
# on tracelens_setup.sh (standalone pip install + versioned modulefile,
# Lua/Tcl flavor detection, sudo write-probes, EXIT-trap cleanup, Lmod
# cache bump, git-provenance whatis stamp).
#
# WHAT THIS MODULE IS:
#   * Installs the prebuilt `onnxruntime-migraphx` wheel (the standalone
#     ROCm execution provider was removed in ORT >= 1.23; AMD's path is the
#     MIGraphX EP) from the ROCm manylinux wheel index into a self-contained
#     site-packages dir and exposes it on PYTHONPATH so `import onnxruntime`
#     works with the system/module python.
#   * REUSES the system MIGraphX already shipped by the rocm module
#     (libmigraphx_c.so* + python bindings under ${ROCM_PATH}/lib); it does
#     NOT install or build MIGraphX. The modulefile adds ${ROCM_PATH}/lib to
#     PYTHONPATH so `import migraphx` and the EP's C library resolve against
#     the loaded ROCm.
#   * torch-independent: ONNX Runtime needs no pytorch module and is not ABI
#     bound to torch. The orchestrator's --amdgpu-gfxmodel is accepted and
#     ignored (the wheel is a manylinux binary; the EP targets the GPU at
#     runtime via MIGraphX).
#
# Install layout (keyed on the ROCm version, like the rocmplus tree):
#   site-packages : ${ONNXRUNTIME_PATH}/lib/python<MM>/site-packages
#   modulefile    : ${MODULE_PATH}/${ONNXRUNTIME_VERSION}.lua  (onnxruntime/<ver>)
# The modulefile lands in the ROCmPlus-AI overlay the rocm module adds to
# MODULEPATH (same overlay as instella), so onnxruntime/<ver> is only visible
# once rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
ROCM_VERSION=7.2.4
BUILD_ONNXRUNTIME=1
# Version LABEL (keys install dir + module) AND the pinned wheel version.
# onnxruntime_migraphx-1.23.2 is the cp312 wheel published for ROCm 7.2.x on
# the manylinux index (mirrors primus/TraceLens pinning a released version).
ONNXRUNTIME_VERSION=1.23.2
# pip distribution name for the MIGraphX-EP build of ONNX Runtime.
ONNXRUNTIME_PKG="onnxruntime-migraphx"
# Wheel index; defaults (below, once ROCM_VERSION is known) to the ROCm
# manylinux index keyed by the wheel-form ROCm version, mirroring the triton
# install in pytorch_setup.sh. Override for a different repo/mirror.
ONNXRUNTIME_INDEX=""
# Optional numpy constraint. ORT >= 1.23 supports numpy 2, so empty by default;
# set e.g. "numpy<2" if a wheel requires it.
ONNXRUNTIME_NUMPY_PIN=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/onnxruntime
# ${ONNXRUNTIME_PATH} finalized after ONNXRUNTIME_VERSION/ROCM_VERSION are known.
ONNXRUNTIME_PATH=""
ONNXRUNTIME_PATH_INPUT=""
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
   echo "  --build-onnxruntime [ 0|1 ]      default $BUILD_ONNXRUNTIME"
   echo "  --onnxruntime-version [ VER ]    version LABEL + pinned wheel version; default $ONNXRUNTIME_VERSION"
   echo "  --onnxruntime-pkg [ NAME ]       pip distribution name; default $ONNXRUNTIME_PKG"
   echo "  --onnxruntime-index [ URL ]      wheel find-links index; default the ROCm manylinux index for the rocm version"
   echo "  --onnxruntime-numpy-pin [ SPEC ] optional numpy constraint (e.g. 'numpy<2'); default none"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION (keys the install dir /opt/rocmplus-<ver>)"
   echo "  --module-path [ PATH ]           default $MODULE_PATH"
   echo "  --install-path [ PATH ]          parent dir; install goes to \${PATH}/onnxruntime-v\${ONNXRUNTIME_VERSION}"
   echo "  --install-path-no-version [ DIR ] full leaf install dir (wins over --install-path)"
   echo "  --amdgpu-gfxmodel [ GFX ]        accepted and ignored (manylinux wheel; EP targets the GPU at runtime)"
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
      "--build-onnxruntime")
          shift; BUILD_ONNXRUNTIME=${1}; reset-last ;;
      "--onnxruntime-version")
          shift; ONNXRUNTIME_VERSION=${1}; reset-last ;;
      "--onnxruntime-pkg")
          shift; ONNXRUNTIME_PKG=${1}; reset-last ;;
      "--onnxruntime-index")
          shift; ONNXRUNTIME_INDEX=${1}; reset-last ;;
      "--onnxruntime-numpy-pin")
          shift; ONNXRUNTIME_NUMPY_PIN=${1}; reset-last ;;
      "--rocm-version")
          shift; ROCM_VERSION=${1}; reset-last ;;
      "--module-path")
          shift; MODULE_PATH=${1}; reset-last ;;
      "--install-path")
          shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version")
          shift; ONNXRUNTIME_PATH_INPUT=${1}; reset-last ;;
      # Accept-and-ignore the COMMON_OPTIONS main_setup.sh threads to
      # ROCm-aware leaves; the onnxruntime wheel is a manylinux binary.
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

# ── BUILD_ONNXRUNTIME=0 short-circuit: operator opt-out ───────────────
NOOP_RC=43
if [ "${BUILD_ONNXRUNTIME}" = "0" ]; then
   echo "[onnxruntime BUILD_ONNXRUNTIME=0] operator opt-out; skipping (no install)."
   echo "  Use --build-onnxruntime 1 to install ONNX Runtime."
   exit ${NOOP_RC}
fi

# Bring `module` into scope for standalone invocation (for ROCM_PATH).
if [ -f /etc/profile.d/lmod.sh ]; then
   source /etc/profile.d/lmod.sh
fi

# Derive the wheel-form ROCm version (patch .0 collapses to major.minor,
# mirroring pytorch_setup.sh) and the default manylinux index.
ROCM_VERSION_WHEEL=${ROCM_VERSION}
if [[ "$(echo "${ROCM_VERSION}" | cut -f3-3 -d'.')" == 0 ]]; then
   ROCM_VERSION_WHEEL=$(echo "${ROCM_VERSION}" | cut -f1-2 -d'.')
fi
if [ -z "${ONNXRUNTIME_INDEX}" ]; then
   ONNXRUNTIME_INDEX="https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/"
fi

# Finalize install path now that versions are known.
ONNXRUNTIME_DIRNAME="onnxruntime-v${ONNXRUNTIME_VERSION}"
if [ -n "${ONNXRUNTIME_PATH_INPUT}" ]; then
   ONNXRUNTIME_PATH="${ONNXRUNTIME_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   ONNXRUNTIME_PATH="${ROCMPLUS_PATH_INPUT}/${ONNXRUNTIME_DIRNAME}"
else
   ONNXRUNTIME_PATH="/opt/rocmplus-${ROCM_VERSION}/${ONNXRUNTIME_DIRNAME}"
fi

# Derive the rocm modulefile token for the modulefile's prereq line (same
# resolution order as tracelens_setup.sh).
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

# Resolve a base Python >= 3.8 for the install target.
PYTHON_BASE="$(command -v python3 || true)"
[ -z "${PYTHON_BASE}" ] && send-error "no python3 on PATH to install ONNX Runtime."
PY_MM="$(${PYTHON_BASE} -c 'import sys; print("%d.%d"%sys.version_info[:2])')"
case "${PY_MM}" in
   3.8|3.9|3.10|3.11|3.12|3.13) : ;;
   *) send-error "ONNX Runtime needs Python 3.8-3.13; base python3 is ${PY_MM}." ;;
esac

ONNXRUNTIME_SITE="${ONNXRUNTIME_PATH}/lib/python${PY_MM}/site-packages"
ONNXRUNTIME_BINDIR="${ONNXRUNTIME_PATH}/bin"

echo ""
echo "====================================="
echo " Installing ONNX Runtime (ROCm / MIGraphX EP)"
echo " ONNX Runtime ver:  $ONNXRUNTIME_VERSION (pkg ${ONNXRUNTIME_PKG})"
echo " Wheel index:       $ONNXRUNTIME_INDEX"
echo " Base python:       $PYTHON_BASE (${PY_MM})"
echo " Install directory: $ONNXRUNTIME_PATH"
echo " Module directory:  $MODULE_PATH"
echo " Module name:       onnxruntime/$ONNXRUNTIME_VERSION"
echo " ROCm module:       $ROCM_MODULE_NAME (MIGraphX EP reused from \${ROCM_PATH}/lib)"
echo "====================================="
echo ""

# ── Install-path sudo: probe nearest existing ancestor for writability ─
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${ONNXRUNTIME_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .onnxruntime-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "onnxruntime: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "onnxruntime: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
MODULEFILE_LUA="${MODULE_PATH}/${ONNXRUNTIME_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${ONNXRUNTIME_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[onnxruntime --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${ONNXRUNTIME_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi
if [ -d "${ONNXRUNTIME_PATH}" ]; then
   echo ""
   echo "[onnxruntime existence-check] ${ONNXRUNTIME_PATH} already installed; skipping."
   echo "  pass --replace 1 to reinstall."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
_onnxruntime_on_exit() {
   local rc=$?
   [ -n "${ONNXRUNTIME_BUILD_ROOT:-}" ] && rm -rf "${ONNXRUNTIME_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[onnxruntime fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${ONNXRUNTIME_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[onnxruntime fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _onnxruntime_on_exit EXIT

# Create the install tree.
if ! ${SUDO} mkdir -p "${ONNXRUNTIME_SITE}" "${ONNXRUNTIME_BINDIR}"; then
   send-error "could not create install dir ${ONNXRUNTIME_PATH} (SUDO='${SUDO}')."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+rwX "${ONNXRUNTIME_PATH}"
fi

ONNXRUNTIME_BUILD_ROOT=$(mktemp -d -t onnxruntime-build.XXXXXX)

# Harden pip against a polluted global/user pip config on shared NFS HOME
# (mirrors tracelens_setup.sh): neutralize config files and pin canonical PyPI
# for pure-python deps; the ROCm wheel comes from the find-links index.
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"

# Install the ONNX Runtime wheel + its deps flat into the prefix site-packages.
# --target gives a self-contained, importable dir (no venv python to shadow the
# framework modules' python); deps resolve from PyPI, the ORT wheel from -f.
ONNXRUNTIME_SPEC="${ONNXRUNTIME_PKG}"
[ -n "${ONNXRUNTIME_VERSION}" ] && ONNXRUNTIME_SPEC="${ONNXRUNTIME_PKG}==${ONNXRUNTIME_VERSION}"
_np_args=()
[ -n "${ONNXRUNTIME_NUMPY_PIN}" ] && _np_args=("${ONNXRUNTIME_NUMPY_PIN}")
echo "onnxruntime: installing '${ONNXRUNTIME_SPEC}' (find-links ${ONNXRUNTIME_INDEX}) into ${ONNXRUNTIME_SITE}"
if ! ${SUDO} env PIP_CONFIG_FILE=/dev/null PIP_INDEX_URL="https://pypi.org/simple" \
      "${PYTHON_BASE}" -m pip install --no-cache-dir --no-warn-script-location \
      --target="${ONNXRUNTIME_SITE}" \
      -f "${ONNXRUNTIME_INDEX}" "${ONNXRUNTIME_SPEC}" "${_np_args[@]}"; then
   send-error "pip install of ${ONNXRUNTIME_SPEC} failed; see log above (check the wheel exists for python${PY_MM} at ${ONNXRUNTIME_INDEX})."
fi

# Relocate any console scripts pip dropped under the target into bin/ (ORT
# usually ships none; keep the dir for PATH consistency with sibling leaves).
if [ -d "${ONNXRUNTIME_SITE}/bin" ]; then
   shopt -s nullglob
   for _exe in "${ONNXRUNTIME_SITE}/bin"/*; do
      ${SUDO} ln -sf "${_exe}" "${ONNXRUNTIME_BINDIR}/$(basename "${_exe}")"
   done
   shopt -u nullglob
   unset _exe
fi

# Sanity: the onnxruntime package must be importable from the target alone.
if ! PYTHONPATH="${ONNXRUNTIME_SITE}" "${PYTHON_BASE}" -c 'import onnxruntime as o; print("onnxruntime", o.__version__)'; then
   send-error "onnxruntime did not import from ${ONNXRUNTIME_SITE}; install is incomplete."
fi

# Normalize ownership/permissions like the sibling leaves.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${ONNXRUNTIME_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${ONNXRUNTIME_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} chmod -R go-w "${ONNXRUNTIME_PATH}"
fi

echo "onnxruntime: installed into ${ONNXRUNTIME_PATH} (site: ${ONNXRUNTIME_SITE})"

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .onnxruntime-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "onnxruntime: module ancestor ${_mprobe} is user-writable; not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "onnxruntime: module ancestor ${_mprobe} not user-writable; using sudo for modulefile"
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
# when Lmod is absent (mirrors tracelens/roc-optiq).
if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
   MODULEFILE="${MODULEFILE_LUA}"; MODFLAVOR="lua"
else
   MODULEFILE="${MODULEFILE_TCL}"; MODFLAVOR="tcl"
fi

if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("ONNX Runtime ${ONNXRUNTIME_VERSION} -- ML inference with the AMD MIGraphX execution provider (ROCm)")
	whatis("Package: ${ONNXRUNTIME_PKG} from ${ONNXRUNTIME_INDEX}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- MIGraphX (the execution provider's backend) is reused from the rocm
	-- module; adding \${ROCM_PATH}/lib to PYTHONPATH exposes the migraphx
	-- python bindings and lets the EP load libmigraphx_c.so.
	prereq("${ROCM_MODULE_NAME}")

	local base = "${ONNXRUNTIME_PATH}"
	prepend_path("PYTHONPATH", pathJoin(base, "lib/python${PY_MM}/site-packages"))
	prepend_path("PATH", pathJoin(base, "bin"))
	local rocm = os.getenv("ROCM_PATH")
	if (rocm ~= nil) then
	  prepend_path("PYTHONPATH", pathJoin(rocm, "lib"))
	end
	setenv("ONNXRUNTIME_HOME", base)

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#  ONNX Runtime ${ONNXRUNTIME_VERSION} (MIGraphX EP). Verify the provider:")
	  LmodMessage("#    python -c 'import onnxruntime as o; print(o.get_available_providers())'")
	  LmodMessage("#  Expect 'MIGraphXExecutionProvider' in the list; create a session with")
	  LmodMessage("#  providers=['MIGraphXExecutionProvider','CPUExecutionProvider'].")
	  LmodMessage("")
	end
EOF
else
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "ONNX Runtime ${ONNXRUNTIME_VERSION} -- ML inference with the AMD MIGraphX execution provider (ROCm)"
	module-whatis "Package: ${ONNXRUNTIME_PKG} from ${ONNXRUNTIME_INDEX}"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_MODULE_NAME}

	set base "${ONNXRUNTIME_PATH}"
	prepend-path PYTHONPATH \$base/lib/python${PY_MM}/site-packages
	prepend-path PATH \$base/bin
	if { [info exists env(ROCM_PATH)] } {
	  prepend-path PYTHONPATH \$env(ROCM_PATH)/lib
	}
	setenv ONNXRUNTIME_HOME \$base

	if { [module-info mode load] } {
	  puts stderr ""
	  puts stderr "#  ONNX Runtime ${ONNXRUNTIME_VERSION} (MIGraphX EP): python -c 'import onnxruntime as o; print(o.get_available_providers())'"
	  puts stderr ""
	}
EOF
fi

# ── Refresh the Lmod spider cache timestamp (mirrors tracelens_setup.sh) ─
LMOD_TS_FILE=""
if command -v module >/dev/null 2>&1; then
   LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
fi
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   if ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null; then
      echo "[onnxruntime] bumped Lmod cache timestamp; onnxruntime/${ONNXRUNTIME_VERSION} is loadable now."
   else
      echo "[onnxruntime] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load onnxruntime/${ONNXRUNTIME_VERSION}"
   fi
else
   echo "[onnxruntime] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load onnxruntime/${ONNXRUNTIME_VERSION}"
fi

echo ""
echo "[onnxruntime] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} onnxruntime/${ONNXRUNTIME_VERSION}"
echo "[onnxruntime] modulefile: ${MODULEFILE} (${MODFLAVOR})"
echo ""
