#!/bin/bash

# Capture this script's absolute path BEFORE any cd, for the git-provenance
# block that stamps the modulefile.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# xDiT (xfuser) setup for AMD CDNA GPUs, in the HPCTrainingDock leaf style.
# xDiT is a parallel/distributed inference engine for Diffusion Transformers
# (DiTs). Mirrors atom_setup.sh / sglang_setup.sh's SAFE install model: it
# layers on the `pytorch` module (never ships its own torch), hard-pins the
# module's torch/triton/flash-attn in a constraints file, resolves the
# dependency delta with a dry-run, and installs ONLY that delta into a
# per-(xdit,pytorch) PREFIX with --no-deps --ignore-installed so the shared
# pytorch module is never mutated.
#
# WHAT THIS MODULE IS:
#   * xDiT ships as the pure-python `xfuser` wheel on PyPI (no native compile).
#   * It is BOUND to a concrete pytorch module (its torch-compile / attention
#     paths use the module torch), but it has NO ABI-locked kernels of its
#     own, so a SINGLE pytorch binding is sufficient (unlike ATOM/vLLM).
#   * REUSES the pytorch module's torch/triton and its flash-attn (xfuser's
#     flash-attn is an OPTIONAL extra; its unified/ring sequence-parallel
#     attention uses whatever flash-attn is importable at runtime -- i.e. the
#     module's). Only xfuser's pure-python deps (diffusers, transformers,
#     accelerate, peft, yunchang, distvae, av, ...) land in the prefix.
#
# Install layout (keyed on BOTH versions so pairs coexist, like atom):
#   prefix     : /opt/rocmplus-${ROCM_VERSION}/xdit-v${XDIT_VERSION}-pt${PYTORCH_VERSION}
#   modulefile : ${MODULE_PATH}/${XDIT_VERSION}-pt${PYTORCH_VERSION}.lua
# Lands in the ROCmPlus-AI overlay the rocm module adds to MODULEPATH, so
# xdit/<ver> is only visible once the matching rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

ROCM_VERSION=7.2.4
BUILD_XDIT=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/xdit
# Version LABEL for the module name + install dir AND the pinned wheel version.
# xfuser 0.7.0 is the latest released PyPI wheel (mirrors primus/TraceLens/
# atom pinning a released version).
XDIT_VERSION=0.7.0
# pip distribution name for xDiT.
XDIT_PKG="xfuser"
# Optional extra wheel find-links index; empty -> canonical PyPI.
XDIT_INDEX=""
PYTORCH_MODULE="pytorch"
PYTORCH_VERSION=""
# Hard-pin these (ABI/ROCm-compiled) to the pytorch module's EXACT version so
# the dep resolve can never plan a different torch/triton/flash-attn; xfuser's
# attention backends reuse the module's flash-attn rather than a rebuilt one.
PROTECTED_PACKAGES="torch torchvision torchaudio triton pytorch-triton-rocm flash-attn flash-attention aotriton deepspeed xformers"
AMDGPU_GFXMODEL_INPUT=""
XDIT_PATH=""
XDIT_PATH_INPUT=""
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
   echo "  --build-xdit [ 0|1 ]             default $BUILD_XDIT"
   echo "  --xdit-version [ VER ]           xDiT (xfuser) version LABEL + pinned wheel version; default $XDIT_VERSION"
   echo "  --xdit-pkg [ NAME ]              pip distribution name; default $XDIT_PKG"
   echo "  --xdit-index [ URL ]             optional extra wheel find-links index; default none (PyPI)"
   echo "  --pytorch-module [ MOD ]         pytorch module to load; default $PYTORCH_MODULE"
   echo "  --pytorch-version [ VER ]        bound pytorch version; keys the install dir + modulefile. Empty -> resolved from the loaded token."
   echo "  --protect-packages [ names ]     extra ABI/ROCm packages to hard-pin from the pytorch module"
   echo "  --amdgpu-gfxmodel [ GFX ]        default autodetected via rocminfo"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION"
   echo "  --install-path [ DIR ]           parent dir; install -> \${DIR}/xdit-v\${XDIT_VERSION}-pt\${PYTORCH_VERSION}"
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
      "--build-xdit")        shift; BUILD_XDIT=${1}; reset-last ;;
      "--xdit-version")      shift; XDIT_VERSION=${1}; reset-last ;;
      "--xdit-pkg")          shift; XDIT_PKG=${1}; reset-last ;;
      "--xdit-index")        shift; XDIT_INDEX=${1}; reset-last ;;
      "--pytorch-module")    shift; PYTORCH_MODULE=${1}; reset-last ;;
      "--pytorch-version")   shift; PYTORCH_VERSION=${1}; reset-last ;;
      "--protect-packages")  shift; PROTECTED_PACKAGES="${PROTECTED_PACKAGES} ${1}"; reset-last ;;
      "--amdgpu-gfxmodel")   shift; AMDGPU_GFXMODEL_INPUT=${1}; reset-last ;;
      "--rocm-version")      shift; ROCM_VERSION=${1}; reset-last ;;
      "--install-path")      shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version") shift; XDIT_PATH_INPUT=${1}; reset-last ;;
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

# ── BUILD_XDIT=0 short-circuit ────────────────────────────────────────
MISSING_PREREQ_RC=42
NOOP_RC=43
if [ "${BUILD_XDIT}" = "0" ]; then
   echo "[xdit BUILD_XDIT=0] operator opt-out; skipping (no install)."
   echo "  Use --build-xdit 1 to install xDiT."
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

# Derive the rocm module token to (re-)load (same order as atom_setup.sh).
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
   echo "[xdit missing-prereq] could not 'module load ${PYTORCH_MODULE}' after"
   echo "  '${ROCM_MODULE_NAME}'. Build the pytorch module first (pytorch_setup.sh)"
   echo "  or pass --pytorch-module. Skipping xDiT."
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
[ -z "${TORCH_VERSION}" ] && send-error "could not import torch from '${PYTORCH_MODULE}'; cannot install xDiT."
python3 - <<'PY' || send-error "the pytorch module's torch is not a ROCm build (torch.version.hip is None); refusing to install xDiT."
import torch, sys
sys.exit(0 if getattr(torch.version, "hip", None) else 1)
PY

# gfx model detection (for IS_APU gating + the whatis line; xfuser is pure
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
XDIT_DIRNAME="xdit-v${XDIT_VERSION}-pt${PYTORCH_VERSION}"
XDIT_MODULE_TOKEN="${XDIT_VERSION}-pt${PYTORCH_VERSION}"
if [ -n "${XDIT_PATH_INPUT}" ]; then
   XDIT_PATH="${XDIT_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   XDIT_PATH="${ROCMPLUS_PATH_INPUT}/${XDIT_DIRNAME}"
else
   XDIT_PATH="/opt/rocmplus-${ROCM_VERSION}/${XDIT_DIRNAME}"
fi

# ── Install-path sudo (write-probe of nearest existing ancestor) ──────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${XDIT_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .xdit-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "xdit: install ancestor ${_iprobe} is user-writable; not using sudo for install"
   else
      SUDO="sudo"
      echo "xdit: install ancestor ${_iprobe} not user-writable; using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[xdit --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${XDIT_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${XDIT_MODULE_TOKEN}.lua"
fi
if [ -d "${XDIT_PATH}" ]; then
   echo ""
   echo "[xdit existence-check] already installed; skipping (${XDIT_PATH}). Pass --replace 1 to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── Consolidated EXIT trap (build-dir + fail-cleanup) ─────────────────
_xdit_on_exit() {
   local rc=$?
   [ -n "${XDIT_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${XDIT_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[xdit fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${XDIT_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${XDIT_MODULE_TOKEN}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[xdit fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _xdit_on_exit EXIT

echo ""
echo "====================================="
echo " Installing xDiT (xfuser, ROCm)"
echo " xDiT version:      $XDIT_VERSION  (pkg ${XDIT_PKG})"
echo " Install directory: $XDIT_PATH"
echo " Module name:       xdit/$XDIT_MODULE_TOKEN"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo " Pytorch module:    $PYTORCH_MODULE_RESOLVED (torch $TORCH_VERSION, ${AMDGPU_GFXMODEL})"
echo "====================================="
echo ""

if ! ${SUDO} mkdir -p "${XDIT_PATH}"; then
   send-error "could not create install dir ${XDIT_PATH} (SUDO='${SUDO}'). Re-run as root or with passwordless sudo."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${XDIT_PATH}"
fi

XDIT_BUILD_ROOT=$(mktemp -d -t xdit-build.XXXXXX)
cd "${XDIT_BUILD_ROOT}"

# Harden pip against a polluted NFS-HOME pip config (mirrors atom_setup.sh).
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"

# ── Build a constraints file pinning the module's ABI/ROCm packages ───
CONSTRAINTS="${XDIT_BUILD_ROOT}/constraints.txt"
printf '%s\n' "${PYTORCH_MODULE_PYPATHS}" > "${XDIT_BUILD_ROOT}/pytorch_pypaths.txt"
python3 - "${XDIT_BUILD_ROOT}/pytorch_pypaths.txt" "${CONSTRAINTS}" "${PROTECTED_PACKAGES}" <<'PY'
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
echo "xdit: hard-pinned ABI/ROCm packages (sourced only from the pytorch module):"
sed -e 's/^/  /' "${CONSTRAINTS}"

XDIT_SPEC="${XDIT_PKG}==${XDIT_VERSION}"
_idx_args=()
[ -n "${XDIT_INDEX}" ] && _idx_args=(-f "${XDIT_INDEX}")

# ── Resolve the dependency delta against the LIVE module env ──────────
# Dry-run honoring the pytorch module + the hard-pin constraints; filter out
# the protected ABI packages (torch family, flash-attn) and xfuser itself,
# then install only the remaining closure into the prefix with --no-deps.
REPORT="${XDIT_BUILD_ROOT}/resolve-report.json"
DEP_REQS="${XDIT_BUILD_ROOT}/dep-closure.txt"
echo "xdit: resolving dependency closure (dry-run; honors the pytorch module, never writes)"
pip3 install --dry-run --report "${REPORT}" \
   --constraint "${CONSTRAINTS}" \
   "${_idx_args[@]}" "${XDIT_SPEC}" \
   || send-error "dependency resolution (dry-run) failed; see log above (often a real torch/ABI conflict)."
python3 - "${REPORT}" "${DEP_REQS}" "${PROTECTED_PACKAGES}" "${XDIT_PKG}" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
protected = set(x.lower().replace("_", "-") for x in sys.argv[3].split())
skip = protected | {sys.argv[4].lower().replace("_", "-")}
reqs = []
for item in rep.get("install", []):
    md = item.get("metadata", {})
    name = (md.get("name") or "").strip()
    ver = (md.get("version") or "").strip()
    if not name or name.lower().replace("_", "-") in skip:
        continue
    reqs.append(f"{name}=={ver}")
open(sys.argv[2], "w").write("\n".join(sorted(reqs)) + ("\n" if reqs else ""))
print(f"xdit: dependency closure = {len(reqs)} package(s) to install into the prefix")
PY

if [ -s "${DEP_REQS}" ]; then
   echo "xdit: installing resolved deps into the prefix (--no-deps --ignore-installed; module untouched)"
   pip3 install --prefix="${XDIT_PATH}" --no-deps --ignore-installed --no-warn-script-location \
      --constraint "${CONSTRAINTS}" \
      "${_idx_args[@]}" -r "${DEP_REQS}" || send-error "installing the resolved dependency closure failed; see log above."
fi

# ── Install xfuser itself into the PREFIX (wheel; --no-deps) ──────────
echo "xdit: installing ${XDIT_SPEC} into the prefix (--no-deps)"
pip3 install --prefix="${XDIT_PATH}" --no-deps --ignore-installed --no-warn-script-location \
   "${_idx_args[@]}" "${XDIT_SPEC}" \
   || send-error "installing ${XDIT_SPEC} failed; see log above."

# Resolve the prefix site/bin dirs for the modulefile.
XDIT_SITE="$(find "${XDIT_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
[ -z "${XDIT_SITE}" ] && send-error "xdit install produced no site/dist-packages under ${XDIT_PATH}; install likely failed."
XDIT_BINDIR="${XDIT_SITE%/lib/*}/bin"
echo "xdit: installed into prefix ${XDIT_PATH} (site: ${XDIT_SITE})"

# Normalize ownership/permissions.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${XDIT_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${XDIT_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
fi
[[ "${USER}" != "root" ]] && ${SUDO} chmod go-w "${XDIT_PATH}" 2>/dev/null || true

cd /

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .xdit-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "xdit: module ancestor ${_mprobe} is user-writable; not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "xdit: module ancestor ${_mprobe} not user-writable; using sudo for modulefile"
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
-- model / batch so the diffusion pipeline fits the shared pool; run ONLY in a
-- GPU allocation (never fe1).
LUA
)
else
   APU_MODULE_BLOCK=""
fi

cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${XDIT_MODULE_TOKEN}.lua
	whatis("xDiT ${XDIT_VERSION} -- xfuser: parallel/distributed inference engine for Diffusion Transformers (bound to ${PYTORCH_MODULE_RESOLVED}, torch ${TORCH_VERSION}, ${AMDGPU_GFXMODEL})")
	whatis("Package: ${XDIT_PKG}==${XDIT_VERSION} (PyPI)")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- xDiT layers on the pytorch module (torch/triton) and reuses its
	-- flash-attn for unified/ring sequence-parallel attention.
	prereq("${ROCM_MODULE_NAME}")
	load("${PYTORCH_MODULE_RESOLVED}")

	local base = "${XDIT_PATH}"
	prepend_path("PYTHONPATH","${XDIT_SITE}")
	prepend_path("PATH","${XDIT_BINDIR}")
	setenv("XDIT_HOME", base)
${APU_MODULE_BLOCK}

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#  xDiT ${XDIT_VERSION} (xfuser): parallel diffusion-transformer inference. Run ONLY in a GPU allocation.")
	  LmodMessage("#  See https://github.com/xdit-project/xDiT for examples (torchrun ... examples/*_example.py).")
	  LmodMessage("")
	end
EOF

# ── Refresh the Lmod spider cache timestamp (mirrors atom_setup.sh) ────
LMOD_TS_FILE=""
if command -v module >/dev/null 2>&1; then
   LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
fi
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null \
      && echo "[xdit] bumped Lmod cache timestamp; xdit/${XDIT_MODULE_TOKEN} is loadable now." \
      || echo "[xdit] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load xdit/${XDIT_MODULE_TOKEN}"
else
   echo "[xdit] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load xdit/${XDIT_MODULE_TOKEN}"
fi

echo ""
echo "[xdit] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} ${PYTORCH_MODULE_RESOLVED} xdit/${XDIT_MODULE_TOKEN}"
echo ""
