#!/bin/bash

# Capture this script's absolute path BEFORE any cd, for the git-provenance
# block that stamps the modulefile.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# AMD Quark -- model quantization toolkit for PyTorch and ONNX. Packaged in
# the HPCTrainingDock leaf style, modeled on atom_setup.sh / xdit_setup.sh's
# SAFE install model: it layers on the `pytorch` module (never ships its own
# torch), hard-pins the module's ML stack (torch/transformers/huggingface_hub/
# tokenizers/safetensors) in a constraints file, resolves the dependency delta
# with a dry-run, and installs ONLY that delta into a per-(quark,pytorch)
# PREFIX with --no-deps --ignore-installed so the shared pytorch module is
# never mutated and its multi-GB torch stack is REUSED, not duplicated.
#
# WHY TORCH-BOUND (not standalone): amd-quark's functional backends BOTH import
# the framework at import time -- `quark.torch` imports torch+transformers and
# `quark.onnx` imports torch (and needs onnxruntime). So Quark is effectively
# bound to a concrete pytorch module's ML stack. Pinning that stack also avoids
# a real version clash: amd-quark's base deps (via datasets) would otherwise
# pull huggingface_hub>=2.0, which the pytorch module's transformers (pinned
# <2.0) rejects. Reusing the module's huggingface_hub/transformers sidesteps it.
#
# Install layout (keyed on BOTH versions so pairs coexist, like atom):
#   prefix     : /opt/rocmplus-${ROCM_VERSION}/quark-v${QUARK_VERSION}-pt${PYTORCH_VERSION}
#   modulefile : ${MODULE_PATH}/${QUARK_VERSION}-pt${PYTORCH_VERSION}.lua
# The /opt/rocmplus-${ROCM_VERSION} prefix is already per-ROCm-version, so one
# quark build exists per (quark, pytorch, rocm) triple with no cross-talk.
# Lands in the ROCmPlus-AI overlay the rocm module adds to MODULEPATH, so
# quark/<ver> is only visible once the matching rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

ROCM_VERSION=7.2.4
BUILD_QUARK=1
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/quark
# Version LABEL (keys install dir + module) AND the pinned wheel version.
# amd-quark 0.13 is the latest released py3-none-any wheel on PyPI.
QUARK_VERSION=0.13
# pip distribution name for AMD Quark.
QUARK_PKG="amd-quark"
# Optional extra wheel find-links index; empty -> canonical PyPI.
QUARK_INDEX=""
PYTORCH_MODULE="pytorch"
PYTORCH_VERSION=""
# Hard-pin these to the pytorch module's EXACT versions so the dep resolve can
# never upgrade the module's ML stack. huggingface-hub/transformers/tokenizers/
# safetensors are pinned (not just the torch family) because amd-quark's base
# deps would otherwise drag in huggingface_hub>=2.0 and break the module's
# transformers (pinned <2.0); reusing the module's stack keeps them consistent.
PROTECTED_PACKAGES="torch torchvision torchaudio triton pytorch-triton-rocm flash-attn flash-attention aotriton transformers tokenizers huggingface-hub huggingface_hub safetensors"
AMDGPU_GFXMODEL_INPUT=""
QUARK_PATH=""
QUARK_PATH_INPUT=""
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
   echo "  --build-quark [ 0|1 ]            default $BUILD_QUARK"
   echo "  --quark-version [ VER ]          AMD Quark version LABEL + pinned wheel version; default $QUARK_VERSION"
   echo "  --quark-pkg [ NAME ]             pip distribution name; default $QUARK_PKG"
   echo "  --quark-index [ URL ]            optional extra wheel find-links index; default none (PyPI)"
   echo "  --pytorch-module [ MOD ]         pytorch module to load; default $PYTORCH_MODULE"
   echo "  --pytorch-version [ VER ]        bound pytorch version; keys the install dir + modulefile. Empty -> resolved from the loaded token."
   echo "  --protect-packages [ names ]     extra ABI/ML packages to hard-pin from the pytorch module"
   echo "  --amdgpu-gfxmodel [ GFX ]        default autodetected via rocminfo"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION"
   echo "  --install-path [ DIR ]           parent dir; install -> \${DIR}/quark-v\${QUARK_VERSION}-pt\${PYTORCH_VERSION}"
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
      "--build-quark")       shift; BUILD_QUARK=${1}; reset-last ;;
      "--quark-version")     shift; QUARK_VERSION=${1}; reset-last ;;
      "--quark-pkg")         shift; QUARK_PKG=${1}; reset-last ;;
      "--quark-index")       shift; QUARK_INDEX=${1}; reset-last ;;
      "--pytorch-module")    shift; PYTORCH_MODULE=${1}; reset-last ;;
      "--pytorch-version")   shift; PYTORCH_VERSION=${1}; reset-last ;;
      "--protect-packages")  shift; PROTECTED_PACKAGES="${PROTECTED_PACKAGES} ${1}"; reset-last ;;
      "--amdgpu-gfxmodel")   shift; AMDGPU_GFXMODEL_INPUT=${1}; reset-last ;;
      "--rocm-version")      shift; ROCM_VERSION=${1}; reset-last ;;
      "--install-path")      shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version") shift; QUARK_PATH_INPUT=${1}; reset-last ;;
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

# ── BUILD_QUARK=0 short-circuit ───────────────────────────────────────
MISSING_PREREQ_RC=42
NOOP_RC=43
if [ "${BUILD_QUARK}" = "0" ]; then
   echo "[quark BUILD_QUARK=0] operator opt-out; skipping (no install)."
   echo "  Use --build-quark 1 to install AMD Quark."
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
   echo "[quark missing-prereq] could not 'module load ${PYTORCH_MODULE}' after"
   echo "  '${ROCM_MODULE_NAME}'. Build the pytorch module first (pytorch_setup.sh)"
   echo "  or pass --pytorch-module. Skipping AMD Quark."
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

# ── Early guard: Python version (amd-quark requires >=3.11,<3.14) ─────
PY_MM=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
case "${PY_MM}" in
   3.11|3.12|3.13) : ;;
   *) send-error "amd-quark requires Python >=3.11,<3.14, but the pytorch module's python is ${PY_MM}. Refusing to install." ;;
esac

# Confirm the module torch is a ROCm build and resolve its version.
TORCH_VERSION=$(python3 -c 'import torch; print(torch.__version__.split("+")[0])' 2>/dev/null || true)
[ -z "${TORCH_VERSION}" ] && send-error "could not import torch from '${PYTORCH_MODULE}'; cannot install AMD Quark."
python3 - <<'PY' || send-error "the pytorch module's torch is not a ROCm build (torch.version.hip is None); refusing to install AMD Quark."
import torch, sys
sys.exit(0 if getattr(torch.version, "hip", None) else 1)
PY

# gfx model detection (for IS_APU gating + the whatis line; amd-quark is pure
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
QUARK_DIRNAME="quark-v${QUARK_VERSION}-pt${PYTORCH_VERSION}"
QUARK_MODULE_TOKEN="${QUARK_VERSION}-pt${PYTORCH_VERSION}"
if [ -n "${QUARK_PATH_INPUT}" ]; then
   QUARK_PATH="${QUARK_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   QUARK_PATH="${ROCMPLUS_PATH_INPUT}/${QUARK_DIRNAME}"
else
   QUARK_PATH="/opt/rocmplus-${ROCM_VERSION}/${QUARK_DIRNAME}"
fi

# ── Install-path sudo (write-probe of nearest existing ancestor) ──────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${QUARK_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .quark-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "quark: install ancestor ${_iprobe} is user-writable; not using sudo for install"
   else
      SUDO="sudo"
      echo "quark: install ancestor ${_iprobe} not user-writable; using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[quark --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${QUARK_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${QUARK_MODULE_TOKEN}.lua"
fi
if [ -d "${QUARK_PATH}" ]; then
   echo ""
   echo "[quark existence-check] already installed; skipping (${QUARK_PATH}). Pass --replace 1 to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── Consolidated EXIT trap (build-dir + fail-cleanup) ─────────────────
_quark_on_exit() {
   local rc=$?
   [ -n "${QUARK_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${QUARK_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[quark fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${QUARK_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${QUARK_MODULE_TOKEN}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[quark fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _quark_on_exit EXIT

echo ""
echo "====================================="
echo " Installing AMD Quark (ROCm)"
echo " Quark version:     $QUARK_VERSION  (pkg ${QUARK_PKG})"
echo " Install directory: $QUARK_PATH"
echo " Module name:       quark/$QUARK_MODULE_TOKEN"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo " Pytorch module:    $PYTORCH_MODULE_RESOLVED (torch $TORCH_VERSION, py ${PY_MM}, ${AMDGPU_GFXMODEL})"
echo "====================================="
echo ""

if ! ${SUDO} mkdir -p "${QUARK_PATH}"; then
   send-error "could not create install dir ${QUARK_PATH} (SUDO='${SUDO}'). Re-run as root or with passwordless sudo."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${QUARK_PATH}"
fi

QUARK_BUILD_ROOT=$(mktemp -d -t quark-build.XXXXXX)
cd "${QUARK_BUILD_ROOT}"

# Harden pip against a polluted NFS-HOME pip config (mirrors atom_setup.sh).
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"

# ── Build a constraints file pinning the module's ML/ABI packages ─────
CONSTRAINTS="${QUARK_BUILD_ROOT}/constraints.txt"
printf '%s\n' "${PYTORCH_MODULE_PYPATHS}" > "${QUARK_BUILD_ROOT}/pytorch_pypaths.txt"
python3 - "${QUARK_BUILD_ROOT}/pytorch_pypaths.txt" "${CONSTRAINTS}" "${PROTECTED_PACKAGES}" <<'PY'
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
echo "quark: hard-pinned ML/ABI packages reused from the pytorch module (not duplicated):"
sed -e 's/^/  /' "${CONSTRAINTS}"

QUARK_SPEC="${QUARK_PKG}==${QUARK_VERSION}"
_idx_args=()
[ -n "${QUARK_INDEX}" ] && _idx_args=(-f "${QUARK_INDEX}")

# ── Resolve the dependency delta against the LIVE module env ──────────
# Dry-run honoring the pytorch module + the hard-pin constraints; filter out
# the protected ML packages (torch family, transformers, huggingface_hub, ...)
# and amd-quark itself, then install only the remaining closure into the prefix
# with --no-deps (module untouched, torch stack reused).
REPORT="${QUARK_BUILD_ROOT}/resolve-report.json"
DEP_REQS="${QUARK_BUILD_ROOT}/dep-closure.txt"
echo "quark: resolving dependency closure (dry-run; honors the pytorch module, never writes)"
pip3 install --dry-run --report "${REPORT}" \
   --constraint "${CONSTRAINTS}" \
   "${_idx_args[@]}" "${QUARK_SPEC}" \
   || send-error "dependency resolution (dry-run) failed; see log above (often a real torch/transformers/hf_hub conflict with this pytorch module)."
python3 - "${REPORT}" "${DEP_REQS}" "${PROTECTED_PACKAGES}" "${QUARK_PKG}" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
protected = set(x.lower().replace("_", "-") for x in sys.argv[3].split())
skip = protected | {sys.argv[4].lower().replace("_", "-"), "quark"}
reqs = []
for item in rep.get("install", []):
    md = item.get("metadata", {})
    name = (md.get("name") or "").strip()
    ver = (md.get("version") or "").strip()
    if not name or name.lower().replace("_", "-") in skip:
        continue
    reqs.append(f"{name}=={ver}")
open(sys.argv[2], "w").write("\n".join(sorted(reqs)) + ("\n" if reqs else ""))
print(f"quark: dependency closure = {len(reqs)} package(s) to install into the prefix")
PY

if [ -s "${DEP_REQS}" ]; then
   echo "quark: installing resolved deps into the prefix (--no-deps --ignore-installed; module untouched)"
   pip3 install --prefix="${QUARK_PATH}" --no-deps --ignore-installed --no-warn-script-location \
      --constraint "${CONSTRAINTS}" \
      "${_idx_args[@]}" -r "${DEP_REQS}" || send-error "installing the resolved dependency closure failed; see log above."
fi

# ── Install amd-quark itself into the PREFIX (wheel; --no-deps) ───────
echo "quark: installing ${QUARK_SPEC} into the prefix (--no-deps)"
pip3 install --prefix="${QUARK_PATH}" --no-deps --ignore-installed --no-warn-script-location \
   "${_idx_args[@]}" "${QUARK_SPEC}" \
   || send-error "installing ${QUARK_SPEC} failed; see log above."

# Resolve the prefix site/bin dirs for the modulefile.
QUARK_SITE="$(find "${QUARK_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
[ -z "${QUARK_SITE}" ] && send-error "quark install produced no site/dist-packages under ${QUARK_PATH}; install likely failed."
QUARK_BINDIR="${QUARK_SITE%/lib/*}/bin"
echo "quark: installed into prefix ${QUARK_PATH} (site: ${QUARK_SITE})"

# Early sanity: top-level `import quark` must work against the module stack
# (does not need a GPU). Fails fast if the dep delta is internally broken.
if ! PYTHONPATH="${QUARK_SITE}:${PYTHONPATH:-}" python3 -c 'import quark; print("quark import OK", getattr(quark,"__version__","?"))'; then
   send-error "post-install 'import quark' failed; see traceback above."
fi

# ── Precompile the stable-ABI C++ kernels into the prefix (read-only-safe) ──
# quark.torch (hw_emulation) and quark.onnx (custom_ops) JIT-compile a
# stable-ABI torch-ops .so on first use. On ROCm that JIT runs hipify, which
# WRITES `_hip` source siblings INTO the package's csrc/ tree -- which fails
# with EACCES from a read-only install prefix (production /nfsapps), killing
# the import. The loader instead prefers a PRE-COMPILED
# `<pkg>/lib/lib<name>[_gpu].so` (torch.ops.load_library) over JIT, so build
# those .so ONCE here while the prefix is writable (needs a visible GPU) and
# drop them in place -> runtime loads them with no hipify and no writes.
# torch >= 2.10 uses a stable-ABI kernel whose loader prefers a pre-compiled
# lib/*.so over JIT; torch < 2.10 uses the legacy pybind11 kernel that is
# JIT-only (no pre-compiled hook). Both JIT paths hipify INTO the package tree,
# so the install-time build below (prefix still writable) is what makes a
# read-only runtime safe: >=2.10 gets a pre-compiled .so dropped in lib/ (no
# runtime JIT at all); <2.10 gets its sources pre-hipified so the per-user
# runtime JIT (into TORCH_EXTENSIONS_DIR in $HOME) needs no writes to the prefix.
QUARK_HAS_GPU=$(python3 -c 'import torch; print(1 if torch.cuda.is_available() else 0)' 2>/dev/null || echo 0)
QUARK_STABLE_ABI=$(PYTHONPATH="${QUARK_SITE}:${PYTHONPATH:-}" python3 -c 'from quark.common.utils.torch_utils import torch_supports_stable_abi; print(1 if torch_supports_stable_abi() else 0)' 2>/dev/null || echo 0)
if [ "${QUARK_HAS_GPU}" = "1" ]; then
   if [ "${QUARK_STABLE_ABI}" = "1" ]; then
      echo "quark: torch ${TORCH_VERSION} supports stable-ABI; pre-compiling kernels so a read-only prefix needs no runtime JIT"
   else
      echo "quark: torch ${TORCH_VERSION} is pre-stable-ABI (<2.10); pre-hipifying the legacy kernels so the per-user runtime JIT needs no writes to the prefix"
   fi
   # quark.onnx's custom_ops build needs onnxruntime importable; best-effort.
   module load onnxruntime 2>/dev/null || true
   QUARK_TORCH_EXT_DIR="${QUARK_BUILD_ROOT}/torch_ext"
   mkdir -p "${QUARK_TORCH_EXT_DIR}"
   _rocm_lib=""
   [ -n "${ROCM_PATH:-}" ] && _rocm_lib="${ROCM_PATH}/lib"
   # Build both backends once (prefix writable): places _hip siblings in the
   # package tree and, on stable-ABI torch, the .so artifacts in TORCH_EXTENSIONS_DIR.
   PYTHONPATH="${QUARK_SITE}:${_rocm_lib}:${PYTHONPATH:-}" \
   TORCH_EXTENSIONS_DIR="${QUARK_TORCH_EXT_DIR}" \
   python3 - <<'PY' || echo "quark: WARNING kernel pre-build step errored; see above."
import importlib
try:
    hwe = importlib.import_module("quark.torch.kernel.hw_emulation.extensions")
    hwe._initialize_kernels()
    print("quark: quark.torch hw_emulation kernel build OK")
except Exception as e:
    print("quark: WARNING hw_emulation pre-build failed:", type(e).__name__, str(e)[:200])
try:
    importlib.import_module("quark.onnx.operators.custom_ops.build_custom_ops")
    print("quark: quark.onnx custom_ops kernel build OK")
except Exception as e:
    print("quark: NOTE custom_ops pre-build skipped/failed:", type(e).__name__, str(e)[:200])
PY
   if [ "${QUARK_STABLE_ABI}" = "1" ]; then
      # Copy the freshly-built stable-ABI .so into the loader's pre-compiled lib/
      # locations so runtime loads them (torch.ops.load_library) with no JIT.
      _hwe_dir="${QUARK_SITE}/quark/torch/kernel/hw_emulation"
      _cus_dir="${QUARK_SITE}/quark/onnx/operators/custom_ops"
      _hwe_so="$(find "${QUARK_TORCH_EXT_DIR}" -path '*hw_emulation*' -name '*.so' 2>/dev/null | head -1)"
      _cus_so="$(find "${QUARK_TORCH_EXT_DIR}" -path '*custom_ops*' -name '*.so' 2>/dev/null | head -1)"
      if [ -n "${_hwe_so}" ]; then
         mkdir -p "${_hwe_dir}/lib"
         cp -f "${_hwe_so}" "${_hwe_dir}/lib/libhw_emulation_gpu.so"
         echo "quark: placed pre-compiled hw_emulation -> ${_hwe_dir}/lib/libhw_emulation_gpu.so"
      else
         echo "quark: WARNING stable-ABI torch but no hw_emulation .so was produced; quark.torch will JIT at runtime (fails read-only)."
      fi
      if [ -n "${_cus_so}" ]; then
         mkdir -p "${_cus_dir}/lib"
         cp -f "${_cus_so}" "${_cus_dir}/lib/libcustom_ops_stable_abi_gpu.so"
         echo "quark: placed pre-compiled custom_ops -> ${_cus_dir}/lib/libcustom_ops_stable_abi_gpu.so"
      fi
      # Verify the pre-compiled path loads with JIT fallback DISABLED, so success
      # proves no runtime compile/hipify is needed (i.e. read-only-safe).
      if [ -n "$(find "${_hwe_dir}/lib" -name 'libhw_emulation*.so' 2>/dev/null)" ]; then
         PYTHONPATH="${QUARK_SITE}:${PYTHONPATH:-}" \
         TORCH_EXTENSIONS_DIR="${QUARK_BUILD_ROOT}/verify_ext" \
         QUARK_BUILD_DISABLE_JIT_FALLBACK=1 \
         python3 -c 'import quark.torch.kernel.hw_emulation.extensions as h; h._initialize_kernels(); print("quark: pre-compiled hw_emulation load verified (no JIT)")' \
            || send-error "pre-compiled hw_emulation kernel failed to load with JIT disabled; the read-only-safe path is broken."
      fi
      unset _hwe_dir _cus_dir _hwe_so _cus_so
   else
      echo "quark: legacy kernels pre-hipified in the prefix; quark.torch/quark.onnx will JIT once per user into TORCH_EXTENSIONS_DIR (\$HOME) on first use (~1-2 min), with no writes to the read-only prefix."
   fi
   unset _rocm_lib
else
   echo "quark: WARNING no GPU visible at build time; skipping kernel pre-build."
   echo "  quark.torch/quark.onnx JIT-compile on first use and hipify INTO the package"
   echo "  tree, which FAILS from a read-only install prefix. Rebuild on a GPU node for"
   echo "  a production (read-only) deployment."
fi

# Normalize ownership/permissions.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${QUARK_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${QUARK_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
fi
[[ "${USER}" != "root" ]] && ${SUDO} chmod go-w "${QUARK_PATH}" 2>/dev/null || true

cd /

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .quark-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "quark: module ancestor ${_mprobe} is user-writable; not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "quark: module ancestor ${_mprobe} not user-writable; using sudo for modulefile"
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
LUA
)
else
   APU_MODULE_BLOCK=""
fi

cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${QUARK_MODULE_TOKEN}.lua
	whatis("AMD Quark ${QUARK_VERSION} -- model quantization toolkit for PyTorch and ONNX (bound to ${PYTORCH_MODULE_RESOLVED}, torch ${TORCH_VERSION}, ${AMDGPU_GFXMODEL})")
	whatis("Package: ${QUARK_PKG}==${QUARK_VERSION} (PyPI); reuses the pytorch module's torch/transformers/huggingface_hub stack")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- Quark's quark.torch backend uses the pytorch module's torch+transformers;
	-- only Quark + its non-module deps (onnx, datasets, ...) live in this prefix.
	prereq("${ROCM_MODULE_NAME}")
	load("${PYTORCH_MODULE_RESOLVED}")

	local base = "${QUARK_PATH}"
	prepend_path("PYTHONPATH","${QUARK_SITE}")
	prepend_path("PATH","${QUARK_BINDIR}")
	-- Expose the rocm module's MIGraphX python bindings for the quark.onnx path.
	local rocm = os.getenv("ROCM_PATH")
	if (rocm ~= nil) then
	  prepend_path("PYTHONPATH", pathJoin(rocm, "lib"))
	end
	setenv("QUARK_HOME", base)
${APU_MODULE_BLOCK}

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#  AMD Quark ${QUARK_VERSION}: quantization for PyTorch (quark.torch) and ONNX (quark.onnx).")
	  LmodMessage("#  quark.torch works now (torch is loaded). For quark.onnx also load onnxruntime:")
	  LmodMessage("#    module load onnxruntime")
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
      && echo "[quark] bumped Lmod cache timestamp; quark/${QUARK_MODULE_TOKEN} is loadable now." \
      || echo "[quark] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load quark/${QUARK_MODULE_TOKEN}"
else
   echo "[quark] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load quark/${QUARK_MODULE_TOKEN}"
fi

echo ""
echo "[quark] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} ${PYTORCH_MODULE_RESOLVED} quark/${QUARK_MODULE_TOKEN}"
echo ""
