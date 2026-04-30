#!/bin/bash

: ${ROCM_VERSION:=""}
: ${ROCM_INSTALLPATH:="/opt/"}
: ${TOP_INSTALL_PATH:="/opt"}
: ${TOP_MODULE_PATH:="/etc/lmod/modules"}
: ${BUILD_PYTORCH:="1"}
: ${BUILD_CUPY:="1"}
: ${BUILD_HIP_PYTHON:="1"}
: ${BUILD_TENSORFLOW:="1"}
: ${BUILD_JAX:="1"}
: ${BUILD_FTORCH:="1"}
: ${BUILD_JULIA:="1"}
: ${BUILD_MAGMA:="1"}
: ${BUILD_PETSC:="1"}
: ${BUILD_HYPRE:="1"}
: ${BUILD_SCOREP:="1"}
: ${BUILD_KOKKOS:="1"}
: ${BUILD_HIPFORT:="1"}
: ${BUILD_HDF5:="1"}
: ${BUILD_NETCDF:="1"}
: ${BUILD_FFTW:="1"}
: ${BUILD_MINICONDA3:="1"}
: ${BUILD_MINIFORGE3:="1"}
: ${BUILD_HPCTOOLKIT:="1"}
: ${BUILD_MPI4PY:="1"}
: ${BUILD_TAU:="1"}
: ${BUILD_X11VNC:="0"}
: ${BUILD_FLANGNEW:="0"}
: ${BUILD_ROCPROFILER_SDK:="1"}
: ${HIPIFLY_MODULE:="1"}
: ${PYTHON_VERSION:="12"} # python3 minor release
: ${USE_MAKEFILE:="0"}

INSTALL_ROCPROF_SYS_FROM_SOURCE=0
INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=0
AMDGPU_GFXMODEL_INPUT=""
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [[ "${DISTRO}" == "ubuntu" ]]; then
   if [[ "${DISTRO_VERSION}" == "22.04" ]]; then
      PYTHON_VERSION="10"
   fi
fi

reset-last()
{
   last() { echo "Unsupported argument :: ${1}"; }
}

usage()
{
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ]:  auto-detected from loaded module, or specify explicitly"
   echo "  --rocm-install-path [ ROCM_INSTALL_PATH ]:  default is $ROCM_INSTALLPATH"
   echo "  --top-install-path [ TOP_INSTALL_PATH ]:  top-level directory for software installation, default is $TOP_INSTALL_PATH"
   echo "  --top-module-path [ TOP_MODULE_PATH ]:  top-level directory for module files, default is $TOP_MODULE_PATH"
   echo "  --python-version [ PYTHON_VERSION ]: python3 minor release, default is $PYTHON_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ]: auto-detected via rocminfo, can specify multiple separated by semicolons (e.g. gfx942;gfx90a)"
   echo "  --install-rocprof-compute-from-source [0 or 1]:  default is $INSTALL_ROCPROF_COMPUTE_FROM_SOURCE (false)"
   echo "  --install-rocprof-sys-from-source [0 or 1]:  default is $INSTALL_ROCPROF_SYS_FROM_SOURCE (false)"
   echo "  --use-makefile [0 or 1]:  default is 0 (false)"
   echo "  --help: prints this message"
   exit 1
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
      "--rocm-install-path")
          shift
          ROCM_INSTALLPATH=${1}
          reset-last
          ;;
      "--top-install-path")
          shift
          TOP_INSTALL_PATH=${1}
          reset-last
          ;;
      "--top-module-path")
          shift
          TOP_MODULE_PATH=${1}
          reset-last
          ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--install-rocprof-sys-from-source")
          shift
          INSTALL_ROCPROF_SYS_FROM_SOURCE=${1}
          reset-last
          ;;
      "--install-rocprof-compute-from-source")
          shift
          INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=${1}
          reset-last
          ;;
      "--use-makefile")
          shift
          USE_MAKEFILE=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

# ── Detect ROCm version from loaded module (if any) ──────────────────
# Always check what's loaded so we can decide whether to skip the install.
ROCM_MODULE_VERSION=""

if [ -n "${ROCM_PATH}" ] && [ -f "${ROCM_PATH}/.info/version" ]; then
   ROCM_MODULE_VERSION=$(cat "${ROCM_PATH}/.info/version" | cut -f1 -d'-')
   echo "Detected loaded ROCm module version ${ROCM_MODULE_VERSION} (ROCM_PATH=${ROCM_PATH})"
fi

if [ -z "${ROCM_MODULE_VERSION}" ]; then
   ROCM_AFAR_LINE=$(module list 2>&1 | grep 'rocm/afar' || true)
   if [[ $ROCM_AFAR_LINE =~ (rocm/afar-[0-9.]*) ]]; then
      ROCM_MODULE_VERSION=$(echo "${BASH_REMATCH[1]}" | sed -e 's!rocm/!!')
      echo "Detected loaded ROCm AFAR module: ${ROCM_MODULE_VERSION}"
   fi
fi

if [ -z "${ROCM_MODULE_VERSION}" ]; then
   ROCM_THEROCK_LINE=$(module list 2>&1 | grep 'rocm/therock' || true)
   if [[ $ROCM_THEROCK_LINE =~ (rocm/therock-[0-9.]*) ]]; then
      ROCM_MODULE_VERSION=$(echo "${BASH_REMATCH[1]}" | sed -e 's!rocm/!!')
      echo "Detected loaded ROCm TheRock module: ${ROCM_MODULE_VERSION}"
   fi
fi

# If --rocm-version was not provided, use detected version or fall back.
if [ -z "${ROCM_VERSION}" ]; then
   if [ -n "${ROCM_MODULE_VERSION}" ]; then
      ROCM_VERSION="${ROCM_MODULE_VERSION}"
      echo "Using detected ROCm version: ${ROCM_VERSION}"
   else
      echo "WARNING: ROCm version not specified and no ROCm module detected."
      echo -n "         Proceed with default ROCm version 6.2.0? [y/N] (timeout 60s, default N) "
      read -r -t 60 REPLY || true
      if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
         ROCM_VERSION="6.2.0"
         echo "         Using default ROCm version ${ROCM_VERSION}"
      else
         echo "Aborting. Please load a ROCm module or specify --rocm-version."
         exit 1
      fi
   fi
fi

# ── GPU architecture detection ───────────────────────────────────────
# If --amdgpu-gfxmodel was provided, use it; otherwise try rocminfo.
if [ -n "${AMDGPU_GFXMODEL_INPUT}" ]; then
   AMDGPU_GFXMODEL="${AMDGPU_GFXMODEL_INPUT}"
else
   AMDGPU_GFXMODEL=$(rocminfo 2>/dev/null | grep gfx | sed -e 's/Name://' | head -1 | sed 's/ //g' || true)
   if [ -z "${AMDGPU_GFXMODEL}" ]; then
      echo "ERROR: No GPU architecture specified and rocminfo is not available or found no GPUs."
      echo "       Please provide --amdgpu-gfxmodel (e.g. --amdgpu-gfxmodel gfx942 or --amdgpu-gfxmodel 'gfx942;gfx90a')"
      exit 1
   fi
fi

if [ "${USE_MAKEFILE}" == 1 ]; then
   exit
fi

# ── Logging setup ────────────────────────────────────────────────────
TODAY=$(date +%m_%d_%Y)
LOG_DIR="${PWD}/logs_${TODAY}"
mkdir -p "${LOG_DIR}"

run_and_log() {
   local log_name="$1"
   shift
   "$@" 2>&1 | tee "${LOG_DIR}/log_${log_name}_${TODAY}.txt"
}

# ── Configuration summary ────────────────────────────────────────────
echo ""
echo "=============================================="
echo "  Installation Configuration Summary"
echo "=============================================="
echo "  TOP_INSTALL_PATH : ${TOP_INSTALL_PATH}"
echo "  TOP_MODULE_PATH  : ${TOP_MODULE_PATH}"
echo "  ROCM_VERSION     : ${ROCM_VERSION}"
echo "  AMDGPU_GFXMODEL  : ${AMDGPU_GFXMODEL}"
echo "  PYTHON_VERSION   : 3.${PYTHON_VERSION}"
echo "  ROCM_INSTALLPATH : ${ROCM_INSTALLPATH}"
echo "  DISTRO           : ${DISTRO} ${DISTRO_VERSION}"
echo "  LOG_DIR          : ${LOG_DIR}"
echo "=============================================="
echo ""
echo -n "Does this look correct? [Y/n] (default Y, continuing in 30s) "
if read -r -t 30 CONFIRM; then
   if [[ "${CONFIRM}" =~ ^[Nn]$ ]]; then
      echo "Aborting."
      exit 1
   fi
else
   echo ""
   echo "No response received, assuming yes..."
fi

# ── Derived paths ────────────────────────────────────────────────────
ROCMPLUS="${TOP_INSTALL_PATH}/rocmplus-${ROCM_VERSION}"

USE_CUSTOM_PATHS=0
if [[ "${TOP_INSTALL_PATH}" != "/opt" || "${TOP_MODULE_PATH}" != "/etc/lmod/modules" ]]; then
   USE_CUSTOM_PATHS=1
fi

COMMON_OPTIONS="--rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}"

# Helper: returns --install-path + --module-path flags for a given package.
# Usage: $(path_args <install_subpath> <module_category/package>)
path_args()
{
   if [ "${USE_CUSTOM_PATHS}" == 1 ]; then
      echo "--install-path ${ROCMPLUS}/${1} --module-path ${TOP_MODULE_PATH}/${2}"
   fi
}

# ── ROCm base install ────────────────────────────────────────────────
SKIP_ROCM_INSTALL=0
if [ -n "${ROCM_MODULE_VERSION}" ] && [ "${ROCM_MODULE_VERSION}" == "${ROCM_VERSION}" ]; then
   echo "ROCm ${ROCM_VERSION} already loaded from module — skipping ROCm base installation"
   SKIP_ROCM_INSTALL=1
elif [ -n "${ROCM_MODULE_VERSION}" ] && [ "${ROCM_MODULE_VERSION}" != "${ROCM_VERSION}" ]; then
   echo "ERROR: Loaded ROCm module (${ROCM_MODULE_VERSION}) does not match requested version (${ROCM_VERSION})."
   echo "       Please unload the current module or use --rocm-version ${ROCM_MODULE_VERSION}"
   exit 1
fi

if [ "${SKIP_ROCM_INSTALL}" == 0 ]; then
   run_and_log baseospackages rocm/scripts/baseospackages_setup.sh

   run_and_log lmod rocm/scripts/lmod_setup.sh

   source ~/.bashrc

   run_and_log rocm rocm/scripts/rocm_setup.sh --rocm-version ${ROCM_VERSION}

   run_and_log rocm-rocprof-sys rocm/scripts/rocm_rocprof-sys_setup.sh --rocm-version ${ROCM_VERSION}

   run_and_log rocm-rocprof-compute rocm/scripts/rocm_rocprof-compute_setup.sh --rocm-version ${ROCM_VERSION}
else
   source ~/.bashrc
fi

# ── Package installation ─────────────────────────────────────────────
# Each block checks whether the package directory already exists before
# invoking the setup script, allowing incremental/rerun installs.

if [[ ! -d ${ROCMPLUS}/flang-new ]] || [ "${SKIP_ROCM_INSTALL}" == 0 ]; then
   run_and_log flang-new rocm/scripts/flang-new_setup.sh ${COMMON_OPTIONS} --build-flang-new ${BUILD_FLANGNEW} \
      $(path_args " " rocmplus-${ROCM_VERSION}/amdflang-new)
fi

if ! compgen -G "${ROCMPLUS}/openmpi*" >/dev/null; then
   run_and_log openmpi comm/scripts/openmpi_setup.sh ${COMMON_OPTIONS} --build-xpmem 1 \
      $(path_args " " rocmplus-${ROCM_VERSION}/openmpi)
fi

if [[ ! -d ${ROCMPLUS}/mpi4py ]]; then
   run_and_log mpi4py comm/scripts/mpi4py_setup.sh ${COMMON_OPTIONS} --build-mpi4py ${BUILD_MPI4PY} \
      $(path_args mpi4py rocmplus-${ROCM_VERSION}/mpi4py)
fi

if [[ ! -d ${ROCMPLUS}/mvapich ]]; then
   run_and_log mvapich comm/scripts/mvapich_setup.sh ${COMMON_OPTIONS} \
      $(path_args mvapich rocmplus-${ROCM_VERSION}/mvapich)
fi

if [[ ! -d ${ROCMPLUS}/rocprofiler-system ]]; then
   run_and_log rocprof-sys tools/scripts/rocprof-sys_setup.sh ${COMMON_OPTIONS} --install-rocprof-sys-from-source ${INSTALL_ROCPROF_SYS_FROM_SOURCE} --python-version ${PYTHON_VERSION} \
      $(path_args rocprofiler-system rocmplus-${ROCM_VERSION}/rocprofiler-system)
fi

if [[ ! -d ${ROCMPLUS}/rocprofiler-compute ]]; then
   run_and_log rocprof-compute tools/scripts/rocprof-compute_setup.sh ${COMMON_OPTIONS} --install-rocprof-compute-from-source ${INSTALL_ROCPROF_COMPUTE_FROM_SOURCE} --python-version ${PYTHON_VERSION} \
      $(path_args rocprofiler-compute rocmplus-${ROCM_VERSION}/rocprofiler-compute)
fi

#if [[ ! -d ${ROCMPLUS}/rocprofiler-sdk ]]; then
#   run_and_log rocprofiler-sdk tools/scripts/rocprofiler-sdk_setup.sh ${COMMON_OPTIONS} --build-rocprofiler-sdk ${BUILD_ROCPROFILER_SDK} --python-version ${PYTHON_VERSION} \
#      $(path_args rocprofiler-sdk rocmplus-${ROCM_VERSION}/rocprofiler-sdk)
#fi

if [[ ! -d ${ROCMPLUS}/hpctoolkit ]]; then
   run_and_log hpctoolkit tools/scripts/hpctoolkit_setup.sh ${COMMON_OPTIONS} --build-hpctoolkit ${BUILD_HPCTOOLKIT} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--hpctoolkit-install-path ${ROCMPLUS}/hpctoolkit --hpcviewer-install-path ${ROCMPLUS}/hpcviewer --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hpctoolkit")
fi

if [[ ! -d ${ROCMPLUS}/scorep ]]; then
   run_and_log scorep tools/scripts/scorep_setup.sh ${COMMON_OPTIONS} --build-scorep ${BUILD_SCOREP} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--scorep-install-path ${ROCMPLUS}/scorep --pdt-install-path ${ROCMPLUS}/pdt --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/scorep")
fi

#run_and_log grafana tools/scripts/grafana_setup.sh

if [[ ! -d ${ROCMPLUS}/tau ]]; then
   run_and_log tau tools/scripts/tau_setup.sh ${COMMON_OPTIONS} --build-tau ${BUILD_TAU} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--tau-install-path ${ROCMPLUS}/tau --pdt-install-path ${ROCMPLUS}/pdt --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/tau")
fi
exit

#run_and_log compiler extras/scripts/compiler_setup.sh

if [[ ! -d ${ROCMPLUS}/cupy ]]; then
   run_and_log cupy extras/scripts/cupy_setup.sh ${COMMON_OPTIONS} --build-cupy ${BUILD_CUPY} \
      $(path_args cupy rocmplus-${ROCM_VERSION}/cupy)
fi

if [[ ! -d ${ROCMPLUS}/hip-python ]]; then
   run_and_log hip-python extras/scripts/hip-python_setup.sh ${COMMON_OPTIONS} --build-hip-python ${BUILD_HIP_PYTHON} \
      $(path_args hip-python rocmplus-${ROCM_VERSION}/hip-python)
fi

if [[ ! -d ${ROCMPLUS}/tensorflow ]]; then
   run_and_log tensorflow extras/scripts/tensorflow_setup.sh ${COMMON_OPTIONS} --build-tensorflow ${BUILD_TENSORFLOW} \
      $(path_args tensorflow rocmplus-${ROCM_VERSION}/tensorflow)
fi

if [[ ! -d ${ROCMPLUS}/jax ]]; then
   run_and_log jax extras/scripts/jax_setup.sh ${COMMON_OPTIONS} --build-jax ${BUILD_JAX} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--jax-install-path ${ROCMPLUS}/jax --jaxlib-install-path ${ROCMPLUS}/jaxlib --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/jax")
fi

if [[ ! -d ${ROCMPLUS}/ftorch ]]; then
   run_and_log ftorch extras/scripts/ftorch_setup.sh ${COMMON_OPTIONS} --build-ftorch ${BUILD_FTORCH} \
      $(path_args ftorch rocmplus-${ROCM_VERSION}/ftorch)
fi

if [[ ! -d ${ROCMPLUS}/pytorch ]]; then
   run_and_log pytorch extras/scripts/pytorch_setup.sh ${COMMON_OPTIONS} --build-pytorch ${BUILD_PYTORCH} --python_version ${PYTHON_VERSION} \
      $(path_args pytorch rocmplus-${ROCM_VERSION}/pytorch)
fi

if [[ ! -d ${ROCMPLUS}/magma ]]; then
   run_and_log magma extras/scripts/magma_setup.sh ${COMMON_OPTIONS} --build-magma ${BUILD_MAGMA} \
      $(path_args magma rocmplus-${ROCM_VERSION}/magma)
fi

run_and_log apps extras/scripts/apps_setup.sh

if [[ ! -d ${ROCMPLUS}/kokkos ]]; then
   run_and_log kokkos extras/scripts/kokkos_setup.sh ${COMMON_OPTIONS} --build-kokkos ${BUILD_KOKKOS} \
      $(path_args kokkos rocmplus-${ROCM_VERSION}/kokkos)
fi

if [[ ! -d ${TOP_INSTALL_PATH}/miniconda3 ]]; then
   run_and_log miniconda3 extras/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniconda3 ${BUILD_MINICONDA3} --python-version ${PYTHON_VERSION} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH}/miniconda3 --module-path ${TOP_MODULE_PATH}/LinuxPlus/miniconda3")
fi

if [[ ! -d ${TOP_INSTALL_PATH}/miniforge3 ]]; then
   run_and_log miniforge3 extras/scripts/miniforge3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniforge3 ${BUILD_MINIFORGE3} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH}/miniforge3 --module-path ${TOP_MODULE_PATH}/LinuxPlus/miniforge3")
fi

if [[ ! -d ${ROCMPLUS}/hipfort ]]; then
   run_and_log hipfort extras/scripts/hipfort_setup.sh ${COMMON_OPTIONS} --build-hipfort ${BUILD_HIPFORT} \
      $(path_args hipfort rocmplus-${ROCM_VESION}/hipfort_from_source)
fi

if [[ ! -d ${ROCMPLUS}/hipifly ]]; then
   run_and_log hipifly extras/scripts/hipifly_setup.sh --rocm-version ${ROCM_VERSION} --hipifly-module ${HIPIFLY_MODULE} \
      $(path_args hipifly rocmplus-${ROCM_VESION}/hipifly)
fi

if [[ ! -d ${ROCMPLUS}/hdf5 ]]; then
   run_and_log hdf5 extras/scripts/hdf5_setup.sh ${COMMON_OPTIONS} --build-hdf5 ${BUILD_HDF5} \
      $(path_args hdf5 rocmplus-${ROCM_VESION}/hdf5)
fi

if [[ ! -d ${ROCMPLUS}/netcdf ]]; then
   run_and_log netcdf extras/scripts/netcdf_setup.sh ${COMMON_OPTIONS} --build-netcdf ${BUILD_NETCDF} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${ROCMPLUS}/netcdf --netcdf-c-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/netcdf-c --netcdf-f-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/netcdf-fortran")
fi

if [[ ! -d ${ROCMPLUS}/fftw ]]; then
   run_and_log fftw extras/scripts/fftw_setup.sh ${COMMON_OPTIONS} --build-fftw ${BUILD_FFTW} \
      $(path_args fftw rocmplus-${ROCM_VERSION}/fftw)
fi

#run_and_log x11vnc extras/scripts/x11vnc_setup.sh --build-x11vnc ${BUILD_X11VNC}

if [[ ! -d ${ROCMPLUS}/petsc ]]; then
   run_and_log petsc extras/scripts/petsc_setup.sh ${COMMON_OPTIONS} --build-petsc ${BUILD_PETSC} \
      $(path_args petsc rocmplus-${ROCM_VERSION}/petsc)
fi

if [[ ! -d ${ROCMPLUS}/hypre ]]; then
   run_and_log hypre extras/scripts/hypre_setup.sh ${COMMON_OPTIONS} --build-hypre ${BUILD_HYPRE} \
      $(path_args hypre rocmplus-${ROCM_VERSION}/hypre)
fi

#If ROCm should be installed in a different location
#if [ "${ROCM_INSTALLPATH}" != "/opt/" ]; then
#   ${SUDO} mv /opt/rocm-${ROCM_VERSION} ${ROCM_INSTALLPATH}
#   ${SUDO} mv /opt/rocmplus-${ROCM_VERSION} ${ROCM_INSTALLPATH}
#   ${SUDO} ln -sfn ${ROCM_INSTALLPATH}/rocm-${ROCM_VERSION} /etc/alternatives/rocm
#   ${SUDO} sed -i "s|\/opt\/|${ROCM_INSTALLPATH}|" /etc/lmod/modules/ROCm/*/*.lua
#fi

#run_and_log hpctrainingexamples git clone https://github.com/AMD/HPCTrainingExamples.git
