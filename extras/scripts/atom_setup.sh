#!/bin/bash

# Capture this script's absolute path BEFORE any cd, for the git-provenance
# block that stamps the modulefile.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

set -eo pipefail

# ─────────────────────────────────────────────────────────────────────
# ATOM (ROCm/ATOM, "AiTer Optimized Model") setup for AMD CDNA GPUs, in the
# HPCTrainingDock leaf style. Mirrors sglang_setup.sh / instella_setup.sh's
# SAFE install model: it layers on the `pytorch` module (never ships its own
# torch), hard-pins the module's torch/triton in a constraints file, resolves
# the dependency delta with a dry-run, and installs ONLY that delta into a
# per-(atom,pytorch) PREFIX with --no-deps --ignore-installed so the shared
# pytorch module is never mutated.
#
# WHAT THIS MODULE IS:
#   * ATOM is a lightweight vLLM-like LLM INFERENCE/serving engine built on
#     AMD's AITER kernels (ASM/CK/Triton), with an OpenAI-compatible server.
#   * It is BOUND to a concrete pytorch module and to AITER, both ABI-locked
#     to that torch and compiled for the node's gfx arch, exactly like sglang.
#   * REUSES the pytorch module's triton for the AITER build
#     (AITER_USE_SYSTEM_TRITON=1) instead of building a second triton.
#
# Install layout (keyed on BOTH versions so pairs coexist, like sglang):
#   prefix     : /opt/rocmplus-${ROCM_VERSION}/atom-v${ATOM_VERSION}-pt${PYTORCH_VERSION}
#   modulefile : ${MODULE_PATH}/${ATOM_VERSION}-pt${PYTORCH_VERSION}.lua
# Lands in the ROCmPlus-AI overlay the rocm module adds to MODULEPATH, so
# atom/<ver> is only visible once the matching rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

ROCM_VERSION=7.2.4
BUILD_ATOM=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/atom
# Version LABEL for the module name + install dir; ATOM_REF is the git tag
# actually built. Upstream publishes release tags (v0.1.2 .. v0.1.8); pin the
# latest release (mirrors primus/TraceLens pinning a released version).
ATOM_VERSION=0.1.8
ATOM_REPO="https://github.com/ROCm/ATOM.git"
ATOM_REF="v0.1.8"
# AITER: AMD optimized kernels ATOM is built on. Built from source for the
# node gfx and ABI-locked to the module torch, reusing the module triton.
WITH_AITER=1
AITER_REPO="https://github.com/ROCm/aiter.git"
AITER_REF="v0.1.9.post1"
PYTORCH_MODULE="pytorch"
PYTORCH_VERSION=""
# Hard-pin these (ABI/ROCm-compiled) to the pytorch module's EXACT version so
# the dep resolve can never plan a different torch/triton, and so the
# separately-built AITER is never pulled from PyPI.
PROTECTED_PACKAGES="torch torchvision torchaudio triton pytorch-triton-rocm flash-attn flash-attention aotriton deepspeed xformers aiter amd-aiter"
AMDGPU_GFXMODEL_INPUT=""
ATOM_PATH=""
ATOM_PATH_INPUT=""
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
   echo "  --build-atom [ 0|1 ]             default $BUILD_ATOM"
   echo "  --atom-version [ VER ]           ATOM version LABEL (keys install dir + module); default $ATOM_VERSION"
   echo "  --atom-ref [ REF ]               git tag/branch/commit to build; default $ATOM_REF"
   echo "  --atom-repo [ URL ]              git repo; default $ATOM_REPO"
   echo "  --with-aiter [ 0|1 ]             build AITER into the prefix (REQUIRED by ATOM); default $WITH_AITER"
   echo "  --aiter-repo [ URL ]             default $AITER_REPO"
   echo "  --aiter-ref [ REF ]              default $AITER_REF"
   echo "  --pytorch-module [ MOD ]         pytorch module to load; default $PYTORCH_MODULE"
   echo "  --pytorch-version [ VER ]        bound pytorch version; keys the install dir + modulefile. Empty -> resolved from the loaded token."
   echo "  --protect-packages [ names ]     extra ABI/ROCm packages to hard-pin from the pytorch module"
   echo "  --amdgpu-gfxmodel [ GFX ]        default autodetected via rocminfo"
   echo "  --rocm-version [ VER ]           default $ROCM_VERSION"
   echo "  --install-path [ DIR ]           parent dir; install -> \${DIR}/atom-v\${ATOM_VERSION}-pt\${PYTORCH_VERSION}"
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
      "--build-atom")        shift; BUILD_ATOM=${1}; reset-last ;;
      "--atom-version")      shift; ATOM_VERSION=${1}; reset-last ;;
      "--atom-ref")          shift; ATOM_REF=${1}; reset-last ;;
      "--atom-repo")         shift; ATOM_REPO=${1}; reset-last ;;
      "--with-aiter")        shift; WITH_AITER=${1}; reset-last ;;
      "--aiter-repo")        shift; AITER_REPO=${1}; reset-last ;;
      "--aiter-ref")         shift; AITER_REF=${1}; reset-last ;;
      "--pytorch-module")    shift; PYTORCH_MODULE=${1}; reset-last ;;
      "--pytorch-version")   shift; PYTORCH_VERSION=${1}; reset-last ;;
      "--protect-packages")  shift; PROTECTED_PACKAGES="${PROTECTED_PACKAGES} ${1}"; reset-last ;;
      "--amdgpu-gfxmodel")   shift; AMDGPU_GFXMODEL_INPUT=${1}; reset-last ;;
      "--rocm-version")      shift; ROCM_VERSION=${1}; reset-last ;;
      "--install-path")      shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version") shift; ATOM_PATH_INPUT=${1}; reset-last ;;
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

# ── BUILD_ATOM=0 short-circuit ────────────────────────────────────────
MISSING_PREREQ_RC=42
NOOP_RC=43
if [ "${BUILD_ATOM}" = "0" ]; then
   echo "[atom BUILD_ATOM=0] operator opt-out; skipping (no build)."
   echo "  Use --build-atom 1 to build ATOM."
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
   echo "[atom missing-prereq] could not 'module load ${PYTORCH_MODULE}' after"
   echo "  '${ROCM_MODULE_NAME}'. Build the pytorch module first (pytorch_setup.sh)"
   echo "  or pass --pytorch-module. Skipping ATOM."
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
[ -z "${TORCH_VERSION}" ] && send-error "could not import torch from '${PYTORCH_MODULE}'; cannot build ATOM."
python3 - <<'PY' || send-error "the pytorch module's torch is not a ROCm build (torch.version.hip is None); refusing to build ATOM."
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
# AITER's build takes a SINGLE gfx target; take the first gfx (like sglang).
PYTORCH_ROCM_ARCH=$(echo "${AMDGPU_GFXMODEL}" | tr ',;' '  ' | sed -e 's/:[^ ]*//g')
AOT_ARCH=$(echo "${PYTORCH_ROCM_ARCH}" | awk '{print $1}')
[ -z "${AOT_ARCH}" ] && AOT_ARCH="gfx942"

# APU gating for the modulefile warnings.
IS_APU=0
rocminfo 2>/dev/null | grep -q "MI300A" && IS_APU=1

# Finalize prefix now that both versions are known.
ATOM_DIRNAME="atom-v${ATOM_VERSION}-pt${PYTORCH_VERSION}"
ATOM_MODULE_TOKEN="${ATOM_VERSION}-pt${PYTORCH_VERSION}"
if [ -n "${ATOM_PATH_INPUT}" ]; then
   ATOM_PATH="${ATOM_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   ATOM_PATH="${ROCMPLUS_PATH_INPUT}/${ATOM_DIRNAME}"
else
   ATOM_PATH="/opt/rocmplus-${ROCM_VERSION}/${ATOM_DIRNAME}"
fi

# ── Install-path sudo (write-probe of nearest existing ancestor) ──────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :
else
   _iprobe="$(dirname "${ATOM_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .atom-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "atom: install ancestor ${_iprobe} is user-writable; not using sudo for install"
   else
      SUDO="sudo"
      echo "atom: install ancestor ${_iprobe} not user-writable; using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[atom --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${ATOM_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${ATOM_MODULE_TOKEN}.lua"
fi
if [ -d "${ATOM_PATH}" ]; then
   echo ""
   echo "[atom existence-check] already installed; skipping (${ATOM_PATH}). Pass --replace 1 to rebuild."
   echo ""
   exit ${NOOP_RC}
fi

# ── Consolidated EXIT trap (build-dir + fail-cleanup) ─────────────────
_atom_on_exit() {
   local rc=$?
   [ -n "${ATOM_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${ATOM_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[atom fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${ATOM_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${ATOM_MODULE_TOKEN}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[atom fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _atom_on_exit EXIT

echo ""
echo "====================================="
echo " Installing ATOM (ROCm, from source)"
echo " ATOM version:      $ATOM_VERSION  (ref ${ATOM_REF})"
echo " AITER:             ${AITER_REF} (build=${WITH_AITER}, arch ${AOT_ARCH}, system-triton)"
echo " Install directory: $ATOM_PATH"
echo " Module name:       atom/$ATOM_MODULE_TOKEN"
echo " ROCm module:       $ROCM_MODULE_NAME"
echo " Pytorch module:    $PYTORCH_MODULE_RESOLVED (torch $TORCH_VERSION)"
echo "====================================="
echo ""

if ! ${SUDO} mkdir -p "${ATOM_PATH}"; then
   send-error "could not create install dir ${ATOM_PATH} (SUDO='${SUDO}'). Re-run as root or with passwordless sudo."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${ATOM_PATH}"
fi

ATOM_BUILD_ROOT=$(mktemp -d -t atom-build.XXXXXX)
cd "${ATOM_BUILD_ROOT}"

# Harden pip against a polluted NFS-HOME pip config (mirrors sglang_setup.sh).
export PIP_CONFIG_FILE=/dev/null
export PIP_INDEX_URL="https://pypi.org/simple"
export MAX_JOBS="${MAX_JOBS:-$(nproc)}"

# ── Build a constraints file pinning the module's ABI/ROCm packages ───
CONSTRAINTS="${ATOM_BUILD_ROOT}/constraints.txt"
printf '%s\n' "${PYTORCH_MODULE_PYPATHS}" > "${ATOM_BUILD_ROOT}/pytorch_pypaths.txt"
python3 - "${ATOM_BUILD_ROOT}/pytorch_pypaths.txt" "${CONSTRAINTS}" "${PROTECTED_PACKAGES}" <<'PY'
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
echo "atom: hard-pinned ABI/ROCm packages (sourced only from the pytorch module):"
sed -e 's/^/  /' "${CONSTRAINTS}"

# ── AITER (REQUIRED): ATOM is built on AITER kernels ──────────────────
# Reuse the module triton (AITER_USE_SYSTEM_TRITON=1); build a wheel for the
# node gfx with --no-build-isolation (module torch at build time) and install
# into the PREFIX only. Mirrors the sglang_setup.sh AITER block, but FATAL
# here because ATOM cannot run without aiter.
if [ "${WITH_AITER}" = "1" ]; then
   case ";${PYTORCH_ROCM_ARCH// /;};" in
      *";gfx942;"*|*";gfx950;"*|*";gfx90a;"*)
         echo "atom: building AITER ${AITER_REF} into the prefix (arch ${AOT_ARCH}, system triton)"
         AITER_SRC="${ATOM_BUILD_ROOT}/aiter-src"
         _aiter_branch_args=()
         [ -n "${AITER_REF}" ] && _aiter_branch_args=(--branch "${AITER_REF}")
         git clone --depth 1 "${_aiter_branch_args[@]}" --recurse-submodules --shallow-submodules \
            "${AITER_REPO}" "${AITER_SRC}" \
            || send-error "AITER clone failed (${AITER_REPO}@${AITER_REF})."
         AITER_WH="${ATOM_BUILD_ROOT}/aiter-wheelhouse"; mkdir -p "${AITER_WH}"
         GPU_ARCHS="${AOT_ARCH}" AITER_USE_SYSTEM_TRITON=1 PYTORCH_ROCM_ARCH="${AOT_ARCH}" MAX_JOBS="${MAX_JOBS}" \
            pip3 wheel -v --no-build-isolation --no-deps --wheel-dir "${AITER_WH}" "${AITER_SRC}" \
            || send-error "AITER wheel build failed; see log above (ROCm AITER is GPU/arch-sensitive)."
         AITER_WHEEL="$(find "${AITER_WH}" -maxdepth 1 \( -name 'aiter-*.whl' -o -name 'amd_aiter-*.whl' \) 2>/dev/null | head -1)"
         [ -z "${AITER_WHEEL}" ] && send-error "AITER build produced no wheel in ${AITER_WH}."
         echo "atom: installing AITER wheel into the prefix"
         pip3 install --prefix="${ATOM_PATH}" --no-deps --ignore-installed --no-warn-script-location \
            "${AITER_WHEEL}" || send-error "installing the AITER wheel failed."
         unset _aiter_branch_args ;;
      *)
         send-error "ATOM requires AITER, but PYTORCH_ROCM_ARCH='${PYTORCH_ROCM_ARCH}' has no aiter-supported gfx (gfx90a/gfx942/gfx950)." ;;
   esac
else
   echo "atom: WARNING --with-aiter 0; ATOM will not run without AITER unless it is already on PYTHONPATH."
fi

# Make the just-installed AITER importable during the ATOM dep-resolve/build
# (so the resolver sees aiter satisfied and ATOM's build can import it).
AITER_SITE="$(find "${ATOM_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
[ -n "${AITER_SITE}" ] && export PYTHONPATH="${AITER_SITE}:${PYTHONPATH:-}"

# ── Fetch ATOM source at the pinned ref (recursive: AITER submodule) ──
ATOM_SRC="${ATOM_BUILD_ROOT}/ATOM"
echo "atom: fetching ${ATOM_REPO}@${ATOM_REF}"
if ! git clone --depth 1 --branch "${ATOM_REF}" --recurse-submodules --shallow-submodules \
      "${ATOM_REPO}" "${ATOM_SRC}" 2>/dev/null; then
   # --branch fails for a bare commit SHA; fall back to full clone + checkout.
   rm -rf "${ATOM_SRC}"
   git clone --recurse-submodules "${ATOM_REPO}" "${ATOM_SRC}"
   ( cd "${ATOM_SRC}" && git checkout "${ATOM_REF}" && git submodule update --init --recursive )
fi

# ── Resolve the dependency delta against the LIVE module env ──────────
# Dry-run honoring the pytorch module + the hard-pin constraints (incl. a
# requirements.txt if ATOM ships one); filter out the protected ABI packages
# (torch family, aiter) and atom itself, then install only the remaining
# closure into the prefix with --no-deps.
REPORT="${ATOM_BUILD_ROOT}/resolve-report.json"
DEP_REQS="${ATOM_BUILD_ROOT}/dep-closure.txt"
_atom_targets=("${ATOM_SRC}")
[ -f "${ATOM_SRC}/requirements.txt" ] && _atom_targets+=(-r "${ATOM_SRC}/requirements.txt")
echo "atom: resolving dependency closure (dry-run; honors the pytorch module, never writes)"
pip3 install --dry-run --report "${REPORT}" \
   --constraint "${CONSTRAINTS}" \
   "${_atom_targets[@]}" \
   || send-error "dependency resolution (dry-run) failed; see log above (often a real torch/ABI conflict)."
python3 - "${REPORT}" "${DEP_REQS}" "${PROTECTED_PACKAGES}" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
protected = set(x.lower().replace("_", "-") for x in sys.argv[3].split())
skip = protected | {"atom"}
reqs = []
for item in rep.get("install", []):
    md = item.get("metadata", {})
    name = (md.get("name") or "").strip()
    ver = (md.get("version") or "").strip()
    if not name or name.lower().replace("_", "-") in skip:
        continue
    reqs.append(f"{name}=={ver}")
open(sys.argv[2], "w").write("\n".join(sorted(reqs)) + ("\n" if reqs else ""))
print(f"atom: dependency closure = {len(reqs)} package(s) to install into the prefix")
PY

if [ -s "${DEP_REQS}" ]; then
   echo "atom: installing resolved deps into the prefix (--no-deps --ignore-installed; module untouched)"
   pip3 install --prefix="${ATOM_PATH}" --no-deps --ignore-installed --no-warn-script-location \
      --constraint "${CONSTRAINTS}" \
      -r "${DEP_REQS}" || send-error "installing the resolved dependency closure failed; see log above."
fi

# ── Install the atom package itself into the PREFIX ───────────────────
# Build atom WITH build isolation (unlike aiter): atom is pure-python packaging
# (build-system.requires = setuptools/wheel/setuptools_scm only, no torch), so
# isolation lets pip pull a current setuptools instead of the pytorch module's.
# The module setuptools varies per torch version and older ones (e.g. 75.8.2 on
# pytorch/2.7.1) reject atom's PEP 639 `license = "MIT"` string ("project.license
# must be valid exactly by one definition"); isolation makes all torch bindings
# robust against that drift.
echo "atom: installing the atom package into the prefix (--no-deps, build-isolated; from source)"
pip3 install --prefix="${ATOM_PATH}" --no-deps --ignore-installed \
   --no-warn-script-location "${ATOM_SRC}" \
   || send-error "installing the atom package failed; see log above."

# Resolve the prefix site/bin dirs for the modulefile.
ATOM_SITE="$(find "${ATOM_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
[ -z "${ATOM_SITE}" ] && send-error "atom install produced no site/dist-packages under ${ATOM_PATH}; build likely failed."
ATOM_BINDIR="${ATOM_SITE%/lib/*}/bin"
echo "atom: installed into prefix ${ATOM_PATH} (site: ${ATOM_SITE})"

# Normalize ownership/permissions.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${ATOM_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${ATOM_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
fi
[[ "${USER}" != "root" ]] && ${SUDO} chmod go-w "${ATOM_PATH}" 2>/dev/null || true

cd /

# ── Modulefile ────────────────────────────────────────────────────────
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .atom-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
      echo "atom: module ancestor ${_mprobe} is user-writable; not using sudo for modulefile"
   else
      PKG_SUDO_MOD="sudo"
      echo "atom: module ancestor ${_mprobe} not user-writable; using sudo for modulefile"
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
-- KV cache / model so serving fits the shared pool; run ONLY in a GPU
-- allocation (never fe1).
LUA
)
else
   APU_MODULE_BLOCK=""
fi

cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${ATOM_MODULE_TOKEN}.lua
	whatis("ATOM ${ATOM_VERSION} -- AiTer Optimized Model: lightweight ROCm LLM inference/serving engine (bound to ${PYTORCH_MODULE_RESOLVED}, torch ${TORCH_VERSION}, ${AMDGPU_GFXMODEL})")
	whatis("Upstream: ${ATOM_REPO} (ref ${ATOM_REF}); AITER ${AITER_REF}")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	-- ATOM builds on the pytorch module (torch/triton) and AITER kernels
	-- compiled against it: its ROCm kernels are ABI-locked to that torch.
	prereq("${ROCM_MODULE_NAME}")
	load("${PYTORCH_MODULE_RESOLVED}")

	local base = "${ATOM_PATH}"
	prepend_path("PYTHONPATH","${ATOM_SITE}")
	prepend_path("PATH","${ATOM_BINDIR}")
	setenv("ATOM_HOME", base)
	-- Suppress AITER kernel log flooding during server startup (per ATOM docs).
	setenv("AITER_LOG_LEVEL","WARNING")
	setenv("GPU_ARCHS","${AOT_ARCH}")
	-- AITER JIT-compiles kernels on first use and writes a build tree. The
	-- install prefix is read-only (root-owned) for normal users, so redirect
	-- AITER's JIT dir to a per-user, per-binding writable location; otherwise
	-- aiter tries to mkdir inside its read-only package dir and import fails.
	setenv("AITER_JIT_DIR", pathJoin(os.getenv("HOME") or "/tmp", ".aiter", "atom-${ATOM_MODULE_TOKEN}"))
${APU_MODULE_BLOCK}

	if (mode() == "load") then
	  LmodMessage("")
	  LmodMessage("#  ATOM ${ATOM_VERSION}: OpenAI-compatible LLM server. Run ONLY in a GPU allocation, e.g.:")
	  LmodMessage("#    python -m atom.entrypoints.openai_server --model <model> --kv_cache_dtype fp8")
	  LmodMessage("#  Simple inference: python -m atom.examples.simple_inference --model <model>")
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
      && echo "[atom] bumped Lmod cache timestamp; atom/${ATOM_MODULE_TOKEN} is loadable now." \
      || echo "[atom] WARNING could not touch ${LMOD_TS_FILE}; load with: module --ignore_cache load atom/${ATOM_MODULE_TOKEN}"
else
   echo "[atom] NOTE could not locate the Lmod cache timestamp; if load reports unknown, use: module --ignore_cache load atom/${ATOM_MODULE_TOKEN}"
fi

echo ""
echo "[atom] installed. Load with:"
echo "  module load ${ROCM_MODULE_NAME} ${PYTORCH_MODULE_RESOLVED} atom/${ATOM_MODULE_TOKEN}"
echo ""
