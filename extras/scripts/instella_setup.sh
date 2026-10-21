#!/bin/bash

# Capture this script's absolute path BEFORE any cd, for the git-provenance
# block that stamps the modulefile.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# Instella (AMD-AGI/Instella) setup for AMD CDNA GPUs, in the
# HPCTrainingDock leaf style. Mirrors sglang_setup.sh's SAFE install model:
# it layers on the `pytorch` module (never ships its own torch), hard-pins
# the module's torch/triton in a constraints file, resolves the [all]
# dependency delta with a dry-run, and installs ONLY that delta into a
# per-(instella,pytorch) PREFIX with --no-deps --ignore-installed so the
# shared pytorch module is never mutated.
#
# WHAT THIS MODULE IS:
#   * Instella is a fully-open LLM TRAINING/fine-tuning framework (built on
#     allenai/OLMo) from the AMD GenAI team, trained on MI300X. This module
#     installs the `instella` python package + its [all] runtime deps into a
#     prefix, builds Flash-Attention from source for the node's gfx arch, and
#     ships the source tree (configs/, scripts/) under share/ so the training
#     entry points (scripts/train.py, the configs) are available.
#   * It is BOUND to a concrete pytorch module: Flash-Attention is compiled
#     against that torch and is ABI-locked to it, exactly like sglang/vllm.
#
# Install layout (keyed on BOTH versions so pairs coexist, like sglang):
#   prefix     : /opt/rocmplus-${ROCM_VERSION}/instella-v${INSTELLA_VERSION}-pt${PYTORCH_VERSION}
#   source     : ${INSTELLA_PATH}/share/instella   (configs/, scripts/, ...)
#   modulefile : ${MODULE_PATH}/${INSTELLA_VERSION}-pt${PYTORCH_VERSION}.lua
# Lands in the ROCmPlus-AI overlay the rocm module adds to MODULEPATH, so
# instella/<ver> is only visible once the matching rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

ROCM_VERSION=7.2.4
BUILD_INSTELLA=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/instella
# Version LABEL for the module name + install dir (not a pip version; the
# Instella training repo publishes no release tags). INSTELLA_REF is the git
# ref actually checked out. Upstream has no releases, so rather than track the
# moving main branch we pin a specific main commit for reproducibility; the
# label is the installed package version plus the short commit. Keep both in
# sync when bumping (e.g. --instella-ref <sha> --instella-version 0.1.0-<sha>).
INSTELLA_VERSION=0.1.0-49b16709
# User gave AMD-AGI/Instella; upstream README clones AMD-AIG-AIMA/Instella
# (identical mirror). Default to the user-provided repo; override either with
# --instella-repo / --instella-ref.
INSTELLA_REPO="https://github.com/AMD-AGI/Instella.git"
INSTELLA_REF="49b1670910363247d1a8238dfa306b30742cb36f"
# `.[all]` is the README-recommended install extra for training/fine-tuning.
INSTELLA_EXTRAS="all"
# Flash-Attention is built from source for the node gfx (README: MI300X=gfx942);
# ABI-locked to the module torch. Overridable for a pinned commit.
FLASH_ATTN_REPO="https://github.com/Dao-AILab/flash-attention.git"
FLASH_ATTN_REF=""
WITH_FLASH_ATTN=1
PYTORCH_MODULE="pytorch"
PYTORCH_VERSION=""
# Hard-pin these (ABI/ROCm-compiled) to the pytorch module's EXACT version so
# the [all] resolve can never plan a different torch/triton, and so the
# separately-built flash-attn is never pulled from PyPI.
PROTECTED_PACKAGES="torch torchvision torchaudio triton pytorch-triton-rocm flash-attn flash-attention aotriton deepspeed xformers aiter"
AMDGPU_GFXMODEL_INPUT=""
INSTELLA_PATH=""
INSTELLA_PATH_INPUT=""
ROCMPLUS_PATH_INPUT=""
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"
if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-instella [ 0|1 ]         default $BUILD_INSTELLA"
   echo "  --instella-version [ VER ]       Instella version LABEL (keys install dir + module); default $INSTELLA_VERSION"
   echo "  --instella-ref [ REF ]           git tag/branch/commit to build; default $INSTELLA_REF"
   echo "  --instella-repo [ URL ]          git repo; default $INSTELLA_REPO"
   echo "  --instella-extras [ NAME ]       pip extras to install (comma-sep, no brackets); default $INSTELLA_EXTRAS"
   echo "  --with-flash-attn [ 0|1 ]        build Flash-Attention from source for the node gfx; default $WITH_FLASH_ATTN"
   echo "  --flash-attn-repo [ URL ]        default $FLASH_ATTN_REPO"
   echo "  --flash-attn-ref [ REF ]         default the repo's default branch"
   echo "  --pytorch-module [ MOD ]         pytorch module to load; default $PYTORCH_MODULE"
   echo "  --pytorch-version [ VER ]        bound pytorch version; keys the install dir + modulefile. Empty -> resolved from the loaded token."
   echo "  --protect-packages [ names ]     extra ABI/ROCm packages to hard-pin from the pytorch module"
   echo "  --amdgpu-gfxmodel [ GFX ]        default autodetected via rocminfo"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION"
   echo "  --install-path [ DIR ]           parent dir; install -> \${DIR}/instella-v\${INSTELLA_VERSION}-pt\${PYTORCH_VERSION}"
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
      "--build-instella")    shift; BUILD_INSTELLA=${1}; reset-last ;;
      "--instella-version")  shift; INSTELLA_VERSION=${1}; reset-last ;;
      "--instella-ref")      shift; INSTELLA_REF=${1}; reset-last ;;
      "--instella-repo")     shift; INSTELLA_REPO=${1}; reset-last ;;
      "--instella-extras")   shift; INSTELLA_EXTRAS=${1}; reset-last ;;
      "--with-flash-attn")   shift; WITH_FLASH_ATTN=${1}; reset-last ;;
      "--flash-attn-repo")   shift; FLASH_ATTN_REPO=${1}; reset-last ;;
      "--flash-attn-ref")    shift; FLASH_ATTN_REF=${1}; reset-last ;;
      "--pytorch-module")    shift; PYTORCH_MODULE=${1}; reset-last ;;
      "--pytorch-version")   shift; PYTORCH_VERSION=${1}; reset-last ;;
      "--protect-packages")  shift; PROTECTED_PACKAGES="${PROTECTED_PACKAGES} ${1}"; reset-last ;;
      "--amdgpu-gfxmodel")   shift; AMDGPU_GFXMODEL_INPUT=${1}; reset-last ;;
      "--rocm-version")      shift; ROCM_VERSION=${1}; reset-last ;;
      "--install-path")      shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version") shift; INSTELLA_PATH_INPUT=${1}; reset-last ;;
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

# ── BUILD_INSTELLA=0 short-circuit ────────────────────────────────────
MISSING_PREREQ_RC=42
NOOP_RC=43
if [ "${BUILD_INSTELLA}" = "0" ]; then
   echo "[instella BUILD_INSTELLA=0] operator opt-out; skipping (no build)."
   echo "  Use --build-instella 1 to build Instella."
   exit ${NOOP_RC}
fi

# Bring `module` into scope for standalone invocation.
if [ -f /etc/profile.d/lmod.sh ]; then
   source /etc/profile.d/lmod.sh
fi

# Derive the rocm module token to (re-)load (same order as sglang_setup.sh).
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
   echo "[instella missing-prereq] could not 'module load ${PYTORCH_MODULE}' after"
   echo "  '${ROCM_MODULE_NAME}'. Build the pytorch module first (pytorch_setup.sh)"
   echo "  or pass --pytorch-module. Skipping Instella."
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
[ -z "${TORCH_VERSION}" ] && send-error "could not import torch from '${PYTORCH_MODULE}'; cannot build Instella."
python3 - <<'PY' || send-error "the pytorch module's torch is not a ROCm build (torch.version.hip is None); refusing to build Instella."
import torch, sys
sys.exit(0 if getattr(torch.version, "hip", None) else 1)
PY

# gfx model detection.
if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
[ -z "${AMDGPU_GFXMODEL}" ] && send-error "no GPU architecture specified and rocminfo found none. Pass --amdgpu-gfxmodel (e.g. gfx942)."
# Flash-Attention's ROCm build takes a SINGLE gfx target; take the first gfx.
PYTORCH_ROCM_ARCH=$(echo "${AMDGPU_GFXMODEL}" | tr ',;' '  ' | sed -e 's/:[^ ]*//g')
FA_ARCH=$(echo "${PYTORCH_ROCM_ARCH}" | awk '{print $1}')
[ -z "${FA_ARCH}" ] && FA_ARCH="gfx942"

# APU gating for the modulefile warnings.
IS_APU=0
rocminfo 2>/dev/null | grep -q "MI300A" && IS_APU=1

# Finalize prefix now that both versions are known.
INSTELLA_DIRNAME="instella-v${INSTELLA_VERSION}-pt${PYTORCH_VERSION}"
INSTELLA_MODULE_TOKEN="${INSTELLA_VERSION}-pt${PYTORCH_VERSION}"
if [ -n "${INSTELLA_PATH_INPUT}" ]; then
   INSTELLA_PATH="${INSTELLA_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   INSTELLA_PATH="${ROCMPLUS_PATH_INPUT}/${INSTELLA_DIRNAME}"
else
   INSTELLA_PATH="/opt/rocmplus-${ROCM_VERSION}/${INSTELLA_DIRNAME}"
fi

# ── Install-path sudo (write-probe of nearest existing ancestor) ──────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${INSTELLA_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .instella-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "instella: install ancestor ${_iprobe} is user-writable; not using sudo for install"
   else
      SUDO="sudo"
      echo "instella: install ancestor ${_iprobe} not user-writable; using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[instella --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${INSTELLA_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${INSTELLA_MODULE_TOKEN}.lua"
fi
if [ -d "${INSTELLA_PATH}" ]; then
   echo ""
   echo "[instella existence-check] already installed; skipping (${INSTELLA_PATH}). Pass --replace 1 to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── Consolidated EXIT trap (build-dir + fail-cleanup) ─────────────────
_instella_on_exit() {
   local rc=$?
   [ -n "${INSTELLA_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${INSTELLA_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[instella fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${INSTELLA_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${INSTELLA_MODULE_TOKEN}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[instella fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _instella_on_exit EXIT

echo ""
echo "====================================="
echo " Installing Instella (ROCm, from source)"
echo " Instella version:  $INSTELLA_VERSION  (ref ${INSTELLA_REF})"
echo " Install directory: $INSTELLA_PATH"
echo " Module name:       instella/$INSTELLA_MODULE_TOKEN"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo " Pytorch module:    $PYTORCH_MODULE_RESOLVED (torch $TORCH_VERSION)"
echo " Flash-Attn arch:   $FA_ARCH (build=${WITH_FLASH_ATTN})"
echo "====================================="
echo ""

if ! ${SUDO} mkdir -p "${INSTELLA_PATH}"; then
   send-error "could not create install dir ${INSTELLA_PATH} (SUDO='${SUDO}'). Re-run as root or with passwordless sudo."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${INSTELLA_PATH}"
fi

INSTELLA_BUILD_ROOT=$(mktemp -d -t instella-build.XXXXXX)
cd "${INSTELLA_BUILD_ROOT}"

# Harden pip against a polluted NFS-HOME pip config (mirrors sglang_setup.sh).
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"

# ── Build a constraints file pinning the module's ABI/ROCm packages ───
CONSTRAINTS="${INSTELLA_BUILD_ROOT}/constraints.txt"
printf '%s\n' "${PYTORCH_MODULE_PYPATHS}" > "${INSTELLA_BUILD_ROOT}/pytorch_pypaths.txt"
python3 - "${INSTELLA_BUILD_ROOT}/pytorch_pypaths.txt" "${CONSTRAINTS}" "${PROTECTED_PACKAGES}" <<'PY'
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
echo "instella: hard-pinned ABI/ROCm packages (sourced only from the pytorch module):"
sed -e 's/^/  /' "${CONSTRAINTS}"

# ── Fetch Instella source at the pinned ref ───────────────────────────
INSTELLA_SRC="${INSTELLA_BUILD_ROOT}/Instella"
echo "instella: fetching ${INSTELLA_REPO}@${INSTELLA_REF}"
if ! git clone --depth 1 --branch "${INSTELLA_REF}" "${INSTELLA_REPO}" "${INSTELLA_SRC}" 2>/dev/null; then
   # --branch fails for a bare commit SHA; fall back to full clone + checkout.
   rm -rf "${INSTELLA_SRC}"
   git clone "${INSTELLA_REPO}" "${INSTELLA_SRC}"
   ( cd "${INSTELLA_SRC}" && git checkout "${INSTELLA_REF}" )
fi

# ── Flash-Attention (ROCm) built from source, ABI-locked to module torch ─
# README recipe: GPU_ARCH=gfx942 MAX_JOBS=$(nproc) pip install git+.../flash-attention
# Build a wheel with --no-build-isolation (reuse the module torch at build),
# install into the PREFIX only (never the module). Pass both GPU_ARCH and
# GPU_ARCHS so either the upstream or the ROCm-fork env name is honored.
export MAX_JOBS="${MAX_JOBS:-$(nproc)}"
WHEELHOUSE="${INSTELLA_BUILD_ROOT}/wheelhouse"
mkdir -p "${WHEELHOUSE}"
if [ "${WITH_FLASH_ATTN}" = "1" ]; then
   echo "instella: building Flash-Attention from source (GPU_ARCH=${FA_ARCH})"
   _fa_spec="${FLASH_ATTN_REPO}"
   [ -n "${FLASH_ATTN_REF}" ] && _fa_spec="${FLASH_ATTN_REPO}@${FLASH_ATTN_REF}"
   GPU_ARCH="${FA_ARCH}" GPU_ARCHS="${FA_ARCH}" PYTORCH_ROCM_ARCH="${FA_ARCH}" MAX_JOBS="${MAX_JOBS}" \
      pip3 wheel -v --no-build-isolation --no-deps --wheel-dir "${WHEELHOUSE}" "git+${_fa_spec}" \
      || send-error "Flash-Attention wheel build failed; see log above (ROCm flash-attn is GPU/arch-sensitive)."
   FA_WHEEL="$(find "${WHEELHOUSE}" -maxdepth 1 \( -name 'flash_attn-*.whl' -o -name 'flash-attn-*.whl' \) 2>/dev/null | head -1)"
   [ -z "${FA_WHEEL}" ] && send-error "Flash-Attention build produced no wheel in ${WHEELHOUSE}."
   echo "instella: installing Flash-Attention wheel into the prefix"
   pip3 install --prefix="${INSTELLA_PATH}" --no-deps --ignore-installed --no-warn-script-location \
      "${FA_WHEEL}" || send-error "installing the Flash-Attention wheel failed."
   unset _fa_spec
else
   echo "instella: Flash-Attention build disabled (--with-flash-attn 0)."
fi

# ── Resolve the [all] dependency delta against the LIVE module env ────
# Dry-run honoring the pytorch module + the hard-pin constraints; filter out
# the protected ABI packages (torch family, flash-attn) and instella itself,
# then install only the remaining closure into the prefix with --no-deps.
INSTELLA_EXTRAS_SPEC=""
[ -n "${INSTELLA_EXTRAS}" ] && INSTELLA_EXTRAS_SPEC="[${INSTELLA_EXTRAS}]"
REPORT="${INSTELLA_BUILD_ROOT}/resolve-report.json"
DEP_REQS="${INSTELLA_BUILD_ROOT}/dep-closure.txt"
echo "instella: resolving ${INSTELLA_EXTRAS_SPEC:-(base)} dependency closure (dry-run; honors the pytorch module, never writes)"
pip3 install --dry-run --report "${REPORT}" \
   --constraint "${CONSTRAINTS}" \
   "${INSTELLA_SRC}${INSTELLA_EXTRAS_SPEC}" \
   || send-error "dependency resolution (dry-run) failed; see log above (often a real torch/ABI conflict)."
python3 - "${REPORT}" "${DEP_REQS}" "${PROTECTED_PACKAGES}" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
protected = set(x.lower().replace("_", "-") for x in sys.argv[3].split())
skip = protected | {"instella", "ai2-olmo", "olmo-core"}
reqs = []
for item in rep.get("install", []):
    md = item.get("metadata", {})
    name = (md.get("name") or "").strip()
    ver = (md.get("version") or "").strip()
    if not name or name.lower().replace("_", "-") in skip:
        continue
    reqs.append(f"{name}=={ver}")
open(sys.argv[2], "w").write("\n".join(sorted(reqs)) + ("\n" if reqs else ""))
print(f"instella: dependency closure = {len(reqs)} package(s) to install into the prefix")
PY

if [ -s "${DEP_REQS}" ]; then
   echo "instella: installing resolved deps into the prefix (--no-deps --ignore-installed; module untouched)"
   pip3 install --prefix="${INSTELLA_PATH}" --no-deps --ignore-installed --no-warn-script-location \
      --constraint "${CONSTRAINTS}" \
      -r "${DEP_REQS}" || send-error "installing the resolved dependency closure failed; see log above."
fi

# ── Install the instella package itself into the PREFIX ───────────────
echo "instella: installing the instella package into the prefix (--no-deps; from source)"
pip3 install --prefix="${INSTELLA_PATH}" --no-deps --ignore-installed --no-build-isolation \
   --no-warn-script-location "${INSTELLA_SRC}" \
   || send-error "installing the instella package failed; see log above."

# Resolve the prefix site/bin dirs for the modulefile.
INSTELLA_SITE="$(find "${INSTELLA_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
[ -z "${INSTELLA_SITE}" ] && send-error "instella install produced no site/dist-packages under ${INSTELLA_PATH}; build likely failed."
INSTELLA_BINDIR="${INSTELLA_SITE%/lib/*}/bin"
echo "instella: installed into prefix ${INSTELLA_PATH} (site: ${INSTELLA_SITE})"

# Ship the source tree (configs/, scripts/) so the training entry points are
# available from the module (INSTELLA_HOME).
INSTELLA_SHARE="${INSTELLA_PATH}/share/instella"
${SUDO} mkdir -p "${INSTELLA_SHARE}"
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${INSTELLA_PATH}/share"
fi
# Copy without the .git history to keep the module tree lean.
( cd "${INSTELLA_SRC}" && tar --exclude='.git' -cf - . ) | ( cd "${INSTELLA_SHARE}" && ${SUDO} tar -xf - )

# Normalize ownership/permissions.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${INSTELLA_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${INSTELLA_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
fi
[[ "${USER}" != "root" ]] && ${SUDO} chmod go-w "${INSTELLA_PATH}" 2>/dev/null || true

cd /

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .instella-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "instella: module ancestor ${_mprobe} is user-writable; not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "instella: module ancestor ${_mprobe} not user-writable; using sudo for modulefile"
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
-- global/micro batch and activation checkpointing so training fits the shared
-- pool; prefer a GPU allocation (never fe1) for any torchrun job.
LUA
)
else
   APU_MODULE_BLOCK=""
fi

cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${INSTELLA_MODULE_TOKEN}.lua
	whatis("Instella ${INSTELLA_VERSION} -- fully-open LLM training framework with ROCm support (bound to ${PYTORCH_MODULE_RESOLVED}, torch ${TORCH_VERSION}, ${AMDGPU_GFXMODEL})")
	whatis("Upstream: ${INSTELLA_REPO} (ref ${INSTELLA_REF})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- Instella builds on the pytorch module (torch/triton) and a Flash-Attn
	-- compiled against it: its ROCm kernels are ABI-locked to that torch.
	prereq("${ROCM_MODULE_NAME}")
	load("${PYTORCH_MODULE_RESOLVED}")

	local base = "${INSTELLA_PATH}"
	prepend_path("PYTHONPATH","${INSTELLA_SITE}")
	prepend_path("PATH","${INSTELLA_BINDIR}")
	setenv("INSTELLA_HOME", pathJoin(base, "share/instella"))
${APU_MODULE_BLOCK}

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#  Instella ${INSTELLA_VERSION}: training sources under \$INSTELLA_HOME (configs/, scripts/).")
	  LmodMessage("#  Launch training ONLY in a GPU allocation (never fe1), e.g.:")
	  LmodMessage("#    torchrun --nproc_per_node=<N> \$INSTELLA_HOME/scripts/train.py \$INSTELLA_HOME/configs/<cfg>.yaml")
	  LmodMessage("")
	end
EOF

# ── Refresh the Lmod spider cache timestamp (mirrors sglang_setup.sh) ──
LMOD_TS_FILE=""
if command -v module >/dev/null 2>&1; then
   LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
fi
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null \
      && echo "[instella] bumped Lmod cache timestamp; instella/${INSTELLA_MODULE_TOKEN} is loadable now." \
      || echo "[instella] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load instella/${INSTELLA_MODULE_TOKEN}"
else
   echo "[instella] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load instella/${INSTELLA_MODULE_TOKEN}"
fi

echo ""
echo "[instella] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} ${PYTORCH_MODULE_RESOLVED} instella/${INSTELLA_MODULE_TOKEN}"
echo ""
