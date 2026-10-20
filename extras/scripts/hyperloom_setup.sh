#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# ROCm Hyperloom (AMD-AGI/Hyperloom) -- an agentic LLM-inference optimizer.
# Packaged as a self-contained Python venv + Lmod modulefile, in the
# HPCTrainingDock leaf style (mirrors vllm_setup.sh's prefix/module keying
# and emacs_setup.sh's guard/provenance patterns).
#
# WHAT THIS MODULE IS (and is NOT):
#   * It installs the `hyperloom-inference-optimizer` wheel into an isolated
#     venv and exposes ONLY the `hyperloom` CLI on PATH (via a wrapper bin),
#     so it never shadows the system python the pytorch/vllm/sglang modules
#     rely on. Hyperloom drives the serving framework as a SUBPROCESS, so the
#     venv does not need torch/framework importable in-process.
#   * It does NOT bundle an LLM agent CLI (Claude Code / Codex) or any
#     credentials. Those are user-supplied. A per-user, per-workspace `.env`
#     (template shipped under the module) holds the AMD-gateway key.
#   * It does NOT run the optimizer. A real run needs an EXCLUSIVE GPU
#     allocation (never fe1), a framework module (vllm or sglang) loaded, an
#     agent CLI, and an AMD-gateway key -- all per-user at runtime.
#
# Install layout (keyed on the ROCm version, like the rocmplus tree):
#   venv        : ${HYPERLOOM_PATH}/venv
#   wrapper bin : ${HYPERLOOM_PATH}/bin/hyperloom  (symlink to venv console script)
#   env template: ${HYPERLOOM_PATH}/share/hyperloom/env.template
#   modulefile  : ${MODULE_PATH}/${HYPERLOOM_VERSION}.lua  (module hyperloom/<ver>)
# The modulefile lands in the ROCmPlus-AI overlay the rocm module adds to
# MODULEPATH, so hyperloom/<ver> is only visible once rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
ROCM_VERSION=7.2.4
BUILD_HYPERLOOM=0
HYPERLOOM_VERSION=1.0.0
# pip distribution name for the Hyperloom wheel on PyPI.
HYPERLOOM_PKG="hyperloom-inference-optimizer"
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/hyperloom
# ${HYPERLOOM_PATH} finalized after HYPERLOOM_VERSION/ROCM_VERSION are known.
HYPERLOOM_PATH=""
HYPERLOOM_PATH_INPUT=""
ROCMPLUS_PATH_INPUT=""
# AMD enterprise LLM gateway baked into the shipped .env template (no secret).
AMD_GATEWAY_URL="https://llm-api.amd.com/anthropic"
CLAUDE_MODEL_DEFAULT="claude-opus-5"
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
   echo "  --build-hyperloom [ 0|1 ]        default $BUILD_HYPERLOOM"
   echo "  --hyperloom-version [ VER ]      PyPI wheel version; default $HYPERLOOM_VERSION"
   echo "  --hyperloom-pkg [ NAME ]         PyPI distribution name; default $HYPERLOOM_PKG"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION (keys the install dir /opt/rocmplus-<ver>)"
   echo "  --module-path [ PATH ]           default $MODULE_PATH"
   echo "  --install-path [ PATH ]          parent dir; install goes to \${PATH}/hyperloom-v\${HYPERLOOM_VERSION}"
   echo "  --install-path-no-version [ DIR ] full leaf install dir (wins over --install-path)"
   echo "  --amd-gateway-url [ URL ]        Anthropic base URL baked into the .env template; default $AMD_GATEWAY_URL"
   echo "  --claude-model [ ID ]            CLAUDE_MODEL baked into the .env template; default $CLAUDE_MODEL_DEFAULT"
   echo "  --amdgpu-gfxmodel [ GFX ]        accepted and ignored (the orchestrator is arch-agnostic)"
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
      "--build-hyperloom")
          shift; BUILD_HYPERLOOM=${1}; reset-last ;;
      "--hyperloom-version")
          shift; HYPERLOOM_VERSION=${1}; reset-last ;;
      "--hyperloom-pkg")
          shift; HYPERLOOM_PKG=${1}; reset-last ;;
      "--rocm-version")
          shift; ROCM_VERSION=${1}; reset-last ;;
      "--module-path")
          shift; MODULE_PATH=${1}; reset-last ;;
      "--install-path")
          shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version")
          shift; HYPERLOOM_PATH_INPUT=${1}; reset-last ;;
      "--amd-gateway-url")
          shift; AMD_GATEWAY_URL=${1}; reset-last ;;
      "--claude-model")
          shift; CLAUDE_MODEL_DEFAULT=${1}; reset-last ;;
      # Accept-and-ignore the COMMON_OPTIONS main_setup.sh threads to
      # ROCm-aware leaves; the orchestrator wheel is arch-agnostic.
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

# ── BUILD_HYPERLOOM=0 short-circuit: operator opt-out ─────────────────
NOOP_RC=43
if [ "${BUILD_HYPERLOOM}" = "0" ]; then
   echo "[hyperloom BUILD_HYPERLOOM=0] operator opt-out; skipping (no install)."
   echo "  Use --build-hyperloom 1 to install Hyperloom."
   exit ${NOOP_RC}
fi

# Finalize install path now that versions are known.
HYPERLOOM_DIRNAME="hyperloom-v${HYPERLOOM_VERSION}"
if [ -n "${HYPERLOOM_PATH_INPUT}" ]; then
   HYPERLOOM_PATH="${HYPERLOOM_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   HYPERLOOM_PATH="${ROCMPLUS_PATH_INPUT}/${HYPERLOOM_DIRNAME}"
else
   HYPERLOOM_PATH="/opt/rocmplus-${ROCM_VERSION}/${HYPERLOOM_DIRNAME}"
fi

# Derive the rocm modulefile token for the modulefile's prereq line (same
# resolution order as vllm_setup.sh / jax_setup.sh).
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

echo ""
echo "====================================="
echo " Installing ROCm Hyperloom"
echo " Hyperloom version: $HYPERLOOM_VERSION ($HYPERLOOM_PKG)"
echo " Install directory: $HYPERLOOM_PATH"
echo " Module directory:  $MODULE_PATH"
echo " Module name:       hyperloom/$HYPERLOOM_VERSION"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo "====================================="
echo ""

# ── Install-path sudo: probe nearest existing ancestor for writability ─
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${HYPERLOOM_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .hyperloom-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "hyperloom: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "hyperloom: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
MODULEFILE_LUA="${MODULE_PATH}/${HYPERLOOM_VERSION}.lua"
MODULEFILE_TCL="${MODULE_PATH}/${HYPERLOOM_VERSION}"
if [ "${REPLACE}" = "1" ]; then
   echo "[hyperloom --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${HYPERLOOM_PATH}"
   ${SUDO} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
fi
if [ -d "${HYPERLOOM_PATH}" ]; then
   echo ""
   echo "[hyperloom existence-check] ${HYPERLOOM_PATH} already installed; skipping."
   echo "  pass --replace 1 to reinstall."
   echo ""
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup of partial install + modulefile ───────────
_hyperloom_on_exit() {
   local rc=$?
   [ -n "${HYPERLOOM_BUILD_ROOT:-}" ] && rm -rf "${HYPERLOOM_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[hyperloom fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${HYPERLOOM_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULEFILE_LUA}" "${MODULEFILE_TCL}"
   elif [ ${rc} -ne 0 ]; then
      echo "[hyperloom fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _hyperloom_on_exit EXIT

# Resolve a base Python >= 3.10 for the venv (Hyperloom wheel needs 3.10+).
PYTHON_BASE="$(command -v python3 || true)"
[ -z "${PYTHON_BASE}" ] && send-error "no python3 on PATH to create the Hyperloom venv."
PY_MM="$(${PYTHON_BASE} -c 'import sys; print("%d.%d"%sys.version_info[:2])')"
case "${PY_MM}" in
   3.10|3.11|3.12|3.13) : ;;
   *) send-error "Hyperloom needs Python >= 3.10; base python3 is ${PY_MM}." ;;
esac
echo "hyperloom: base python ${PYTHON_BASE} (${PY_MM})"

# Create the install tree.
if ! ${SUDO} mkdir -p "${HYPERLOOM_PATH}/bin" "${HYPERLOOM_PATH}/share/hyperloom"; then
   send-error "could not create install dir ${HYPERLOOM_PATH} (SUDO='${SUDO}')."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+rwX "${HYPERLOOM_PATH}"
fi

HYPERLOOM_BUILD_ROOT=$(mktemp -d -t hyperloom-build.XXXXXX)

# ── Create the venv and install the wheel ─────────────────────────────
# Harden pip against a polluted global/user pip config on shared NFS HOME
# (mirrors vllm_setup.sh): neutralize config files and pin canonical PyPI.
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"

VENV="${HYPERLOOM_PATH}/venv"
echo "hyperloom: creating venv at ${VENV}"
${SUDO} ${PYTHON_BASE} -m venv "${VENV}"
# Make the venv user-writable for the pip phase when we created it via sudo.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+rwX "${HYPERLOOM_PATH}"
fi
"${VENV}/bin/python" -m pip install --upgrade pip wheel setuptools \
   || send-error "could not upgrade pip/wheel/setuptools in the venv."
echo "hyperloom: installing ${HYPERLOOM_PKG}==${HYPERLOOM_VERSION} into the venv"
"${VENV}/bin/python" -m pip install "${HYPERLOOM_PKG}==${HYPERLOOM_VERSION}" \
   || send-error "pip install ${HYPERLOOM_PKG}==${HYPERLOOM_VERSION} failed; see log above."

# Locate the console script the wheel installed.
HL_CONSOLE="${VENV}/bin/hyperloom"
if [ ! -x "${HL_CONSOLE}" ]; then
   # Fall back to a module-run shim if the wheel exposes no console script.
   echo "hyperloom: no 'hyperloom' console script in the venv; writing a python -m shim."
   cat > "${HYPERLOOM_BUILD_ROOT}/hyperloom" <<SHIM
#!/bin/bash
exec "${VENV}/bin/python" -m hyperloom "\$@"
SHIM
   chmod +x "${HYPERLOOM_BUILD_ROOT}/hyperloom"
   ${SUDO} cp "${HYPERLOOM_BUILD_ROOT}/hyperloom" "${HYPERLOOM_PATH}/bin/hyperloom"
else
   # Expose ONLY the console script on PATH (never the venv python/python3),
   # so a user's system python stays authoritative for the framework modules.
   ${SUDO} ln -sf "${HL_CONSOLE}" "${HYPERLOOM_PATH}/bin/hyperloom"
fi

# ── Ship the per-user .env template (no secret) ───────────────────────
cat > "${HYPERLOOM_BUILD_ROOT}/env.template" <<ENVEOF
# Hyperloom per-workspace .env TEMPLATE -- copy to a writable workspace you
# own and fill in your own key. NEVER commit a real key, and never put one
# in the shared module tree.
#
#   mkdir -p \$HOME/hyperloom-work && cd \$HOME/hyperloom-work
#   cp \$HYPERLOOM_ENV_TEMPLATE .env
#   \$EDITOR .env    # paste your AMD-gateway key into ANTHROPIC_API_KEY
#
# AMD enterprise LLM gateway (recommended on the AMD network). The gateway
# authenticates on an Ocp-Apim-Subscription-Key header in addition to the
# bearer key; \${VAR} is expanded from this same file so the secret stays in
# one place. Keep the double quotes (a bare space+colon value is parsed as a
# command by a shell 'source').
ANTHROPIC_API_KEY=<PLEASE_FILL_IN>
ANTHROPIC_BASE_URL=${AMD_GATEWAY_URL}
ANTHROPIC_CUSTOM_HEADERS="Ocp-Apim-Subscription-Key: \${ANTHROPIC_API_KEY}"
CLAUDE_MODEL=${CLAUDE_MODEL_DEFAULT}

# Writable artifact root you own (logs, dependency checkouts, optimizer runs).
# Use per-user scratch, NOT the shared module tree. Example:
USER_DATA_PATH=<PLEASE_FILL_IN e.g. /shareddata/\${USER}/hyperloom>

# Bare-metal run mode (this module is a bare-metal install).
HYPERLOOM_RUN_MODE=baremetal

# FRAMEWORK is set per session to the framework module you loaded:
#   sglang  (module load sglang/...)   or   vllm (module load vllm/...)
# FRAMEWORK=sglang
ENVEOF
${SUDO} cp "${HYPERLOOM_BUILD_ROOT}/env.template" "${HYPERLOOM_PATH}/share/hyperloom/env.template"

# Normalize ownership/permissions like the sibling leaves.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${HYPERLOOM_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${HYPERLOOM_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} chmod -R go-w "${HYPERLOOM_PATH}"
fi

echo "hyperloom: installed into ${HYPERLOOM_PATH}"

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .hyperloom-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "hyperloom: module ancestor ${_mprobe} is user-writable (probe succeeded); not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "hyperloom: module ancestor ${_mprobe} not user-writable (probe failed); using sudo for modulefile"
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

if [ -n "${LMOD_VERSION:-}${LMOD_CMD:-}${LMOD_DIR:-}" ]; then
   MODULEFILE="${MODULEFILE_LUA}"; MODFLAVOR="lua"
else
   MODULEFILE="${MODULEFILE_TCL}"; MODFLAVOR="tcl"
fi

if [ "${MODFLAVOR}" = "lua" ]; then
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	whatis("ROCm Hyperloom ${HYPERLOOM_VERSION} -- agentic LLM-inference optimizer (venv)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	prereq("${ROCM_MODULE_NAME}")

	local base = "${HYPERLOOM_PATH}"
	-- Expose ONLY the hyperloom CLI; do NOT put the venv python on PATH, so
	-- the system python stays authoritative for the pytorch/vllm/sglang modules.
	prepend_path("PATH", pathJoin(base, "bin"))
	setenv("HYPERLOOM_HOME", base)
	setenv("HYPERLOOM_VENV", pathJoin(base, "venv"))
	setenv("HYPERLOOM_ENV_TEMPLATE", pathJoin(base, "share/hyperloom/env.template"))

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#####################################################################")
	  LmodMessage("#  ROCm Hyperloom ${HYPERLOOM_VERSION} (agentic inference optimizer)")
	  LmodMessage("#  Run ONLY inside an exclusive GPU allocation (never on fe1).")
	  LmodMessage("#  Also load a framework:  module load pytorch  &&  module load vllm|sglang")
	  LmodMessage("#  Per-user setup:         cp \$HYPERLOOM_ENV_TEMPLATE <workspace>/.env")
	  LmodMessage("#    then fill ANTHROPIC_API_KEY (AMD gateway) + USER_DATA_PATH")
	  LmodMessage("#  Agent CLI (claude or codex) is user-supplied; not bundled.")
	  LmodMessage("#  Launch:                 hyperloom optimize   (see 'hyperloom --help')")
	  LmodMessage("#####################################################################")
	  LmodMessage("")
	end
EOF
else
   cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULEFILE}
	#%Module1.0
	module-whatis "ROCm Hyperloom ${HYPERLOOM_VERSION} -- agentic LLM-inference optimizer (venv)"
	module-whatis "Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})"

	prereq ${ROCM_MODULE_NAME}

	set base "${HYPERLOOM_PATH}"
	prepend-path PATH \$base/bin
	setenv HYPERLOOM_HOME \$base
	setenv HYPERLOOM_VENV \$base/venv
	setenv HYPERLOOM_ENV_TEMPLATE \$base/share/hyperloom/env.template

	if { [module-info mode load] } {
	  puts stderr ""
	  puts stderr "#  ROCm Hyperloom ${HYPERLOOM_VERSION}: run in an exclusive GPU allocation,"
	  puts stderr "#  load pytorch + vllm|sglang, copy \$base/share/hyperloom/env.template to"
	  puts stderr "#  <workspace>/.env, fill the AMD-gateway key, bring a claude/codex CLI."
	  puts stderr ""
	}
EOF
fi

# ── Refresh the Lmod spider cache timestamp (mirrors vllm_setup.sh) ────
LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   if ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null; then
      echo "[hyperloom] bumped Lmod cache timestamp; hyperloom/${HYPERLOOM_VERSION} is loadable now."
   else
      echo "[hyperloom] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load hyperloom/${HYPERLOOM_VERSION}"
   fi
else
   echo "[hyperloom] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load hyperloom/${HYPERLOOM_VERSION}"
fi

echo ""
echo "[hyperloom] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} hyperloom/${HYPERLOOM_VERSION}"
echo "[hyperloom] modulefile: ${MODULEFILE} (${MODFLAVOR})"
echo ""
