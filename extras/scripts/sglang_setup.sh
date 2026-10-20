#!/bin/bash

# Capture this script's absolute path BEFORE any cd, for the git-provenance
# block that stamps the modulefile.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# SGLang (ROCm) setup for AMD CDNA GPUs, in the HPCTrainingDock leaf style.
# Mirrors vllm_setup.sh's SAFE install model: it layers on the `pytorch`
# module (never ships its own torch), hard-pins the module's torch/triton
# in a constraints file, resolves the [srt_hip] dependency delta with a
# dry-run, and installs ONLY that delta into a per-(sglang,pytorch) PREFIX
# with --no-deps --ignore-installed so the shared pytorch module is never
# mutated.
#
# SOURCE build (authoritative recipe = Hyperloom install_baremetal.sh):
# AMD's amd-sglang ROCm wheels are cp310-only, so on Python != 3.10 SGLang
# is built FROM SOURCE at a pinned commit: clone, build the in-tree ROCm
# AOT kernel (python/sglang/kernels/aot/setup_rocm.py for v0.5.17+, or the
# legacy sgl-kernel/ dir), then install python[srt_hip]. AITER is installed
# into the same prefix (SGLang routes GEMM through it) but is NON-FATAL.
#
# Install layout (keyed on BOTH versions so pairs coexist, like vllm):
#   prefix     : /opt/rocmplus-${ROCM_VERSION}/sglang-v${SGLANG_VERSION}-pt${PYTORCH_VERSION}
#   modulefile : ${MODULE_PATH}/${SGLANG_VERSION}-pt${PYTORCH_VERSION}.lua
# Lands in the ROCmPlus-AI overlay the rocm module adds to MODULEPATH, so
# sglang/<ver> is only visible once the matching rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

ROCM_VERSION=7.2.4
BUILD_SGLANG=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/sglang
SGLANG_VERSION=0.5.17
# v0.5.17 release commit (peeled). Fetched by SHA, not branch/tag, so GitHub
# serves the exact commit. Overridable with --sglang-ref.
SGLANG_REPO="https://github.com/sgl-project/sglang.git"
SGLANG_REF="b6a09f38fcc5e96574324b4acc19d421c539cfc6"
SGLANG_REF_USER_SET=0
# setuptools-scm pretend version (the shallow checkout has no tags).
SGLANG_PRETEND_VERSION=""
# ROCm editable installs only need multimodal Rust crates for VLM serving.
SGLANG_BUILD_RUST_EXTS="none"
# AITER: AMD optimized kernels SGLang routes GEMM through. Built into the
# prefix; NON-FATAL (a failure leaves a working SGLang that falls back).
WITH_AITER=1
AITER_REPO="https://github.com/ROCm/aiter.git"
AITER_REF=""
PYTORCH_MODULE="pytorch"
PYTORCH_VERSION=""
# Hard-pin these (ABI/ROCm-compiled) to the pytorch module's EXACT version so
# the [srt_hip] resolve can never plan a different torch/triton.
PROTECTED_PACKAGES="torch torchvision torchaudio triton pytorch-triton-rocm flash-attn flash-attention aotriton deepspeed xformers aiter"
AMDGPU_GFXMODEL_INPUT=""
SGLANG_PATH=""
SGLANG_PATH_INPUT=""
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
   echo "  --build-sglang [ 0|1 ]           default $BUILD_SGLANG"
   echo "  --sglang-version [ VER ]         SGLang version label; default $SGLANG_VERSION"
   echo "  --sglang-ref [ SHA ]             git commit to build; default the v${SGLANG_VERSION} release commit"
   echo "  --sglang-repo [ URL ]            git repo; default $SGLANG_REPO"
   echo "  --with-aiter [ 0|1 ]             build AITER into the prefix (non-fatal); default $WITH_AITER"
   echo "  --aiter-repo [ URL ]             default $AITER_REPO"
   echo "  --aiter-ref [ REF ]              default the repo's default branch"
   echo "  --pytorch-module [ MOD ]         pytorch module to load; default $PYTORCH_MODULE"
   echo "  --pytorch-version [ VER ]        bound pytorch version; keys the install dir + modulefile. Empty -> resolved from the loaded token."
   echo "  --protect-packages [ names ]     extra ABI/ROCm packages to hard-pin from the pytorch module"
   echo "  --amdgpu-gfxmodel [ GFX ]        default autodetected via rocminfo"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION"
   echo "  --install-path [ DIR ]           parent dir; install -> \${DIR}/sglang-v\${SGLANG_VERSION}-pt\${PYTORCH_VERSION}"
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
      "--build-sglang")      shift; BUILD_SGLANG=${1}; reset-last ;;
      "--sglang-version")    shift; SGLANG_VERSION=${1}; reset-last ;;
      "--sglang-ref")        shift; SGLANG_REF=${1}; SGLANG_REF_USER_SET=1; reset-last ;;
      "--sglang-repo")       shift; SGLANG_REPO=${1}; reset-last ;;
      "--with-aiter")        shift; WITH_AITER=${1}; reset-last ;;
      "--aiter-repo")        shift; AITER_REPO=${1}; reset-last ;;
      "--aiter-ref")         shift; AITER_REF=${1}; reset-last ;;
      "--pytorch-module")    shift; PYTORCH_MODULE=${1}; reset-last ;;
      "--pytorch-version")   shift; PYTORCH_VERSION=${1}; reset-last ;;
      "--protect-packages")  shift; PROTECTED_PACKAGES="${PROTECTED_PACKAGES} ${1}"; reset-last ;;
      "--amdgpu-gfxmodel")   shift; AMDGPU_GFXMODEL_INPUT=${1}; reset-last ;;
      "--rocm-version")      shift; ROCM_VERSION=${1}; reset-last ;;
      "--install-path")      shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version") shift; SGLANG_PATH_INPUT=${1}; reset-last ;;
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

[ -z "${SGLANG_PRETEND_VERSION}" ] && SGLANG_PRETEND_VERSION="${SGLANG_VERSION}"

# ── BUILD_SGLANG=0 short-circuit ──────────────────────────────────────
MISSING_PREREQ_RC=42
NOOP_RC=43
if [ "${BUILD_SGLANG}" = "0" ]; then
   echo "[sglang BUILD_SGLANG=0] operator opt-out; skipping (no build)."
   echo "  Use --build-sglang 1 to build SGLang."
   exit ${NOOP_RC}
fi

# Bring `module` into scope for standalone invocation.
if [ -f /etc/profile.d/lmod.sh ]; then
   source /etc/profile.d/lmod.sh
fi

# Derive the rocm module token to (re-)load (same order as vllm_setup.sh).
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
   echo "[sglang missing-prereq] could not 'module load ${PYTORCH_MODULE}' after"
   echo "  '${ROCM_MODULE_NAME}'. Build the pytorch module first (pytorch_setup.sh)"
   echo "  or pass --pytorch-module. Skipping SGLang."
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
[ -z "${TORCH_VERSION}" ] && send-error "could not import torch from '${PYTORCH_MODULE}'; cannot build SGLang."
python3 - <<'PY' || send-error "the pytorch module's torch is not a ROCm build (torch.version.hip is None); refusing to build SGLang."
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
# SGLang's AOT kernel build takes a SINGLE AMDGPU_TARGET; take the first gfx.
PYTORCH_ROCM_ARCH=$(echo "${AMDGPU_GFXMODEL}" | tr ',;' '  ' | sed -e 's/:[^ ]*//g')
AOT_ARCH=$(echo "${PYTORCH_ROCM_ARCH}" | awk '{print $1}')
[ -z "${AOT_ARCH}" ] && AOT_ARCH="gfx942"

# APU gating for the modulefile warnings.
IS_APU=0
rocminfo 2>/dev/null | grep -q "MI300A" && IS_APU=1

# Finalize prefix now that both versions are known.
SGLANG_DIRNAME="sglang-v${SGLANG_VERSION}-pt${PYTORCH_VERSION}"
SGLANG_MODULE_TOKEN="${SGLANG_VERSION}-pt${PYTORCH_VERSION}"
if [ -n "${SGLANG_PATH_INPUT}" ]; then
   SGLANG_PATH="${SGLANG_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   SGLANG_PATH="${ROCMPLUS_PATH_INPUT}/${SGLANG_DIRNAME}"
else
   SGLANG_PATH="/opt/rocmplus-${ROCM_VERSION}/${SGLANG_DIRNAME}"
fi

# ── Install-path sudo (write-probe of nearest existing ancestor) ──────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${SGLANG_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .sglang-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "sglang: install ancestor ${_iprobe} is user-writable; not using sudo for install"
   else
      SUDO="sudo"
      echo "sglang: install ancestor ${_iprobe} not user-writable; using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[sglang --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${SGLANG_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${SGLANG_MODULE_TOKEN}.lua"
fi
if [ -d "${SGLANG_PATH}" ]; then
   echo ""
   echo "[sglang existence-check] already installed; skipping (${SGLANG_PATH}). Pass --replace 1 to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── Consolidated EXIT trap (build-dir + fail-cleanup) ─────────────────
_sglang_on_exit() {
   local rc=$?
   [ -n "${SGLANG_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${SGLANG_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[sglang fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${SGLANG_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${SGLANG_MODULE_TOKEN}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[sglang fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _sglang_on_exit EXIT

echo ""
echo "====================================="
echo " Installing SGLang (ROCm, from source)"
echo " SGLang version:    $SGLANG_VERSION  (ref ${SGLANG_REF})"
echo " Install directory: $SGLANG_PATH"
echo " Module name:       sglang/$SGLANG_MODULE_TOKEN"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo " Pytorch module:    $PYTORCH_MODULE_RESOLVED (torch $TORCH_VERSION)"
echo " AOT kernel arch:   $AOT_ARCH"
echo "====================================="
echo ""

if ! ${SUDO} mkdir -p "${SGLANG_PATH}"; then
   send-error "could not create install dir ${SGLANG_PATH} (SUDO='${SUDO}'). Re-run as root or with passwordless sudo."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${SGLANG_PATH}"
fi

SGLANG_BUILD_ROOT=$(mktemp -d -t sglang-build.XXXXXX)
cd "${SGLANG_BUILD_ROOT}"

# Harden pip against a polluted NFS-HOME pip config (mirrors vllm_setup.sh).
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"

# ── Build a constraints file pinning the module's ABI/ROCm packages ───
CONSTRAINTS="${SGLANG_BUILD_ROOT}/constraints.txt"
printf '%s\n' "${PYTORCH_MODULE_PYPATHS}" > "${SGLANG_BUILD_ROOT}/pytorch_pypaths.txt"
python3 - "${SGLANG_BUILD_ROOT}/pytorch_pypaths.txt" "${CONSTRAINTS}" "${PROTECTED_PACKAGES}" <<'PY'
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
echo "sglang: hard-pinned ABI/ROCm packages (sourced only from the pytorch module):"
sed -e 's/^/  /' "${CONSTRAINTS}"

# ── Fetch SGLang source at the pinned commit ──────────────────────────
SGLANG_SRC="${SGLANG_BUILD_ROOT}/sglang"
echo "sglang: fetching ${SGLANG_REPO}@${SGLANG_REF}"
mkdir -p "${SGLANG_SRC}"
git -C "${SGLANG_SRC}" init -q
git -C "${SGLANG_SRC}" remote add origin "${SGLANG_REPO}"
git -C "${SGLANG_SRC}" fetch --depth 1 origin "${SGLANG_REF}"
git -C "${SGLANG_SRC}" checkout -q FETCH_HEAD
git -C "${SGLANG_SRC}" submodule update --init --recursive --depth 1

# Build toolchain for --no-build-isolation (reuse the module torch at build).
BUILD_TOOLS="${SGLANG_BUILD_ROOT}/buildtools"
pip3 install --target="${BUILD_TOOLS}" \
   "cmake>=3.26,<4" ninja "setuptools>=77,<81" setuptools-scm setuptools-rust wheel packaging jinja2 \
   "scikit-build-core>=0.10" pybind11
export PATH="${BUILD_TOOLS}/bin:${PATH}"
export PYTHONPATH="${BUILD_TOOLS}:${PYTHONPATH}"

# ── Resolve the in-tree ROCm AOT kernel dir (v0.5.17+ vs legacy) ──────
KERNEL_DIR=""
if [ -f "${SGLANG_SRC}/python/sglang/kernels/aot/setup_rocm.py" ]; then
   KERNEL_DIR="${SGLANG_SRC}/python/sglang/kernels/aot"
elif [ -f "${SGLANG_SRC}/sgl-kernel/setup_rocm.py" ]; then
   KERNEL_DIR="${SGLANG_SRC}/sgl-kernel"
else
   send-error "no in-tree ROCm sgl-kernel build path under ${SGLANG_SRC} (checked python/sglang/kernels/aot/ and sgl-kernel/)."
fi
echo "sglang: building in-tree ROCm kernel from ${KERNEL_DIR} (AMDGPU_TARGET=${AOT_ARCH})"

# ── Install the sgl-kernel + sglang into the PREFIX (never the module) ─
# Mirror vllm_setup.sh: build wheels with --no-build-isolation --no-deps so
# the compile sees the module torch, then install into the prefix with
# --no-deps --ignore-installed so pip can only ever write inside SGLANG_PATH.
export MAX_JOBS="${MAX_JOBS:-$(nproc)}"
export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_SGLANG="${SGLANG_PRETEND_VERSION}"
export SGLANG_BUILD_RUST_EXTS="${SGLANG_BUILD_RUST_EXTS}"
WHEELHOUSE="${SGLANG_BUILD_ROOT}/wheelhouse"
mkdir -p "${WHEELHOUSE}"

echo "sglang: building sgl-kernel wheel via setup_rocm.py (bypasses the scikit-build-core pyproject backend; AOT ROCm path)"
( cd "${KERNEL_DIR}" && AMDGPU_TARGET="${AOT_ARCH}" PYTORCH_ROCM_ARCH="${AOT_ARCH}" MAX_JOBS="${MAX_JOBS}" \
     python3 setup_rocm.py bdist_wheel --dist-dir "${WHEELHOUSE}" )

# The sglang python package lives under python/. A plain --no-deps wheel does
# not capture [srt_hip] extras, so resolve that extra's delta separately below.
if [ -f "${SGLANG_SRC}/python/pyproject_other.toml" ]; then
   cp "${SGLANG_SRC}/python/pyproject_other.toml" "${SGLANG_SRC}/python/pyproject.toml"
fi
echo "sglang: building sglang wheel"
pip3 wheel -v --no-build-isolation --no-deps --wheel-dir "${WHEELHOUSE}" "${SGLANG_SRC}/python"

SGL_KERNEL_WHEEL="$(find "${WHEELHOUSE}" -maxdepth 1 \( -name 'sgl_kernel-*.whl' -o -name 'sgl-kernel-*.whl' \) 2>/dev/null | head -1)"
SGLANG_WHEEL="$(find "${WHEELHOUSE}" -maxdepth 1 \( -name 'sglang-*.whl' -o -name 'amd_sglang-*.whl' \) 2>/dev/null | head -1)"
[ -z "${SGLANG_WHEEL}" ] && send-error "sglang wheel build produced no wheel in ${WHEELHOUSE}; see log above."

# ── Resolve [srt_hip] dependency delta against the LIVE module env ────
REPORT="${SGLANG_BUILD_ROOT}/resolve-report.json"
DEP_REQS="${SGLANG_BUILD_ROOT}/dep-closure.txt"
echo "sglang: resolving [srt_hip] dependency closure (dry-run; honors the pytorch module, never writes)"
pip3 install --dry-run --report "${REPORT}" \
   --constraint "${CONSTRAINTS}" \
   "${SGLANG_WHEEL}[srt_hip]" \
   || send-error "dependency resolution (dry-run) failed; see log above (often a real torch/ABI conflict)."
python3 - "${REPORT}" "${DEP_REQS}" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
reqs = []
for item in rep.get("install", []):
    md = item.get("metadata", {})
    name = (md.get("name") or "").strip()
    ver = (md.get("version") or "").strip()
    if not name or name.lower() in ("sglang", "amd-sglang", "sgl-kernel", "sgl_kernel"):
        continue
    reqs.append(f"{name}=={ver}")
open(sys.argv[2], "w").write("\n".join(sorted(reqs)) + ("\n" if reqs else ""))
print(f"sglang: dependency closure = {len(reqs)} package(s) to install into the prefix")
PY

if [ -s "${DEP_REQS}" ]; then
   echo "sglang: installing resolved deps into the prefix (--no-deps --ignore-installed; module untouched)"
   pip3 install --prefix="${SGLANG_PATH}" --no-deps --ignore-installed --no-warn-script-location \
      -r "${DEP_REQS}" || send-error "installing the resolved dependency closure failed; see log above."
fi

if [ -n "${SGL_KERNEL_WHEEL}" ]; then
   echo "sglang: installing sgl-kernel wheel into the prefix"
   pip3 install --prefix="${SGLANG_PATH}" --no-deps --ignore-installed --no-warn-script-location \
      "${SGL_KERNEL_WHEEL}" || send-error "installing the sgl-kernel wheel failed."
fi
echo "sglang: installing the sglang wheel into the prefix"
pip3 install --prefix="${SGLANG_PATH}" --no-deps --ignore-installed --no-warn-script-location \
   "${SGLANG_WHEEL}" || send-error "installing the sglang wheel failed."

# ── AITER (non-fatal): SGLang routes GEMM through it ──────────────────
if [ "${WITH_AITER}" = "1" ]; then
   case ";${PYTORCH_ROCM_ARCH// /;};" in
      *";gfx942;"*|*";gfx950;"*)
         echo "sglang: building AITER into the prefix (non-fatal)"
         _aiter_ok=1
         AITER_SRC="${SGLANG_BUILD_ROOT}/aiter-src"
         _aiter_branch_args=()
         [ -n "${AITER_REF}" ] && _aiter_branch_args=(--branch "${AITER_REF}")
         if git clone --depth 1 "${_aiter_branch_args[@]}" --recurse-submodules --shallow-submodules \
               "${AITER_REPO}" "${AITER_SRC}"; then
            AITER_WH="${SGLANG_BUILD_ROOT}/aiter-wheelhouse"; mkdir -p "${AITER_WH}"
            if GPU_ARCHS="${AOT_ARCH}" AITER_USE_SYSTEM_TRITON=1 MAX_JOBS="${MAX_JOBS}" \
                  pip3 wheel -v --no-build-isolation --no-deps --wheel-dir "${AITER_WH}" "${AITER_SRC}"; then
               AITER_WHEEL="$(find "${AITER_WH}" -maxdepth 1 \( -name 'aiter-*.whl' -o -name 'amd_aiter-*.whl' \) 2>/dev/null | head -1)"
               if [ -n "${AITER_WHEEL}" ]; then
                  pip3 install --prefix="${SGLANG_PATH}" --no-deps --ignore-installed --no-warn-script-location \
                     "${AITER_WHEEL}" || _aiter_ok=0
               else
                  _aiter_ok=0
               fi
            else
               _aiter_ok=0
            fi
         else
            _aiter_ok=0
         fi
         if [ "${_aiter_ok}" = "1" ]; then
            echo "sglang: AITER built and installed into the prefix."
         else
            echo "sglang: WARNING AITER build/install FAILED (non-fatal); SGLang installed WITHOUT aiter."
         fi
         unset _aiter_ok _aiter_branch_args ;;
      *)
         echo "sglang: AITER skipped -- PYTORCH_ROCM_ARCH='${PYTORCH_ROCM_ARCH}' has no aiter-supported gfx (gfx942/gfx950)." ;;
   esac
else
   echo "sglang: AITER build disabled (--with-aiter 0)."
fi

# Resolve the prefix site/bin dirs for the modulefile.
SGLANG_SITE="$(find "${SGLANG_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
[ -z "${SGLANG_SITE}" ] && send-error "sglang install produced no site/dist-packages under ${SGLANG_PATH}; build likely failed."
SGLANG_BINDIR="${SGLANG_SITE%/lib/*}/bin"
echo "sglang: installed into prefix ${SGLANG_PATH} (site: ${SGLANG_SITE})"

# Normalize ownership/permissions.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${SGLANG_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${SGLANG_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
fi
[[ "${USER}" != "root" ]] && ${SUDO} chmod go-w "${SGLANG_PATH}" 2>/dev/null || true

ROCM_PATH_FOR_MODULE="${ROCM_PATH}"
cd /

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .sglang-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "sglang: module ancestor ${_mprobe} is user-writable; not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "sglang: module ancestor ${_mprobe} not user-writable; using sudo for modulefile"
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
-- WARNING (MI300A APU): host RAM and GPU HBM are ONE physical pool. Avoid
-- CPU-offload serving flags; prefer fp8 KV cache and a lower max context.
LUA
)
else
   APU_MODULE_BLOCK=""
fi

if [ -d "${SGLANG_SITE}/aiter" ]; then
   AITER_MODULE_BLOCK=$'\n-- AITER is BUILT into this install; SGLang uses it by default.\nsetenv("SGLANG_USE_AITER","1")'
else
   AITER_MODULE_BLOCK=""
fi

cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${SGLANG_MODULE_TOKEN}.lua
	whatis("SGLang ${SGLANG_VERSION} with ROCm support (bound to ${PYTORCH_MODULE_RESOLVED}, torch ${TORCH_VERSION}, ${AMDGPU_GFXMODEL})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- SGLang builds on the pytorch module (torch/triton). Load the EXACT
	-- pytorch it was compiled against: its ROCm kernels are ABI-locked to it.
	prereq("${ROCM_MODULE_NAME}")
	load("${PYTORCH_MODULE_RESOLVED}")

	prepend_path("PYTHONPATH","${SGLANG_SITE}")
	prepend_path("PATH","${SGLANG_BINDIR}")
${AITER_MODULE_BLOCK}
${APU_MODULE_BLOCK}
EOF

# ── Refresh the Lmod spider cache timestamp (mirrors vllm_setup.sh) ────
LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null \
      && echo "[sglang] bumped Lmod cache timestamp; sglang/${SGLANG_MODULE_TOKEN} is loadable now." \
      || echo "[sglang] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load sglang/${SGLANG_MODULE_TOKEN}"
else
   echo "[sglang] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load sglang/${SGLANG_MODULE_TOKEN}"
fi

echo ""
echo "[sglang] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} ${PYTORCH_MODULE_RESOLVED} sglang/${SGLANG_MODULE_TOKEN}"
echo ""
