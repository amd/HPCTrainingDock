#!/bin/bash

# ── Preflight: declare and load required Lmod modules ─────────────────
# Inlined (mirrors extras/scripts/magma_setup.sh:7-37) so this script is
# self-contained and can be copied/run standalone. preflight_modules
# loads each module in order; on the first failure it prints the Lmod
# diagnostic and returns MISSING_PREREQ_RC=42, which the parent
# main_setup.sh re-classifies as SKIPPED rather than FAILED.
# Added 2026-05-02 after slurm 8032 confirmed that bare `module load`
# calls were the last remaining silent-failure surface in this script
# (the rocm + magma loads at the build entry point would print to
# stderr and continue if the module was missing, leaving MAGMA_HOME
# unset and the build hitting cuda.h ~65 min later).
MISSING_PREREQ_RC=42
if ! type module >/dev/null 2>&1; then
   [ -r /etc/profile.d/lmod.sh ]            && . /etc/profile.d/lmod.sh
   [ -r /usr/share/lmod/lmod/init/bash ]    && . /usr/share/lmod/lmod/init/bash
fi
preflight_modules() {
   [ "$#" -eq 0 ] && return 0
   if ! type module >/dev/null 2>&1; then
      echo "ERROR: Lmod 'module' command not available; needed:$(printf ' %s' "$@")" >&2
      return ${MISSING_PREREQ_RC}
   fi
   echo "preflight: required modules:$(printf ' %s' "$@")"
   local m err
   err=$(mktemp -t preflight.XXXXXX.err 2>/dev/null || echo /tmp/preflight.$$.err)
   for m in "$@"; do
      if ! module load "${m}" 2>"${err}"; then
         echo "ERROR: required module '${m}' could not be loaded." >&2
         [ -s "${err}" ] && sed 's/^/  module> /' "${err}" >&2
         rm -f "${err}"
         return ${MISSING_PREREQ_RC}
      fi
   done
   rm -f "${err}"
   echo "preflight: all required modules loaded."
}

ROCM_VERSION=6.2.0
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_PYTORCH=0
PYTORCH_VERSION=2.9.1
PYTHON_VERSION=10
TORCHVISION_VERSION=0.22.1
FLASHATTENTION_VERSION=2.8.3
TRITON_VERSION=3.4.0
TRITON_WHEEL_NAME="triton"
TORCHVISION_HASH="59a3e1f"
TORCHAUDIO_VERSION=2.7.1
TORCHAUDIO_HASH="95c61b4"
PILLOW_VERSION=12.1.1
SAGEATTENTION_VERSION="1.0.6" #SageAttention 2 does not support ROCm
DEEPSPEED_VERSION="latest"
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/pytorch
# Versioned install root: /opt/rocmplus-X/pytorch-v${PYTORCH_VERSION}.
# All companion subdirs (vision, audio, triton, aotriton, transformers,
# flashattention, sageattention, deepspeed) live UNDER this root, so
# versioning the parent dir versions the whole stack and lets multiple
# pytorch releases coexist.
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/pytorch-v${PYTORCH_VERSION}
INSTALL_PATH_INPUT=""
MPI_MODULE="openmpi"
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
USE_WHEEL=0
DEBUG=0
# pytorch + all its companion packages (aotriton, triton, vision, audio,
# transformers, flashattention, sageattention, deepspeed) are installed
# as subdirectories under one ${INSTALL_PATH} root, so a single
# --replace flag cleans the whole stack. Two modulefiles get written:
# ${PYTORCH_VERSION}.lua and ${PYTORCH_VERSION}_tunableop_enabled.lua.
# --keep-failed-installs 1: skip EXIT-trap fail-cleanup. See hypre_setup.sh.
REPLACE=0
KEEP_FAILED_INSTALLS=0

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" == *"rocky"* || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi


if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "--amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is autodetected"
   echo "--build-pytorch [ BUILD_PYTORCH ] set to 1 to build jax default is 0"
   echo "--pytorch-version [ PYTORCH_VERSION ] version of PyTorch, default is $PYTORCH_VERSION"
   echo "--python-version [ PYTHON_VERSION ] version of Python, default is $PYTHON_VERSION"
   echo "--install-path [ INSTALL_PATH ] directory where PyTorch, Torchaudio and Torchvision will be installed, default is $INSTALL_PATH"
   echo "--mpi-module [ MPI_MODULE ] mpi module to build pytorch with, default is $MPI_MODULE"
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "--use-wheel [ USE_WHEEL ] build with a wheel instead of from source, default is $USE_WHEEL"
   echo "--replace [ 0|1 ] remove prior pytorch+companion installs and modulefiles before building, default $REPLACE"
   echo "--keep-failed-installs [ 0|1 ] skip EXIT-trap cleanup of partial installs on failure, default $KEEP_FAILED_INSTALLS"
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
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
	  reset-last
          ;;
      "--build-pytorch")
          shift
          BUILD_PYTORCH=${1}
	  reset-last
          ;;
      "--help")
         usage
         ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
	  reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
	  reset-last
          ;;
      "--pytorch-version")
          shift
          PYTORCH_VERSION=${1}
	  reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
	  reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
	  reset-last
          ;;
      "--use-wheel")
          shift
          USE_WHEEL=${1}
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
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case ROCM_VERSION or PYTORCH_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/pytorch-v${PYTORCH_VERSION}
fi

TRANSFORMERS_PATH=$INSTALL_PATH/transformers
TRITON_PATH=$INSTALL_PATH/triton
SAGEATTENTION_PATH=$INSTALL_PATH/sageattention
FLASHATTENTION_PATH=$INSTALL_PATH/flashattention
AOTRITON_PATH=$INSTALL_PATH/aotriton
PYTORCH_PATH=$INSTALL_PATH/pytorch
TORCHVISION_PATH=$INSTALL_PATH/vision
TORCHAUDIO_PATH=$INSTALL_PATH/audio
DEEPSPEED_PATH=$INSTALL_PATH/deepspeed

# ── --replace + EXIT trap (see hypre_setup.sh for design) ────────────
# All companion subdirs live under ${INSTALL_PATH}, so a single rm -rf
# of the root cleans pytorch + aotriton + triton + vision + audio +
# transformers + flashattention + sageattention + deepspeed in one go.
# Two modulefiles need cleaning: ${PYTORCH_VERSION}.lua and
# ${PYTORCH_VERSION}_tunableop_enabled.lua.
# ── BUILD_PYTORCH=0 short-circuit: operator opt-out (see hypre_setup.sh) ─
NOOP_RC=43
if [ "${BUILD_PYTORCH}" = "0" ]; then
   echo "[pytorch BUILD_PYTORCH=0] operator opt-out; skipping (no source build, no cache restore)."
   exit ${NOOP_RC}
fi

if [ "${REPLACE}" = "1" ]; then
   echo "[pytorch --replace 1] removing prior install + modulefiles if present"
   echo "  install dir:        ${INSTALL_PATH}"
   echo "  modulefile:         ${MODULE_PATH}/${PYTORCH_VERSION}.lua"
   echo "  modulefile (tunop): ${MODULE_PATH}/${PYTORCH_VERSION}_tunableop_enabled.lua"
   ${SUDO} rm -rf "${INSTALL_PATH}"
   ${SUDO} rm -f  "${MODULE_PATH}/${PYTORCH_VERSION}.lua" \
                  "${MODULE_PATH}/${PYTORCH_VERSION}_tunableop_enabled.lua"
fi

# ── Existence guard: skip if already installed (see hypre_setup.sh) ──
NOOP_RC=43
if [ -d "${INSTALL_PATH}" ]; then
   echo ""
   echo "[pytorch existence-check] ${INSTALL_PATH} already installed; skipping."
   echo "                          pass --replace 1 to force a clean rebuild of this version."
   echo ""
   exit ${NOOP_RC}
fi

# Consolidated EXIT trap: triton + pytorch build-dir cleanup
# (TRITON_BUILD_ROOT, PYTORCH_BUILD_ROOT, set later under
# BUILD_PYTORCH=1) PLUS fail-cleanup of partial install + both
# modulefiles. Replaces the inline two-target trap that lived next to
# the mktemp calls.
_pytorch_on_exit() {
   local rc=$?
   [ -n "${TRITON_BUILD_ROOT:-}" ]  && ${SUDO:-sudo} rm -rf "${TRITON_BUILD_ROOT}"
   [ -n "${PYTORCH_BUILD_ROOT:-}" ] && ${SUDO:-sudo} rm -rf "${PYTORCH_BUILD_ROOT}"
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[pytorch fail-cleanup] rc=${rc}: removing partial install + modulefiles"
      ${SUDO:-sudo} rm -rf "${INSTALL_PATH}"
      ${SUDO:-sudo} rm -f  "${MODULE_PATH}/${PYTORCH_VERSION}.lua" \
                           "${MODULE_PATH}/${PYTORCH_VERSION}_tunableop_enabled.lua"
   elif [ ${rc} -ne 0 ]; then
      echo "[pytorch fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   return ${rc}
}
trap _pytorch_on_exit EXIT

if [ "${BUILD_PYTORCH}" = "0" ]; then

   echo "pytorch will not be built, according to the specified value of BUILD_PYTORCH"
   echo "BUILD_PYTORCH: $BUILD_PYTORCH"
   exit

else

   # Per-job triton/torchinductor scratch dirs so concurrent pytorch
   # builds on the same node do not race on -- or clobber -- each
   # other's compiled kernel cache. The previous code allowed triton
   # to drop kernels at its default location (/tmp/amd_triton_kernel_*
   # and friends) and then ran a blanket `${SUDO} rm -rf
   # /tmp/amd_triton_kernel* /tmp/can*` at end-of-build, which would
   # nuke any concurrent job's in-flight triton cache (and, in the
   # `/tmp/can*` case, anything else under /tmp starting with "can").
   # Redirecting the cache up front + cleaning via the EXIT trap is
   # both safer and collision-free. See audit_2026_05_01.md follow-up
   # to commit fc21433 (mktemp build dirs sweep).
   TRITON_BUILD_ROOT=$(mktemp -d -t pytorch-triton-cache.XXXXXX)
   # PYTORCH_BUILD_ROOT is the on-/tmp working dir for the source-build
   # branch (aotriton, pytorch_build venv, vision/audio/flash-attn
   # checkouts). Created here so the EXIT trap is single-source-of-truth.
   # The previous behavior cloned and built directly under the script's
   # CWD (the HPCTrainingDock NFS checkout), which (a) was slow and
   # (b) collided with concurrent ROCm-version builds in the same repo.
   PYTORCH_BUILD_ROOT=$(mktemp -d -t pytorch-build.XXXXXX)
   # NOTE: build-dir cleanup for both TRITON_BUILD_ROOT and
   # PYTORCH_BUILD_ROOT is consolidated into _pytorch_on_exit installed
   # above (which also fail-cleans the install + modulefiles).
   export TRITON_CACHE_DIR="${TRITON_BUILD_ROOT}/triton"
   export TORCHINDUCTOR_CACHE_DIR="${TRITON_BUILD_ROOT}/torchinductor"
   mkdir -p "${TRITON_CACHE_DIR}" "${TORCHINDUCTOR_CACHE_DIR}"

   if [[ "${AMDGPU_GFXMODEL}" == "gfx90a" ]]; then
      TARGET_GPUS="MI200"
   elif [[ "${AMDGPU_GFXMODEL}" == "gfx942" ]]; then
      TARGET_GPUS="MI300X"
   elif [[ "${AMDGPU_GFXMODEL}" == "gfx942;gfx90a" ]]; then
      TARGET_GPUS="MI300X;MI200"
   elif [[ "${AMDGPU_GFXMODEL}" == "gfx90a;gfx942" ]]; then
      TARGET_GPUS="MI200;MI300X"
   else
      echo "Please select gfx90a, gfx942, or both separated with a ; as AMDGPU_GFXMODEL"
      exit 1
   fi
  
   AOTRITON_EXTRA_CMAKE_FLAGS="-DTARGET_GPUS=${TARGET_GPUS}"
   # aotriton's gpu_targets.py requires the `_mod0` suffix on EVERY entry
   # in --target_gpus (e.g. gfx942_mod0;gfx90a_mod0). The previous
   # `${AMDGPU_GFXMODEL}_mod0` only appended the suffix to the last
   # arch, so a multi-arch sweep ("gfx942;gfx90a") produced
   # "gfx942;gfx90a_mod0" and aotriton's configure errored with
   # `argument --target_gpus: invalid choice: 'gfx942'` (audit job 7975
   # log_pytorch_05_01_2026.txt). The sed expression below rewrites
   # each ;-separated arch token to <token>_mod0.
   AMDGPU_GFXMODEL_MOD0=$(echo "${AMDGPU_GFXMODEL}" | sed -e 's/[^;][^;]*/&_mod0/g')
   PYTORCH_SHORT_VERSION=`echo ${PYTORCH_VERSION} | cut -f1-2 -d'.'`
   if [ "${PYTORCH_SHORT_VERSION}" == "2.9" ]; then
      # Was 0.11b. Bumped to 0.11.2b (2026-01-28) because 0.11b's
      # v3python/ld_script.py emits an `INSERT AFTER .comment;` directive
      # on a SECTIONS block that itself contains a `.comment` rule, which
      # is rejected by ROCm 7.2.1's bundled lld 22.0.0:
      #   ld.lld: error: unable to insert .comment after .comment
      # (verify: log_pytorch_05_02_2026.txt:4631 in
      # logs_05_02_2026/rocm-7.2.1_8014/). Upstream 0.11.2b replaces the
      # linker-script trick with v3python/comment_only_asm, an .s source
      # compiled into the SO -- bypasses the lld self-reference check
      # entirely. Same beta line, gfx1151/1152/1153 also enabled,
      # explicit precompiled runtime for ROCm 7.2 included.
      AOTRITON_VERSION="0.11.2b"
      AOTRITON_EXTRA_CMAKE_FLAGS="-DAOTRITON_TARGET_ARCH=${AMDGPU_GFXMODEL} -DAOTRITON_OVERRIDE_TARGET_GPUS=${AMDGPU_GFXMODEL_MOD0} -DAOTRITON_USE_TORCH=0"
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.8" ]; then
      AOTRITON_VERSION="0.10b"
      AOTRITON_EXTRA_CMAKE_FLAGS="-DAOTRITON_TARGET_ARCH=${AMDGPU_GFXMODEL} -DAOTRITON_OVERRIDE_TARGET_GPUS=${AMDGPU_GFXMODEL_MOD0}"
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.7" ]; then
      AOTRITON_VERSION="0.9.2b"
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.6" ]; then
      AOTRITON_VERSION="0.8b"
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.5" ]; then
      AOTRITON_VERSION="0.7b"
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.4" ]; then
      AOTRITON_VERSION="0.6b"
   elif [ "${PYTORCH_SHORT_VERSION}" == "2.3" ]; then
      AOTRITON_VERSION="0.4b"
   else
      echo " No AOTriton support for requested PyTorch version: https://github.com/ROCm/aotriton "
      echo " Build aborted, please select a PyTorch version >= 2.3 "
      exit 1
   fi

   echo ""
   echo "======================================"
   echo "Starting Pytorch Install with"
   echo "PyTorch Version: $PYTORCH_VERSION"
   echo "PyTorch Install Directory: $PYTORCH_PATH"
   echo "Torchvision Version: $TORCHVISION_VERSION"
   echo "Torchvision Install Directory: $TORCHVISION_PATH"
   echo "Torchaudio Version: $TORCHAUDIO_VERSION"
   echo "Torchaudio Install Directory: $TORCHAUDIO_PATH"
   echo "DeepSpeed Install Directory: $DEEPSPEED_PATH"
   echo "AOTriton Version: $AOTRITON_VERSION"
   echo "AOTriton Install Directory: $AOTRITON_PATH"
   echo "ROCm Version: $ROCM_VERSION"
   echo "Module Directory: $MODULE_PATH"
   echo "Use Wheel to Build?: $USE_WHEEL"
   echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
   echo "======================================"
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/pytorch-v${PYTORCH_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Pytorch v${PYTORCH_VERSION}"
      echo "============================"
      echo ""

      # Install the cached version. Tarball top-level dir is
      # pytorch-v${PYTORCH_VERSION}/{pytorch,vision,audio,triton,...}
      # -- matches the versioned INSTALL_PATH layout the from-source
      # branch writes to, so multiple pytorch releases coexist on disk.
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzf ${CACHE_FILES}/pytorch-v${PYTORCH_VERSION}.tgz
      ${SUDO} chown -R root:root ${INSTALL_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/pytorch-v${PYTORCH_VERSION}.tgz
      fi

   elif [ "${USE_WHEEL}" == "1" ]; then

      # don't use sudo if user has write access to install path
      if [ -d "$INSTALL_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${TRANSFORMERS_PATH}
      ${SUDO} mkdir -p ${TRITON_PATH}
      ${SUDO} mkdir -p ${DEEPSPEED_PATH}
      ${SUDO} mkdir -p ${SAGEATTENTION_PATH}
      ${SUDO} mkdir -p ${FLASHATTENTION_PATH}
      ${SUDO} mkdir -p ${PYTORCH_PATH}
      ${SUDO} mkdir -p ${TORCHAUDIO_PATH}
      ${SUDO} mkdir -p ${TORCHVISION_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      python3 -m venv pytorch_build
      source pytorch_build/bin/activate
      cd pytorch_build

      # install of pre-built pytorch using a wheel
      ROCM_VERSION_WHEEL=${ROCM_VERSION}
      echo "Installing PyTorch, Torchaudio and Torchvision with wheel"
      if [[ `echo ${ROCM_VERSION} | cut -f3-3 -d'.'` == 0 ]]; then
         ROCM_VERSION_WHEEL=`echo ${ROCM_VERSION} | cut -f1-2 -d'.'`
      fi
      echo "ROCM_VERSION_WHEEL is ${ROCM_VERSION_WHEEL}"
      pip3 install torch==${PYTORCH_VERSION} --no-index -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${PYTORCH_PATH}

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Torchaudio

      pip3 install torchaudio==${TORCHAUDIO_VERSION} --no-index -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TORCHAUDIO_PATH} --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Torchvision

      pip3 install torchvision==${TORCHVISION_VERSION} --no-index -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TORCHVISION_PATH} --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Transformers

      pip3 install --target=${TRANSFORMERS_PATH} transformers --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Sage Attention

      pip3 install --target=${SAGEATTENTION_PATH} sageattention==${SAGEATTENTION_VERSION} --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Flash Attention

      pip3 install --target=${FLASHATTENTION_PATH} packaging
      export PYTHONPATH=$PYTHONPATH:${FLASHATTENTION_PATH}
      git clone --depth 1 --branch v${FLASHATTENTION_VERSION} https://github.com/Dao-AILab/flash-attention.git
      cd flash-attention
      python3 setup.py install --prefix=${FLASHATTENTION_PATH}

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Installing Triton

      ROCM_VERSION_WHEEL=${ROCM_VERSION}
      if [[ `echo ${ROCM_VERSION} | cut -f3-3 -d'.'` == 0 ]]; then
         ROCM_VERSION_WHEEL=`echo ${ROCM_VERSION} | cut -f1-2 -d'.'`
      fi

      if [[ "${ROCM_VERSION}" == "6.4.2" || "${ROCM_VERSION}" == "6.4.3" ]]; then
         TRITON_VERSION=3.2.0
      fi

      if [ "$(printf '%s\n' "$ROCM_VERSION" "7.0" | sort -V | head -n1)" = "$ROCM_VERSION" ]; then
        TRITON_WHEEL_NAME="pytorch_triton_rocm"
      fi

      echo "pip3 install ${TRITON_WHEEL_NAME}==${TRITON_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TRITON_PATH} --no-build-isolation"
      pip3 install ${TRITON_WHEEL_NAME}==${TRITON_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TRITON_PATH} --no-build-isolation

      export PYTHONPATH=$PYTORCH_PATH:$PYTHONPATH

      # Buidling Deep Speed

      DS_BUILD_AIO=1 \
      DS_BUILD_CCL_COMM=0 \
      DS_BUILD_CPU_ADAM=1 \
      DS_BUILD_CPU_LION=1 \
      DS_BUILD_EVOFORMER_ATTN=0 \
      DS_BUILD_FUSED_ADAM=1 \
      DS_BUILD_FUSED_LION=1 \
      DS_BUILD_FUSED_LAMB=1 \
      DS_BUILD_QUANTIZER=1 \
      DS_BUILD_RANDOM_LTD=1 \
      DS_BUILD_TRANSFORMER=1 \
      DS_BUILD_STOCHASTIC_TRANSFORMER=1 \
      DS_BUILD_SPARSE_ATTN=0 \
      DS_BUILD_TRANSFORMER_INFERENCE=0 \
      DS_BUILD_INFERENCE_CORE_OPS=0 \
      DS_BUILD_SPATIAL_INFERENCE=0 \
      DS_BUILD_CUTLASS_OPS=0 \
      DS_BUILD_RAGGED_OPS=0 \
      DS_BUILD_RAGGED_DEVICE_OPS=0 \
      DS_BUILD_OPS=0 \
      pip3 install --upgrade deepspeed einops psutil pydantic==2.11.9 hjson pydantic-core==2.33.2 msgpack typing_inspection annotated_types py-cpuinfo --no-cache-dir --target=$DEEPSPEED_PATH --no-build-isolation --no-deps

      deactivate
      cd ..
      rm -rf pytorch_build

      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi

   else

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh

      # Replaces the previous bare `module load rocm/${ROCM_VERSION}` and
      # `module load magma` (which silently continued on failure). With
      # preflight_modules, a missing rocm or magma module aborts the
      # build IMMEDIATELY with a clear Lmod diagnostic and returns
      # MISSING_PREREQ_RC=42 -- main_setup.sh then reports the package
      # as SKIPPED rather than FAILED, which is the correct downstream
      # signal for "you must build magma first".
      #
      # openmpi (the GPU-aware UCX/UCC build) is a hard prereq because we
      # set USE_MPI=1 below. PyTorch's CMake glue does NOT propagate the
      # MPI -I include directory to the torch_python target -- so even
      # though FindMPI succeeds and `c10d` itself links libmpi.so, the
      # later compile of caffe2/torch/.../c10d/init.cpp (which transitively
      # includes ProcessGroupMPI.hpp -> <mpi.h>) fails with
      #   fatal error: 'mpi.h' file not found
      # unless openmpi's CPLUS_INCLUDE_PATH (set by its modulefile) puts
      # the openmpi headers on amdclang++'s default search path.
      # Audited failure: slurm 8052 log_pytorch_05_02_2026.txt:98270.
      # NOTE: "amdclang" is intentionally NOT in this list. Loading the
      # amdclang module exports CC=amdclang, CXX=amdclang++, which makes
      # PyTorch build libtorch_cpu with clang 22 -- triggering the
      # libtorch_cpu/libtorch_hip mangling drift documented in the
      # "Compiler selection: rely on system GCC" block below. Letting
      # CC/CXX fall through to PyTorch CMake's autodetect (system GCC)
      # matches the working 7.1.0/7.1.1/7.2.0/7.2.1 builds in the user
      # success study and produces SHORT-form const_data_ptr mangling
      # that matches the HIP-side references.
      REQUIRED_MODULES=( "rocm/${ROCM_VERSION}" "openmpi" "magma" )
      preflight_modules "${REQUIRED_MODULES[@]}" || exit $?

      # ── Firewall amdclang's CC/CXX exports (transitive via magma) ─────
      # magma's modulefile contains `load("amdclang")`, which exports
      # CC=amdclang, CXX=amdclang++ (plus FC, OMPI_CC/CXX/FC, F77, F90).
      # That is correct for magma's OWN build (libmagma needs LLVM
      # libomp), but POISONS PyTorch's CMake autodetect: PyTorch then
      # builds libtorch_cpu with clang 22, which per LLVM #85656 emits
      # long-form mangling of std::enable_if NTTP defaults
      # (..Tn..enable_if..Li0EEE..) while HIP TUs emit short-form
      # references (..Li0EEE..) -- libtorch_cpu.so / libtorch_hip.so
      # disagree at link time, dlopen at "import torch" fails with:
      #   ImportError: libtorch_hip.so: undefined symbol:
      #   _ZNK2at10TensorBase14const_data_ptrIN3c104HalfELi0EEEPKT_v
      # First diagnosed in slurm 8093 cycle 4 (2026-05-03 17:09): the
      # fix of dropping "amdclang" from REQUIRED_MODULES at line 560
      # was insufficient because magma's load() pulls amdclang in
      # transitively (CMake config in 8093's log shows
      # "C++ compiler : .../llvm/bin/amdclang++").
      # The unset below restores the GCC-as-CC build path that
      # produced the working 7.1.0 / 7.1.1 / 7.2.0 / 7.2.1 builds in
      # the user success study (libtorch_cpu .comment = "GCC: 11.4").
      # Magma's runtime libomp dependency is independent of this --
      # the magma module's LD_LIBRARY_PATH update survives the unset.
      unset CC CXX FC F77 F90 OMPI_CC OMPI_CXX OMPI_FC
      echo "pytorch: cleared CC/CXX/FC/OMPI_* (amdclang firewall);"
      echo "         CMake will auto-detect system GCC for CPU TUs."

      # Preflight: detect system libmagma-dev. Ubuntu's libmagma-dev
      # ships /usr/include/magma_v2.h whose magma_types.h:63 includes
      # <cuda.h>. If MAGMA_HOME is unset, PyTorch's FindMAGMA
      # (cmake/Modules/FindMAGMA.cmake) HINTS go nowhere and the
      # FIND_PATH falls through to /usr/include, then the wheel build
      # aborts ~65 min in at HIPHooks.cpp.o on `cuda.h: No such file
      # or directory` (verify: line 90085 of
      # logs_05_01_2026/rocm-7.2.1_7979/log_pytorch_05_01_2026.txt).
      # We unconditionally `module load magma` and export MAGMA_HOME
      # below, so this detector is informational; it gives operators
      # a one-liner to remove the trap entirely if they want defense
      # in depth.
      if dpkg-query -W -f='${Status}\n' libmagma-dev 2>/dev/null | grep -q "^install ok installed"; then
         echo ""
         echo "############################################################"
         echo "WARNING: system libmagma-dev (CUDA-flavored) is installed."
         echo "WARNING: This script sets MAGMA_HOME via the magma module"
         echo "WARNING: below so the build is safe; you may also fully"
         echo "WARNING: remove the system magma with:"
         echo "WARNING:   sudo apt purge libmagma-dev libmagma2 libmagma-sparse2"
         echo "############################################################"
         echo ""
      fi

      # Pin PyTorch's FindMAGMA HINTS to the rocmplus magma. The magma
      # modulefile (cite: extras/scripts/magma_setup.sh) sets
      # MAGMA_PATH and MAGMA_HOME (and MAGMA_ROOT/MAGMA_DIR). The magma
      # module was already loaded above by preflight_modules; we keep
      # the MAGMA_HOME fallback as belt-and-suspender for older
      # deployed magma modules that only set MAGMA_PATH (no MAGMA_HOME),
      # per the audit_2026_05_01.md plan.
      : "${MAGMA_HOME:=${MAGMA_PATH}}"
      export MAGMA_HOME
      echo "pytorch: MAGMA_HOME=${MAGMA_HOME}"
      if [ ! -f "${MAGMA_HOME}/include/magma_v2.h" ]; then
         echo "ERROR: MAGMA_HOME=${MAGMA_HOME} but magma_v2.h not found there."
         echo "ERROR: refusing to start the wheel build -- it would pick up"
         echo "ERROR: /usr/include/magma_v2.h (CUDA-flavored) and crash"
         echo "ERROR: ~65 min in at HIPHooks.cpp.o. Fix the magma module"
         echo "ERROR: install for rocm-${ROCM_VERSION} and retry."
         exit 1
      fi

      # OpenMP runtime hints. PyTorch's cmake/Modules/FindOpenMP.cmake
      # autodetects the OpenMP runtime via find_library; on Ubuntu 22.04
      # with ROCm clang it picks /usr/lib/gcc/x86_64-linux-gnu/12/libgomp.so
      # first. fbgemm's omp-outlined regions are compiled with
      # `-fopenmp=libomp` (clang's runtime ABI -> __kmpc_* symbols), so
      # the final libtorch_cpu.so / test-binary link fails with:
      #   ld.lld: error: undefined symbol: __kmpc_barrier
      #     >>> referenced by libfbgemm.a Utils.cc.o (.omp_outlined)
      # libgomp only provides the GOMP_* ABI -- distinct from __kmpc_*.
      # ROCm 7.2.1 ships clang's libomp at ${ROCM_PATH}/llvm/lib/libomp.so;
      # forcing FindOpenMP to resolve to that file fixes the link.
      # (verify: log_pytorch_05_02_2026.txt:45895-46258 in
      # logs_05_02_2026/rocm-7.2.1_8016/ -- the audit-time evidence
      # for this incident.)
      export OpenMP_C_FLAGS="-fopenmp=libomp"
      export OpenMP_CXX_FLAGS="-fopenmp=libomp"
      export OpenMP_C_LIB_NAMES="omp"
      export OpenMP_CXX_LIB_NAMES="omp"
      export OpenMP_omp_LIBRARY="${ROCM_PATH}/llvm/lib/libomp.so"
      # Belt-and-suspender: many CMake projects ignore the OpenMP_* env
      # vars and re-do find_library with the system search path. Putting
      # ROCm's llvm/lib first in LIBRARY_PATH makes the GCC tree lose
      # the find_library race even if env vars are dropped.
      export LIBRARY_PATH="${ROCM_PATH}/llvm/lib:${LIBRARY_PATH:-}"
      if [ ! -f "${OpenMP_omp_LIBRARY}" ]; then
         echo "ERROR: OpenMP_omp_LIBRARY=${OpenMP_omp_LIBRARY} not found."
         echo "ERROR: ROCm clang's libomp.so is required to link fbgemm-using"
         echo "ERROR: targets in pytorch. Check the rocm/${ROCM_VERSION} install."
         exit 1
      fi
      echo "pytorch: OpenMP_omp_LIBRARY=${OpenMP_omp_LIBRARY}"

      # don't use sudo if user has write access to install path
      if [ -d "$INSTALL_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${INSTALL_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      # PKG_SUDO: apt/dnf need root regardless of the install-path-derived
      # SUDO. The original `if [[ ${SUDO} != "" ]]` guard conflated
      # "install path needs sudo to write" with "I have sudo authority
      # for apt", which broke any build to an admin-writable install
      # path. We change the guard to a sudo-availability check
      # (root or passwordless sudo); the no-sudo branch -- pip-install
      # mkl as a userspace fallback -- is preserved for environments
      # that genuinely lack sudo. See openmpi_setup.sh /
      # audit_2026_05_01.md Issue 2.
      PKG_SUDO=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")

      # ── No Intel MKL on ROCm builds ───────────────────────────────────
      # This script used to download and install Intel oneAPI MKL
      # (intel-onemkl-2025.0.0.940.sh) on every PyTorch build. That was
      # wrong for two reasons:
      #
      #  1. The MKL-only installer ships libmkl_intel_thread.so which
      #     NEEDS libiomp5.so (Intel's OpenMP runtime). libiomp5 ships
      #     with the Intel compilers package, which we never install.
      #     Result: at first `import torch`, ctypes loads
      #     libtorch_global_deps -> libmkl_intel_thread -> unresolved
      #     symbol omp_get_max_active_levels -> OSError. First seen in
      #     slurm 8032 (2026-05-02 17:00); the wheel build itself
      #     succeeded and the failure surfaced when deepspeed's setup.py
      #     did `import torch`.
      #
      #  2. ROCm-flavored PyTorch is supposed to use OpenBLAS (CPU) and
      #     rocBLAS (GPU); MKL was the x86/CUDA path. Upstream pytorch
      #     and AMD's rocm/pytorch container both set USE_MKL=0 for HIP
      #     builds.
      #
      # USE_MKL=0 / BLAS=OpenBLAS exports above are belt-and-suspender
      # in case oneAPI is on the system from an earlier (pre-fix) run
      # of this script -- they neutralize PyTorch's CMake auto-detect.
      # The operator-visible warning below makes that situation loud.
      if [ -d /opt/intel/oneapi ]; then
         echo ""
         echo "############################################################"
         echo "WARNING: /opt/intel/oneapi exists on this system."
         echo "WARNING: This is leftover from a pre-2026-05-02 PyTorch"
         echo "WARNING: build of this repo. We deliberately do NOT use"
         echo "WARNING: it; USE_MKL=0 / BLAS=OpenBLAS above keep PyTorch"
         echo "WARNING: from auto-detecting it. To remove fully:"
         echo "WARNING:   sudo rm -rf /opt/intel"
         echo "############################################################"
         echo ""
      fi

      if [[ "${DISTRO}" == "ubuntu" ]]; then
         if [ "${EUID:-$(id -u)}" -eq 0 ] || sudo -n true 2>/dev/null; then
            ${PKG_SUDO} apt-get update
            ${PKG_SUDO} ${DEB_FRONTEND} apt-get install -y python-is-python3 liblzma-dev libzstd-dev git-lfs
            module load ${MPI_MODULE}
            if [[ `which mpicc | wc -l` -eq 0 ]]; then
               ${PKG_SUDO} ${DEB_FRONTEND} apt-get install -y libopenmpi-dev
            fi
         else
            ln -s $(which python3) ~/bin/python
            export PATH="$HOME/bin:$PATH"
            source $HOME/.bashrc
         fi
      elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
         if [ "${EUID:-$(id -u)}" -eq 0 ] || sudo -n true 2>/dev/null; then
            ${PKG_SUDO} dnf install -y ninja-build
            module load ${MPI_MODULE}
         else
            dnf install -y ninja-build
	 fi
      fi


      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} mkdir -p ${TRANSFORMERS_PATH}
      ${SUDO} mkdir -p ${TRITON_PATH}
      ${SUDO} mkdir -p ${DEEPSPEED_PATH}
      ${SUDO} mkdir -p ${SAGEATTENTION_PATH}
      ${SUDO} mkdir -p ${FLASHATTENTION_PATH}
      ${SUDO} mkdir -p ${AOTRITON_PATH}
      ${SUDO} mkdir -p ${PYTORCH_PATH}
      ${SUDO} mkdir -p ${TORCHAUDIO_PATH}
      ${SUDO} mkdir -p ${TORCHVISION_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      # Move the entire source-build (aotriton, pytorch venv,
      # vision/audio/flash-attn checkouts) onto /tmp via the
      # PYTORCH_BUILD_ROOT created at the top of this branch. The
      # subsequent `cd ../..` / `rm -rf` patterns within this block
      # were authored relative to this single CWD, so a single
      # chdir-then-restore brackets the whole tree without disturbing
      # those relative paths.
      PYTORCH_ORIG_CWD="$(pwd)"
      cd "${PYTORCH_BUILD_ROOT}"

      echo ""
      echo "=================================="
      echo " Installing AOTriton from source "
      echo "=================================="
      echo " build dir: ${PYTORCH_BUILD_ROOT} (off NFS)"
      echo ""

      export GPU_TARGETS=${AMDGPU_GFXMODEL}
      export AMDGPU_TARGETS=${AMDGPU_GFXMODEL}

      # Clean up stale source tree from prior interrupted runs.
      # No zstd build needed: aotriton 0.8+ replaced its zstd
      # compression path with liblzma (already installed via apt at
      # the top of this branch). The Ubuntu 22.04 system zstd CLI
      # (v1.4.8 at /usr/bin/zstd) covers the only remaining mention
      # in v2python/generate_compile.py, which is gated behind
      # --test-clustering and not invoked during a normal build.
      # See aotriton README L30, CMakeLists.txt:131 (liblzma path),
      # and bindings/CMakeLists.txt:13 (zstd_interface guarded by
      # AOTRITON_COMPRESS_KERNEL, which is never set in 0.11.2b).
      rm -rf aotriton

      git clone --depth 1 --branch ${AOTRITON_VERSION}  https://github.com/ROCm/aotriton.git

      cd aotriton
      git submodule update --init --recursive --depth 1

      # Triton (vendored under aotriton/third_party/triton, not the
      # standalone TRITON_VERSION pin earlier in this script) sets
      # `-Werror -Wno-covered-switch-default` unconditionally in its
      # top-level CMakeLists.txt. On Ubuntu 22.04 (libstdc++ 12) two
      # TUs reach `std::stable_sort` -> `std::_Temporary_buffer` ->
      # `std::get_temporary_buffer`, which libstdc++ marks
      # _GLIBCXX17_DEPRECATED. amdclang++ promotes it to
      # -Werror,-Wdeprecated-declarations and the compile fails:
      #   - lib/Analysis/Allocation.cpp.o
      #   - third_party/amd/lib/TritonAMDGPUTransforms/BlockPingpong.cpp.o
      # (verify: logs_05_02_2026/rocm-7.2.1_8013/log_pytorch_05_02_2026.txt
      #  lines 2894 and 2989). Append `-Wno-error=deprecated-declarations`
      # so the deprecation stays a warning while every other -Werror
      # promotion is preserved. Targeted, reversible, version-pinned to
      # the aotriton checkout we just produced.
      TRITON_CMAKELISTS="third_party/triton/CMakeLists.txt"
      if [ -f "${TRITON_CMAKELISTS}" ] && grep -q -- "-Werror" "${TRITON_CMAKELISTS}"; then
         echo "pytorch: patching ${TRITON_CMAKELISTS} to neutralise -Werror,-Wdeprecated-declarations"
         sed -i 's/-Werror\b/-Werror -Wno-error=deprecated-declarations/g' "${TRITON_CMAKELISTS}"
         grep -n -- "-Werror" "${TRITON_CMAKELISTS}" || echo "pytorch: WARNING: -Werror disappeared after sed; review patch"
      else
         echo "pytorch: NOTE: ${TRITON_CMAKELISTS} has no -Werror; skip patch (aotriton may have changed triton pin)"
      fi

      mkdir -p build && cd build

      if [[ "${AMDGPU_GFXMODEL}" == "gfx90a" ]]; then
         TARGET_GPUS="MI200"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx942" ]]; then
	 TARGET_GPUS="MI300X"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx942;gfx90a" ]]; then
	 TARGET_GPUS="MI300X;MI200"
      elif [[ "${AMDGPU_GFXMODEL}" == "gfx90a;gfx942" ]]; then
	 TARGET_GPUS="MI200;MI300X"
      else
         echo "Please select gfx90a, gfx942, or both separated with a ; as AMDGPU_GFXMODEL"
	 exit 1
      fi

      cmake -DAOTRITON_HIPCC_PATH=${ROCM_PATH}/bin ${AOTRITON_EXTRA_CMAKE_FLAGS} -DCMAKE_INSTALL_PREFIX=${AOTRITON_PATH} -DCMAKE_BUILD_TYPE=Release -DAOTRITON_GPU_BUILD_TIMEOUT=0  -G Ninja ..
      AOTRITON_CONFIGURE_RC=$?
      if [ ${AOTRITON_CONFIGURE_RC} -ne 0 ]; then
         echo ""
         echo "ERROR: aotriton cmake configure failed (rc=${AOTRITON_CONFIGURE_RC})"
         echo "ERROR: AOTRITON_EXTRA_CMAKE_FLAGS='${AOTRITON_EXTRA_CMAKE_FLAGS}'"
         echo "ERROR: refusing to continue -- a missing libaotriton_v2.so"
         echo "ERROR: would only show up later during pytorch's ninja link"
         echo "ERROR: as 'missing and no known rule to make it', wasting"
         echo "ERROR: ~30-90 min of cmake/ninja work in pytorch's wheel build"
         echo "ERROR: (audit job 7975, log_pytorch_05_01_2026.txt)."
         exit 1
      fi

      ninja install
      AOTRITON_NINJA_RC=$?
      if [ ${AOTRITON_NINJA_RC} -ne 0 ]; then
         echo ""
         echo "ERROR: aotriton ninja install failed (rc=${AOTRITON_NINJA_RC})"
         exit 1
      fi

      cd ../..
      rm -rf aotriton

      echo ""
      echo "============================"
      echo " Installing Pytorch, "
      echo " Torchaudio and Torchvision"
      echo " from source"
      echo "============================"
      echo ""

      # Remove any stale build directory from a prior interrupted run.
      # Uses sudo because a previous build may have created root-owned
      # files via the sed fixup of torchrun scripts.
      ${SUDO} rm -rf pytorch_build
      python3 -m venv pytorch_build
      source pytorch_build/bin/activate
      cd pytorch_build
      export PYTORCH_BUILD_DIR=`pwd`

      export _GLIBCXX_USE_CXX11_ABI=1
      export ROCM_HOME=${ROCM_PATH}
      export ROCM_SOURCE_DIR=${ROCM_PATH}
      export USE_ROCM=1
      export USE_CUDA=0
      export MAX_JOBS=32
      export USE_MPI=1

      # ── Compiler selection: rely on system GCC (NOT amdclang) ─────────
      # We deliberately do NOT load the amdclang module for the build
      # (note the absence of "amdclang" from REQUIRED_MODULES above), so
      # CC/CXX fall through to PyTorch's CMake autodetect, which picks
      # the system GCC (Ubuntu 22.04: GCC 11.4). This matches the four
      # ROCm versions in the user's success study (7.1.0 / 7.1.1 / 7.2.0
      # / 7.2.1, all PyTorch 2.9.1, all built before "amdclang" was
      # briefly added to REQUIRED_MODULES).
      #
      # Why GCC and not amdclang: ROCm 7.x bundles clang 22, which per
      # LLVM #85656 mangles SFINAE-defaulted std::enable_if NTTPs with
      # the long form (..Tn..enable_if..Li0EEE..). HIP TUs (driven via
      # hipcc) still emit short-form references (..Li0EEE.. only). When
      # CPU TUs are also built by amdclang the libtorch_cpu /
      # libtorch_hip dynamic-symbol tables drift: cpu defines LONG, hip
      # references SHORT, dlopen fails at "import torch":
      #   ImportError: libtorch_hip.so: undefined symbol:
      #   _ZNK2at10TensorBase14const_data_ptrIN3c104HalfELi0EEEPKT_v
      # GCC 11.4 emits the SHORT form (matching the historical clang<=17
      # ABI), which matches the HIP-side references. The C1 import-torch
      # validation block below catches any future regression of this
      # class (search "C1 validation"). References:
      #   PyTorch issue #173707 (still open, 2026-02-24)
      #   LLVM issue #85656 (mangling change clang>=18)
      #   slurm 8065 (rocm-7.2.1, amdclang build, FAILED at runtime)
      #   slurm 8066 (rocm-7.2.0, amdclang build, FAILED at runtime)

      # ── Disable Intel MKL detection on ROCm builds ────────────────────
      # When Intel oneAPI is visible on the build host (e.g. via
      # /opt/intel/oneapi/mkl on PATH/LD_LIBRARY_PATH/CPATH), PyTorch's
      # CMake auto-detects MKL and links libtorch_cpu / libtorch_global_deps
      # against /opt/intel/oneapi/mkl/.../libmkl_intel_thread.so.
      # That DSO needs Intel's libiomp5.so for the OpenMP API symbols
      # (omp_get_max_active_levels, etc).  iomp5 is NOT in the chain we
      # ship -- our MAGMA + ROCm-libomp.so combination uses LLVM-OMP --
      # so at "import torch" time the ctypes.CDLL of libtorch_global_deps
      # raises:
      #   OSError: /opt/intel/oneapi/mkl/.../libmkl_intel_thread.so.2:
      #            undefined symbol: omp_get_max_active_levels
      # First seen in slurm 8032 (2026-05-02 17:00) right after the wheel
      # install succeeded -- the error only fires at first import, so
      # main_setup.sh's per-package check passed, and the failure surfaced
      # during the *next* package (deepspeed) which does `import torch`
      # in its setup.py.
      # Fix: keep MKL OUT of the build entirely; CPU BLAS comes from
      # OpenBLAS (which magma_setup.sh now installs at the right version),
      # MKLDNN/oneDNN can still build, just without the MKL backend.
      export USE_MKL=0
      export BLAS=OpenBLAS
      export OpenBLAS_HOME=${MAGMA_PATH:-/usr}
      export PYTORCH_ROCM_ARCH=${AMDGPU_GFXMODEL}
      export PYTORCH_INSTALL_DIR=${PYTORCH_PATH}
      export AOTRITON_INSTALLED_PREFIX=${AOTRITON_PATH}
      if [ "${PYTORCH_SHORT_VERSION}" == "2.9" ] && [[ "${AMDGPU_GFXMODEL}" == *"gfx942"* ]]; then
         export USE_FBGEMM_GENAI=0
      fi

      # this block of code is to retry if git clone fails.
      RETRIES=6
      DELAY=30
      COUNT=1
      while [ $COUNT -lt $RETRIES ]; do
        git clone --recursive --depth 1 --branch v${PYTORCH_VERSION} https://github.com/pytorch/pytorch
        if [ $? -eq 0 ]; then
          RETRIES=0
          break
        fi
        let COUNT=$COUNT+1
        sleep $DELAY
      done

      cd pytorch

      # ── MAGMA 2.10+ compatibility (backport of pytorch PR #180388) ───
      # PyTorch v2.9.1 (and earlier) encodes AT_MAGMA_VERSION as
      #   MAJOR*100 + MINOR*10 + MICRO
      # which overflows when MAGMA's MINOR reaches 10 (current MAGMA
      # master tag is v2.10.0).  A hard #error in
      #   aten/src/ATen/native/cuda/linalg/BatchLinearAlgebra.cpp
      # then aborts the build with:
      #   "MAGMA release minor or micro version >= 10, please correct
      #    AT_MAGMA_VERSION"
      # First seen in slurm 8017 (rc=1, magma=2.10.0, pytorch=2.9.1).
      # Upstream pytorch fixed this in PR #180388 (commit 5c3f8fd1,
      # 2026-04-16) by widening the encoding to
      #   MAJOR*10000 + MINOR*100 + MICRO
      # and bumping the (only) magic-number consumer (>= 254) to its
      # new-encoding equivalent (>= 20504).  We backport the same patch
      # here.  Hipify regenerates the HIP variant from this CUDA source
      # at configure time, so patching the CUDA file alone propagates
      # to torch_hip.  The grep guard makes this idempotent and a no-op
      # on PyTorch versions that already include PR #180388.
      _BLA="aten/src/ATen/native/cuda/linalg/BatchLinearAlgebra.cpp"
      if [ -f "${_BLA}" ] && grep -q 'MAGMA_VERSION_MAJOR\*100 + MAGMA_VERSION_MINOR\*10' "${_BLA}"; then
         echo "Patching ${_BLA} for MAGMA 2.10+ compatibility (backport of pytorch PR #180388)"
         sed -i \
            -e 's#MAGMA_VERSION_MAJOR\*100 + MAGMA_VERSION_MINOR\*10 + MAGMA_VERSION_MICRO#MAGMA_VERSION_MAJOR*10000 + MAGMA_VERSION_MINOR*100 + MAGMA_VERSION_MICRO#g' \
            -e 's#MAGMA_VERSION_MINOR >= 10 || MAGMA_VERSION_MICRO >= 10#MAGMA_VERSION_MINOR >= 100 || MAGMA_VERSION_MICRO >= 100#g' \
            -e 's#MAGMA release minor or micro version >= 10#MAGMA release minor or micro version >= 100#g' \
            -e 's#AT_MAGMA_VERSION >= 254#AT_MAGMA_VERSION >= 20504#g' \
            "${_BLA}"
         echo "  -> patched (verify):"
         grep -nE 'AT_MAGMA_VERSION|MAGMA release minor' "${_BLA}" | sed 's/^/    /'
      else
         echo "Skipping ${_BLA} MAGMA 2.10+ patch (file missing or already patched)"
      fi

      # ── HIP_CXX_FLAGS leak to torch_python C sources (issue #103222) ──
      # caffe2/CMakeLists.txt:1768 (v2.9.1; same line in upstream main):
      #   target_compile_options(torch_hip PUBLIC ${HIP_CXX_FLAGS})  # experiment
      # HIP_CXX_FLAGS contains "-std=c++17" (Dependencies.cmake:1011).
      # PUBLIC propagation drags those flags into every consumer of
      # torch_hip, including torch_python -- which compiles plain C
      # sources (csrc/dynamo/cpython_defs.c).  amdclang then errors:
      #   error: invalid argument '-std=c++17' not allowed with 'C'
      # First seen in slurm 8024 (2026-05-02 14:44, ninja step 7591/8074).
      # Upstream issue #103222 is OPEN (unfixed) as of today; main has
      # the same broken line.  Fix: wrap HIP_CXX_FLAGS in a
      # $<COMPILE_LANGUAGE:CXX> generator expression so the flags only
      # apply to C++ compilations.  The "# experiment" comment is the
      # unique anchor; grep guard makes the patch idempotent.
      _CAF=caffe2/CMakeLists.txt
      if [ -f "${_CAF}" ] && grep -q 'target_compile_options(torch_hip PUBLIC ${HIP_CXX_FLAGS})  # experiment' "${_CAF}"; then
         echo "Patching ${_CAF} for HIP_CXX_FLAGS C-leak (workaround for pytorch issue #103222)"
         sed -i 's|target_compile_options(torch_hip PUBLIC ${HIP_CXX_FLAGS})  # experiment|target_compile_options(torch_hip PUBLIC "$<$<COMPILE_LANGUAGE:CXX>:${HIP_CXX_FLAGS}>")  # filter to CXX so -std=c++17 etc. do not leak to .c files via PUBLIC propagation (workaround for #103222)|' "${_CAF}"
         echo "  -> patched (verify):"
         grep -nE 'torch_hip PUBLIC.*HIP_CXX_FLAGS' "${_CAF}" | sed 's/^/    /'
      else
         echo "Skipping ${_CAF} HIP_CXX_FLAGS patch (file missing or already patched)"
      fi

      # ── Autograd codegen: increase shard count for the long-tail TUs ──
      # The 4 ninja monsters that dominate caffe2/torch_cpu wall time are:
      #   TraceType_3.cpp.o, TraceType_4.cpp.o,
      #   ADInplaceOrViewType_0.cpp.o, ADInplaceOrViewType_1.cpp.o
      # Each compiles single-threaded for 35-45 min on amdclang++ at -O3
      # (see slurm 8032 .ninja_log: TraceType_4 finished at ninja step
      # 7126/8074 while step ~6500 already had everything else done).
      # The shard counts come from autograd codegen:
      #   tools/autograd/gen_trace_type.py        : num_shards=5  (TraceType_*)
      #   tools/autograd/gen_inplace_or_view_type.py: num_shards=2  (ADInplaceOrViewType_*)
      # Doubling them splits each monster TU into ~half-size shards and
      # roughly halves the long-tail wall time (~15-20 min off every
      # PyTorch build).  Each shard is independent so the total compile
      # work is unchanged; we trade more parallelism for more files.
      # The sed anchors the substitution on the unique env_callable line
      # immediately above num_shards, so the patch is robust against
      # other "num_shards=5" / "num_shards=2" occurrences elsewhere in
      # torchgen.  Each grep guard makes the patch idempotent.
      _GTT=tools/autograd/gen_trace_type.py
      if [ -f "${_GTT}" ] && grep -q 'env_callable=gen_trace_type_func,' "${_GTT}"; then
         echo "Patching ${_GTT}: TraceType num_shards 5 -> 10 (long-tail mitigation)"
         sed -i '/env_callable=gen_trace_type_func,/{n;s/num_shards=5,/num_shards=10,/}' "${_GTT}"
         echo "  -> patched (verify):"
         grep -nB1 'num_shards=' "${_GTT}" | grep -A1 gen_trace_type_func | sed 's/^/    /'
      else
         echo "Skipping ${_GTT} shard patch (file missing or anchor not found)"
      fi

      _GIV=tools/autograd/gen_inplace_or_view_type.py
      if [ -f "${_GIV}" ] && grep -q 'env_callable=gen_inplace_or_view_type_env,' "${_GIV}"; then
         echo "Patching ${_GIV}: ADInplaceOrViewType num_shards 2 -> 4 (long-tail mitigation)"
         sed -i '/env_callable=gen_inplace_or_view_type_env,/{n;s/num_shards=2,/num_shards=4,/}' "${_GIV}"
         echo "  -> patched (verify):"
         grep -nB1 'num_shards=' "${_GIV}" | grep -A1 gen_inplace_or_view_type_env | sed 's/^/    /'
      else
         echo "Skipping ${_GIV} shard patch (file missing or anchor not found)"
      fi

      if [[ "${USER}" == "root" ]]; then
	 # we will add the environment variables above the line that says "# set up appropriate env variable" in setup.py
	 LINE=`sed -n '/# set up appropriate env variable/=' setup.py | grep -n ""`
	 LINE=`echo ${LINE} | cut -c 3-`

         sed -i ''"${LINE}"'i os.environ["ROCM_HOME"] = '"${ROCM_HOME}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["ROCM_SOURCE_DIR"] = '"${ROCM_SOURCE_DIR}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["PYTORCH_ROCM_ARCH"] = '"${PYTORCH_ROCM_ARCH}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["AOTRITON_INSTALLED_PREFIX"] = '"${AOTRITON_INSTALLED_PREFIX}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["CMAKE_INCLUDE_PATH"] = '"${CMAKE_INCLUDE_PATH}"'' setup.py
         sed -i ''"${LINE}"'i os.environ["LIBS"] = '"${LIBS}"'' setup.py
      fi

      if [ "${PYTORCH_SHORT_VERSION}" == "2.4" ]; then
         # the USE_ROCM define is not passed to the CAFFE2 build
         # https://github.com/pytorch/pytorch/issues/103312
         # We comment out the lines within the USE_ROCM block in the torch/csrc/jit/ir/ir.cpp file
         sed -i -e 's/case cuda/\/\/case cuda/' torch/csrc/jit/ir/ir.cpp
         # prevent Caffe2 from writing into /usr/local/
         sed -i '/install(DIRECTORY ${CMAKE_BINARY_DIR}\/caffe2 DESTINATION ${PYTHON_LIB_REL_PATH}/s/^/#/g' caffe2/CMakeLists.txt
         sed -i '/FILES_MATCHING PATTERN \"\*\.py")/s/^/#/g' caffe2/CMakeLists.txt
      fi

      if [ "${PYTORCH_SHORT_VERSION}" == "2.9" ]; then
         cd third_party
	 find . -name 'CMakeLists.txt' -exec sed -i 's/^CMAKE_MINIMUM_REQUIRED(VERSION .*/CMAKE_MINIMUM_REQUIRED(VERSION 3.5)/' {} +
	 cd ..
      fi

      # Ensure PyTorch's bundled flatbuffers headers are found before any
      # ROCm-provided flatbuffers headers to avoid version mismatches.
      # Must use target_include_directories on torch_cpu (not global
      # include_directories) because target-level includes take priority
      # over directory-level includes in CMake's compile command ordering.
      echo 'target_include_directories(torch_cpu BEFORE PRIVATE "${CMAKE_SOURCE_DIR}/third_party/flatbuffers/include")' >> caffe2/CMakeLists.txt

      python3 -m pip install -r requirements.txt
      pip3 install -r requirements.txt --target=${INSTALL_PATH}/pypackages

      echo ""
      echo "===================="
      echo "Running build_amd.py (hipification)"
      echo "===================="
      echo ""
      python3 tools/amd_build/build_amd.py
      if [ $? -ne 0 ]; then
         echo "ERROR: build_amd.py (hipification) failed"
         exit 1
      fi

      echo ""
      echo "===================="
      echo "Starting setup.py install"
      echo "===================="
      echo ""
      python3 setup.py install --prefix=${PYTORCH_PATH}
      SETUP_PY_RC=$?
      if [ ${SETUP_PY_RC} -ne 0 ]; then
         echo ""
         echo "######################################################"
         echo "ERROR: pytorch wheel build failed (rc=${SETUP_PY_RC})."
         echo "ERROR: refusing to silently continue with vision/audio/"
         echo "ERROR: triton/sageattention/flash-attn/deepspeed -- those"
         echo "ERROR: would 'install' against a non-existent torch and"
         echo "ERROR: produce a fake-OK install tree (which then fools"
         echo "ERROR: main_setup.sh's per-package summary into reporting"
         echo "ERROR: pytorch=OK while disk has no torch/ directory --"
         echo "ERROR: see audit_2026_05_01.md for the original incident)."
         echo "ERROR:"
         echo "ERROR: Common root causes (search the log above for the"
         echo "ERROR: first 'error:' line):"
         echo "ERROR:   - magma_v2.h cuda.h missing  -> MAGMA_HOME unset"
         echo "ERROR:                                   or pointed at"
         echo "ERROR:                                   /usr (CUDA magma)."
         echo "ERROR:                                   See preflight above."
         echo "ERROR:   - libaotriton_v2.so missing  -> aotriton configure"
         echo "ERROR:                                   failed earlier."
         echo "ERROR:   - HIPHooks.cpp.o failure     -> ROCm/LLVM toolchain"
         echo "ERROR:                                   mismatch."
         echo "######################################################"
         exit 1
      fi
      cd ..
      rm -rf pytorch
      # With PyTorch 2.9.1:
      # WARNING: Redirecting 'python setup.py install' to 'pip install . -v --no-build-isolation', for more info see https://github.com/pytorch/pytorch/issues/152276
      if [ "${PYTORCH_SHORT_VERSION}" == "2.9" ]; then
        PYTORCH_PATH_SITE_PACKAGES=${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages
	${SUDO} mkdir -p ${PYTORCH_PATH_SITE_PACKAGES}
        ${SUDO} cp -a lib/python*/site-packages/* ${PYTORCH_PATH_SITE_PACKAGES}
	${SUDO} mkdir -p ${PYTORCH_PATH}/bin
	export PYTHON3_PATH=`which python3`
	${SUDO} find bin/ -maxdepth 1 -type f ! -name 'python*' -exec sed -i "s#${PYTORCH_BUILD_DIR}/bin/python3#${PYTHON3_PATH}#g" {} +
	${SUDO} cp -a bin/* ${PYTORCH_PATH}/bin
      fi
      echo ""
      echo "===================="
      echo "Finished setup.py install"
      echo "===================="
      echo ""

      # ── C1: Mandatory `import torch` validation ─────────────────────────
      # Catches the libtorch_cpu/libtorch_hip ABI-mismatch class of bug
      # the moment it surfaces (vs in a downstream pip subprocess), so
      # main_setup.sh's per-package gate fails the script cleanly here
      # instead of marking pytorch DONE and letting the failure cascade
      # into deepspeed / flash-attention installs that import torch in
      # their setup.py (jobs 8049-8065 silently produced "DONE pytorch"
      # then "metadata-generation-failed deepspeed" -- the post-mortem
      # signal pointed at deepspeed even though pytorch was the real
      # cause). Replaces the prior `if [[ "${DEBUG}" != 0 ]]` gate
      # which made these checks dead code in production.
      export PYTHONPATH=${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages
      export PYTHONPATH=${PYTHONPATH}:${INSTALL_PATH}/pypackages
      echo ""
      echo "[pytorch C1 validation] PYTHONPATH=${PYTHONPATH}"
      echo "[pytorch C1 validation] running 'import torch' check"
      if ! python3 -c "
import torch
print('  torch.__version__   =', torch.__version__)
print('  torch.version.hip   =', getattr(torch.version, 'hip', None))
print('  torch.version.cuda  =', torch.version.cuda)
print('  torch.cuda.is_available() =', torch.cuda.is_available())
"; then
         echo "" >&2
         echo "######################################################################" >&2
         echo "[pytorch C1 validation] FAILED -- 'import torch' did not succeed." >&2
         echo "" >&2
         echo "This is the failure mode that silently passed in slurm 8049 / 8061 /" >&2
         echo "8063 / 8065 because the validation was gated by DEBUG=0. The libtorch" >&2
         echo "shared objects were built but cannot be loaded -- the most common" >&2
         echo "cause is CC=amdclang for CPU TUs, which (per LLVM #85656) emits" >&2
         echo "long-form mangling of std::enable_if NTTP defaults that does not" >&2
         echo "match the short-form references emitted by hipcc for HIP TUs." >&2
         echo "See PyTorch issue #173707 for context." >&2
         echo "" >&2
         echo "Diagnostic next steps:" >&2
         echo "  1. readelf -p .comment libtorch_cpu.so | head" >&2
         echo "     EXPECT 'GCC: ...'. If 'AMD clang version', then REQUIRED_MODULES" >&2
         echo "     in pytorch_setup.sh accidentally pulls in 'amdclang' (which" >&2
         echo "     exports CC=amdclang); restore the GCC-as-CC build path." >&2
         echo "  2. nm -D libtorch_cpu.so | grep ' T ' | grep const_data_ptr | head" >&2
         echo "     EXPECT short-form (...Li0EEEPKT_v). Long-form (...Tn..enable_if..)" >&2
         echo "     means clang built libtorch_cpu and the ABI does not match HIP." >&2
         echo "  3. nm -D libtorch_hip.so | grep ' U ' | grep const_data_ptr | head" >&2
         echo "     Always short-form; libtorch_cpu MUST also be short-form." >&2
         echo "######################################################################" >&2
         exit 1
      fi
      echo "[pytorch C1 validation] OK"
      echo ""

      # Installing Torchvision

      git clone --recursive --depth 1 --branch v${TORCHVISION_VERSION} https://github.com/pytorch/vision
      cd vision
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages:$PYTHONPATH
      python3 setup.py install --prefix=${TORCHVISION_PATH}
      cd ..
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchvision-${TORCHVISION_VERSION}+${TORCHVISION_HASH}-py3.${PYTHON_VERSION}-linux-x86_64.egg:$PYTHONPATH
      # Detect the actual installed pillow version from the egg directory name,
      # since torchvision pulls pillow as a dependency and the version may differ
      # from what PILLOW_VERSION specifies.
      PILLOW_EGG=$(ls -d ${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-*-py3.${PYTHON_VERSION}-linux-x86_64.egg 2>/dev/null | head -1)
      if [ -n "${PILLOW_EGG}" ]; then
         PILLOW_VERSION=$(basename "${PILLOW_EGG}" | sed 's/^pillow-\(.*\)-py3\..*/\1/')
      fi
      export PYTHONPATH=${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-${PILLOW_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg:$PYTHONPATH
      if [[ "${DEBUG}" != 0 ]]; then
         echo "Testing import torchvision"
         python3 -c 'import torchvision'
         echo "Finished testing import torchvision"
      fi

      # Installing Torchaudio

      git clone --recursive --depth 1 --branch v${TORCHAUDIO_VERSION} https://github.com/pytorch/audio
      cd audio
      export PYTHONPATH=${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages:$PYTHONPATH
      python3 setup.py install --prefix=${TORCHAUDIO_PATH}
      export PYTHONPATH=${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchaudio-${TORCHAUDIO_VERSION}a0+${TORCHAUDIO_HASH}-py3.${PYTHON_VERSION}-linux-x86_64.egg:$PYTHONPATH
      if [[ "${DEBUG}" != 0 ]]; then
         echo "Testing import torchaudio"
         python3 -c 'import torchaudio'
         echo "Finished testing import torchaudio"
      fi
      cd ..

      # Installing Transformers

      pip3 install --target=${TRANSFORMERS_PATH} transformers --no-build-isolation

      # Installing Triton

      ROCM_VERSION_WHEEL=${ROCM_VERSION}
      if [[ `echo ${ROCM_VERSION} | cut -f3-3 -d'.'` == 0 ]]; then
         ROCM_VERSION_WHEEL=`echo ${ROCM_VERSION} | cut -f1-2 -d'.'`
      fi

      if [[ "${ROCM_VERSION}" == "6.4.2" || "${ROCM_VERSION}" == "6.4.3" ]]; then
         TRITON_VERSION=3.2.0
      fi

      if [ "$(printf '%s\n' "$ROCM_VERSION" "7.0" | sort -V | head -n1)" = "$ROCM_VERSION" ]; then
        TRITON_WHEEL_NAME="pytorch_triton_rocm"
      fi

      pip3 install ${TRITON_WHEEL_NAME}==${TRITON_VERSION} -f https://repo.radeon.com/rocm/manylinux/rocm-rel-${ROCM_VERSION_WHEEL}/ --no-cache-dir --target=${TRITON_PATH} --no-build-isolation

      # Installing Sage Attention

      pip3 install --target=${SAGEATTENTION_PATH} sageattention==${SAGEATTENTION_VERSION} --no-build-isolation

      # Building Flash Attention

      pip3 install --target=${FLASHATTENTION_PATH} packaging
      export PYTHONPATH=$PYTHONPATH:${FLASHATTENTION_PATH}
      export PYTHONPATH=$PYTHONPATH:${FLASHATTENTION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages
      git clone --depth 1 --branch v${FLASHATTENTION_VERSION} https://github.com/Dao-AILab/flash-attention.git
      cd flash-attention
      #FLASH_ATTENTION_SKIP_CUDA_BUILD="FALSE" FLASH_ATTENTION_TRITON_AMD_ENABLE="TRUE" python3 setup.py install --prefix=${FLASHATTENTION_PATH}
      BUILD_TARGET="rocm" GPU_ARCHS="$AMDGPU_GFXMODEL" FLASH_ATTENTION_SKIP_CUDA_BUILD="FALSE" python3 setup.py install --prefix=${FLASHATTENTION_PATH}

      # Building Deep Speed

      DS_BUILD_AIO=1 \
      DS_BUILD_CCL_COMM=0 \
      DS_BUILD_CPU_ADAM=1 \
      DS_BUILD_CPU_LION=1 \
      DS_BUILD_EVOFORMER_ATTN=0 \
      DS_BUILD_FUSED_ADAM=1 \
      DS_BUILD_FUSED_LION=1 \
      DS_BUILD_FUSED_LAMB=1 \
      DS_BUILD_QUANTIZER=1 \
      DS_BUILD_RANDOM_LTD=1 \
      DS_BUILD_TRANSFORMER=1 \
      DS_BUILD_STOCHASTIC_TRANSFORMER=1 \
      DS_BUILD_SPARSE_ATTN=0 \
      DS_BUILD_TRANSFORMER_INFERENCE=0 \
      DS_BUILD_INFERENCE_CORE_OPS=0 \
      DS_BUILD_SPATIAL_INFERENCE=0 \
      DS_BUILD_CUTLASS_OPS=0 \
      DS_BUILD_RAGGED_OPS=0 \
      DS_BUILD_RAGGED_DEVICE_OPS=0 \
      DS_BUILD_OPS=0 \
      pip3 install --upgrade deepspeed einops psutil pydantic==2.11.9 hjson pydantic-core==2.33.2 msgpack typing_inspection annotated_types py-cpuinfo --no-cache-dir --target=$DEEPSPEED_PATH --no-build-isolation --no-deps

      deactivate
      # cd from pytorch_build/flash-attention back to the starting directory
      cd ../..
      rm -rf pytorch_build


      if [[ "${USER}" != "root" ]] && [ -n "${SUDO}" ]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${INSTALL_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi

      # cleanup: the EXIT trap on TRITON_BUILD_ROOT and PYTORCH_BUILD_ROOT
      # (set at the start of the BUILD_PYTORCH=1 branch) handles
      # triton/torchinductor cache and source-build tree removal. The
      # previous blanket
      #   ${SUDO} rm -rf /tmp/amd_triton_kernel* /tmp/can*
      # was unsafe (`/tmp/can*` matches arbitrary unrelated files
      # under /tmp) and racy with concurrent pytorch builds.
      # Restore the original CWD (we cd'd into PYTORCH_BUILD_ROOT for the
      # source-build above). The intel-onemkl installer cleanup that used
      # to live here is gone -- we no longer download it.
      cd "${PYTORCH_ORIG_CWD}"

   fi
fi

# create a module file for pytorch
#
# Modulefile-write sudo: canonical PKG_SUDO pattern (job 8063 audit;
# see netcdf_setup.sh for the lying-probe failure mode this replaces).
PKG_SUDO_MOD=$([ "${EUID:-$(id -u)}" -eq 0 ] && echo "" || echo "sudo")
${PKG_SUDO_MOD} mkdir -p ${MODULE_PATH}

# the - option suppresses tabs
cat <<-EOF | ${PKG_SUDO_MOD} tee ${MODULE_PATH}/${PYTORCH_VERSION}.lua
	whatis("PyTorch version ${PYTORCH_VERSION} with ROCm Support")

	prereq("rocm/${ROCM_VERSION}")
	-- openmpi is required because libtorch_cpu links libmpi.so when
	-- USE_MPI=1 was set at build time (which it is in pytorch_setup.sh).
	load("${MPI_MODULE}")
	-- magma provides libmagma.so on LD_LIBRARY_PATH (and MAGMA_HOME
	-- for any downstream cmake build that re-uses our toolchain).
	-- Without this, "import torch" fails at runtime with
	-- ImportError: libmagma.so: cannot open shared object file.
	load("magma")
	conflict("miniconda3")
	prepend_path("PYTHONPATH","${FLASHATTENTION_PATH}")
	prepend_path("PYTHONPATH","${FLASHATTENTION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/flash_attn-${FLASHATTENTION_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${SAGEATTENTION_PATH}")
	prepend_path("PYTHONPATH","${TRANSFORMERS_PATH}")
	prepend_path("PYTHONPATH","${TORCHAUDIO_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchaudio-${TORCHAUDIO_VERSION}a0+${TORCHAUDIO_HASH}-py3.${PYTHON_VERSION}-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/torchvision-${TORCHVISION_VERSION}+${TORCHVISION_HASH}-py3.${PYTHON_VERSION}-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}/lib/python3.${PYTHON_VERSION}/site-packages/pillow-${PILLOW_VERSION}-py3.${PYTHON_VERSION}-linux-x86_64.egg")
	prepend_path("PYTHONPATH","${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages")
	prepend_path("PYTHONPATH","${PYTORCH_PATH}")
	prepend_path("PYTHONPATH","${TORCHAUDIO_PATH}")
	prepend_path("PYTHONPATH","${TORCHVISION_PATH}")
	prepend_path("PYTHONPATH","${DEEPSPEED_PATH}")
	prepend_path("PYTHONPATH","${INSTALL_PATH}/pypackages")
	prepend_path("PYTHONPATH","${TRITON_PATH}")

	prepend_path("PATH","${PYTORCH_PATH}/bin")
	local user = os.getenv("USER")
	setenv("MIOPEN_USER_DB_PATH", "/tmp/" .. user .. "/my-miopen-cache")
	setenv("MIOPEN_CUSTOM_CACHE_DIR", "/tmp/" .. user .. "/my-miopen-cache")
	setenv("Torch_DIR","${PYTORCH_PATH}/lib/python3.${PYTHON_VERSION}/site-packages")
EOF
# An alternate module with tunable gemms
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${PYTORCH_VERSION}_tunableop_enabled.lua
	whatis("PyTorch version ${PYTORCH_VERSION} with ROCm Support and Tunable GEMMS")

	load pytorch
	setenv("PYTORCH_TUNABLEOP_ENABLED","1")
EOF
#	cmd1="mkdir -p $$HOME/miopen_tmpdir; export TMPDIR=$$HOME/miopen_tmpdir"
#	cmd2="rm -rf $$HOME/miopen_tmpdir; unset TMPDIR"
#	execute{cmd=cmd1, modeA={"load"}}
#	execute{cmd=cmd2, modeA={"unload"}}

#pip download --only-binary :all: --dest /opt/wheel_files_6.0/pytorch-rocm --no-cache --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/rocm6.0
#cat > /opt/wheel_files_6.0/README_pytorch <<-EOF
#	To install the pytorch package for ROCM 6.0
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torch-2.3.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#	   pip3 install /opt/wheel_files-6.0/pytorch-rocm/torchvision-0.18.0.dev20240301+rocm6.0-cp310-cp310-linux_x86_64.whl
#EOF

