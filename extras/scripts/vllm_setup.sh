#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# ─────────────────────────────────────────────────────────────────────
# vLLM setup for the MI300A (gfx942) cluster.
#
# Layers on top of the `pytorch` module (which already provides torch,
# triton, transformers, deepspeed, flashattention). vLLM pins an exact
# torch, so this script derives a compatible vLLM version from the
# loaded pytorch module's torch and freezes the whole torch stack with a
# pip constraints file so pip cannot replace the module's torch.
#
# Install layout mirrors jax_setup.sh / pytorch_setup.sh:
#   install dir : /opt/rocmplus-${ROCM_VERSION}/vllm-v${VLLM_VERSION}
#   modulefile  : ${MODULE_PATH}/${VLLM_VERSION}.lua  (module vllm/<ver>)
# The modulefile lands in the rocmplus-<rocm> overlay the rocm module
# adds to MODULEPATH, so vllm/<ver> is only visible once the matching
# rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
ROCM_VERSION=7.2.4
BUILD_VLLM=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/vllm
AMDGPU_GFXMODEL_INPUT=""
# vLLM prebuilt wheels bundle their OWN torch and are ABI-locked to it;
# they will not work against the pytorch module's from-source torch
# (e.g. torch 2.11.0a0+git). So we BUILD vLLM FROM SOURCE against the
# module's torch (vLLM's own docs mandate this for an existing PyTorch).
# Repo + ref are overridable; ref defaults to v${VLLM_VERSION}.
VLLM_REPO="https://github.com/vllm-project/vllm.git"
VLLM_REF=""
VLLM_REF_USER_SET=0
# vLLM version. Empty => auto-derive from the pytorch module's torch
# (see the "vLLM version gate" block after arg parsing). Tracked
# separately so that block can tell "user passed --vllm-version" from
# "we fell through to autodetect", and only autodetect when unset.
VLLM_VERSION=""
VLLM_VERSION_USER_SET=0
# Pytorch module to load (bare name like smartsim_setup.sh; the overlay
# resolves the concrete pytorch/<ver> built for this rocm).
PYTORCH_MODULE="pytorch"
# Default HF cache/weights location: co-located with the team's ollama
# models on /shareddata (sibling of /shareddata/Ollama_Models).
HF_HOME_DEFAULT=/shareddata/HF_Models
# ABI/ROCm-critical packages: the pytorch module builds these with
# compiled extensions tuned for torch's C++ ABI and ROCm. They MUST come
# from the pytorch module and are never replaced by the vLLM install
# (hard-pinned to the module's version + pruned from the target if pip
# drops a copy). Everything ELSE the module provides is treated as
# pure-Python: it stays available via PYTHONPATH, but if a chosen vLLM
# hard-requires a NEWER one (commonly transformers) pip may install that
# newer version into the vLLM target -- which shadows the module copy at
# runtime and does NOT touch pytorch. Extend this list with
# --protect-packages if a given pytorch module ships more compiled deps.
PROTECTED_PACKAGES="torch torchvision torchaudio triton pytorch-triton-rocm flash-attn flash-attention aotriton sageattention deepspeed xformers aiter"
# Versioned install dir: /opt/rocmplus-X/vllm-v${VLLM_VERSION}. Finalized
# in the version gate below once VLLM_VERSION is known (empty until then).
VLLM_PATH=""
VLLM_PATH_INPUT=""
ROCMPLUS_PATH_INPUT=""
# --replace 1 removes a prior install + modulefile before building.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [ -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path-no-version and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected, specify as a comma separated list"
   echo "  --build-vllm [ BUILD_VLLM ] set to 1 to build vllm, default is $BUILD_VLLM"
   echo "  --vllm-version [ VLLM_VERSION ] vLLM version; default autodetected from the pytorch module's torch"
   echo "  --vllm-repo [ VLLM_REPO ] git repo to build vLLM from, default $VLLM_REPO"
   echo "  --vllm-ref [ VLLM_REF ] git tag/branch/commit to build, default v\${VLLM_VERSION}"
   echo "  --pytorch-module [ PYTORCH_MODULE ] pytorch module to load, default $PYTORCH_MODULE"
   echo "  --protect-packages [ names ] extra space-separated ABI/ROCm packages to hard-pin from the pytorch module (appended to the default set)"
   echo "  --hf-home [ HF_HOME_DEFAULT ] default HF_HOME baked into the modulefile, default $HF_HOME_DEFAULT"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set, install goes to \${ROCMPLUS_PATH}/vllm-v\${VLLM_VERSION}"
   echo "  --install-path-no-version [ VLLM_PATH ] full leaf install dir (wins over --install-path)"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before building, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information"
}

compat_info()
{
   echo " vLLM <-> torch compatibility used by the auto-derive gate (vLLM pins an exact torch): "
   echo "   torch 2.11.x --> vLLM 0.24.0 "
   echo "   torch 2.10.x --> vLLM 0.19.1 "
   echo "   torch 2.9.x  --> vLLM 0.11.0 "
   echo "   torch 2.8.x  --> vLLM 0.10.1 "
   echo "   torch 2.7.x  --> vLLM 0.9.1 "
   echo " NOTE: override with --vllm-version if the pytorch module ships a torch not in this table. "
   echo " vLLM is BUILT FROM SOURCE (git tag v\${VLLM_VERSION}) against the pytorch module's torch, "
   echo " because prebuilt wheels bundle their own ABI-locked torch. "
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--build-vllm")
          shift
          BUILD_VLLM=${1}
          reset-last
          ;;
      "--vllm-version")
          shift
          VLLM_VERSION=${1}
          VLLM_VERSION_USER_SET=1
          reset-last
          ;;
      "--vllm-repo")
          shift
          VLLM_REPO=${1}
          reset-last
          ;;
      "--vllm-ref")
          shift
          VLLM_REF=${1}
          VLLM_REF_USER_SET=1
          reset-last
          ;;
      "--pytorch-module")
          shift
          PYTORCH_MODULE=${1}
          reset-last
          ;;
      "--protect-packages")
          shift
          PROTECTED_PACKAGES="${PROTECTED_PACKAGES} ${1}"
          reset-last
          ;;
      "--hf-home")
          shift
          HF_HOME_DEFAULT=${1}
          reset-last
          ;;
      "--install-path")
          shift
          ROCMPLUS_PATH_INPUT=${1}
          reset-last
          ;;
      "--install-path-no-version")
          shift
          VLLM_PATH_INPUT=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
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
          compat_info
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

# ── BUILD_VLLM=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_VLLM}" = "0" ]; then
   echo "[vllm BUILD_VLLM=0] operator opt-out; skipping (no vllm build, no cache restore)."
   echo "  Use --build-vllm 1 to build vLLM."
   exit ${NOOP_RC}
fi

# Bring `module` into scope for standalone invocation.
if [ -f /etc/profile.d/lmod.sh ]; then
   source /etc/profile.d/lmod.sh
fi

# Derive the rocm modulefile token to (re-)load. Three sources, in
# decreasing order of authority (same pattern as jax_setup.sh):
#   1. LMOD's LOADEDMODULES (handles therock-afar dual naming).
#   2. ROCM_PATH basename minus the `rocm-` prefix.
#   3. rocm/${ROCM_VERSION} standalone fallback.
ROCM_MODULE_NAME=""
if [[ -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      case "${_m}" in
         rocm/*) ROCM_MODULE_NAME="${_m}"; break ;;
      esac
   done
   IFS="${_OLD_IFS}"; unset _OLD_IFS _m
fi
if [[ -z "${ROCM_MODULE_NAME}" ]]; then
   if [[ -n "${ROCM_PATH:-}" ]]; then
      _rp_bn="${ROCM_PATH##*/}"
      ROCM_MODULE_NAME="rocm/${_rp_bn#rocm-}"
      unset _rp_bn
   else
      ROCM_MODULE_NAME="rocm/${ROCM_VERSION}"
   fi
fi

# Load ROCm + pytorch for this vLLM build. pytorch is REQUIRED: vLLM
# imports torch at build/resolve time and we deliberately do not ship a
# torch of our own (the pytorch module owns it).
module load ${ROCM_MODULE_NAME}
# Capture PYTHONPATH before loading pytorch so we can isolate EXACTLY
# which site dirs the pytorch module contributes. Everything installed
# in those dirs (torch, torchvision, torchaudio, triton, transformers,
# deepspeed, flashattention, ...) is the authoritative set that vLLM
# must NOT reinstall -- it has to be leveraged from `module load pytorch`.
PYTHONPATH_PRE="${PYTHONPATH:-}"
if ! module load ${PYTORCH_MODULE} 2>/dev/null; then
   send-error "could not 'module load ${PYTORCH_MODULE}'. Build the pytorch module for ${ROCM_MODULE_NAME} first (pytorch_setup.sh), or pass --pytorch-module."
fi
# PYTHONPATH entries added by the pytorch module (newline-separated).
PYTORCH_MODULE_PYPATHS=$(PYTHONPATH_PRE="${PYTHONPATH_PRE}" python3 - <<'PY'
import os
pre = set(p for p in os.environ.get("PYTHONPATH_PRE", "").split(":") if p)
for p in os.environ.get("PYTHONPATH", "").split(":"):
    if p and p not in pre:
        print(p)
PY
)

# gfx model detection. Stderr-silenced + `|| true`: rocminfo can fail
# when the SDK is built against a newer glibc than the host, and would
# kill the script under pipefail.
if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi
# Default to gfx942 (MI300A/MI300X) when detection yields nothing (e.g.
# building on the GPU-less frontend).
[ -z "${AMDGPU_GFXMODEL}" ] && AMDGPU_GFXMODEL="gfx942"

# vLLM's source build reads PYTORCH_ROCM_ARCH to pick which gfx targets
# to compile kernels for. Normalize the detected/space-separated gfx
# model into vLLM's expected semicolon-separated form and strip the
# ":sramecc+:xnack-" feature suffixes rocminfo appends. Default to
# gfx942 (MI300A) when detection is empty (e.g. GPU-less frontend).
PYTORCH_ROCM_ARCH=$(echo "${AMDGPU_GFXMODEL}" | tr ',' ';' | sed -e 's/:[^;]*//g')
[ -z "${PYTORCH_ROCM_ARCH}" ] && PYTORCH_ROCM_ARCH="gfx942"

# ── vLLM version gate ────────────────────────────────────────────────
# vLLM pins an exact torch, so unless the user forced --vllm-version we
# derive a compatible vLLM from the torch the pytorch module provides.
TORCH_VERSION=$(python3 -c 'import torch; print(torch.__version__.split("+")[0])' 2>/dev/null || true)
if [ -z "${TORCH_VERSION}" ]; then
   send-error "could not import torch from the '${PYTORCH_MODULE}' module; cannot resolve a vLLM version."
fi
TORCH_MAJOR_MINOR="${TORCH_VERSION%.*}"
if [ "${VLLM_VERSION_USER_SET}" != "1" ]; then
   case "${TORCH_MAJOR_MINOR}" in
      2.11) VLLM_VERSION="0.24.0" ;;
      2.10) VLLM_VERSION="0.19.1" ;;
      2.9)  VLLM_VERSION="0.11.0" ;;
      2.8)  VLLM_VERSION="0.10.1" ;;
      2.7)  VLLM_VERSION="0.9.1"  ;;
      *)
         send-error "no default vLLM mapping for torch ${TORCH_VERSION} (major.minor ${TORCH_MAJOR_MINOR}); pass --vllm-version. See --help for the table."
         ;;
   esac
   echo "[vllm version gate] torch ${TORCH_VERSION} -> vLLM ${VLLM_VERSION} (override with --vllm-version)"
else
   echo "[vllm version gate] user-specified vLLM ${VLLM_VERSION} against torch ${TORCH_VERSION}"
fi
# Default the git ref to the release tag matching the resolved version.
[ "${VLLM_REF_USER_SET}" != "1" ] && VLLM_REF="v${VLLM_VERSION}"

# Finalize install path now that VLLM_VERSION is known.
if [ -n "${VLLM_PATH_INPUT}" ]; then
   VLLM_PATH="${VLLM_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   VLLM_PATH="${ROCMPLUS_PATH_INPUT}/vllm-v${VLLM_VERSION}"
else
   VLLM_PATH="/opt/rocmplus-${ROCM_VERSION}/vllm-v${VLLM_VERSION}"
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[vllm --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${VLLM_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${VLLM_VERSION}.lua"
   ${SUDO} rm -rf "${VLLM_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${VLLM_VERSION}.lua"
fi
if [ -d "${VLLM_PATH}" ]; then
   echo ""
   echo "[vllm existence-check] already installed; skipping."
   echo "  install: ${VLLM_PATH}"
   echo "  pass --replace 1 to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: per-job build-dir cleanup PLUS fail-cleanup of
# a partial install + modulefile (see jax_setup.sh / hypre_setup.sh).
_vllm_on_exit() {
   local rc=$?
   [ -n "${VLLM_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${VLLM_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[vllm fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${VLLM_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${VLLM_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[vllm fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _vllm_on_exit EXIT

echo ""
echo "====================================="
echo " Installing vLLM"
echo " vLLM version:     $VLLM_VERSION"
echo " Install directory: $VLLM_PATH"
echo " Module directory:  $MODULE_PATH"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo " Pytorch module:    $PYTORCH_MODULE (torch $TORCH_VERSION)"
echo " Build source:      $VLLM_REPO @ $VLLM_REF"
echo " gfx / build arch:  $AMDGPU_GFXMODEL / $PYTORCH_ROCM_ARCH"
echo "====================================="
echo ""

# Per-job throwaway build dir (constraints file, wheel scratch); avoids
# racing a concurrent vllm build on the same node.
VLLM_BUILD_ROOT=$(mktemp -d -t vllm-build.XXXXXX)
cd "${VLLM_BUILD_ROOT}"

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
CACHE_TARBALL="${CACHE_FILES}/vllm-v${VLLM_VERSION}.tgz"

if [ -f "${CACHE_TARBALL}" ]; then
   echo ""
   echo "==================================="
   echo " Installing Cached vLLM v${VLLM_VERSION}"
   echo "==================================="
   echo ""

   # Tarball top-level dir is vllm-v${VLLM_VERSION}/ -- matches VLLM_PATH.
   ${SUDO} mkdir -p "$(dirname "${VLLM_PATH}")"
   cd "$(dirname "${VLLM_PATH}")"
   ${SUDO} tar -xzpf "${CACHE_TARBALL}"
   ${SUDO} chown -R root:root "${VLLM_PATH}"
   if [ "${USER}" != "sysadmin" ]; then
      ${SUDO} rm -f "${CACHE_TARBALL}"
   fi
else
   echo ""
   echo "======================================="
   echo " Building vLLM v${VLLM_VERSION} from source"
   echo "   repo: ${VLLM_REPO}"
   echo "   ref:  ${VLLM_REF}"
   echo "   arch: ${PYTORCH_ROCM_ARCH}"
   echo "======================================="
   echo ""

   # don't use sudo if the user has write access to the install path
   if [ -d "$(dirname "${VLLM_PATH}")" ] && [ -w "$(dirname "${VLLM_PATH}")" ]; then
      SUDO=""
   fi
   ${SUDO} mkdir -p "${VLLM_PATH}"
   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} chmod -R a+w "${VLLM_PATH}"
   fi

   # ── Leverage the pytorch module; two-tier dependency handling ──────
   # Discover EVERY distribution the pytorch module puts on PYTHONPATH
   # (torch, torchvision, transformers, deepspeed, flashattention, ...),
   # then split into two tiers:
   #
   #   PROTECTED (ABI/ROCm-compiled: torch stack, flash-attn, deepspeed,
   #   ...): hard-pinned to the module's EXACT version via a constraints
   #   file, so pip can never substitute a different build; and pruned
   #   from the target afterwards so the module is the sole provider.
   #   If a chosen vLLM hard-requires a different torch, pip fails here
   #   -- which is the correct signal to pick a matching vLLM.
   #
   #   PURE-PYTHON (everything else, e.g. transformers): NOT pinned. It
   #   stays visible via PYTHONPATH, so pip skips it when the module's
   #   version already satisfies vLLM. If vLLM needs a NEWER one, pip
   #   installs that newer version into the vLLM target; at runtime the
   #   modulefile prepends VLLM_PATH ahead of the pytorch dirs so the
   #   newer copy wins -- and pytorch is never touched.
   CONSTRAINTS="${VLLM_BUILD_ROOT}/constraints.txt"
   PROVIDED_LIST="${VLLM_BUILD_ROOT}/provided.txt"
   PROTECTED_PRESENT="${VLLM_BUILD_ROOT}/protected_present.txt"
   printf '%s\n' "${PYTORCH_MODULE_PYPATHS}" > "${VLLM_BUILD_ROOT}/pytorch_pypaths.txt"

   python3 - "${VLLM_BUILD_ROOT}/pytorch_pypaths.txt" "${CONSTRAINTS}" "${PROVIDED_LIST}" "${PROTECTED_PRESENT}" "${PROTECTED_PACKAGES}" <<'PY'
import sys
from importlib.metadata import distributions
paths = [l.strip() for l in open(sys.argv[1]) if l.strip()]
protected = {p.lower().replace("_", "-") for p in sys.argv[5].split()}
seen = {}
for dist in distributions(path=paths):
    name = (dist.metadata["Name"] or "").strip()
    if not name:
        continue
    key = name.lower().replace("_", "-")
    seen.setdefault(key, (name, dist.version))
with open(sys.argv[2], "w") as c, open(sys.argv[3], "w") as p, open(sys.argv[4], "w") as pr:
    for key, (name, ver) in sorted(seen.items()):
        p.write(name + "\n")
        if key in protected:
            c.write(f"{name}=={ver}\n")   # hard-pin ABI/ROCm packages only
            pr.write(name + "\n")
PY
   echo "vllm: pytorch module provides $(wc -l < "${PROVIDED_LIST}" | tr -d ' ') packages (kept on PYTHONPATH; pure-Python deps may be upgraded into the target as needed)."
   echo "vllm: hard-pinned ABI/ROCm packages (never reinstalled, sourced only from the pytorch module):"
   sed -e 's/^/  /' "${CONSTRAINTS}"

   # ── Fetch vLLM source ──────────────────────────────────────────────
   # We BUILD from source (not a prebuilt wheel) because prebuilt wheels
   # bundle their own torch and are ABI-locked to it; they will not load
   # against the pytorch module's from-source torch (2.11.0a0+git...).
   # vLLM's own docs mandate a source build to reuse an existing PyTorch.
   VLLM_SRC="${VLLM_BUILD_ROOT}/vllm-src"
   echo "vllm: cloning ${VLLM_REPO} @ ${VLLM_REF}"
   git clone --depth 1 --branch "${VLLM_REF}" --recurse-submodules --shallow-submodules \
      "${VLLM_REPO}" "${VLLM_SRC}"

   # ── Build toolchain for --no-build-isolation ───────────────────────
   # With --no-build-isolation pip uses THIS environment's build backend
   # instead of provisioning a clean one, which is exactly what lets the
   # module's torch (not a fresh torch==2.11.0 pulled from PyPI, which
   # would violate the pin against our 2.11.0a0 build) drive the compile.
   # So the build tools must be importable/on PATH here. Install them into
   # a throwaway prefix rather than polluting the user or the target.
   BUILD_TOOLS="${VLLM_BUILD_ROOT}/buildtools"
   pip3 install --target="${BUILD_TOOLS}" \
      "cmake>=3.26,<4" ninja "setuptools>=77,<81" setuptools-scm setuptools-rust wheel packaging
   export PATH="${BUILD_TOOLS}/bin:${PATH}"
   export PYTHONPATH="${BUILD_TOOLS}:${PYTHONPATH}"

   # ── Compile + install vLLM into the target ─────────────────────────
   # PYTHONPATH keeps the pytorch module dirs visible so pip treats
   # torch/triton/transformers/... as already installed. VLLM_TARGET_DEVICE
   # forces the ROCm backend; PYTORCH_ROCM_ARCH selects the gfx kernels.
   # torch is NOT a runtime dependency in v0.24.0's requirements (only a
   # build-system requirement, which --no-build-isolation ignores), so
   # this never tries to replace the module's torch.
   export VLLM_TARGET_DEVICE=rocm
   export MAX_JOBS="${MAX_JOBS:-$(nproc)}"
   echo "vllm: compiling with PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH} MAX_JOBS=${MAX_JOBS} (this is slow)"
   PYTORCH_ROCM_ARCH="${PYTORCH_ROCM_ARCH}" \
   pip3 install -v \
      --no-build-isolation \
      --target="${VLLM_PATH}" \
      --constraint "${CONSTRAINTS}" \
      "${VLLM_SRC}"

   # Install the ROCm-specific runtime extras (grpcio, numba, datasets,
   # peft, tensorizer, timm, amd-quark, tilelang, fastsafetensors, ...).
   # These live in requirements/rocm.txt (which also -r's common.txt) and
   # are NOT captured in the wheel's runtime metadata. rocm.txt carries no
   # torch pin, so the constraints file keeps the ABI stack from moving.
   if [ -f "${VLLM_SRC}/requirements/rocm.txt" ]; then
      echo "vllm: installing ROCm runtime extras from requirements/rocm.txt"
      pip3 install \
         --target="${VLLM_PATH}" \
         --constraint "${CONSTRAINTS}" \
         -r "${VLLM_SRC}/requirements/rocm.txt" || \
         echo "vllm: WARNING some rocm.txt extras failed to install; review above (some are optional)."
   fi

   # Defensive uninstall of ONLY the PROTECTED packages from the target
   # (same pinned version), so the ABI/ROCm stack comes solely from the
   # pytorch module. Pure-Python upgrades pip made (e.g. a newer
   # transformers) are intentionally kept. Reads each dist's RECORD so it
   # removes exactly the files pip wrote.
   python3 - "${VLLM_PATH}" "${PROTECTED_PRESENT}" <<'PY'
import os, sys, shutil
from importlib.metadata import distributions
target = sys.argv[1]
protected = {l.strip().lower().replace("_", "-") for l in open(sys.argv[2]) if l.strip()}
removed = []
for dist in distributions(path=[target]):
    name = (dist.metadata["Name"] or "").strip()
    if not name or name.lower().replace("_", "-") not in protected:
        continue
    for f in (dist.files or []):
        fp = os.path.join(target, str(f))
        try:
            if os.path.isfile(fp) or os.path.islink(fp):
                os.remove(fp)
        except OSError:
            pass
    info = getattr(dist, "_path", None)
    if info and os.path.isdir(str(info)):
        shutil.rmtree(str(info), ignore_errors=True)
    removed.append(name)
for root, _dirs, _files in os.walk(target, topdown=False):
    if root != target and not os.listdir(root):
        try:
            os.rmdir(root)
        except OSError:
            pass
if removed:
    print("vllm: pruned ABI/ROCm packages from target (using the pytorch module's instead): " + ", ".join(sorted(removed)))
else:
    print("vllm: no ABI/ROCm packages landed in the target (pip used the pytorch module's).")
PY

   # Normalize ownership/permissions like the sibling scripts.
   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find "${VLLM_PATH}" -type f -execdir chown root:root "{}" +
      ${SUDO} find "${VLLM_PATH}" -type d -execdir chown root:root "{}" +
   fi
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod go-w "${VLLM_PATH}"
   fi
fi

# Capture ROCM_PATH before any unload so the modulefile heredoc resolves
# it correctly (see jax_setup.sh for the empty-expansion footgun).
ROCM_PATH_FOR_MODULE="${ROCM_PATH}"
cd /

# ── Modulefile ───────────────────────────────────────────────────────
# Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit).
PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

# Provenance: capture this leaf script's git state for the modulefile
# whatis() line. Uses LEAF_SCRIPT_PATH captured at the top before any cd.
# Falls back to "unknown" when run from a stripped-of-.git context.
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

# The - option suppresses leading tabs in the heredoc body.
cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${VLLM_VERSION}.lua
	whatis("vLLM ${VLLM_VERSION} with ROCm support (torch ${TORCH_VERSION}, ${AMDGPU_GFXMODEL})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- vLLM builds on the pytorch module (torch/triton/transformers/deepspeed).
	prereq("${ROCM_MODULE_NAME}")
	load("${PYTORCH_MODULE}")

	prepend_path("PYTHONPATH","${VLLM_PATH}")
	prepend_path("PATH","${VLLM_PATH}/bin")

	-- MI300A APU: scratch-reclaim workaround (matches the rocm modulefile).
	setenv("HSA_NO_SCRATCH_RECLAIM","1")

	-- Co-locate HF weights/cache with the team's ollama models on /shareddata.
	setenv("HF_HOME","${HF_HOME_DEFAULT}")

	-- WARNING (MI300A APU): host RAM and GPU HBM are ONE physical pool.
	-- Do NOT use vLLM --swap-space / --cpu-offload-gb (nor DeepSpeed/FSDP
	-- CPU offload): "offloading" moves data within the same pool and can
	-- OOM/HANG. Prefer --kv-cache-dtype fp8 and a lower --max-model-len.
EOF

echo ""
echo "[vllm] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} ${PYTORCH_MODULE} vllm/${VLLM_VERSION}"
echo ""
