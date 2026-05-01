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
# BUILD_<X> flags for packages that previously had no top-level gate.
# These default to 1 (matching the previous "always" behavior); when
# --packages is used these are flipped to 0 for every package not on the
# whitelist so each block becomes uniformly gated.
: ${BUILD_OPENMPI:="1"}
: ${BUILD_MVAPICH:="1"}
: ${BUILD_ROCPROF_SYS:="1"}
: ${BUILD_ROCPROF_COMPUTE:="1"}
: ${BUILD_HIPIFLY:="1"}
: ${PACKAGES_INPUT:=""}      # comma- or space-separated whitelist; empty = all (subject to other flags)
: ${PYTHON_VERSION:="12"} # python3 minor release
: ${USE_MAKEFILE:="0"}
: ${QUICK_INSTALLS:="0"}     # 1 = skip long-pole (>~1h) packages
: ${REPLACE_EXISTING:="0"}   # 1 = remove prior rocmplus-<v> install + module dirs first
: ${KEEP_FAILED_INSTALLS:="0"}  # 1 = keep partial install dirs/modulefiles when a package fails (for post-mortem)

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
   echo "  --quick-installs [0 or 1]:  skip long-pole (>~1h) packages: pytorch, tensorflow, jax, ftorch, julia, magma, petsc, hpctoolkit, flang-new, cupy. Default $QUICK_INSTALLS"
   echo "  --replace-existing [0 or 1]:  per-package replacement -- before each package block, if its BUILD_<PKG> flag is 1, remove that one package's install + module dirs so the setup script reinstalls it. Packages whose BUILD_<PKG> is 0 (e.g. under --quick-installs 1 or not in --packages) keep their existing install untouched. Never touches \${TOP_INSTALL_PATH}/rocm-\${ROCM_VERSION} or \${TOP_MODULE_PATH}/rocm-\${ROCM_VERSION}. Also exempts miniconda3 and miniforge3, whose install dirs are shared across ROCm versions; to force a rebuild of those, manually rm -rf \${TOP_INSTALL_PATH}/miniconda3 (or miniforge3). Default $REPLACE_EXISTING"
   echo "  --keep-failed-installs [0 or 1]:  on a per-package failure, default (0) wipes the partial install dir + half-written modulefile so the next run starts clean. Set to 1 to leave the artifacts on disk for post-mortem inspection. Default $KEEP_FAILED_INSTALLS"
   echo "  --packages \"name1 name2 ...\":  whitelist; only these packages are built. Disables every other gated package (overrides --quick-installs for listed names). Recognized: flang-new, openmpi, mpi4py, mvapich, rocprof-sys, rocprof-compute, hpctoolkit, scorep, tau, cupy, hip-python, tensorflow, jax, ftorch, pytorch, magma, kokkos, miniconda3, miniforge3, hipfort, hipifly, hdf5, netcdf, fftw, petsc, hypre. Empty = all (subject to --quick-installs)."
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
      "--quick-installs")
          shift
          QUICK_INSTALLS=${1}
          reset-last
          ;;
      "--replace-existing")
          shift
          REPLACE_EXISTING=${1}
          reset-last
          ;;
      "--keep-failed-installs")
          shift
          KEEP_FAILED_INSTALLS=${1}
          reset-last
          ;;
      "--packages")
          shift
          PACKAGES_INPUT=${1}
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

# ── --quick-installs: disable long-pole packages (>~1h on this hardware) ──
# Each one gates a sub-script that has been observed to dominate wall time.
# This runs AFTER arg parsing so a user could (in theory) re-enable a single
# package by exporting BUILD_<name>=1 between this point and sub-script
# invocation; we don't expose per-package CLI flags here on purpose.
QUICK_INSTALLS_PKGS=( BUILD_PYTORCH BUILD_TENSORFLOW BUILD_JAX BUILD_FTORCH \
                     BUILD_JULIA BUILD_MAGMA BUILD_PETSC BUILD_HPCTOOLKIT \
                     BUILD_FLANGNEW BUILD_CUPY )
if [[ "${QUICK_INSTALLS}" == "1" ]]; then
   echo ""
   echo "QUICK_INSTALLS=1 -> disabling long-pole packages (>~1h):"
   for v in "${QUICK_INSTALLS_PKGS[@]}"; do
      printf "  %-22s %s -> 0\n" "${v}" "${!v}"
      eval "${v}=0"
   done
   echo ""
fi

# ── --packages: whitelist which packages to build ────────────────────
# Maps user-facing package names to their BUILD_<X> flag variable. Only
# names listed here are recognized by --packages; --packages "openmpi mpi4py"
# turns BUILD_<X>=0 for every package NOT in the list and BUILD_<X>=1 for
# every package that IS on the list (overriding any --quick-installs decision
# that might have turned it off). Order: --quick-installs runs first, then
# --packages, so explicitly whitelisted packages always build.
declare -A PKG_FLAG=(
   [flang-new]=BUILD_FLANGNEW
   [openmpi]=BUILD_OPENMPI
   [mpi4py]=BUILD_MPI4PY
   [mvapich]=BUILD_MVAPICH
   [rocprof-sys]=BUILD_ROCPROF_SYS
   [rocprof-compute]=BUILD_ROCPROF_COMPUTE
   [hpctoolkit]=BUILD_HPCTOOLKIT
   [scorep]=BUILD_SCOREP
   [tau]=BUILD_TAU
   [cupy]=BUILD_CUPY
   [hip-python]=BUILD_HIP_PYTHON
   [tensorflow]=BUILD_TENSORFLOW
   [jax]=BUILD_JAX
   [ftorch]=BUILD_FTORCH
   [pytorch]=BUILD_PYTORCH
   [magma]=BUILD_MAGMA
   [kokkos]=BUILD_KOKKOS
   [miniconda3]=BUILD_MINICONDA3
   [miniforge3]=BUILD_MINIFORGE3
   [hipfort]=BUILD_HIPFORT
   [hipifly]=BUILD_HIPIFLY
   [hdf5]=BUILD_HDF5
   [netcdf]=BUILD_NETCDF
   [fftw]=BUILD_FFTW
   [petsc]=BUILD_PETSC
   [hypre]=BUILD_HYPRE
)

PACKAGES_NORM="${PACKAGES_INPUT//,/ }"
read -r -a PACKAGES_ARR <<< "${PACKAGES_NORM}"

if (( ${#PACKAGES_ARR[@]} > 0 )); then
   # Validate all requested names first; abort on unknown.
   UNKNOWN_PKGS=()
   for p in "${PACKAGES_ARR[@]}"; do
      if [[ -z "${PKG_FLAG[${p}]:-}" ]]; then
         UNKNOWN_PKGS+=("${p}")
      fi
   done
   if (( ${#UNKNOWN_PKGS[@]} > 0 )); then
      echo "ERROR: --packages contains unknown name(s): ${UNKNOWN_PKGS[*]}" >&2
      echo "       Recognized names: ${!PKG_FLAG[*]}" >&2
      exit 1
   fi

   echo ""
   echo "PACKAGES whitelist active. Disabling all packages, then enabling:"
   # Disable every gated package first.
   for flag in "${PKG_FLAG[@]}"; do
      eval "${flag}=0"
   done
   # Then enable the requested ones (overrides --quick-installs).
   for p in "${PACKAGES_ARR[@]}"; do
      flag="${PKG_FLAG[${p}]}"
      printf "  %-18s -> %s=1\n" "${p}" "${flag}"
      eval "${flag}=1"
   done
   echo ""
fi

# ── Logging setup ────────────────────────────────────────────────────
# Per-package logs go under logs_<date>/rocm-<version>_<jobid>/ so that
# concurrent or sequential same-day sweep jobs don't trample each other's
# log_<pkg>_<date>.txt files. Audited as P2 in slurm-7934-rocmplus-7.0.2.out:
# log_openmpi_04_30_2026.txt from job 7934 was overwritten by job 7935
# within minutes of 7934 ending, leaving us with no openmpi log for 7934.
# SLURM_JOB_ID is set in sbatch context; falls back to pid for ad-hoc runs.
TODAY=$(date +%m_%d_%Y)
LOG_DIR="${PWD}/logs_${TODAY}/rocm-${ROCM_VERSION}_${SLURM_JOB_ID:-pid$$}"
mkdir -p "${LOG_DIR}"

# Per-package outcome tracking. Three buckets:
#   SUCCESS_PKGS  -- built or already-installed and verified clean.
#   FAILED_PKGS   -- the setup script exited non-zero. Partial install
#                    artifacts are wiped automatically (unless
#                    --keep-failed-installs 1) so a re-run starts clean.
#   SKIPPED_PKGS  -- a declared dependency failed or was skipped, so the
#                    build was not even attempted.
#
# Without this, a failed sub-script silently returned rc=0 (because
# `tee` was the last command in the pipe), and main_setup.sh advertised
# success even when xpmem / pnetcdf / openmpi etc. blew up. Audited as
# P3 in slurm-7865-rocmplus-7.0.2.out.
FAILED_PKGS=()
SUCCESS_PKGS=()
SKIPPED_PKGS=()

# cleanup_pkg <label> -- remove install dirs and modulefiles for a
# package whose setup script just failed. Lookup tables PKG_CLEAN_DIRS
# and PKG_CLEAN_MODS are populated below (after ROCMPLUS is defined).
# Globs are expanded by ${SUDO} rm -rf via the shell, matching the same
# pattern replace_pkg uses upstream.
cleanup_pkg() {
   local label="$1"
   if [ "${KEEP_FAILED_INSTALLS}" = "1" ]; then
      echo "### KEEP_FAILED_INSTALLS=1: leaving partial artifacts for ${label} on disk."
      return 0
   fi
   local dirs="${PKG_CLEAN_DIRS[${label}]:-}"
   local mods="${PKG_CLEAN_MODS[${label}]:-}"
   if [ -z "${dirs}" ] && [ -z "${mods}" ]; then
      # No cleanup metadata for this label (e.g., baseospackages, lmod).
      # That is intentional -- those steps don't install into ROCMPLUS.
      return 0
   fi
   echo "### Cleaning up partial install artifacts for ${label}..."
   if [ -n "${dirs}" ]; then
      # `eval` so that globs like ${ROCMPLUS}/openmpi* expand correctly.
      eval ${SUDO:-sudo} rm -rf -- ${dirs} 2>/dev/null || true
   fi
   if [ -n "${mods}" ]; then
      eval ${SUDO:-sudo} rm -rf -- ${mods} 2>/dev/null || true
   fi
}

# Sentinel return codes for setup scripts. Both reclassify the result as
# SKIPPED (not FAILED) and do not force a non-zero overall exit on their
# own. Distinguished so the per-package summary tells the operator WHY
# the package was skipped:
#
#   MISSING_PREREQ_RC=42 -- preflight_modules failed: a required module
#       wasn't loadable (e.g., openmpi failed earlier so its module was
#       never written, or the user typoed a module name). Each setup
#       script defines its own copy of this constant (see e.g.
#       comm/scripts/openmpi_setup.sh); kept in sync by convention.
#
#   NOOP_RC=43 -- the setup script intentionally declined to do anything
#       (e.g., mvapich on Ubuntu where the install path isn't
#       implemented; rocprof-sys/rocprof-compute when their
#       --install-from-source flag is 0 because the SDK already ships
#       these tools). The script ran cleanly to its no-op exit; no
#       artifacts to clean up. Audited as P5 in
#       slurm-7934-rocmplus-7.0.2.out: those scripts were misclassified
#       as OK, making the summary lie about what was actually built.
MISSING_PREREQ_RC=42
NOOP_RC=43

run_and_log() {
   local log_name="$1"
   shift
   # PIPESTATUS[0] is the exit status of the actual sub-script (before tee).
   "$@" 2>&1 | tee "${LOG_DIR}/log_${log_name}_${TODAY}.txt"
   local rc=${PIPESTATUS[0]}
   if [ "${rc}" -eq 0 ]; then
      SUCCESS_PKGS+=("${log_name}")
   elif [ "${rc}" -eq "${MISSING_PREREQ_RC}" ]; then
      # The sub-script's preflight_modules call failed: a required
      # module wasn't available. Treat as SKIPPED, not FAILED.
      # No cleanup -- the script aborted before installing anything.
      SKIPPED_PKGS+=("${log_name}(missing-prereq)")
      echo ""
      echo "### SKIP ${log_name}: a required module was not available."
      echo "### See ${LOG_DIR}/log_${log_name}_${TODAY}.txt for which module."
      echo "### No artifacts created; nothing to clean up."
      echo ""
   elif [ "${rc}" -eq "${NOOP_RC}" ]; then
      # The sub-script declined the install on purpose (unsupported
      # distro, --install-from-source 0, etc.). Treat as SKIPPED, not
      # FAILED. No cleanup -- the script never wrote anything.
      SKIPPED_PKGS+=("${log_name}(no-op)")
      echo ""
      echo "### SKIP ${log_name}: setup script intentionally declined to install."
      echo "### See ${LOG_DIR}/log_${log_name}_${TODAY}.txt for the reason."
      echo "### No artifacts created; nothing to clean up."
      echo ""
   else
      FAILED_PKGS+=("${log_name}(rc=${rc})")
      echo ""
      echo "######################################################"
      echo "### WARNING: ${log_name} setup script exited rc=${rc}."
      echo "### See ${LOG_DIR}/log_${log_name}_${TODAY}.txt for details."
      echo "### main_setup.sh will continue with remaining packages."
      echo "### Packages whose preflight requires ${log_name}'s module"
      echo "### will mark themselves SKIPPED on entry."
      echo "### main_setup.sh will exit non-zero at the end."
      echo "######################################################"
      echo ""
      cleanup_pkg "${log_name}"
   fi
   return ${rc}
}

# Print a per-run summary on EXIT and propagate failure as a non-zero
# exit code. Critical for the rocmplus sweep: dependent jobs use
# --dependency=afterany so the chain proceeds either way, but we still
# want sacct + the slurm log to clearly mark which versions had package
# failures. SKIPPED alone does NOT force non-zero -- the chain ran
# cleanly given the constraint imposed by the actual FAILED package.
final_summary() {
   local saved_rc=$?
   echo ""
   echo "=================================================================="
   echo "  main_setup.sh per-package summary for rocm-${ROCM_VERSION:-?}"
   echo "=================================================================="
   if [ ${#SUCCESS_PKGS[@]} -gt 0 ]; then
      echo "  OK       (${#SUCCESS_PKGS[@]}): ${SUCCESS_PKGS[*]}"
   fi
   if [ ${#SKIPPED_PKGS[@]} -gt 0 ]; then
      echo "  SKIPPED  (${#SKIPPED_PKGS[@]}): ${SKIPPED_PKGS[*]}"
   fi
   if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
      echo "  FAILED   (${#FAILED_PKGS[@]}): ${FAILED_PKGS[*]}"
      echo "=================================================================="
      # If we got here on a normal path with zero saved_rc, force non-zero
      # so callers (the slurm sbatch, sacct, the dependency chain logger)
      # see this version as failed.
      [ "${saved_rc}" -eq 0 ] && exit 1
   else
      echo "=================================================================="
   fi
}
trap final_summary EXIT

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
echo "  QUICK_INSTALLS   : ${QUICK_INSTALLS}"
echo "  REPLACE_EXISTING : ${REPLACE_EXISTING}"
echo "  KEEP_FAILED      : ${KEEP_FAILED_INSTALLS}"
echo "  PACKAGES         : ${PACKAGES_INPUT:-<all>}"
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

# ── Cleanup tables for failed installs ───────────────────────────────
#
# When a package's setup script exits with a non-zero, non-MISSING_PREREQ
# rc, run_and_log calls
# cleanup_pkg <label>, which `rm -rf`s every entry in the two tables
# below for that label (unless --keep-failed-installs 1 is set).
# Globs are intentional and are expanded by the shell at cleanup time
# (see cleanup_pkg). These mirror the install patterns already passed
# to the upstream `replace_pkg` helper, so any new package added to
# main_setup.sh should add an entry here too.
declare -A PKG_CLEAN_DIRS=(
   [flang-new]="${ROCMPLUS}/flang-new"
   [openmpi]="${ROCMPLUS}/openmpi* ${ROCMPLUS}/xpmem-* ${ROCMPLUS}/ucx-* ${ROCMPLUS}/ucc-*"
   [mpi4py]="${ROCMPLUS}/mpi4py"
   [mvapich]="${ROCMPLUS}/mvapich"
   [rocprof-sys]="${ROCMPLUS}/rocprofiler-system"
   [rocprof-compute]="${ROCMPLUS}/rocprofiler-compute"
   [hpctoolkit]="${ROCMPLUS}/hpctoolkit ${ROCMPLUS}/hpcviewer"
   [scorep]="${ROCMPLUS}/scorep ${ROCMPLUS}/pdt"
   [tau]="${ROCMPLUS}/tau"
   [cupy]="${ROCMPLUS}/cupy"
   [hip-python]="${ROCMPLUS}/hip-python"
   [tensorflow]="${ROCMPLUS}/tensorflow"
   [jax]="${ROCMPLUS}/jax ${ROCMPLUS}/jaxlib"
   [ftorch]="${ROCMPLUS}/ftorch"
   [pytorch]="${ROCMPLUS}/pytorch"
   [magma]="${ROCMPLUS}/magma"
   [kokkos]="${ROCMPLUS}/kokkos"
   [miniconda3]="${TOP_INSTALL_PATH}/miniconda3"
   [miniforge3]="${TOP_INSTALL_PATH}/miniforge3"
   [hipfort]="${ROCMPLUS}/hipfort"
   [hipifly]="${ROCMPLUS}/hipifly"
   [hdf5]="${ROCMPLUS}/hdf5"
   [netcdf]="${ROCMPLUS}/netcdf"
   [fftw]="${ROCMPLUS}/fftw"
   [petsc]="${ROCMPLUS}/petsc"
   [hypre]="${ROCMPLUS}/hypre"
)
declare -A PKG_CLEAN_MODS=(
   [flang-new]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/amdflang-new"
   [openmpi]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/openmpi"
   [mpi4py]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/mpi4py"
   [mvapich]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/mvapich"
   [rocprof-sys]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/rocprofiler-system"
   [rocprof-compute]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/rocprofiler-compute"
   [hpctoolkit]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hpctoolkit"
   [scorep]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/scorep"
   [tau]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/tau"
   [cupy]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/cupy"
   [hip-python]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hip-python"
   [tensorflow]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/tensorflow"
   [jax]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/jax"
   [ftorch]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/ftorch"
   [pytorch]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/pytorch"
   [magma]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/magma"
   [kokkos]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/kokkos"
   [miniconda3]="${TOP_MODULE_PATH}/LinuxPlus/miniconda3"
   [miniforge3]="${TOP_MODULE_PATH}/LinuxPlus/miniforge3"
   [hipfort]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hipfort_from_source"
   [hipifly]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hipifly"
   [hdf5]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hdf5"
   [netcdf]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/netcdf-c ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/netcdf-fortran"
   [fftw]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/fftw"
   [petsc]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/petsc"
   [hypre]="${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hypre"
)

# ── --replace-existing: per-package replacement helper ───────────────
# Called before each per-package install block. Removes that one package's
# install + module dirs ONLY when:
#   1. REPLACE_EXISTING=1, AND
#   2. its build flag is 1 (or "always" for packages with no build gate)
# This way --quick-installs 1 does not nuke the long-pole packages
# (pytorch/jax/etc.) that the current run is *not* going to rebuild.
#
# Usage:
#   replace_pkg <build_flag_var | "always"> <install_path> [install_path...] \
#               -- <module_path> [module_path...]
# Paths may contain shell globs.
replace_pkg()
{
   [[ "${REPLACE_EXISTING}" == "1" ]] || return 0
   local flag="$1"; shift
   if [[ "${flag}" != "always" ]]; then
      # Indirect expansion: BUILD_PYTORCH, BUILD_JAX, etc.
      [[ "${!flag:-0}" == "1" ]] || return 0
   fi
   local label="install"
   shopt -s nullglob
   for p in "$@"; do
      if [[ "${p}" == "--" ]]; then label="module"; continue; fi
      local matched=( ${p} )
      for q in "${matched[@]}"; do
         echo "[replace_pkg] removing ${label}: ${q}"
         ${SUDO} rm -rf "${q}"
      done
   done
   shopt -u nullglob
}

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

replace_pkg BUILD_FLANGNEW "${ROCMPLUS}/flang-new" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/amdflang-new"
if [[ "${BUILD_FLANGNEW}" == "1" ]] && { [[ ! -d ${ROCMPLUS}/flang-new ]] || [ "${SKIP_ROCM_INSTALL}" == 0 ]; }; then
   run_and_log flang-new rocm/scripts/flang-new_setup.sh ${COMMON_OPTIONS} --build-flang-new ${BUILD_FLANGNEW} \
      $(path_args " " rocmplus-${ROCM_VERSION}/amdflang-new)
fi

# openmpi block also produces xpmem-*, ucx-*, ucc-* under ROCMPLUS.
replace_pkg BUILD_OPENMPI "${ROCMPLUS}/openmpi*" "${ROCMPLUS}/xpmem-*" "${ROCMPLUS}/ucx-*" "${ROCMPLUS}/ucc-*" \
   -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/openmpi"
if [[ "${BUILD_OPENMPI}" == "1" ]] && ! compgen -G "${ROCMPLUS}/openmpi*" >/dev/null; then
   run_and_log openmpi comm/scripts/openmpi_setup.sh ${COMMON_OPTIONS} --build-xpmem 1 \
      $(path_args " " rocmplus-${ROCM_VERSION}/openmpi)
fi

replace_pkg BUILD_MPI4PY "${ROCMPLUS}/mpi4py" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/mpi4py"
if [[ "${BUILD_MPI4PY}" == "1" ]] && [[ ! -d ${ROCMPLUS}/mpi4py ]]; then
   run_and_log mpi4py comm/scripts/mpi4py_setup.sh ${COMMON_OPTIONS} --build-mpi4py ${BUILD_MPI4PY} \
      $(path_args mpi4py rocmplus-${ROCM_VERSION}/mpi4py)
fi

replace_pkg BUILD_MVAPICH "${ROCMPLUS}/mvapich" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/mvapich"
if [[ "${BUILD_MVAPICH}" == "1" ]] && [[ ! -d ${ROCMPLUS}/mvapich ]]; then
   run_and_log mvapich comm/scripts/mvapich_setup.sh ${COMMON_OPTIONS} \
      $(path_args mvapich rocmplus-${ROCM_VERSION}/mvapich)
fi

replace_pkg BUILD_ROCPROF_SYS "${ROCMPLUS}/rocprofiler-system" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/rocprofiler-system"
if [[ "${BUILD_ROCPROF_SYS}" == "1" ]] && [[ ! -d ${ROCMPLUS}/rocprofiler-system ]]; then
   run_and_log rocprof-sys tools/scripts/rocprof-sys_setup.sh ${COMMON_OPTIONS} --install-rocprof-sys-from-source ${INSTALL_ROCPROF_SYS_FROM_SOURCE} --python-version ${PYTHON_VERSION} \
      $(path_args rocprofiler-system rocmplus-${ROCM_VERSION}/rocprofiler-system)
fi

replace_pkg BUILD_ROCPROF_COMPUTE "${ROCMPLUS}/rocprofiler-compute" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/rocprofiler-compute"
if [[ "${BUILD_ROCPROF_COMPUTE}" == "1" ]] && [[ ! -d ${ROCMPLUS}/rocprofiler-compute ]]; then
   run_and_log rocprof-compute tools/scripts/rocprof-compute_setup.sh ${COMMON_OPTIONS} --install-rocprof-compute-from-source ${INSTALL_ROCPROF_COMPUTE_FROM_SOURCE} --python-version ${PYTHON_VERSION} \
      $(path_args rocprofiler-compute rocmplus-${ROCM_VERSION}/rocprofiler-compute)
fi

#if [[ ! -d ${ROCMPLUS}/rocprofiler-sdk ]]; then
#   run_and_log rocprofiler-sdk tools/scripts/rocprofiler-sdk_setup.sh ${COMMON_OPTIONS} --build-rocprofiler-sdk ${BUILD_ROCPROFILER_SDK} --python-version ${PYTHON_VERSION} \
#      $(path_args rocprofiler-sdk rocmplus-${ROCM_VERSION}/rocprofiler-sdk)
#fi

replace_pkg BUILD_HPCTOOLKIT "${ROCMPLUS}/hpctoolkit" "${ROCMPLUS}/hpcviewer" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hpctoolkit"
if [[ "${BUILD_HPCTOOLKIT}" == "1" ]] && [[ ! -d ${ROCMPLUS}/hpctoolkit ]]; then
   run_and_log hpctoolkit tools/scripts/hpctoolkit_setup.sh ${COMMON_OPTIONS} --build-hpctoolkit ${BUILD_HPCTOOLKIT} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--hpctoolkit-install-path ${ROCMPLUS}/hpctoolkit --hpcviewer-install-path ${ROCMPLUS}/hpcviewer --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hpctoolkit")
fi

# scorep + tau share ${ROCMPLUS}/pdt; replace pdt only if BOTH scorep and tau
# are being rebuilt (otherwise leave it alone for whichever is staying).
if [[ "${BUILD_SCOREP}" == "1" && "${BUILD_TAU}" == "1" ]]; then
   replace_pkg always "${ROCMPLUS}/pdt"
fi
replace_pkg BUILD_SCOREP "${ROCMPLUS}/scorep" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/scorep"
if [[ "${BUILD_SCOREP}" == "1" ]] && [[ ! -d ${ROCMPLUS}/scorep ]]; then
   run_and_log scorep tools/scripts/scorep_setup.sh ${COMMON_OPTIONS} --build-scorep ${BUILD_SCOREP} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--scorep-install-path ${ROCMPLUS}/scorep --pdt-install-path ${ROCMPLUS}/pdt --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/scorep")
fi

#run_and_log grafana tools/scripts/grafana_setup.sh

replace_pkg BUILD_TAU "${ROCMPLUS}/tau" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/tau"
if [[ "${BUILD_TAU}" == "1" ]] && [[ ! -d ${ROCMPLUS}/tau ]]; then
   run_and_log tau tools/scripts/tau_setup.sh ${COMMON_OPTIONS} --build-tau ${BUILD_TAU} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--tau-install-path ${ROCMPLUS}/tau --pdt-install-path ${ROCMPLUS}/pdt --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/tau")
fi

#run_and_log compiler extras/scripts/compiler_setup.sh

replace_pkg BUILD_CUPY "${ROCMPLUS}/cupy" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/cupy"
if [[ "${BUILD_CUPY}" == "1" ]] && [[ ! -d ${ROCMPLUS}/cupy ]]; then
   run_and_log cupy extras/scripts/cupy_setup.sh ${COMMON_OPTIONS} --build-cupy ${BUILD_CUPY} \
      $(path_args cupy rocmplus-${ROCM_VERSION}/cupy)
fi

replace_pkg BUILD_HIP_PYTHON "${ROCMPLUS}/hip-python" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hip-python"
if [[ "${BUILD_HIP_PYTHON}" == "1" ]] && [[ ! -d ${ROCMPLUS}/hip-python ]]; then
   run_and_log hip-python extras/scripts/hip-python_setup.sh ${COMMON_OPTIONS} --build-hip-python ${BUILD_HIP_PYTHON} \
      $(path_args hip-python rocmplus-${ROCM_VERSION}/hip-python)
fi

replace_pkg BUILD_TENSORFLOW "${ROCMPLUS}/tensorflow" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/tensorflow"
if [[ "${BUILD_TENSORFLOW}" == "1" ]] && [[ ! -d ${ROCMPLUS}/tensorflow ]]; then
   run_and_log tensorflow extras/scripts/tensorflow_setup.sh ${COMMON_OPTIONS} --build-tensorflow ${BUILD_TENSORFLOW} \
      $(path_args tensorflow rocmplus-${ROCM_VERSION}/tensorflow)
fi

replace_pkg BUILD_JAX "${ROCMPLUS}/jax" "${ROCMPLUS}/jaxlib" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/jax"
if [[ "${BUILD_JAX}" == "1" ]] && [[ ! -d ${ROCMPLUS}/jax ]]; then
   run_and_log jax extras/scripts/jax_setup.sh ${COMMON_OPTIONS} --build-jax ${BUILD_JAX} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--jax-install-path ${ROCMPLUS}/jax --jaxlib-install-path ${ROCMPLUS}/jaxlib --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/jax")
fi

replace_pkg BUILD_FTORCH "${ROCMPLUS}/ftorch" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/ftorch"
if [[ "${BUILD_FTORCH}" == "1" ]] && [[ ! -d ${ROCMPLUS}/ftorch ]]; then
   run_and_log ftorch extras/scripts/ftorch_setup.sh ${COMMON_OPTIONS} --build-ftorch ${BUILD_FTORCH} \
      $(path_args ftorch rocmplus-${ROCM_VERSION}/ftorch)
fi

replace_pkg BUILD_PYTORCH "${ROCMPLUS}/pytorch" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/pytorch"
if [[ "${BUILD_PYTORCH}" == "1" ]] && [[ ! -d ${ROCMPLUS}/pytorch ]]; then
   run_and_log pytorch extras/scripts/pytorch_setup.sh ${COMMON_OPTIONS} --build-pytorch ${BUILD_PYTORCH} --python_version ${PYTHON_VERSION} \
      $(path_args pytorch rocmplus-${ROCM_VERSION}/pytorch)
fi

replace_pkg BUILD_MAGMA "${ROCMPLUS}/magma" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/magma"
if [[ "${BUILD_MAGMA}" == "1" ]] && [[ ! -d ${ROCMPLUS}/magma ]]; then
   run_and_log magma extras/scripts/magma_setup.sh ${COMMON_OPTIONS} --build-magma ${BUILD_MAGMA} \
      $(path_args magma rocmplus-${ROCM_VERSION}/magma)
fi

run_and_log apps extras/scripts/apps_setup.sh

replace_pkg BUILD_KOKKOS "${ROCMPLUS}/kokkos" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/kokkos"
if [[ "${BUILD_KOKKOS}" == "1" ]] && [[ ! -d ${ROCMPLUS}/kokkos ]]; then
   run_and_log kokkos extras/scripts/kokkos_setup.sh ${COMMON_OPTIONS} --build-kokkos ${BUILD_KOKKOS} \
      $(path_args kokkos rocmplus-${ROCM_VERSION}/kokkos)
fi

# miniconda3 / miniforge3 are intentionally exempt from --replace-existing.
# Their install paths (${TOP_INSTALL_PATH}/miniconda3, ${TOP_INSTALL_PATH}/
# miniforge3) and module dirs (${TOP_MODULE_PATH}/LinuxPlus/...) are SHARED
# across ROCm versions -- they don't depend on which ROCm release the
# orchestrator is currently iterating. With multi-version sweeps invoked
# under --replace-existing 1, calling replace_pkg here would delete the
# install at the start of every ROCm-version pass and force a full rebuild
# of conda/forge per version, which is pure waste (the result is identical).
# The downstream `[[ ! -d ... ]]` guard below already short-circuits when
# the install survives, so this is the only change needed. To force a
# rebuild, the operator removes ${TOP_INSTALL_PATH}/miniconda3 (or
# miniforge3) by hand.
if [[ "${BUILD_MINICONDA3}" == "1" ]] && [[ ! -d ${TOP_INSTALL_PATH}/miniconda3 ]]; then
   run_and_log miniconda3 extras/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniconda3 ${BUILD_MINICONDA3} --python-version ${PYTHON_VERSION} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH}/miniconda3 --module-path ${TOP_MODULE_PATH}/LinuxPlus/miniconda3")
fi

if [[ "${BUILD_MINIFORGE3}" == "1" ]] && [[ ! -d ${TOP_INSTALL_PATH}/miniforge3 ]]; then
   run_and_log miniforge3 extras/scripts/miniforge3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniforge3 ${BUILD_MINIFORGE3} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH}/miniforge3 --module-path ${TOP_MODULE_PATH}/LinuxPlus/miniforge3")
fi

replace_pkg BUILD_HIPFORT "${ROCMPLUS}/hipfort" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hipfort_from_source"
if [[ "${BUILD_HIPFORT}" == "1" ]] && [[ ! -d ${ROCMPLUS}/hipfort ]]; then
   run_and_log hipfort extras/scripts/hipfort_setup.sh ${COMMON_OPTIONS} --build-hipfort ${BUILD_HIPFORT} \
      $(path_args hipfort rocmplus-${ROCM_VERSION}/hipfort_from_source)
fi

replace_pkg BUILD_HIPIFLY "${ROCMPLUS}/hipifly" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hipifly"
if [[ "${BUILD_HIPIFLY}" == "1" ]] && [[ ! -d ${ROCMPLUS}/hipifly ]]; then
   run_and_log hipifly extras/scripts/hipifly_setup.sh --rocm-version ${ROCM_VERSION} --hipifly-module ${HIPIFLY_MODULE} \
      $(path_args hipifly rocmplus-${ROCM_VERSION}/hipifly)
fi

replace_pkg BUILD_HDF5 "${ROCMPLUS}/hdf5" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hdf5"
if [[ "${BUILD_HDF5}" == "1" ]] && [[ ! -d ${ROCMPLUS}/hdf5 ]]; then
   run_and_log hdf5 extras/scripts/hdf5_setup.sh ${COMMON_OPTIONS} --build-hdf5 ${BUILD_HDF5} \
      $(path_args hdf5 rocmplus-${ROCM_VERSION}/hdf5)
fi

replace_pkg BUILD_NETCDF "${ROCMPLUS}/netcdf" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/netcdf-c" "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/netcdf-fortran"
if [[ "${BUILD_NETCDF}" == "1" ]] && [[ ! -d ${ROCMPLUS}/netcdf ]]; then
   run_and_log netcdf extras/scripts/netcdf_setup.sh ${COMMON_OPTIONS} --build-netcdf ${BUILD_NETCDF} \
      $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${ROCMPLUS}/netcdf --netcdf-c-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/netcdf-c --netcdf-f-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/netcdf-fortran")
fi

replace_pkg BUILD_FFTW "${ROCMPLUS}/fftw" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/fftw"
if [[ "${BUILD_FFTW}" == "1" ]] && [[ ! -d ${ROCMPLUS}/fftw ]]; then
   run_and_log fftw extras/scripts/fftw_setup.sh ${COMMON_OPTIONS} --build-fftw ${BUILD_FFTW} \
      $(path_args fftw rocmplus-${ROCM_VERSION}/fftw)
fi

#run_and_log x11vnc extras/scripts/x11vnc_setup.sh --build-x11vnc ${BUILD_X11VNC}

replace_pkg BUILD_PETSC "${ROCMPLUS}/petsc" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/petsc"
if [[ "${BUILD_PETSC}" == "1" ]] && [[ ! -d ${ROCMPLUS}/petsc ]]; then
   run_and_log petsc extras/scripts/petsc_setup.sh ${COMMON_OPTIONS} --build-petsc ${BUILD_PETSC} \
      $(path_args petsc rocmplus-${ROCM_VERSION}/petsc)
fi

replace_pkg BUILD_HYPRE "${ROCMPLUS}/hypre" -- "${TOP_MODULE_PATH}/rocmplus-${ROCM_VERSION}/hypre"
if [[ "${BUILD_HYPRE}" == "1" ]] && [[ ! -d ${ROCMPLUS}/hypre ]]; then
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
