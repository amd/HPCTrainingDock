#!/bin/bash

# Capture this script's absolute path BEFORE any cd, for the git-provenance
# block that stamps the modulefile.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# ComfyUI (comfyanonymous/ComfyUI) setup for AMD CDNA GPUs, in the
# HPCTrainingDock leaf style. Modeled on instella_setup.sh's SAFE install
# model (layer on the `pytorch` module, hard-pin its torch/triton, resolve a
# dependency delta with a dry-run, install ONLY that delta into a per-binding
# PREFIX with --no-deps so the shared pytorch module is never mutated) PLUS an
# application launcher, because ComfyUI is an APP (a `python main.py` web
# server), not an importable library package.
#
# WHAT THIS MODULE IS:
#   * ComfyUI is a node-based diffusion-model GUI/inference server. It has no
#     pip package of its own: it is run from its source tree (`python main.py`).
#   * torch/torchvision/torchaudio are UNPINNED by ComfyUI, so they are reused
#     from the pytorch module (hard-pinned here); only ComfyUI's remaining
#     requirements.txt closure (comfyui-frontend-package, torchsde, safetensors,
#     aiohttp, kornia, spandrel, pydantic, av, ...) lands in the prefix.
#   * The source tree is shipped under share/comfyui; a `comfyui` launcher is
#     installed on PATH that runs main.py with all writable state
#     (models/custom_nodes/input/output/temp/user) under $HOME via
#     --base-directory, so the root-owned prefix is never written (the same
#     read-only-prefix lesson as ATOM's AITER_JIT_DIR).
#
# Install layout (keyed on BOTH versions so pairs coexist, like instella):
#   prefix     : /opt/rocmplus-${ROCM_VERSION}/comfyui-v${COMFYUI_VERSION}-pt${PYTORCH_VERSION}
#   source     : ${COMFYUI_PATH}/share/comfyui   (main.py, comfy/, ...)
#   launcher   : ${COMFYUI_PATH}/bin/comfyui
#   modulefile : ${MODULE_PATH}/${COMFYUI_VERSION}-pt${PYTORCH_VERSION}.lua
# Lands in the ROCmPlus-AI overlay the rocm module adds to MODULEPATH, so
# comfyui/<ver> is only visible once the matching rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

ROCM_VERSION=7.2.4
BUILD_COMFYUI=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/comfyui
# Version LABEL for the module name + install dir; COMFYUI_REF is the git tag
# actually checked out. Upstream publishes release tags (v0.3.x); pin a release.
COMFYUI_VERSION=0.3.77
COMFYUI_REPO="https://github.com/comfyanonymous/ComfyUI.git"
COMFYUI_REF="v0.3.77"
PYTORCH_MODULE="pytorch"
PYTORCH_VERSION=""
# Hard-pin these (ABI/ROCm-compiled) to the pytorch module's EXACT version so
# the requirements resolve can never plan a different torch/triton/vision.
PROTECTED_PACKAGES="torch torchvision torchaudio triton pytorch-triton-rocm flash-attn flash-attention aotriton xformers"
AMDGPU_GFXMODEL_INPUT=""
COMFYUI_PATH=""
COMFYUI_PATH_INPUT=""
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
   echo "  --build-comfyui [ 0|1 ]          default $BUILD_COMFYUI"
   echo "  --comfyui-version [ VER ]        ComfyUI version LABEL (keys install dir + module); default $COMFYUI_VERSION"
   echo "  --comfyui-ref [ REF ]            git tag/branch/commit to check out; default $COMFYUI_REF"
   echo "  --comfyui-repo [ URL ]           git repo; default $COMFYUI_REPO"
   echo "  --pytorch-module [ MOD ]         pytorch module to load; default $PYTORCH_MODULE"
   echo "  --pytorch-version [ VER ]        bound pytorch version; keys the install dir + modulefile. Empty -> resolved from the loaded token."
   echo "  --protect-packages [ names ]     extra ABI/ROCm packages to hard-pin from the pytorch module"
   echo "  --amdgpu-gfxmodel [ GFX ]        default autodetected via rocminfo"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION"
   echo "  --install-path [ DIR ]           parent dir; install -> \${DIR}/comfyui-v\${COMFYUI_VERSION}-pt\${PYTORCH_VERSION}"
   echo "  --install-path-no-version [ DIR ] full leaf install dir (wins over --install-path)"
   echo "  --module-path [ PATH ]           default $MODULE_PATH"
   echo "  --replace [ 0|1 ]                remove prior install + modulefile first, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ]   skip EXIT-trap cleanup on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information"
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
      "--build-comfyui")     shift; BUILD_COMFYUI=${1}; reset-last ;;
      "--comfyui-version")   shift; COMFYUI_VERSION=${1}; reset-last ;;
      "--comfyui-ref")       shift; COMFYUI_REF=${1}; reset-last ;;
      "--comfyui-repo")      shift; COMFYUI_REPO=${1}; reset-last ;;
      "--pytorch-module")    shift; PYTORCH_MODULE=${1}; reset-last ;;
      "--pytorch-version")   shift; PYTORCH_VERSION=${1}; reset-last ;;
      "--protect-packages")  shift; PROTECTED_PACKAGES="${PROTECTED_PACKAGES} ${1}"; reset-last ;;
      "--amdgpu-gfxmodel")   shift; AMDGPU_GFXMODEL_INPUT=${1}; reset-last ;;
      "--rocm-version")      shift; ROCM_VERSION=${1}; reset-last ;;
      "--install-path")      shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version") shift; COMFYUI_PATH_INPUT=${1}; reset-last ;;
      "--module-path")       shift; MODULE_PATH=${1}; reset-last ;;
      "--replace")           shift; REPLACE=${1}; reset-last ;;
      "--keep-failed-installs") shift; KEEP_FAILED_INSTALLS=${1}; reset-last ;;
      "--help")              usage ;;
      "--*")                 send-error "Unsupported argument at position $((${n} + 1)) :: ${1}" ;;
      *)                     last ${1} ;;
   esac
   n=$((${n} + 1))
   shift
done

# ── BUILD_COMFYUI=0 short-circuit ─────────────────────────────────────
MISSING_PREREQ_RC=42
NOOP_RC=43
if [ "${BUILD_COMFYUI}" = "0" ]; then
   echo "[comfyui BUILD_COMFYUI=0] operator opt-out; skipping (no install)."
   echo "  Use --build-comfyui 1 to install ComfyUI."
   exit ${NOOP_RC}
fi

# Bring `module` into scope for standalone invocation.
if [ -f /etc/profile.d/lmod.sh ]; then
   source /etc/profile.d/lmod.sh
fi

# If a specific pytorch version was requested via --pytorch-version but the
# module is still the unversioned default, target that exact version so
# --pytorch-version alone binds the right torch. main_setup.sh passes an
# explicit --pytorch-module pytorch/<v> (already has a slash) -> left untouched.
case "${PYTORCH_MODULE}" in
   */*) : ;;
   *) [ -n "${PYTORCH_VERSION}" ] && PYTORCH_MODULE="${PYTORCH_MODULE}/${PYTORCH_VERSION}" ;;
esac

# Derive the rocm module token to (re-)load (same order as instella_setup.sh).
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

# Load ROCm + pytorch hierarchically (rocm first). purge so a stray
# pytorch/rocm cannot shadow versions or pollute the PYTHONPATH diff.
module purge 2>/dev/null || true
if ! module load ${ROCM_MODULE_NAME}; then
   send-error "could not 'module load ${ROCM_MODULE_NAME}'. Check --rocm-version and that the module exists."
fi
PYTHONPATH_PRE="${PYTHONPATH:-}"
if ! module load ${PYTORCH_MODULE} 2>/dev/null; then
   echo ""
   echo "[comfyui missing-prereq] could not 'module load ${PYTORCH_MODULE}' after"
   echo "  '${ROCM_MODULE_NAME}'. Build the pytorch module first (pytorch_setup.sh)"
   echo "  or pass --pytorch-module. Skipping ComfyUI."
   exit ${MISSING_PREREQ_RC}
fi

# Resolve the EXACT pytorch token loaded (for ABI-correct keying + modulefile).
PYTORCH_MODULE_RESOLVED=""
if [[ -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      case "${_m}" in pytorch/*) PYTORCH_MODULE_RESOLVED="${_m}" ;; esac
   done
   IFS="${_OLD_IFS}"; unset _OLD_IFS _m
fi
case "${PYTORCH_MODULE}" in
   pytorch/*) [[ -z "${PYTORCH_MODULE_RESOLVED}" ]] && PYTORCH_MODULE_RESOLVED="${PYTORCH_MODULE}" ;;
esac
[[ -z "${PYTORCH_MODULE_RESOLVED}" ]] && PYTORCH_MODULE_RESOLVED="${PYTORCH_MODULE}"
if [[ -z "${PYTORCH_VERSION}" ]]; then
   case "${PYTORCH_MODULE_RESOLVED}" in
      pytorch/*) PYTORCH_VERSION="${PYTORCH_MODULE_RESOLVED#pytorch/}" ;;
   esac
fi
[ -z "${PYTORCH_VERSION}" ] && send-error "could not resolve bound pytorch version from '${PYTORCH_MODULE}' (resolved '${PYTORCH_MODULE_RESOLVED}'); pass --pytorch-version or --pytorch-module pytorch/<VER>."

PYTORCH_MODULE_PYPATHS=$(PYTHONPATH_PRE="${PYTHONPATH_PRE}" python3 - <<'PY'
import os
pre = set(p for p in os.environ.get("PYTHONPATH_PRE", "").split(":") if p)
for p in os.environ.get("PYTHONPATH", "").split(":"):
    if p and p not in pre:
        print(p)
PY
)

# Confirm the module torch is a ROCm build and resolve its version.
TORCH_VERSION=$(python3 -c 'import torch; print(torch.__version__.split("+")[0])' 2>/dev/null || true)
[ -z "${TORCH_VERSION}" ] && send-error "could not import torch from '${PYTORCH_MODULE}'; cannot install ComfyUI."
python3 - <<'PY' || send-error "the pytorch module's torch is not a ROCm build (torch.version.hip is None); refusing to install ComfyUI."
import torch, sys
sys.exit(0 if getattr(torch.version, "hip", None) else 1)
PY

# gfx model detection (for IS_APU gating + the whatis line; ComfyUI is pure
# python so no arch-specific compile is needed).
if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
[ -z "${AMDGPU_GFXMODEL}" ] && AMDGPU_GFXMODEL="gfx942"

# APU gating for the modulefile warnings.
IS_APU=0
rocminfo 2>/dev/null | grep -q "MI300A" && IS_APU=1

# Finalize prefix now that both versions are known.
COMFYUI_DIRNAME="comfyui-v${COMFYUI_VERSION}-pt${PYTORCH_VERSION}"
COMFYUI_MODULE_TOKEN="${COMFYUI_VERSION}-pt${PYTORCH_VERSION}"
if [ -n "${COMFYUI_PATH_INPUT}" ]; then
   COMFYUI_PATH="${COMFYUI_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   COMFYUI_PATH="${ROCMPLUS_PATH_INPUT}/${COMFYUI_DIRNAME}"
else
   COMFYUI_PATH="/opt/rocmplus-${ROCM_VERSION}/${COMFYUI_DIRNAME}"
fi

# ── Install-path sudo (write-probe of nearest existing ancestor) ──────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${COMFYUI_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .comfyui-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "comfyui: install ancestor ${_iprobe} is user-writable; not using sudo for install"
   else
      SUDO="sudo"
      echo "comfyui: install ancestor ${_iprobe} not user-writable; using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[comfyui --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${COMFYUI_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${COMFYUI_MODULE_TOKEN}.lua"
fi
if [ -d "${COMFYUI_PATH}" ]; then
   echo ""
   echo "[comfyui existence-check] already installed; skipping (${COMFYUI_PATH}). Pass --replace 1 to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── Consolidated EXIT trap (build-dir + fail-cleanup) ─────────────────
_comfyui_on_exit() {
   local rc=$?
   [ -n "${COMFYUI_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${COMFYUI_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[comfyui fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${COMFYUI_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${COMFYUI_MODULE_TOKEN}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[comfyui fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _comfyui_on_exit EXIT

echo ""
echo "====================================="
echo " Installing ComfyUI (ROCm, from source)"
echo " ComfyUI version:   $COMFYUI_VERSION  (ref ${COMFYUI_REF})"
echo " Install directory: $COMFYUI_PATH"
echo " Module name:       comfyui/$COMFYUI_MODULE_TOKEN"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo " Pytorch module:    $PYTORCH_MODULE_RESOLVED (torch $TORCH_VERSION, ${AMDGPU_GFXMODEL})"
echo "====================================="
echo ""

if ! ${SUDO} mkdir -p "${COMFYUI_PATH}"; then
   send-error "could not create install dir ${COMFYUI_PATH} (SUDO='${SUDO}'). Re-run as root or with passwordless sudo."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${COMFYUI_PATH}"
fi

COMFYUI_BUILD_ROOT=$(mktemp -d -t comfyui-build.XXXXXX)
cd "${COMFYUI_BUILD_ROOT}"

# Harden pip against a polluted NFS-HOME pip config (mirrors instella_setup.sh).
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"

# ── Fetch ComfyUI source at the pinned ref ────────────────────────────
COMFYUI_SRC="${COMFYUI_BUILD_ROOT}/ComfyUI"
echo "comfyui: fetching ${COMFYUI_REPO}@${COMFYUI_REF}"
if ! git clone --depth 1 --branch "${COMFYUI_REF}" "${COMFYUI_REPO}" "${COMFYUI_SRC}" 2>/dev/null; then
   # --branch fails for a bare commit SHA; fall back to full clone + checkout.
   rm -rf "${COMFYUI_SRC}"
   git clone "${COMFYUI_REPO}" "${COMFYUI_SRC}"
   ( cd "${COMFYUI_SRC}" && git checkout "${COMFYUI_REF}" )
fi
[ -f "${COMFYUI_SRC}/requirements.txt" ] || send-error "ComfyUI source has no requirements.txt (${COMFYUI_SRC}); wrong ref?"
[ -f "${COMFYUI_SRC}/main.py" ]          || send-error "ComfyUI source has no main.py (${COMFYUI_SRC}); wrong ref?"

# ── Build a constraints file pinning the module's ABI/ROCm packages ───
CONSTRAINTS="${COMFYUI_BUILD_ROOT}/constraints.txt"
printf '%s\n' "${PYTORCH_MODULE_PYPATHS}" > "${COMFYUI_BUILD_ROOT}/pytorch_pypaths.txt"
python3 - "${COMFYUI_BUILD_ROOT}/pytorch_pypaths.txt" "${CONSTRAINTS}" "${PROTECTED_PACKAGES}" <<'PY'
import sys
from importlib import metadata
paths_file, constraints_file, protected_str = sys.argv[1], sys.argv[2], sys.argv[3]
protected = set(x.lower().replace("_", "-") for x in protected_str.split())
dirs = [l.strip() for l in open(paths_file) if l.strip()]
seen = {}
for dist in metadata.distributions(path=dirs):
    name = dist.metadata["Name"]
    if not name:
        continue
    key = name.lower().replace("_", "-")
    seen.setdefault(key, (name, dist.version))
with open(constraints_file, "w") as c:
    for key, (name, ver) in sorted(seen.items()):
        if key in protected:
            c.write(f"{name}=={ver}\n")
PY
echo "comfyui: hard-pinned ABI/ROCm packages (sourced only from the pytorch module):"
sed -e 's/^/  /' "${CONSTRAINTS}"

# ── Resolve the requirements.txt delta against the LIVE module env ────
# Dry-run honoring the pytorch module + the hard-pin constraints; filter out
# the protected ABI packages (torch family), then install only the remaining
# closure into the prefix with --no-deps (module untouched).
REPORT="${COMFYUI_BUILD_ROOT}/resolve-report.json"
DEP_REQS="${COMFYUI_BUILD_ROOT}/dep-closure.txt"
echo "comfyui: resolving requirements.txt dependency closure (dry-run; honors the pytorch module, never writes)"
pip3 install --dry-run --report "${REPORT}" \
   --constraint "${CONSTRAINTS}" \
   -r "${COMFYUI_SRC}/requirements.txt" \
   || send-error "dependency resolution (dry-run) failed; see log above (often a real torch/ABI conflict)."
python3 - "${REPORT}" "${DEP_REQS}" "${PROTECTED_PACKAGES}" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
protected = set(x.lower().replace("_", "-") for x in sys.argv[3].split())
reqs = []
for item in rep.get("install", []):
    md = item.get("metadata", {})
    name = (md.get("name") or "").strip()
    ver = (md.get("version") or "").strip()
    if not name or name.lower().replace("_", "-") in protected:
        continue
    reqs.append(f"{name}=={ver}")
open(sys.argv[2], "w").write("\n".join(sorted(reqs)) + ("\n" if reqs else ""))
print(f"comfyui: dependency closure = {len(reqs)} package(s) to install into the prefix")
PY

if [ -s "${DEP_REQS}" ]; then
   echo "comfyui: installing resolved deps into the prefix (--no-deps --ignore-installed; module untouched)"
   pip3 install --prefix="${COMFYUI_PATH}" --no-deps --ignore-installed --no-warn-script-location \
      --constraint "${CONSTRAINTS}" \
      -r "${DEP_REQS}" || send-error "installing the resolved dependency closure failed; see log above."
fi

# Resolve the prefix site/bin dirs for the modulefile.
COMFYUI_SITE="$(find "${COMFYUI_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
[ -z "${COMFYUI_SITE}" ] && send-error "comfyui dep install produced no site/dist-packages under ${COMFYUI_PATH}; install likely failed."
COMFYUI_BINDIR="${COMFYUI_SITE%/lib/*}/bin"
echo "comfyui: deps installed into prefix ${COMFYUI_PATH} (site: ${COMFYUI_SITE})"

# ── Ship the ComfyUI source tree (main.py, comfy/, ...) under share/ ──
COMFYUI_SHARE="${COMFYUI_PATH}/share/comfyui"
${SUDO} mkdir -p "${COMFYUI_SHARE}"
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${COMFYUI_PATH}/share"
fi
# Copy without the .git history to keep the module tree lean.
( cd "${COMFYUI_SRC}" && tar --exclude='.git' -cf - . ) | ( cd "${COMFYUI_SHARE}" && ${SUDO} tar -xf - )

# ── Install the `comfyui` launcher on PATH ────────────────────────────
# Runs the shipped source with ALL writable state under $HOME (never the
# root-owned prefix): --base-directory sets models/custom_nodes/input/output/
# temp/user. Loopback-only by ComfyUI default (127.0.0.1:8188).
${SUDO} mkdir -p "${COMFYUI_BINDIR}"
cat <<-EOF | ${SUDO} tee "${COMFYUI_BINDIR}/comfyui" >/dev/null
	#!/bin/bash
	# ComfyUI launcher (HPCTrainingDock). Serves on 127.0.0.1:8188 by default;
	# all writable state lives under \${COMFYUI_USER_DIR:-\$HOME/.comfyui}.
	set -euo pipefail
	COMFYUI_SRC="\${COMFYUI_HOME:-${COMFYUI_SHARE}}"
	COMFYUI_BASE="\${COMFYUI_USER_DIR:-\${HOME}/.comfyui}"
	mkdir -p "\${COMFYUI_BASE}"
	cd "\${COMFYUI_SRC}"
	exec python main.py --base-directory "\${COMFYUI_BASE}" "\$@"
EOF
${SUDO} chmod a+rx "${COMFYUI_BINDIR}/comfyui"

# Normalize ownership/permissions.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${COMFYUI_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${COMFYUI_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
fi
[[ "${USER}" != "root" ]] && ${SUDO} chmod go-w "${COMFYUI_PATH}" 2>/dev/null || true

cd /

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .comfyui-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "comfyui: module ancestor ${_mprobe} is user-writable; not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "comfyui: module ancestor ${_mprobe} not user-writable; using sudo for modulefile"
   fi
   unset _mprobe _mtest
fi
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

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

if [ "${IS_APU}" = "1" ]; then
   APU_MODULE_BLOCK=$(cat <<'LUA'

-- MI300A APU: scratch-reclaim workaround (matches the rocm modulefile).
setenv("HSA_NO_SCRATCH_RECLAIM","1")
-- WARNING (MI300A APU): host RAM and GPU HBM are ONE physical pool. Size the
-- model/batch so the diffusion pipeline fits the shared pool; run ONLY in a
-- GPU allocation (never fe1).
LUA
)
else
   APU_MODULE_BLOCK=""
fi

cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${COMFYUI_MODULE_TOKEN}.lua
	whatis("ComfyUI ${COMFYUI_VERSION} -- node-based diffusion-model inference GUI/server with ROCm support (bound to ${PYTORCH_MODULE_RESOLVED}, torch ${TORCH_VERSION}, ${AMDGPU_GFXMODEL})")
	whatis("Upstream: ${COMFYUI_REPO} (ref ${COMFYUI_REF})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- ComfyUI runs on the pytorch module (torch/torchvision/torchaudio); only
	-- its pure-python requirements closure lives in this prefix.
	prereq("${ROCM_MODULE_NAME}")
	load("${PYTORCH_MODULE_RESOLVED}")

	local base = "${COMFYUI_PATH}"
	prepend_path("PYTHONPATH","${COMFYUI_SITE}")
	-- Expose the source tree so 'import comfy' works without cd'ing into it.
	prepend_path("PYTHONPATH","${COMFYUI_SHARE}")
	prepend_path("PATH","${COMFYUI_BINDIR}")
	setenv("COMFYUI_HOME", "${COMFYUI_SHARE}")
${APU_MODULE_BLOCK}

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#  ComfyUI ${COMFYUI_VERSION}: start the server ONLY in a GPU allocation (never fe1):")
	  LmodMessage("#    comfyui              # serves on 127.0.0.1:8188; state under \$HOME/.comfyui")
	  LmodMessage("#  Reach the UI by tunneling the port, e.g.: ssh -L 8188:127.0.0.1:8188 <node>")
	  LmodMessage("")
	end
EOF

# ── Refresh the Lmod spider cache timestamp (mirrors instella_setup.sh) ─
LMOD_TS_FILE=""
if command -v module >/dev/null 2>&1; then
   LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
fi
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null \
      && echo "[comfyui] bumped Lmod cache timestamp; comfyui/${COMFYUI_MODULE_TOKEN} is loadable now." \
      || echo "[comfyui] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load comfyui/${COMFYUI_MODULE_TOKEN}"
else
   echo "[comfyui] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load comfyui/${COMFYUI_MODULE_TOKEN}"
fi

echo ""
echo "[comfyui] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} ${PYTORCH_MODULE_RESOLVED} comfyui/${COMFYUI_MODULE_TOKEN}"
echo "  then run:  comfyui"
echo ""
