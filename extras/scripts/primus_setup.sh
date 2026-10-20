#!/bin/bash

# Capture this script's absolute path BEFORE any cd, so the inline
# git-provenance block lower down can resolve the script in the repo
# even after the build has cd'd into a temp dir (mirrors vllm_setup.sh).
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

# ─────────────────────────────────────────────────────────────────────
# Primus (AMD-AGI) setup -- a CLI-LAUNCHER module, not a from-source build.
#
# Unlike vllm_setup.sh (which compiles a wheel against the pytorch module),
# Primus is CONTAINER-FIRST: the heavy training stack (Megatron-LM, Transformer
# Engine, FlashAttention, Primus-Turbo/AITER, RCCL, ...) lives inside AMD's
# published `rocm/primus:<tag>` image. The pip wheel ships ONLY the primus-cli
# launcher plus release-pinned backend SOURCES (fetched by `primus-cli deps
# sync`). So this module:
#   * installs the primus-cli wheel (--no-deps) into a versioned prefix,
#   * syncs the release-pinned backend sources next to it,
#   * pulls the matching image into an Apptainer SIF -- AAC6 has NO Docker, so
#     `primus-cli container` (docker-bound) is unusable here; batch jobs run the
#     SIF under Apptainer and invoke `primus-cli direct` INSIDE it.
#
# Install layout (keyed on the Primus wheel version so releases coexist):
#   install dir : /opt/rocmplus-${ROCM_VERSION}/primus-v${PRIMUS_VERSION}
#   SIF         : ${SIF_DIR}/primus-${PRIMUS_IMAGE_TAG}.sif  (shared on NFS)
#   modulefile  : ${MODULE_PATH}/${PRIMUS_VERSION}.lua  (module primus/<ver>)
# The modulefile lands in the rocmplus-<rocm> overlay the rocm module adds to
# MODULEPATH, so primus/<ver> is only visible once the matching rocm is loaded.
# ─────────────────────────────────────────────────────────────────────

# Variables controlling setup process
ROCM_VERSION=10.1.0
BUILD_PRIMUS=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/primus
AMDGPU_GFXMODEL_INPUT=""
# Primus wheel version (GitHub Pages index) and the matching published image
# tag. Kept separate because the wheel is e.g. 26.8.0 while the image is v26.8.
PRIMUS_VERSION="26.8.0"
PRIMUS_IMAGE_TAG="v26.8"
PRIMUS_IMAGE="rocm/primus"
PRIMUS_INDEX="https://amd-agi.github.io/Primus/simple/"
# Pull the training image into a shared Apptainer SIF (non-fatal: a multi-GB
# pull that needs apptainer + egress; set 0 to install only the CLI and let an
# admin stage the SIF later).
PULL_SIF=1
SIF_DIR=/shareddata/apptainer/primus
# Pre-fetch the release-pinned backend sources (Megatron-LM/TorchTitan/etc.)
# so `primus-cli direct` does not git-clone them on first run. Non-fatal.
SYNC_DEPS=1
# Default HF cache/weights location, co-located with the team's models on
# /shareddata (sibling of the ollama/vllm HF_HOME default).
HF_HOME_DEFAULT=/shareddata/HF_Models
# Versioned install dir parent; --install-path is treated as a PARENT (the
# rocmplus root) and the leaf appends primus-v${PRIMUS_VERSION} (mirrors the
# migrated --install-path semantics vllm/hypre use).
PRIMUS_PATH=""
PRIMUS_PATH_INPUT=""
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
   echo "  --build-primus [ 0|1 ] set to 1 to install Primus, default is $BUILD_PRIMUS"
   echo "  --primus-version [ PRIMUS_VERSION ] Primus wheel version, default $PRIMUS_VERSION"
   echo "  --primus-image-tag [ PRIMUS_IMAGE_TAG ] published image tag to pull as a SIF, default $PRIMUS_IMAGE_TAG"
   echo "  --primus-image [ PRIMUS_IMAGE ] image repo, default $PRIMUS_IMAGE"
   echo "  --primus-index [ PRIMUS_INDEX ] pip index for the wheel, default $PRIMUS_INDEX"
   echo "  --pull-sif [ 0|1 ] pull the image into an Apptainer SIF (non-fatal), default $PULL_SIF"
   echo "  --sif-dir [ SIF_DIR ] shared dir for the SIF, default $SIF_DIR"
   echo "  --sync-deps [ 0|1 ] pre-fetch release-pinned backend sources (non-fatal), default $SYNC_DEPS"
   echo "  --hf-home [ HF_HOME_DEFAULT ] default HF_HOME baked into the modulefile, default $HF_HOME_DEFAULT"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected, comma separated"
   echo "  --install-path [ ROCMPLUS_PATH_INPUT ] parent dir; install goes to \${ROCMPLUS_PATH}/primus-v\${PRIMUS_VERSION}"
   echo "  --install-path-no-version [ PRIMUS_PATH ] full leaf install dir (wins over --install-path)"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --replace [ 0|1 ] remove prior install + modulefile before installing, default $REPLACE"
   echo "  --keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of a partial install on failure, default $KEEP_FAILED_INSTALLS"
   echo "  --help: print this usage information"
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
      "--build-primus")
          shift; BUILD_PRIMUS=${1}; reset-last ;;
      "--primus-version")
          shift; PRIMUS_VERSION=${1}; reset-last ;;
      "--primus-image-tag")
          shift; PRIMUS_IMAGE_TAG=${1}; reset-last ;;
      "--primus-image")
          shift; PRIMUS_IMAGE=${1}; reset-last ;;
      "--primus-index")
          shift; PRIMUS_INDEX=${1}; reset-last ;;
      "--pull-sif")
          shift; PULL_SIF=${1}; reset-last ;;
      "--sif-dir")
          shift; SIF_DIR=${1}; reset-last ;;
      "--sync-deps")
          shift; SYNC_DEPS=${1}; reset-last ;;
      "--hf-home")
          shift; HF_HOME_DEFAULT=${1}; reset-last ;;
      "--amdgpu-gfxmodel")
          shift; AMDGPU_GFXMODEL_INPUT=${1}; reset-last ;;
      "--install-path")
          shift; ROCMPLUS_PATH_INPUT=${1}; reset-last ;;
      "--install-path-no-version")
          shift; PRIMUS_PATH_INPUT=${1}; reset-last ;;
      "--module-path")
          shift; MODULE_PATH=${1}; reset-last ;;
      "--rocm-version")
          shift; ROCM_VERSION=${1}; reset-last ;;
      "--replace")
          shift; REPLACE=${1}; reset-last ;;
      "--keep-failed-installs")
          shift; KEEP_FAILED_INSTALLS=${1}; reset-last ;;
      "--help")
          usage; exit 0 ;;
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}" ;;
      *)
          last ${1} ;;
   esac
   n=$((${n} + 1))
   shift
done

# ── BUILD_PRIMUS=0 short-circuit: operator opt-out (see vllm_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_PRIMUS}" = "0" ]; then
   echo "[primus BUILD_PRIMUS=0] operator opt-out; skipping."
   echo "  Use --build-primus 1 to install Primus."
   exit ${NOOP_RC}
fi

# Bring `module` into scope for standalone invocation (used for optional
# rocminfo-based APU detection; Primus itself needs no module to pip-install).
if [ -f /etc/profile.d/lmod.sh ]; then
   source /etc/profile.d/lmod.sh
fi

# gfx model detection. Stderr-silenced + `|| true`: rocminfo can fail when the
# SDK is built against a newer glibc than the host, and would kill the script
# under pipefail (mirrors vllm_setup.sh).
if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
fi

# Primus kernels in the image target gfx942 (MI300/MI3xx). gfx90a (MI250) is
# not a supported SKU -- warn but do not fail, since the image is arch-fixed.
case ";${AMDGPU_GFXMODEL};" in
   *gfx90a*) echo "[primus] WARNING gfx90a (MI250) detected: Primus images target gfx942 and MI250 is not a supported Primus SKU (no FP8/MXFP4, gfx942-only kernels). The module installs but is not expected to run on MI250." ;;
esac

# ── APU vs discrete-GPU gating (see vllm_setup.sh IS_APU) ─────────────
IS_APU=0
if rocminfo 2>/dev/null | grep -q "MI300A"; then
   IS_APU=1
fi

# Finalize install path (install-path treated as PARENT, like migrated leaves).
PRIMUS_DIRNAME="primus-v${PRIMUS_VERSION}"
if [ -n "${PRIMUS_PATH_INPUT}" ]; then
   PRIMUS_PATH="${PRIMUS_PATH_INPUT}"
elif [ -n "${ROCMPLUS_PATH_INPUT}" ]; then
   PRIMUS_PATH="${ROCMPLUS_PATH_INPUT}/${PRIMUS_DIRNAME}"
else
   PRIMUS_PATH="/opt/rocmplus-${ROCM_VERSION}/${PRIMUS_DIRNAME}"
fi

# ── Install-path sudo (write-probe of nearest existing ancestor) ──────
# Identical rationale to vllm_setup.sh: decide sudo ONCE via a real write
# probe rather than the fragile `[ -w ]` test on a root-owned NFS parent.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   SUDO=""
elif [ -z "${SUDO}" ]; then
   :  # already cleared (e.g. Singularity)
else
   _iprobe="$(dirname "${PRIMUS_PATH}")"
   while [ ! -e "${_iprobe}" ]; do _iprobe="$(dirname "${_iprobe}")"; done
   _itest=$(mktemp --tmpdir="${_iprobe}" .primus-inst-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_itest}" ] && [ -f "${_itest}" ]; then
      rm -f "${_itest}"; SUDO=""
      echo "primus: install ancestor ${_iprobe} is user-writable; not using sudo for install"
   else
      SUDO="sudo"
      echo "primus: install ancestor ${_iprobe} not user-writable; using sudo for install"
   fi
   unset _iprobe _itest
fi

# ── --replace + existence guard ──────────────────────────────────────
if [ "${REPLACE}" = "1" ]; then
   echo "[primus --replace 1] removing prior install + modulefile if present"
   ${SUDO} rm -rf "${PRIMUS_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${PRIMUS_VERSION}.lua"
fi
if [ -d "${PRIMUS_PATH}" ]; then
   echo "[primus existence-check] already installed; skipping (--replace 1 to reinstall)."
   echo "  install: ${PRIMUS_PATH}"
   exit ${NOOP_RC}
fi

# ── EXIT trap: fail-cleanup + attempted-but-failed marker (see vllm) ──
_primus_on_exit() {
   local rc=$?
   [ -n "${PRIMUS_APT_SCRATCH:-}" ] && rm -rf "${PRIMUS_APT_SCRATCH}"
   if [ -n "${PRIMUS_PATH:-}" ]; then
      local _fail_marker="$(dirname "${PRIMUS_PATH}")/primus.FAILED"
      if [ ${rc} -ne 0 ]; then
         ${SUDO:-sudo} mkdir -p "$(dirname "${PRIMUS_PATH}")" 2>/dev/null || true
         ${SUDO:-sudo} tee "${_fail_marker}" >/dev/null 2>/dev/null <<MARKER_EOF || true
FAILED package: primus
ROCm token:   ${ROCM_VERSION:-unknown}
Primus:       ${PRIMUS_VERSION:-unknown} (image ${PRIMUS_IMAGE}:${PRIMUS_IMAGE_TAG})
Date:         $(date -u +%Y-%m-%dT%H:%M:%SZ)
Setup script: primus_setup.sh (EXIT-trap fail marker)
Reason:       install exited rc=${rc}; partial install wiped (see log_primus_*.txt).
MARKER_EOF
      else
         ${SUDO:-sudo} rm -f "${_fail_marker}"
      fi
   fi
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[primus fail-cleanup] rc=${rc}: removing partial install + modulefile"
      ${SUDO:-sudo} rm -rf "${PRIMUS_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${PRIMUS_VERSION}.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[primus fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts"
   fi
   return ${rc}
}
trap _primus_on_exit EXIT

echo ""
echo "====================================="
echo " Installing Primus (CLI launcher + SIF)"
echo " Primus wheel:      $PRIMUS_VERSION"
echo " Image (SIF):       $PRIMUS_IMAGE:$PRIMUS_IMAGE_TAG"
echo " Install directory: $PRIMUS_PATH"
echo " Module directory:  $MODULE_PATH"
echo " Module name:       primus/$PRIMUS_VERSION"
echo " gfx / APU:         ${AMDGPU_GFXMODEL:-unknown} / IS_APU=$IS_APU"
echo "====================================="
echo ""

if ! ${SUDO} mkdir -p "${PRIMUS_PATH}"; then
   send-error "could not create install dir ${PRIMUS_PATH} (SUDO='${SUDO}'); re-run as root, with passwordless sudo, or point --install-path at a writable tree."
fi
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} chmod -R a+w "${PRIMUS_PATH}"
fi

# ── Install the primus-cli wheel into the prefix (--no-deps) ──────────
# Per the Primus docs, the wheel carries ONLY the CLI; the training stack
# comes from the image. --no-deps so pip never drags a torch/numpy into the
# prefix. Harden against a polluted ~/.config/pip/pip.conf on shared NFS
# (same footgun handled in vllm_setup.sh).
export PIP_CONFIG_FILE=/dev/null
echo "primus: installing wheel primus==${PRIMUS_VERSION} (--no-deps) from ${PRIMUS_INDEX}"
if ! pip3 install --prefix="${PRIMUS_PATH}" --no-deps --no-warn-script-location \
      "primus==${PRIMUS_VERSION}" --extra-index-url "${PRIMUS_INDEX}"; then
   send-error "pip install of primus==${PRIMUS_VERSION} failed; see log above."
fi

# Resolve the prefix's site dir + bin dir (Debian posix_local vs posix_prefix).
PRIMUS_SITE="$(find "${PRIMUS_PATH}" -type d \( -name site-packages -o -name dist-packages \) 2>/dev/null | head -1)"
[ -z "${PRIMUS_SITE}" ] && send-error "no site/dist-packages under ${PRIMUS_PATH}; wheel install likely failed."
PRIMUS_BINDIR="${PRIMUS_SITE%/lib/*}/bin"
echo "primus: installed into ${PRIMUS_PATH} (site: ${PRIMUS_SITE}, bin: ${PRIMUS_BINDIR})"

# ── Pre-fetch release-pinned backend sources (non-fatal) ──────────────
PRIMUS_THIRD_PARTY="${PRIMUS_PATH}/third_party"
if [ "${SYNC_DEPS}" = "1" ]; then
   echo "primus: syncing release-pinned backend sources into ${PRIMUS_THIRD_PARTY} (non-fatal)"
   if ! PATH="${PRIMUS_BINDIR}:${PATH}" PYTHONPATH="${PRIMUS_SITE}:${PYTHONPATH}" \
         primus-cli deps sync --dir "${PRIMUS_THIRD_PARTY}"; then
      echo "primus: WARNING 'primus-cli deps sync' failed; sources will be fetched on first run instead."
   fi
else
   echo "primus: --sync-deps 0; backend sources will be fetched on first 'primus-cli direct' run."
fi

# ── Pull the training image into a shared Apptainer SIF (non-fatal) ───
# AAC6 runs batch under Apptainer (no Docker), so this SIF is how the stack is
# actually executed. Skipped (with a notice) when apptainer is unavailable at
# install time; an admin can stage it later with the printed command.
PRIMUS_SIF="${SIF_DIR}/primus-${PRIMUS_IMAGE_TAG}.sif"
if [ "${PULL_SIF}" = "1" ]; then
   _apt_bin=""
   command -v apptainer >/dev/null 2>&1 && _apt_bin=apptainer
   [ -z "${_apt_bin}" ] && command -v singularity >/dev/null 2>&1 && _apt_bin=singularity
   if [ -z "${_apt_bin}" ]; then
      echo "primus: WARNING no apptainer/singularity on PATH; skipping SIF pull."
      echo "        Stage it later with: apptainer pull ${PRIMUS_SIF} docker://${PRIMUS_IMAGE}:${PRIMUS_IMAGE_TAG}"
   elif [ -f "${PRIMUS_SIF}" ]; then
      echo "primus: SIF already present at ${PRIMUS_SIF}; not re-pulling."
   else
      echo "primus: pulling ${PRIMUS_IMAGE}:${PRIMUS_IMAGE_TAG} into ${PRIMUS_SIF} via ${_apt_bin} (multi-GB; non-fatal)"
      # The pull runs as the invoking user, so the SIF dir must be user-writable
      # (a sudo-created root-owned dir would make the pull fail).
      if ! mkdir -p "${SIF_DIR}" 2>/dev/null; then
         ${SUDO} mkdir -p "${SIF_DIR}" && ${SUDO} chown "$(id -u):$(id -g)" "${SIF_DIR}" || true
      fi
      # Layer cache + squashfs scratch for a multi-GB image would otherwise land
      # in $HOME/.apptainer on NFS; keep them on node-local disk and discard.
      if [ -z "${APPTAINER_CACHEDIR:-}" ] || [ -z "${APPTAINER_TMPDIR:-}" ]; then
         PRIMUS_APT_SCRATCH=$(mktemp -d -p "${PRIMUS_SCRATCH_ROOT:-/var/tmp}" primus-apptainer.XXXXXX)
         export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-${PRIMUS_APT_SCRATCH}/cache}"
         export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-${PRIMUS_APT_SCRATCH}/tmp}"
         mkdir -p "${APPTAINER_CACHEDIR}" "${APPTAINER_TMPDIR}"
      fi
      if ${_apt_bin} pull "${PRIMUS_SIF}" "docker://${PRIMUS_IMAGE}:${PRIMUS_IMAGE_TAG}"; then
         chmod a+r "${PRIMUS_SIF}" 2>/dev/null || true
      else
         rm -f "${PRIMUS_SIF}"
         echo "primus: WARNING SIF pull failed; stage it later with:"
         echo "        ${_apt_bin} pull ${PRIMUS_SIF} docker://${PRIMUS_IMAGE}:${PRIMUS_IMAGE_TAG}"
      fi
      [ -n "${PRIMUS_APT_SCRATCH:-}" ] && rm -rf "${PRIMUS_APT_SCRATCH}"
   fi
   unset _apt_bin
else
   echo "primus: --pull-sif 0; not staging a SIF."
fi

# Normalize ownership/permissions like the sibling scripts.
if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
   ${SUDO} find "${PRIMUS_PATH}" -type f -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} find "${PRIMUS_PATH}" -type d -execdir chown root:root "{}" + 2>/dev/null || true
   ${SUDO} chmod go-w "${PRIMUS_PATH}"
fi

cd /

# ── Modulefile ───────────────────────────────────────────────────────
# Modulefile-write sudo via a write-probe of MODULE_PATH's ancestor (mirrors
# vllm_setup.sh PKG_SUDO_MOD).
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
   PKG_SUDO_MOD=""
else
   _mprobe="${MODULE_PATH}"
   while [ ! -e "${_mprobe}" ]; do _mprobe="$(dirname "${_mprobe}")"; done
   _mtest=$(mktemp --tmpdir="${_mprobe}" .primus-mod-probe.XXXXXX 2>/dev/null || true)
   if [ -n "${_mtest}" ] && [ -f "${_mtest}" ]; then
      rm -f "${_mtest}"; PKG_SUDO_MOD=""
   else
      PKG_SUDO_MOD="sudo"
   fi
   unset _mprobe _mtest
fi
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

# Provenance: capture this leaf script's git state for the modulefile whatis.
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

# apptainer aborts on a missing bind source, so only bind HF_HOME if present.
PRIMUS_BIND="${PRIMUS_PATH}"
[ -d "${HF_HOME_DEFAULT}" ] && PRIMUS_BIND="${PRIMUS_BIND},${HF_HOME_DEFAULT}"

# SIF modulefile line: point PRIMUS_SIF at the staged SIF only if it exists;
# otherwise bake the pull command into a help note.
if [ -f "${PRIMUS_SIF}" ]; then
   SIF_MODULE_BLOCK=$(cat <<LUA

-- Training image staged as an Apptainer SIF (AAC6 has no Docker; run the
-- stack under Apptainer and call 'primus-cli direct' INSIDE the container).
setenv("PRIMUS_SIF","${PRIMUS_SIF}")
LUA
)
else
   SIF_MODULE_BLOCK=""
fi

# MI300A-APU-only lines: unified host+GPU memory, and Primus/Megatron expect a
# FULL GPU (SPX), not AAC6's default CPX split.
if [ "${IS_APU}" = "1" ]; then
   APU_MODULE_BLOCK=$(cat <<'LUA'

-- MI300A APU: scratch-reclaim workaround (matches the rocm modulefile).
setenv("HSA_NO_SCRATCH_RECLAIM","1")

-- The image sets DEBUG_CLR_AQL_DEV_QUEUE=1 (AQL queue in device memory, for
-- discrete GPUs); on MI300A the first kernel launch then fails in
-- hsa_amd_queue_create and torch SIGSEGVs. APPTAINERENV_ overrides image env.
setenv("APPTAINERENV_DEBUG_CLR_AQL_DEV_QUEUE","0")

-- WARNING (MI300A APU): host RAM and GPU HBM are ONE physical pool, so any
-- CPU/host offload (DeepSpeed/FSDP offload, optimizer offload) moves data
-- within the same pool and can OOM/HANG. Use a full-GPU SPX partition
-- (PPAC_MI300A_SPX / SH5_MI300A_SPX), NOT the default CPX split, for training.
LUA
)
else
   APU_MODULE_BLOCK=""
fi

# The - option suppresses leading tabs in the heredoc body.
cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${PRIMUS_VERSION}.lua
	whatis("Primus ${PRIMUS_VERSION} (AMD-AGI training framework CLI; image ${PRIMUS_IMAGE}:${PRIMUS_IMAGE_TAG}, ${AMDGPU_GFXMODEL})")
	whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

	help([[
	Primus is container-first. This module provides the 'primus-cli' launcher and
	the release-pinned backend sources; the training stack lives in the image.
	On AAC6 (no Docker) run the stack under Apptainer. This module binds its
	install tree into the container (APPTAINER_BIND) and puts primus-cli on the
	container PATH (APPTAINERENV_PREPEND_PATH); add --bind for your own data:

	  apptainer exec --rocm \$PRIMUS_SIF primus-cli direct -- \\
	    train pretrain --config <your-config.yaml>

	Use a full-GPU SPX partition (not the default CPX). 'primus-cli container'
	is Docker-only and does not apply here.
	]])

	prepend_path("PATH","${PRIMUS_BINDIR}")
	prepend_path("PYTHONPATH","${PRIMUS_SITE}")

	-- Release-pinned backend sources. primus-cli direct reads PRIMUS_THIRDPARTY_DIR:
	-- with Megatron-LM + torchtitan present it skips its per-user auto deps sync
	-- (default ~/.cache/Primus/third_party) and prepends these to PYTHONPATH.
	setenv("PRIMUS_THIRDPARTY_DIR","${PRIMUS_THIRD_PARTY}")
	setenv("HF_HOME","${HF_HOME_DEFAULT}")

	-- The SIF does not see the host install tree or PATH by default.
	prepend_path{"APPTAINER_BIND","${PRIMUS_BIND}",delim=","}
	setenv("APPTAINERENV_PREPEND_PATH","${PRIMUS_BINDIR}")
${SIF_MODULE_BLOCK}
${APU_MODULE_BLOCK}
EOF

# ── Refresh the Lmod spider cache (best-effort; see vllm_setup.sh) ─────
LMOD_TS_FILE="$(module --config 2>&1 | awk '/Time Stamp File/{f=1; next} f && NF>=2 {print $NF; exit}')"
if [ -n "${LMOD_TS_FILE}" ] && [ -e "${LMOD_TS_FILE}" ]; then
   if ${PKG_SUDO_MOD} touch "${LMOD_TS_FILE}" 2>/dev/null; then
      echo "[primus] bumped Lmod cache timestamp; primus/${PRIMUS_VERSION} is loadable now."
   else
      echo "[primus] WARNING could not touch ${LMOD_TS_FILE}; until the next cache rebuild load with: module --ignore_cache load primus/${PRIMUS_VERSION}"
   fi
else
   echo "[primus] NOTE if 'module load primus/${PRIMUS_VERSION}' reports unknown, use: module --ignore_cache load primus/${PRIMUS_VERSION}"
fi

echo ""
echo "[primus] installed. Load with:"
echo "  module load rocm/<ver> primus/${PRIMUS_VERSION}"
echo ""
