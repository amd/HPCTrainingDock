#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir. (BASH_SOURCE[0] is
# whatever path was used to invoke the script -- often relative when
# called from main_setup.sh -- so we absolutize it once, here.)
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# ─────────────────────────────────────────────────────────────────────
# vLLM setup for AMD CDNA GPUs (gfx90a/gfx942/gfx950 -- MI2xx/MI300/MI3xx).
# The gfx target is autodetected from rocminfo (override --amdgpu-gfxmodel),
# so this is not tied to any one CDNA part; the MI300A APU-only tweaks in
# the generated modulefile are gated on runtime APU detection (see IS_APU).
#
# Layers on top of the `pytorch` module (which already provides torch,
# triton, transformers, deepspeed, flashattention). vLLM pins an exact
# torch, so this script derives a compatible vLLM version from the
# loaded pytorch module's torch and freezes the whole torch stack with a
# pip constraints file so pip cannot replace the module's torch.
#
# Install layout mirrors ftorch_setup.sh (keyed on the BOUND pytorch too):
#   install dir : /opt/rocmplus-${ROCM_VERSION}/vllm-v${VLLM_VERSION}-pt${PYTORCH_VERSION}
#   modulefile  : ${MODULE_PATH}/${VLLM_VERSION}-pt${PYTORCH_VERSION}.lua
#                 (module vllm/<vllm-ver>-pt<pytorch-ver>)
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
# Apply the TORCH_HIP_VERSION stable-ABI compile workaround (see the big
# comment where it is applied, below). Default on; disable to re-test on a
# newer rocm/pytorch/vLLM combo that may no longer need it.
HIP_VERSION_PATCH=1
# Apply the atomicAdd half/half2 guard workaround (vllm PR #41802 backport;
# see the comment where it is applied, below). Default on; it self-gates on
# the HIP version in-source, so it is a no-op on ROCm <= 7.12 and on vLLM
# refs that already carry the guard. Disable to re-test on a newer vLLM ref.
ATOMICADD_GUARD_PATCH=1
# vLLM version. Empty => auto-derive from the pytorch module's torch
# (see the "vLLM version gate" block after arg parsing). Tracked
# separately so that block can tell "user passed --vllm-version" from
# "we fell through to autodetect", and only autodetect when unset.
VLLM_VERSION=""
VLLM_VERSION_USER_SET=0
# Pytorch module to load (bare name like smartsim_setup.sh; the overlay
# resolves the concrete pytorch/<ver> built for this rocm).
PYTORCH_MODULE="pytorch"
# Bound pytorch version. vLLM's compiled kernels are ABI-locked to the
# torch they build against, so -- exactly like ftorch_setup.sh -- the
# install dir + modulefile are keyed on BOTH the vLLM version AND this
# bound pytorch version (vllm-v${VLLM_VERSION}-pt${PYTORCH_VERSION}), and
# the generated modulefile loads this EXACT pytorch (never the bare
# `pytorch` alias, which Lmod would later resolve to whatever default is
# current -> ABI mismatch at runtime). Empty => resolved after the pytorch
# module loads, from the LOADEDMODULES token (or a pytorch/<VER> passed via
# --pytorch-module).
PYTORCH_VERSION=""
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
   echo "  --hip-version-patch [ 0|1 ] apply the TORCH_HIP_VERSION stable-ABI ROCm compile workaround, default $HIP_VERSION_PATCH (re-evaluate per rocm/torch/vLLM version)"
   echo "  --atomicadd-guard-patch [ 0|1 ] apply the atomicAdd half/half2 ROCm>=7.13 guard (vllm PR #41802 backport), default $ATOMICADD_GUARD_PATCH (self-gates in-source; no-op on ROCm<=7.12 or vLLM refs that already carry it)"
   echo "  --pytorch-module [ PYTORCH_MODULE ] pytorch module to load, default $PYTORCH_MODULE"
   echo "  --pytorch-version [ PYTORCH_VERSION ] bound pytorch version; keys the install dir + modulefile (vllm-v\${VLLM_VERSION}-pt\${PYTORCH_VERSION}) so multiple (vllm,pytorch) pairs coexist. Empty (default) -> resolved from the loaded pytorch module token."
   echo "  --protect-packages [ names ] extra space-separated ABI/ROCm packages to hard-pin from the pytorch module (appended to the default set)"
   echo "  --hf-home [ HF_HOME_DEFAULT ] default HF_HOME baked into the modulefile, default $HF_HOME_DEFAULT"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; if set, install goes to \${ROCMPLUS_PATH}/vllm-v\${VLLM_VERSION}-pt\${PYTORCH_VERSION}"
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
      "--hip-version-patch")
          shift
          HIP_VERSION_PATCH=${1}
          reset-last
          ;;
      "--atomicadd-guard-patch")
          shift
          ATOMICADD_GUARD_PATCH=${1}
          reset-last
          ;;
      "--pytorch-module")
          shift
          PYTORCH_MODULE=${1}
          reset-last
          ;;
      "--pytorch-version")
          shift
          PYTORCH_VERSION=${1}
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
# MISSING_PREREQ_RC=42: a required module (pytorch) was not loadable; the
# orchestrator (main_setup.sh run_and_log) buckets this as SKIPPED(missing-
# prereq) rather than FAILED -- mirrors ftorch_setup.sh.
MISSING_PREREQ_RC=42
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

# Load ROCm + pytorch for this vLLM build, HIERARCHICALLY and in order.
# Modules here are hierarchical: `pytorch` is only exposed on MODULEPATH
# once its matching `rocm` is loaded, so rocm MUST load first. We `module
# purge` first so a pytorch/rocm already loaded in the caller's env cannot
# (a) shadow the versions we intend or (b) pollute the PYTHONPATH_PRE diff
# below (which must capture EXACTLY what THIS pytorch load contributes).
# pytorch is REQUIRED: vLLM imports torch at build/resolve time and we
# deliberately do not ship a torch of our own (the pytorch module owns it).
module purge 2>/dev/null || true
if ! module load ${ROCM_MODULE_NAME}; then
   send-error "could not 'module load ${ROCM_MODULE_NAME}'. Check --rocm-version and that the module exists."
fi
# Capture PYTHONPATH AFTER rocm but BEFORE pytorch so we isolate EXACTLY
# which site dirs the pytorch module contributes. Everything installed
# in those dirs (torch, torchvision, torchaudio, triton, transformers,
# deepspeed, flashattention, ...) is the authoritative set that vLLM
# must NOT reinstall -- it has to be leveraged from `module load pytorch`.
PYTHONPATH_PRE="${PYTHONPATH:-}"
if ! module load ${PYTORCH_MODULE} 2>/dev/null; then
   echo ""
   echo "[vllm missing-prereq] could not 'module load ${PYTORCH_MODULE}' after"
   echo "  '${ROCM_MODULE_NAME}'. Build the pytorch module for ${ROCM_MODULE_NAME}"
   echo "  first (pytorch_setup.sh) or pass --pytorch-module. Skipping vLLM."
   exit ${MISSING_PREREQ_RC}
fi
# ── Resolve the EXACT pytorch module token that got loaded ────────────
# vLLM is ABI-locked to the torch it compiles against, so both the install
# dir/modulefile keying AND the generated modulefile's pytorch load must
# name the CONCRETE pytorch version -- not the bare `pytorch` alias, which
# Lmod would later resolve to whatever default is current (-> ABI mismatch
# when a newer pytorch becomes the default). Priority: explicit
# --pytorch-version > the loaded LOADEDMODULES token > a pytorch/<VER>
# passed via --pytorch-module. Mirrors ftorch_setup.sh's PYTORCH_VERSION
# resolution.
PYTORCH_MODULE_RESOLVED=""
if [[ -n "${LOADEDMODULES:-}" ]]; then
   _OLD_IFS="${IFS}"; IFS=":"
   for _m in ${LOADEDMODULES}; do
      case "${_m}" in
         pytorch/*) PYTORCH_MODULE_RESOLVED="${_m}" ;;   # last match wins
      esac
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
if [[ -z "${PYTORCH_VERSION}" ]]; then
   send-error "could not resolve the bound pytorch version from module '${PYTORCH_MODULE}' (resolved token '${PYTORCH_MODULE_RESOLVED}'). Pass --pytorch-version <VER> or --pytorch-module pytorch/<VER>."
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
# No silent CDNA-part guess: if rocminfo detected nothing and the operator
# did not pass --amdgpu-gfxmodel, there is no reliable arch to compile
# kernels for. Abort with the same guidance main_setup.sh gives rather than
# defaulting to a specific part (which would bias the build to one CDNA
# arch). main_setup.sh always forwards --amdgpu-gfxmodel, so this only ever
# trips on a manual standalone run on a GPU-less node.
if [ -z "${AMDGPU_GFXMODEL}" ]; then
   send-error "no GPU architecture specified and rocminfo found no GPUs. Pass --amdgpu-gfxmodel (e.g. --amdgpu-gfxmodel gfx942 or --amdgpu-gfxmodel 'gfx942;gfx90a')."
fi

# vLLM's source build reads PYTORCH_ROCM_ARCH to pick which gfx targets
# to compile kernels for. Normalize the detected/space-separated gfx
# model into vLLM's expected semicolon-separated form and strip the
# ":sramecc+:xnack-" feature suffixes rocminfo appends.
PYTORCH_ROCM_ARCH=$(echo "${AMDGPU_GFXMODEL}" | tr ',' ';' | sed -e 's/:[^;]*//g')

# ── APU vs discrete-GPU gating ───────────────────────────────────────
# The scratch-reclaim workaround and the single-physical-pool memory
# warning baked into the modulefile below apply ONLY to the MI300A APU
# (unified host+GPU memory). On CDNA discrete GPUs (MI300X, MI2xx, MI1xx)
# they are inapplicable, so we emit them only when an APU is detected.
# Detection mirrors kokkos_check_apu_enabled.sh (rocminfo marketing name);
# stderr-silenced + guarded so a failing rocminfo just yields IS_APU=0.
IS_APU=0
if rocminfo 2>/dev/null | grep -q "MI300A"; then
   IS_APU=1
fi

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

# Finalize install path now that VLLM_VERSION + PYTORCH_VERSION are known.
# Install dir + modulefile are keyed on BOTH the vLLM version AND the bound
# pytorch version so multiple (vllm,pytorch) pairs coexist and never collide
# when two torch patch releases in one minor derive the same vLLM version
# (mirrors ftorch's -v${PYTORCH_VERSION} keying).
VLLM_DIRNAME="vllm-v${VLLM_VERSION}-pt${PYTORCH_VERSION}"
VLLM_MODULE_TOKEN="${VLLM_VERSION}-pt${PYTORCH_VERSION}"
if [ -n "${VLLM_PATH_INPUT}" ]; then
   VLLM_PATH="${VLLM_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   VLLM_PATH="${ROCMPLUS_PATH_INPUT}/${VLLM_DIRNAME}"
else
   VLLM_PATH="/opt/rocmplus-${ROCM_VERSION}/${VLLM_DIRNAME}"
fi

# ── Install-path sudo (computed EARLY, before --replace) ──────────────
# The --replace block below rm -rf's the install dir + modulefile with
# ${SUDO}, and the source-build branch mkdir's ${VLLM_PATH} with it. The
# leaf default is SUDO=sudo; on a cluster with no passwordless sudo and a
# user-owned tree it must stay sudo, while on a user-owned tree it must
# drop to "" to avoid a password prompt. Decide it ONCE here via an actual
# write-probe of the nearest existing ancestor rather than the fragile
# `[ -w ]` test (which can misreport a root-owned NFS parent as writable,
# clearing sudo and making the later mkdir fail with a bare Permission
# denied -- see rocm-7.14.0 job 16810). Mirrors the hypre/magma/kokkos/
# petsc/rocshmem probe. EUID 0 never needs sudo; a Singularity-cleared
# SUDO is left empty.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :  # already cleared (e.g. Singularity)
else
   _iprobe="$(dirname "${VLLM_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .vllm-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"
      SUDO=""
      echo "vllm: install ancestor ${_iprobe} is user-writable (probe succeeded); not using sudo for install"
   else
      SUDO="sudo"
      echo "vllm: install ancestor ${_iprobe} not user-writable (probe failed); using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[vllm --replace 1] removing prior install + modulefile if present"
   echo "  install dir: ${VLLM_PATH}"
   echo "  modulefile:  ${MODULE_PATH}/${VLLM_MODULE_TOKEN}.lua"
   ${SUDO} rm -rf "${VLLM_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${VLLM_MODULE_TOKEN}.lua"
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
   # ── attempted-but-failed marker (inventory 'F' glyph) ─────────────
   # On failure, drop a persistent vllm.FAILED sibling of the install dir
   # so inventory_packages.py can tell "build attempted but failed" (F)
   # apart from "never attempted" (-). It lives in the rocmplus root (a
   # sibling of VLLM_PATH), so it survives the rm -rf of VLLM_PATH below.
   # On a clean exit we clear any stale marker from a prior failed run.
   # Mirrors hypre_setup.sh. VLLM_PATH may be unset if we exit before it
   # is computed (e.g. arg parsing) -- guard on it so the trap is safe.
   if [ -n "${VLLM_PATH:-}" ]; then
      local _fail_marker="$(dirname "${VLLM_PATH}")/vllm.FAILED"
      if [ ${rc} -ne 0 ]; then
         ${SUDO:-sudo} mkdir -p "$(dirname "${VLLM_PATH}")" 2>/dev/null || true
         ${SUDO:-sudo} tee "${_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: vllm
ROCm SDK:        ${ROCM_PATH:-unknown}
ROCm token:      ${ROCM_VERSION:-unknown}
vLLM version:    ${VLLM_VERSION:-unknown} (ref ${VLLM_REF:-unknown}, bound pytorch ${PYTORCH_VERSION:-unknown})
Date:            $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script:    vllm_setup.sh (EXIT-trap fail marker)
Reason:          build exited rc=${rc}; partial install wiped (see log_vllm_*.txt).
MARKER_EOF
      else
         ${SUDO:-sudo} rm -f "${_fail_marker}"
      fi
   fi
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[vllm fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${VLLM_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${VLLM_MODULE_TOKEN}.lua"
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
echo " Module name:       vllm/$VLLM_MODULE_TOKEN"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo " Pytorch module:    $PYTORCH_MODULE_RESOLVED (bound; torch $TORCH_VERSION)"
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
CACHE_TARBALL="${CACHE_FILES}/${VLLM_DIRNAME}.tgz"

if [ -f "${CACHE_TARBALL}" ]; then
   echo ""
   echo "==================================="
   echo " Installing Cached vLLM v${VLLM_VERSION}"
   echo "==================================="
   echo ""

   # Tarball top-level dir is ${VLLM_DIRNAME}/ -- matches VLLM_PATH.
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

   # ${SUDO} was decided once, up front, by the install-path write-probe
   # (see "Install-path sudo" block above). Create the install dir and
   # ABORT loudly if it fails -- a silent mkdir failure here previously let
   # the build limp on for ~15k log lines before dying on an unrelated
   # compile error, burying the real "Permission denied" (job 16810). The
   # non-zero exit fires the EXIT trap (fail-cleanup) and surfaces as a
   # real FAILED in the main_setup summary instead of a misleading pass.
   if ! ${SUDO} mkdir -p "${VLLM_PATH}"; then
      echo "ERROR: could not create vLLM install dir ${VLLM_PATH} (SUDO='${SUDO}')."
      echo "       The install-path ancestor is not writable and sudo did not succeed;"
      echo "       re-run as root, with passwordless sudo, or point --install-path at a writable tree."
      exit 1
   fi
   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} chmod -R a+w "${VLLM_PATH}"
   fi

   # ── Leverage the pytorch module; build a constraints file ──────────
   # Discover EVERY distribution the pytorch module puts on PYTHONPATH
   # (torch, torchvision, transformers, deepspeed, flashattention, ...) and
   # hard-pin the PROTECTED (ABI/ROCm-compiled) ones -- torch stack, flash-
   # attn, deepspeed, ... -- to the module's EXACT version in a constraints
   # file. That file is fed to the dependency RESOLVE (dry-run) below so the
   # resolver can never plan a different torch/triton build: if a chosen
   # vLLM hard-requires a different torch, the resolve fails (the correct
   # signal to pick a matching vLLM) rather than shadowing the module.
   #
   # Everything else (pure-Python, e.g. transformers) is left unpinned: if
   # the module already satisfies vLLM it is omitted from the resolved delta
   # (so never reinstalled); if vLLM needs a NEWER one, that newer version
   # is installed into the vLLM prefix (via --ignore-installed, so the
   # module copy is never uninstalled) and wins at runtime because the
   # modulefile prepends the prefix ahead of the pytorch dirs.
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

   # ── WORKAROUND: TORCH_HIP_VERSION undefined in vLLM's stable-ABI ROCm build
   #
   # SYMPTOM (vLLM v0.24.0 + torch 2.11 + ROCm 7.2.4):
   #   csrc/libtorch_stable/activation_kernels.hip:294:
   #     error: use of undeclared identifier 'TORCH_HIP_VERSION'
   #
   # ROOT CAUSE: The activation-gate macros gate a CUDA-12.9/Blackwell fast
   #   path on `CUDA_VERSION >= 12090`. hipify rewrites `CUDA_VERSION` ->
   #   `TORCH_HIP_VERSION` for the HIP build. In the REGULAR extension (`_C`)
   #   that symbol is provided by torch's full HIP headers, so `_C` compiles.
   #   The STABLE-ABI extensions (`_C_stable_libtorch`, `_moe_C_stable_libtorch`)
   #   are built with Py_LIMITED_API and include ONLY torch/csrc/stable/*
   #   headers, which never define TORCH_HIP_VERSION -> hard compile error.
   #   Upstream gap in vLLM's new stable-ABI-on-ROCm path (issue vllm#44641,
   #   fix PR vllm#44648 merged 2026-06-05, AFTER the v0.24.0 tag; even main's
   #   source still has the bare CUDA_VERSION gate here).
   #
   # WHY DEFINING IT TO 0 IS SAFE: on all CDNA (gfx9xx) `get_device_prop()->
   #   major` is 9, so the companion `cc_major >= 10` in the same `&&` already
   #   makes the Blackwell branch dead code. The symbol just has to EXIST for the HIP
   #   compile to parse; `TORCH_HIP_VERSION=0` makes every `>= NNNNN` false,
   #   selecting the correct non-Blackwell path. Scoped to the two stable-ABI
   #   targets only (the regular `_C` already has the real symbol).
   #
   # RE-EVALUATE when inputs change, e.g. the planned rocm/7.0.0 build once
   #   its pytorch module lands, or a vLLM ref carrying vllm#44648. Re-test
   #   with --hip-version-patch 0; if it compiles clean, drop the workaround.
   if [ "${HIP_VERSION_PATCH}" = "1" ]; then
      _vllm_cml="${VLLM_SRC}/CMakeLists.txt"
      if [ -f "${_vllm_cml}" ] && ! grep -q "vllm_setup.sh TORCH_HIP_VERSION workaround" "${_vllm_cml}"; then
         cat >> "${_vllm_cml}" <<'CMAKE_PATCH'

# ===== vllm_setup.sh TORCH_HIP_VERSION workaround (appended by installer) =====
# See vllm_setup.sh for the full rationale. hipify rewrites CUDA_VERSION ->
# TORCH_HIP_VERSION in the stable-ABI HIP kernels, but that symbol is not
# defined in the Py_LIMITED_API include set. Define it (to 0 -> Blackwell
# fast path stays disabled, correct on all CDNA gfx9xx) so the stable-ABI targets
# compile. Appended at end-of-file, guarded by if(TARGET ...), so it is
# order-independent and a no-op when the targets do not exist.
if(VLLM_GPU_LANG STREQUAL "HIP")
  foreach(_vllm_stable_tgt _C_stable_libtorch _moe_C_stable_libtorch)
    if(TARGET ${_vllm_stable_tgt})
      target_compile_definitions(${_vllm_stable_tgt} PRIVATE TORCH_HIP_VERSION=0)
    endif()
  endforeach()
endif()
CMAKE_PATCH
         echo "vllm: applied TORCH_HIP_VERSION=0 stable-ABI ROCm CMake workaround (disable with --hip-version-patch 0)"
      fi
      unset _vllm_cml
   else
      echo "vllm: TORCH_HIP_VERSION workaround DISABLED (--hip-version-patch 0)"
   fi

   # ── WORKAROUND: duplicate atomicAdd(half*/half2*) on ROCm >= 7.13 ────
   #
   # SYMPTOM (vLLM v0.11.0 + torch 2.9 + ROCm 7.13/7.14):
   #   csrc/quantization/gptq/q_gemm.hip:322: error: call to 'atomicAdd'
   #   is ambiguous  (candidates: hip/amd_detail/amd_hip_fp16.h:875
   #   'atomicAdd(__half2*, __half2)' vs gptq/compat.cuh's shim).
   #
   # ROOT CAUSE: ROCm 7.13's HIP headers (rocm-systems#5194) added NATIVE
   #   atomicAdd(__half*) and atomicAdd(__half2*). vLLM's compat.cuh still
   #   unconditionally defines its own half/half2 atomicAdd shims to backfill
   #   older ROCm; since half2==__half2 the two are indistinguishable ->
   #   ambiguous overload. Absent in ROCm <= 7.12 (header lacked the native
   #   overload). This is NOT a compiler bug; clang correctly diagnoses it.
   #
   # FIX: upstream vLLM PR #41802 guards the shim block with a HIP-version
   #   check so it is skipped on ROCm >= 7.13. That fix is NOT in the
   #   torch-2.9-compatible release line we build (v0.11.0/0.11.1/0.11.2 and
   #   even v0.12.0 still ship the unguarded shim), so we backport the exact
   #   one-line guard here. It self-gates on HIP_VERSION_MAJOR/MINOR, so it
   #   is correct for 7.13, 7.14 and beyond and a no-op on ROCm <= 7.12.
   #
   # RE-EVALUATE when bumping the vLLM ref: if compat.cuh already carries the
   #   guard (or the gptq kernels are relocated), this block auto-no-ops and
   #   prints a notice. Re-test with --atomicadd-guard-patch 0.
   if [ "${ATOMICADD_GUARD_PATCH}" = "1" ]; then
      _vllm_compat="${VLLM_SRC}/csrc/quantization/gptq/compat.cuh"
      if [ ! -f "${_vllm_compat}" ]; then
         echo "vllm: compat.cuh not found at expected path (gptq kernels relocated upstream?); atomicAdd guard SKIPPED. If the build fails with 'atomicAdd is ambiguous', revisit this workaround."
      elif grep -q 'HIP_VERSION_MAJOR \* 100 + HIP_VERSION_MINOR' "${_vllm_compat}"; then
         echo "vllm: compat.cuh already carries the atomicAdd HIP-version guard; no patch needed."
      elif grep -qF '#if defined(__CUDA_ARCH__) || defined(USE_ROCM)' "${_vllm_compat}"; then
         python3 - "${_vllm_compat}" <<'PY'
import sys
path = sys.argv[1]
old = "#if defined(__CUDA_ARCH__) || defined(USE_ROCM)\n"
new = ("#if defined(__CUDA_ARCH__) || \\\n"
       "    (defined(USE_ROCM) && (HIP_VERSION_MAJOR * 100 + HIP_VERSION_MINOR) < 713)\n")
src = open(path).read()
if src.count(old) != 1:
    sys.exit("vllm: atomicAdd guard anchor not unique in compat.cuh; refusing to patch")
open(path, "w").write(src.replace(old, new, 1))
PY
         echo "vllm: applied atomicAdd half/half2 ROCm>=7.13 guard to compat.cuh (vllm PR #41802 backport; disable with --atomicadd-guard-patch 0)"
      else
         echo "vllm: compat.cuh atomicAdd anchor not found (upstream changed the guard?); atomicAdd guard SKIPPED. If the build fails with 'atomicAdd is ambiguous', revisit this workaround."
      fi
      unset _vllm_compat
   else
      echo "vllm: atomicAdd guard workaround DISABLED (--atomicadd-guard-patch 0)"
   fi

   # ── Harden pip against a polluted global/user pip config ───────────
   # A stray `extra-index-url` in ~/.config/pip/pip.conf (notably
   # https://test.pypi.org/simple, which hip-python_setup.sh used to persist
   # via `pip config set global.extra-index-url`, and $HOME being shared NFS
   # leaks it to every node) makes EVERY pip run below ALSO consult Test PyPI.
   # There a name-squatting `FASTAPI 1.0` placeholder outranks real fastapi
   # (1.0 > 0.115.x) and aborts the dependency resolve with
   # metadata-generation-failed (rocm-7.14.0 job 16823). A `--index-url` flag
   # does NOT clear a config `extra-index-url`, so neutralize the config file
   # itself (PIP_CONFIG_FILE=/dev/null) and pin the canonical index; this makes
   # the toolchain/wheel/resolve/install steps deterministic regardless of the
   # ambient pip config. This cluster reaches pypi.org directly (no internal
   # mirror/proxy in the pip config), so ignoring config files is safe here.
   export PIP_CONFIG_FILE=/dev/null
   export PIP_INDEX_URL="https://pypi.org/simple"

   # ── Build toolchain for --no-build-isolation ───────────────────────
   # With --no-build-isolation pip uses THIS environment's build backend
   # instead of provisioning a clean one, which is exactly what lets the
   # module's torch (not a fresh torch==2.11.0 pulled from PyPI, which
   # would violate the pin against our 2.11.0a0 build) drive the compile.
   # So the build tools must be importable/on PATH here. Install them into
   # a throwaway prefix rather than polluting the user or the target.
   BUILD_TOOLS="${VLLM_BUILD_ROOT}/buildtools"
   pip3 install --target="${BUILD_TOOLS}" \
      "cmake>=3.26,<4" ninja "setuptools>=77,<81" setuptools-scm setuptools-rust wheel packaging jinja2
   export PATH="${BUILD_TOOLS}/bin:${PATH}"
   export PYTHONPATH="${BUILD_TOOLS}:${PYTHONPATH}"

   # ── Compile the vLLM wheel (ONCE) ──────────────────────────────────
   # Build a wheel with --no-deps so the expensive CDNA kernel compile
   # triggers NO dependency resolution (no torch/nvidia pull, no uninstalls).
   # --no-build-isolation reuses THIS env's build backend so the module's
   # torch (not a fresh torch==2.11.0 from PyPI) drives the compile.
   # VLLM_TARGET_DEVICE forces the ROCm backend; PYTORCH_ROCM_ARCH selects
   # the gfx kernels.
   export VLLM_TARGET_DEVICE=rocm
   export MAX_JOBS="${MAX_JOBS:-$(nproc)}"
   WHEELHOUSE="${VLLM_BUILD_ROOT}/wheelhouse"
   mkdir -p "${WHEELHOUSE}"
   echo "vllm: compiling wheel with PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH} MAX_JOBS=${MAX_JOBS} (this is slow)"
   PYTORCH_ROCM_ARCH="${PYTORCH_ROCM_ARCH}" \
   pip3 wheel -v \
      --no-build-isolation \
      --no-deps \
      --wheel-dir "${WHEELHOUSE}" \
      "${VLLM_SRC}"
   VLLM_WHEEL="$(find "${WHEELHOUSE}" -maxdepth 1 -name 'vllm-*.whl' 2>/dev/null | head -1)"
   [ -z "${VLLM_WHEEL}" ] && send-error "vLLM wheel build produced no wheel in ${WHEELHOUSE}; see log above."
   echo "vllm: built $(basename "${VLLM_WHEEL}")"

   # ── Install vLLM + deps into the prefix WITHOUT mutating the module ──
   # CRITICAL SAFETY: a plain `pip install` (even with --prefix/--target),
   # when it needs a NEWER version of a dep the pytorch module already
   # provides, UNINSTALLS the module's copy IN PLACE -- the module dirs are
   # on PYTHONPATH and some (e.g. deepspeed/) are group/world-writable, so
   # pip silently corrupts the shared module for every user. (Also --target
   # ignores installed packages entirely and re-pulls the whole torch +
   # nvidia-cuda-* stack.) To make mutation IMPOSSIBLE we split install in
   # two phases that can only ever write inside ${VLLM_PATH}:
   #
   #   1. RESOLVE (dry-run, --report): let pip compute the plan for the
   #      wheel + rocm.txt against the LIVE module env. The report's
   #      "install" list is exactly the delta pip would add -- new deps and
   #      version upgrades; packages the module already satisfies (torch,
   #      transformers, ...) are omitted. The constraints file pins the
   #      ABI/ROCm stack, so if a vLLM hard-requires a different torch the
   #      resolve fails here (the correct signal to pick a matching vLLM),
   #      instead of silently shadowing the module's torch.
   #   2. INSTALL that pinned delta with --no-deps --ignore-installed.
   #      --ignore-installed => pip never inspects or uninstalls existing
   #      installs (so it CANNOT touch the module/system dirs); --no-deps
   #      => no re-resolution / cascade. Upgrades land in the prefix and win
   #      at runtime via the modulefile's PYTHONPATH prepend; the module
   #      copies are left byte-for-byte intact.
   REPORT="${VLLM_BUILD_ROOT}/resolve-report.json"
   DEP_REQS="${VLLM_BUILD_ROOT}/dep-closure.txt"
   REQ_ROCM_ARGS=()
   [ -f "${VLLM_SRC}/requirements/rocm.txt" ] && REQ_ROCM_ARGS=(-r "${VLLM_SRC}/requirements/rocm.txt")
   echo "vllm: resolving dependency closure (dry-run; honors the pytorch module, never writes)"
   pip3 install --dry-run --report "${REPORT}" \
      --constraint "${CONSTRAINTS}" \
      "${VLLM_WHEEL}" "${REQ_ROCM_ARGS[@]}" \
      || send-error "dependency resolution (dry-run) failed; see log above (often a real torch/ABI conflict)."

   python3 - "${REPORT}" "${DEP_REQS}" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
reqs = []
for item in rep.get("install", []):
    md = item.get("metadata", {})
    name = (md.get("name") or "").strip()
    ver = (md.get("version") or "").strip()
    if not name or name.lower() == "vllm":
        continue  # vllm itself is installed separately, from the local wheel
    reqs.append(f"{name}=={ver}")
with open(sys.argv[2], "w") as f:
    f.write("\n".join(sorted(reqs)) + ("\n" if reqs else ""))
print(f"vllm: dependency closure = {len(reqs)} package(s) to install into the prefix")
PY

   if [ -s "${DEP_REQS}" ]; then
      echo "vllm: installing resolved deps into the prefix (--no-deps --ignore-installed; module untouched)"
      pip3 install \
         --prefix="${VLLM_PATH}" \
         --no-deps --ignore-installed --no-warn-script-location \
         -r "${DEP_REQS}" \
         || send-error "installing the resolved dependency closure failed; see log above."
   fi

   echo "vllm: installing the vLLM wheel into the prefix (--no-deps --ignore-installed)"
   pip3 install \
      --prefix="${VLLM_PATH}" \
      --no-deps --ignore-installed --no-warn-script-location \
      "${VLLM_WHEEL}" \
      || send-error "installing the vLLM wheel failed; see log above."

   # ── amdsmi: REQUIRED for vLLM's ROCm platform detection ────────────
   # vLLM (>=0.24) resolves its platform via amdsmi: rocm_platform_plugin()
   # calls amdsmi_init() + amdsmi_get_processor_handles(). If the amdsmi
   # Python bindings are not importable, that plugin returns None and vLLM
   # SILENTLY falls back to UnspecifiedPlatform -- it imports fine and even
   # runs torch on the GPU, but the engine never selects the ROCm backend.
   # (Confirmed on this cluster: without amdsmi, current_platform resolved
   # to UnspecifiedPlatform with device_name None; with it, RocmPlatform /
   # is_rocm True and offline generation works.) The pytorch module does
   # NOT ship amdsmi, so install the ROCm-provided bindings -- pure-Python
   # plus a bundled libamd_smi.so, ABI-tied to ${ROCM_MODULE_NAME} -- into
   # the SAME prefix. --no-build-isolation reuses the BUILD_TOOLS setuptools
   # (no network); --ignore-installed keeps it inside the prefix only.
   AMDSMI_SRC="${ROCM_PATH:-}/share/amd_smi"
   if [ -n "${ROCM_PATH:-}" ] && [ -f "${AMDSMI_SRC}/pyproject.toml" ]; then
      echo "vllm: installing amdsmi bindings from ${AMDSMI_SRC} (ROCm platform detection)"
      # Build from a WRITABLE COPY, never from ${AMDSMI_SRC} directly. pip does
      # an in-tree PEP 517 build (writes build/ + *.egg-info INTO the source
      # dir), but ${AMDSMI_SRC} lives in the root-owned, read-only ROCm install
      # tree (/opt/rocm-*/share/amd_smi) -> "could not create 'build/lib/amdsmi':
      # Permission denied" (rocm-7.14.0 job 16824). --no-build-isolation does
      # NOT relocate the build. The bindings are self-contained (pure-Python +
      # a bundled libamd_smi.so shipped as package_data), so a plain recursive
      # copy into the per-job build root builds cleanly and never touches the
      # ROCm tree. cp -r (not -a) so we do not try to preserve root ownership
      # (which fails as a normal user); the copy is admin-owned and writable.
      AMDSMI_BUILD="${VLLM_BUILD_ROOT}/amd_smi"
      rm -rf "${AMDSMI_BUILD}"
      mkdir -p "${AMDSMI_BUILD}"
      cp -r "${AMDSMI_SRC}/." "${AMDSMI_BUILD}/"
      pip3 install \
         --prefix="${VLLM_PATH}" \
         --no-build-isolation --no-deps --ignore-installed --no-warn-script-location \
         "${AMDSMI_BUILD}" \
         || send-error "installing amdsmi from ${AMDSMI_SRC} failed; without it vLLM will not detect the ROCm platform."
   else
      echo "vllm: WARNING amdsmi source not found at ${AMDSMI_SRC}; vLLM may fall back to UnspecifiedPlatform and never use the GPU."
   fi

   # Resolve the site dir pip created under the prefix. Ubuntu's Debian
   # python uses the posix_local scheme (local/lib/pythonX.Y/dist-packages);
   # a vanilla python would use lib/pythonX.Y/site-packages. Detect either.
   VLLM_SITE="$(find "${VLLM_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
   [ -z "${VLLM_SITE}" ] && send-error "vLLM install produced no site/dist-packages under ${VLLM_PATH}; build likely failed."
   echo "vllm: installed into prefix ${VLLM_PATH} (site: ${VLLM_SITE})"

   # Normalize ownership/permissions like the sibling scripts.
   if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
      ${SUDO} find "${VLLM_PATH}" -type f -execdir chown root:root "{}" +
      ${SUDO} find "${VLLM_PATH}" -type d -execdir chown root:root "{}" +
   fi
   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod go-w "${VLLM_PATH}"
   fi
fi

# Resolve the prefix's site dir + bin dir for the modulefile. Recomputed
# here (not only in the build branch) so the cache-restore path has them
# too. VLLM_BINDIR is the sibling of the scheme root that holds site/dist-
# packages (posix_local: ${VLLM_PATH}/local/{lib,bin}; posix_prefix:
# ${VLLM_PATH}/{lib,bin}) -- derive it by stripping /lib/... off VLLM_SITE.
VLLM_SITE="$(find "${VLLM_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
if [ -z "${VLLM_SITE}" ]; then
   send-error "no site/dist-packages found under ${VLLM_PATH}; install (or cached tarball) is broken."
fi
VLLM_BINDIR="${VLLM_SITE%/lib/*}/bin"

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

# MI300A-APU-only modulefile lines (see IS_APU detection above). Emitted
# only on an APU; on CDNA discrete GPUs these are inapplicable and omitted.
if [ "${IS_APU}" = "1" ]; then
   APU_MODULE_BLOCK=$(cat <<'LUA'

-- MI300A APU: scratch-reclaim workaround (matches the rocm modulefile).
setenv("HSA_NO_SCRATCH_RECLAIM","1")

-- WARNING (MI300A APU): host RAM and GPU HBM are ONE physical pool.
-- Do NOT use vLLM --swap-space / --cpu-offload-gb (nor DeepSpeed/FSDP
-- CPU offload): "offloading" moves data within the same pool and can
-- OOM/HANG. Prefer --kv-cache-dtype fp8 and a lower --max-model-len.
LUA
)
else
   APU_MODULE_BLOCK=""
fi

# The - option suppresses leading tabs in the heredoc body.
cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${VLLM_MODULE_TOKEN}.lua
	whatis("vLLM ${VLLM_VERSION} with ROCm support (bound to ${PYTORCH_MODULE_RESOLVED}, torch ${TORCH_VERSION}, ${AMDGPU_GFXMODEL})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- vLLM builds on the pytorch module (torch/triton/transformers/deepspeed).
	-- Load the EXACT pytorch it was compiled against: vLLM's ROCm kernels are
	-- ABI-locked to that torch, so loading the bare 'pytorch' alias (which
	-- could resolve to a newer default) would risk a runtime ABI mismatch.
	prereq("${ROCM_MODULE_NAME}")
	load("${PYTORCH_MODULE_RESOLVED}")

	prepend_path("PYTHONPATH","${VLLM_SITE}")
	prepend_path("PATH","${VLLM_BINDIR}")

	-- Co-locate HF weights/cache with the team's ollama models on /shareddata.
	setenv("HF_HOME","${HF_HOME_DEFAULT}")
${APU_MODULE_BLOCK}
EOF

# ── Refresh the Lmod spider cache ──────────────────────────────────────
# A freshly-written modulefile is invisible to `module load` while a valid
# system spider cache exists: Lmod trusts the cache and never sees the new
# file, so `module load vllm/${VLLM_MODULE_TOKEN}` errors "unknown module"
# until the cache expires (24h here) -- only `module --ignore_cache` finds it.
# Bumping the cache TIMESTAMP file newer than the cache marks it stale, so
# Lmod re-walks the tree live and rebuilds per-user caches immediately.
# Best-effort: the timestamp path is parsed from `module --config`; a miss
# just means users may need `module --ignore_cache load` until an admin
# cache rebuild. Never fatal -- the install itself is already complete.
LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   if ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null; then
      echo "[vllm] bumped Lmod cache timestamp (${LMOD_TS_FILE}); vllm/${VLLM_MODULE_TOKEN} is loadable now."
   else
      echo "[vllm] WARNING could not touch ${LMOD_TS_FILE}; until the next cache rebuild load with: module --ignore_cache load vllm/${VLLM_MODULE_TOKEN}"
   fi
else
   echo "[vllm] NOTE could not locate the Lmod cache timestamp; if 'module load vllm/${VLLM_MODULE_TOKEN}' reports unknown, use: module --ignore_cache load vllm/${VLLM_MODULE_TOKEN}"
fi

echo ""
echo "[vllm] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} ${PYTORCH_MODULE_RESOLVED} vllm/${VLLM_MODULE_TOKEN}"
echo ""
