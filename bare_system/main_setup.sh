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
: ${QUICK_INSTALLS:="0"}     # 1 = skip packages whose wall is >= 20 min (see QUICK_INSTALLS_PKGS below)
: ${REPLACE_EXISTING:="0"}   # 1 = remove prior rocmplus-<v> install + module dirs first
: ${KEEP_FAILED_INSTALLS:="0"}  # 1 = keep partial install dirs/modulefiles when a package fails (for post-mortem)

# ── Per-package versions: leaf scripts own them ──────────────────────
# Every per-package setup script under {extras,tools,comm,rocm}/scripts/
# holds its own internal version default (PKG_VERSION declaration at
# the top of the script). main_setup.sh threads only the parent install
# directory via --install-path (which the migrated leaf scripts now
# treat as a parent dir + auto-append their own pkg-v${PKG_VERSION}
# subdir); --install-path-no-version is the leaf-side escape hatch for
# direct-invocation callers who want exact control of the final path.
# miniconda3 / miniforge3 use the same --install-path convention but
# rooted at TOP_INSTALL_PATH (outside the rocmplus tree, since they
# are ROCm-version-independent).
#
# Why: bumping a version is now a 1-line edit in the leaf script and
# the next sweep picks it up automatically. The older versioned install
# dir + .lua modulefile are left in place so multiple versions still
# coexist on disk. cupy_setup.sh additionally resolves CUPY_VERSION
# from a ROCm-aware default ("auto" -> 14.0.1 on ROCm >= 7.0, 13.6.0
# otherwise); jax_setup.sh has a similar policy gate that downshifts
# JAX_VERSION on ROCm 6.x.
#
# Operator escape hatches:
#   * Direct invocation:  pkg_setup.sh --<pkg>-version X.Y.Z ...
#   * Pin from main_setup.sh: edit the PKG_VERSION default in the leaf
#     script (NOT this file). Searches across the tree for the variable
#     name (e.g. `rg FFTW_VERSION extras/scripts/`) point at exactly
#     one place.
#
# mpi4py was the trial migration; the same shape (single PKG_VERSION,
# leaf appends version, orchestrator passes parent dir) applies to all
# 14 leaf scripts touched by this pass.

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
   echo "  --quick-installs [0 or 1]:  skip packages whose wall >= 20 min (measured from job 8065 sweep): pytorch (91m), tensorflow (70m), jax (34m, when policy gate allows). Also skips ftorch (transitive: needs pytorch) and julia (dormant: no install wired). Threshold raised from 15 -> 20 min after job 8065 audit moved petsc (17m) and scorep (17m) under the cutoff. Default $QUICK_INSTALLS"
   echo "  --replace-existing [0 or 1]:  per-package replacement -- before each package block, if its BUILD_<PKG> flag is 1, remove that one package's install + module dirs so the setup script reinstalls it. Packages whose BUILD_<PKG> is 0 (e.g. under --quick-installs 1 or not in --packages) keep their existing install untouched. Never touches \${TOP_INSTALL_PATH}/rocm-\${ROCM_VERSION} or \${TOP_MODULE_PATH}/rocm-\${ROCM_VERSION}. Also exempts miniconda3 and miniforge3, whose install dirs are shared across ROCm versions; to force a rebuild of those, manually rm -rf the versioned subdir under \${TOP_INSTALL_PATH} (the version itself lives in the leaf script). Default $REPLACE_EXISTING"
   echo "  --keep-failed-installs [0 or 1]:  on a per-package failure, default (0) wipes the partial install dir + half-written modulefile so the next run starts clean. Set to 1 to leave the artifacts on disk for post-mortem inspection. Default $KEEP_FAILED_INSTALLS"
   echo "  --packages \"name1 name2 ...\":  whitelist; only these packages are built. Disables every other gated package (overrides --quick-installs for listed names). Recognized: flang-new, openmpi, mpi4py, mvapich, rocprof-sys, rocprof-compute, hpctoolkit, scorep, tau, cupy, hip-python, tensorflow, jax, ftorch, pytorch, magma, kokkos, miniconda3, miniforge3, hipfort, hipifly, hdf5, netcdf, fftw, petsc, hypre. Empty = all (subject to --quick-installs)."
   echo "  --rocm-rc-prefix [ FAMILY ]:  release-candidate family name (e.g. 'therock', 'afar'). Auto-detected from \${ROCM_PATH} basename for rocm-{therock,afar}-* trees. Empty for regular releases. When non-empty, install/module dirs become rocmplus-\${FAMILY}-\${ROCM_VERSION}/ instead of rocmplus-\${ROCM_VERSION}/. Default: auto-detected (empty for regular releases)."
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
      "--rocm-rc-prefix")
          shift
          ROCM_RC_PREFIX=${1}
          ROCM_RC_PREFIX_USER_SET=1
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

# ── Detect ROCm version + RC prefix from loaded module (if any) ──────
# ROCM_MODULE_VERSION is the SDK numeric (from .info/version), used for
# both the loaded-vs-requested cross-check below and (when --rocm-version
# was not explicitly passed) as the fallback for ROCM_VERSION itself.
#
# ROCM_RC_PREFIX is empty for a regular release (rocm-7.2.1) and is the
# release-candidate FAMILY NAME for tagged trees (e.g. 'therock' for
# rocm-therock-23.2.0, 'afar' for rocm-afar-22.2.0). The dash separator
# between prefix and ROCM_VERSION is added downstream by the
# ${ROCM_RC_PREFIX:+${ROCM_RC_PREFIX}-} expansion when constructing
# install / module paths -- this keeps the regular-release path byte-
# identical to the prior behavior (no prefix, no dash, no change).
#
# The --rocm-rc-prefix CLI override (parsed above) wins if explicitly
# set; otherwise we auto-derive from the ROCM_PATH basename. The user-
# set sentinel ROCM_RC_PREFIX_USER_SET is what distinguishes "operator
# passed --rocm-rc-prefix '' to force regular semantics on a tagged
# install dir" (don't auto-detect) from "operator didn't pass it at
# all" (do auto-detect).
ROCM_MODULE_VERSION=""
: ${ROCM_RC_PREFIX:=""}
: ${ROCM_RC_PREFIX_USER_SET:=0}

if [ -n "${ROCM_PATH}" ] && [ -d "${ROCM_PATH}" ]; then
   if [ -f "${ROCM_PATH}/.info/version" ]; then
      ROCM_MODULE_VERSION=$(cut -f1 -d'-' "${ROCM_PATH}/.info/version")
      echo "Detected loaded ROCm module numeric version ${ROCM_MODULE_VERSION} (ROCM_PATH=${ROCM_PATH})"
   fi
   if [ "${ROCM_RC_PREFIX_USER_SET}" != "1" ]; then
      _rocm_basename="${ROCM_PATH##*/}"          # rocm-therock-23.2.0 or rocm-7.2.1
      _rocm_suffix="${_rocm_basename#rocm-}"      # therock-23.2.0 or 7.2.1
      if [[ ! "${_rocm_suffix}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
         ROCM_RC_PREFIX="${_rocm_suffix%%-*}"     # therock | afar (family name only, no trailing dash)
         echo "Detected ROCm release-candidate prefix: '${ROCM_RC_PREFIX}' (RC tag suffix: '${_rocm_suffix#${ROCM_RC_PREFIX}-}')"
      fi
      unset _rocm_basename _rocm_suffix
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

# ── --quick-installs: disable packages whose wall time is >= 20 min ──
# Threshold raised from 15 -> 20 min after the job 8065 sweep (rocm-7.2.1)
# measured petsc at 17:09 and scorep at 16:59, both clearly under the new
# cutoff. The 5-min headroom keeps openmpi (16:29), tau (15:27), and the
# next time it surfaces, jax-on-rocm-6 (was 34m in job 7975) on the right
# sides of the line.
#
# Wall-time data sources, newest first (delta is mtime of the per-package
# log file vs. the previous one, in a full --quick-installs 0 run):
#
#   Package      Wall (8065)  Wall (7975)  Wall (7958)  Decision
#   pytorch      90:52        43:39        n/a          SKIP  (>= 20 min)
#   tensorflow   69:57        75:14        n/a          SKIP  (>= 20 min)
#   jax          policy-skip  34:27        n/a          SKIP  (>= 20 min when active)
#   petsc        17:09        15:44        n/a          BUILD (< 20 min, was SKIP at 15-min cutoff)
#   scorep       16:59        15:35        19:33        BUILD (< 20 min, was SKIP at 15-min cutoff;
#                                                              7958 measurement was the closest call)
#   openmpi      16:29        n/a          n/a          BUILD (< 20 min)
#   tau          15:27        10:23         9:42        BUILD (< 20 min)
#   cupy         14:31        14:21        n/a          BUILD (< 20 min)
#   netcdf        8:54         9:24         8:08        BUILD (< 20 min)
#   magma         8:21         7:18        n/a          BUILD (< 20 min)
#   miniconda3    6:32        n/a          n/a          BUILD (< 20 min)
#   hpctoolkit    4:08         4:30        n/a          BUILD (< 20 min)
#   fftw          3:28         4:04         4:01        BUILD (< 20 min)
#   miniforge3    3:08        n/a          n/a          BUILD (< 20 min)
#   hypre         3:13         3:08         2:55        BUILD (< 20 min)
#   hdf5          2:14         2:16         2:17        BUILD (< 20 min)
#   mpi4py        1:41         1:41         1:37        BUILD (< 20 min)
#   kokkos        1:31         0:30        n/a          BUILD (< 20 min)
#   hip-python    1:17         1:20        n/a          BUILD (< 20 min)
#   ftorch        0:49        <1m         <1m          SKIP  (transitive: preflight
#                                                              requires pytorch which
#                                                              is itself SKIP-ed)
#   hipfort       0:23         0:24        n/a          BUILD (< 20 min)
#   flang-new   skip-policy  <2m (untar) <2m            BUILD (< 20 min)
#   julia         dormant     dormant      dormant      SKIP  (BUILD_JULIA exists but
#                                                              there is no `run_and_log
#                                                              julia` call below; left
#                                                              in this list as a no-op
#                                                              placeholder so future
#                                                              julia wiring inherits
#                                                              the SKIP default until
#                                                              measured)
#
# This runs AFTER arg parsing so a user could (in theory) re-enable a single
# package by exporting BUILD_<name>=1 between this point and sub-script
# invocation; we don't expose per-package CLI flags here on purpose.
QUICK_INSTALLS_PKGS=( BUILD_PYTORCH BUILD_TENSORFLOW BUILD_JAX BUILD_FTORCH \
                     BUILD_JULIA )
QUICK_INSTALLS_THRESHOLD_MIN=20
if [[ "${QUICK_INSTALLS}" == "1" ]]; then
   echo ""
   echo "QUICK_INSTALLS=1 -> disabling packages with wall >= ${QUICK_INSTALLS_THRESHOLD_MIN} min:"
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

# NOTE: the cleanup_pkg() helper, the PKG_CLEAN_DIRS / PKG_CLEAN_MODS
# lookup tables, and the replace_pkg() pre-install helper that used to
# live here have all been removed. Their job (per-package install +
# modulefile removal on --replace-existing 1, fail-cleanup of partial
# installs) is now done by each setup script's own --replace flag and
# EXIT trap (canonical template: extras/scripts/hypre_setup.sh).
# main_setup.sh now just threads `--replace ${REPLACE_EXISTING}
# --keep-failed-installs ${KEEP_FAILED_INSTALLS}` (= ${REPLACE_OPTS},
# defined further below near COMMON_OPTIONS) into every migrated
# run_and_log invocation. The install-path knowledge lives in exactly
# one place per package, so the layout cannot drift.

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
      # NOTE: per-package fail-cleanup is now done inside each setup
      # script's own EXIT trap (template established in
      # extras/scripts/hypre_setup.sh, controlled by --replace and
      # --keep-failed-installs flags threaded through REPLACE_OPTS).
      # The previous cleanup_pkg() helper + PKG_CLEAN_DIRS/MODS lookup
      # tables were removed because they had drifted out of sync with
      # the actual install layouts during the per-package versioning
      # pass; the install-path knowledge now lives in exactly one
      # place: each setup script.
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
echo "  ROCM_RC_PREFIX   : '${ROCM_RC_PREFIX}'  (install dir suffix: rocmplus-${ROCM_RC_PREFIX:+${ROCM_RC_PREFIX}-}${ROCM_VERSION})"
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
# ROCMPLUS_SUFFIX is the suffix used after `rocmplus-` for both install
# dirs and module category dirs. For a regular release ROCM_RC_PREFIX
# is empty and the ${VAR:+...} expansion contributes nothing, so the
# suffix is just ${ROCM_VERSION} (byte-identical to prior behavior).
# For a release-candidate (ROCM_RC_PREFIX='therock', say) it becomes
# 'therock-${ROCM_VERSION}', e.g. 'therock-7.13.0'. This means therock
# / afar installs cannot collide with a future official rocm release
# of the same numeric version (no upstream release has a 'therock-' or
# 'afar-' family prefix).
ROCMPLUS_SUFFIX="${ROCM_RC_PREFIX:+${ROCM_RC_PREFIX}-}${ROCM_VERSION}"
ROCMPLUS="${TOP_INSTALL_PATH}/rocmplus-${ROCMPLUS_SUFFIX}"

# ── --replace-existing + --keep-failed-installs ──────────────────────
#
# These flags used to be implemented here in main_setup.sh via two
# helpers:
#   replace_pkg <flag_var> <dirs...> -- <mods...>   (pre-install)
#   cleanup_pkg <label>                             (fail-cleanup)
# both backed by the PKG_CLEAN_DIRS / PKG_CLEAN_MODS lookup tables
# that mirrored each package's install layout. The duplication caused
# drift: when packages gained version-suffixed install dirs
# (mpi4py-v${VERSION}, scorep-v${VERSION}, …) the lookup tables had
# to be hand-edited, and any miss resulted in stale artifacts on disk.
#
# That logic now lives inside each per-package setup script, behind a
# uniform CLI:
#   --replace 0|1                 (default 0; pre-install rm)
#   --keep-failed-installs 0|1    (default 0; fail-cleanup gate)
# Multi-component scripts (openmpi, jax, magma, netcdf, scorep, tau)
# additionally expose --replace-<component> sub-flags. main_setup.sh
# threads the global REPLACE_OPTS = `--replace ${REPLACE_EXISTING}
# --keep-failed-installs ${KEEP_FAILED_INSTALLS}` into every
# migrated run_and_log call below. miniconda3/miniforge3 do NOT get
# REPLACE_OPTS because their installs are shared across ROCm
# versions; the operator removes them by hand to force a rebuild.
#
# Canonical template: extras/scripts/hypre_setup.sh.

USE_CUSTOM_PATHS=0
if [[ "${TOP_INSTALL_PATH}" != "/opt" || "${TOP_MODULE_PATH}" != "/etc/lmod/modules" ]]; then
   USE_CUSTOM_PATHS=1
fi

COMMON_OPTIONS="--rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}"

# REPLACE_OPTS: passed to every per-package setup script that has
# migrated to the self-contained --replace + --keep-failed-installs
# pattern (template established in extras/scripts/hypre_setup.sh).
# Each script knows its own install dir + modulefile, so replacing
# the prior install + cleaning a partial-fail install is now done
# inside the script itself rather than by replace_pkg/cleanup_pkg
# tables in this file (which had drifted out of sync with the actual
# install paths during the per-package versioning pass).
# miniconda3/miniforge3 are intentionally NOT given REPLACE_OPTS:
# their installs are shared across ROCm versions, see the comment
# block above their run_and_log calls.
REPLACE_OPTS="--replace ${REPLACE_EXISTING} --keep-failed-installs ${KEEP_FAILED_INSTALLS}"

# Helper: returns --install-path + --module-path flags for a given package.
# Usage: $(path_args <install_subpath> <module_category/package>)
# Used by the legacy scripts that have NOT been migrated to the
# version-agnostic --install-path-as-parent pattern (flang-new, openmpi,
# mvapich, rocprof-sys, rocprof-compute, hip-python, hipfort, hipifly,
# tensorflow, ftorch). For these, --install-path is treated as a full
# leaf dir (no version appended by the leaf script) -- effectively the
# legacy semantic predating the new --install-path / --install-path-no-
# version convention. main_setup.sh still constructs the full path
# here, including any subpath under ROCMPLUS.
path_args()
{
   if [ "${USE_CUSTOM_PATHS}" == 1 ]; then
      echo "--install-path ${ROCMPLUS}/${1} --module-path ${TOP_MODULE_PATH}/${2}"
   fi
}

# Helper: returns --install-path + --module-path flags for a MIGRATED
# package. Migrated = leaf script accepts --install-path as a PARENT
# directory and appends its own pkg-v${PKG_VERSION} subdir, so
# main_setup.sh stays version-agnostic. Used by the 14 leaf scripts
# that own their versions: fftw, hdf5, hypre, kokkos, petsc, pytorch,
# cupy, hpctoolkit, jax, magma, netcdf, scorep, miniconda3 / miniforge3
# (those last two get --install-path inline since their install lives
# outside ROCMPLUS, under TOP_INSTALL_PATH).
# Usage: $(rocmplus_args <module_category/package>)
rocmplus_args()
{
   if [ "${USE_CUSTOM_PATHS}" == 1 ]; then
      echo "--install-path ${ROCMPLUS} --module-path ${TOP_MODULE_PATH}/${1}"
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

# ── Guard: amdgpu-install path cannot produce therock/afar trees ──────
# rocm/scripts/rocm_setup.sh installs via amdgpu-install, which only
# knows about official upstream ROCm releases (rocm-X.Y.Z). Trying to
# materialize a release-candidate flavor (rocm-therock-X.Y.Z, rocm-
# afar-X.Y.Z) through it cannot work; the operator must load the
# corresponding pre-installed module first so SKIP_ROCM_INSTALL=1
# above. If we got here with a non-empty ROCM_RC_PREFIX it means no
# matching module was loaded -- abort cleanly with an actionable
# message rather than letting amdgpu-install run and fail confusingly.
if [ "${SKIP_ROCM_INSTALL}" == 0 ] && [ -n "${ROCM_RC_PREFIX}" ]; then
   echo "ERROR: ROCM_RC_PREFIX='${ROCM_RC_PREFIX}' set but no matching rocm module is loaded." >&2
   echo "       The amdgpu-install path cannot produce a ${ROCM_RC_PREFIX}-* tree;" >&2
   echo "       load the appropriate rocm module first (e.g. module load rocm/${ROCM_RC_PREFIX}-<tag>)" >&2
   echo "       so the SDK is provided externally and main_setup.sh proceeds with the rocmplus stack." >&2
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
# Each block invokes the per-package setup script unconditionally,
# threading --build-<x> ${BUILD_<X>} so the script itself decides
# whether to do work, no-op (SKIPPED), or fail. Two checks that used
# to live here as `if [[ "${BUILD_<X>}" == "1" ]] && [[ ! -d <path> ]]`
# wrappers have been moved INTO each setup script:
#
#   * the BUILD_<X>=0 opt-out gate (operator selected --packages w/o
#     this one) -- now an early `exit ${NOOP_RC}` at the top of each
#     script, just after arg parsing and before --replace. Runs
#     cleanly so run_and_log records it as SKIPPED(no-op) in the
#     per-package summary, replacing the prior silent omission that
#     made it hard to grep "what was actually built".
#
#   * the existence-check `[[ ! -d <pkg-v${VER}> ]]` guard -- now an
#     in-script check after --replace and before the EXIT-trap install
#     (also `exit ${NOOP_RC}`). Keeps the install-path knowledge in
#     exactly one place per package; multi-component scripts can
#     correctly check ALL of their installs (not just the leaf
#     main_setup.sh happened to know about).
#
# Pattern established in extras/scripts/hypre_setup.sh (search
# "BUILD_HYPRE=0 short-circuit" and "Existence guard").
#
# The one guard that REMAINS here is the intentional exception
# called out in the existence-check evaluation:
#   * mvapich -- partially migrated; both gates remain here for now.
#
# miniconda3 / miniforge3 have ALSO migrated to the in-script BUILD=0
# + existence-on-disk pattern (see the comment block above their
# run_and_log calls). They are the second exception class: they keep
# the in-script guards but do NOT get the --replace mechanism, since
# their installs are SHARED across ROCm versions and a multi-version
# sweep should never silently nuke a working conda/mamba env. To
# force a rebuild of those, the operator does `rm -rf
# ${TOP_INSTALL_PATH}/miniconda3-v<version>` (or miniforge3 equivalent)
# by hand. The version is owned by the leaf script (MINICONDA3_VERSION
# / MINIFORGE3_VERSION default at the top of each *_setup.sh).

run_and_log flang-new rocm/scripts/flang-new_setup.sh ${COMMON_OPTIONS} --build-flang-new ${BUILD_FLANGNEW} ${REPLACE_OPTS} \
   $(path_args " " rocmplus-${ROCMPLUS_SUFFIX}/amdflang-new)

# openmpi block also produces xpmem-*, ucx-*, ucc-* under ROCMPLUS.
# BUILD_OPENMPI=0 opt-out and existence check both live in
# openmpi_setup.sh; we just thread --build-openmpi through.
run_and_log openmpi comm/scripts/openmpi_setup.sh ${COMMON_OPTIONS} --build-openmpi ${BUILD_OPENMPI} --build-xpmem 1 ${REPLACE_OPTS} \
   $(path_args " " rocmplus-${ROCMPLUS_SUFFIX}/openmpi)

# mpi4py owns its own version (see comment block at the version pins
# above). main_setup.sh passes only --install-path (the parent dir);
# mpi4py_setup.sh appends mpi4py-v${MPI4PY_VERSION} itself.
run_and_log mpi4py comm/scripts/mpi4py_setup.sh ${COMMON_OPTIONS} --build-mpi4py ${BUILD_MPI4PY} ${REPLACE_OPTS} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${ROCMPLUS} --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/mpi4py")

if [[ "${BUILD_MVAPICH}" == "1" ]] && [[ ! -d ${ROCMPLUS}/mvapich ]]; then
   run_and_log mvapich comm/scripts/mvapich_setup.sh ${COMMON_OPTIONS} ${REPLACE_OPTS} \
      $(path_args mvapich rocmplus-${ROCMPLUS_SUFFIX}/mvapich)
fi

run_and_log rocprof-sys tools/scripts/rocprof-sys_setup.sh ${COMMON_OPTIONS} --build-rocprof-sys ${BUILD_ROCPROF_SYS} --install-rocprof-sys-from-source ${INSTALL_ROCPROF_SYS_FROM_SOURCE} --python-version ${PYTHON_VERSION} ${REPLACE_OPTS} \
   $(path_args rocprofiler-system rocmplus-${ROCMPLUS_SUFFIX}/rocprofiler-system)

run_and_log rocprof-compute tools/scripts/rocprof-compute_setup.sh ${COMMON_OPTIONS} --build-rocprof-compute ${BUILD_ROCPROF_COMPUTE} --install-rocprof-compute-from-source ${INSTALL_ROCPROF_COMPUTE_FROM_SOURCE} --python-version ${PYTHON_VERSION} ${REPLACE_OPTS} \
   $(path_args rocprofiler-compute rocmplus-${ROCMPLUS_SUFFIX}/rocprofiler-compute)

#if [[ ! -d ${ROCMPLUS}/rocprofiler-sdk ]]; then
#   run_and_log rocprofiler-sdk tools/scripts/rocprofiler-sdk_setup.sh ${COMMON_OPTIONS} --build-rocprofiler-sdk ${BUILD_ROCPROFILER_SDK} --python-version ${PYTHON_VERSION} \
#      $(path_args rocprofiler-sdk rocmplus-${ROCMPLUS_SUFFIX}/rocprofiler-sdk)
#fi

run_and_log hpctoolkit tools/scripts/hpctoolkit_setup.sh ${COMMON_OPTIONS} --build-hpctoolkit ${BUILD_HPCTOOLKIT} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/hpctoolkit)

# scorep + tau share ${ROCMPLUS}/pdt. Their setup scripts default to
# leaving pdt in place across re-installs (it's a shared dep); only
# when BOTH are being rebuilt do we ask each script to also wipe pdt
# via --replace-pdt 1, matching the prior `replace_pkg always pdt`
# guard. When not threaded, the per-script EXIT trap also preserves
# pdt on a partial-install failure.
SCOREP_REPLACE_PDT=""
TAU_REPLACE_PDT=""
if [[ "${REPLACE_EXISTING}" == "1" && "${BUILD_SCOREP}" == "1" && "${BUILD_TAU}" == "1" ]]; then
   SCOREP_REPLACE_PDT="--replace-pdt 1"
   TAU_REPLACE_PDT="--replace-pdt 1"
fi
run_and_log scorep tools/scripts/scorep_setup.sh ${COMMON_OPTIONS} --build-scorep ${BUILD_SCOREP} ${REPLACE_OPTS} ${SCOREP_REPLACE_PDT} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/scorep)

#run_and_log grafana tools/scripts/grafana_setup.sh

run_and_log tau tools/scripts/tau_setup.sh ${COMMON_OPTIONS} --build-tau ${BUILD_TAU} ${REPLACE_OPTS} ${TAU_REPLACE_PDT} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--tau-install-path ${ROCMPLUS}/tau --pdt-install-path ${ROCMPLUS}/pdt --module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/tau")

#run_and_log compiler extras/scripts/compiler_setup.sh

run_and_log cupy extras/scripts/cupy_setup.sh ${COMMON_OPTIONS} --build-cupy ${BUILD_CUPY} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/cupy)

run_and_log hip-python extras/scripts/hip-python_setup.sh ${COMMON_OPTIONS} --build-hip-python ${BUILD_HIP_PYTHON} ${REPLACE_OPTS} \
   $(path_args hip-python rocmplus-${ROCMPLUS_SUFFIX}/hip-python)

# tensorflow / jax / pytorch / ftorch are the long-pole builds (each
# 30-90 min on a cold workspace) and have been moved to the END of the
# sweep so the short builds (magma, kokkos, hipfort, hipifly, hdf5,
# netcdf, fftw, petsc, hypre) finish first and surface fast in the
# logs. See the block after `hypre` below for the reordered ML group.

run_and_log magma extras/scripts/magma_setup.sh ${COMMON_OPTIONS} --build-magma ${BUILD_MAGMA} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX})

# apps_setup.sh is intentionally disabled. It is not gated by --packages
# (no BUILD_APPS flag), runs unconditionally on every sweep pass, and
# has been the source of 0-byte-log noise in failed runs (job 7974
# logs_05_01_2026/rocm-7.2.0_7974/log_apps_05_01_2026.txt). Re-enable
# only when its output is actually needed; in that case prefer adding a
# BUILD_APPS gate first so it can be selected by --packages.
#run_and_log apps extras/scripts/apps_setup.sh

run_and_log kokkos extras/scripts/kokkos_setup.sh ${COMMON_OPTIONS} --build-kokkos ${BUILD_KOKKOS} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/kokkos)

# miniconda3 / miniforge3 are intentionally exempt from --replace-existing.
# Their install paths (${TOP_INSTALL_PATH}/miniconda3-v<version>,
# ${TOP_INSTALL_PATH}/miniforge3-v<version>) and module dirs
# (${TOP_MODULE_PATH}/LinuxPlus/...) are SHARED across ROCm versions --
# they don't depend on which ROCm release the orchestrator is currently
# iterating. With multi-version sweeps invoked under --replace-existing
# 1, calling replace_pkg here would delete the install at the start of
# every ROCm-version pass and force a full rebuild of conda/forge per
# version, which is pure waste (the result is identical).
#
# Architecture (matches the rest of the migrated packages, with two
# deliberate exceptions):
#   * BUILD_<X>=0 opt-out + existence-on-disk skip: handled INSIDE
#     miniconda3_setup.sh / miniforge3_setup.sh (both exit NOOP_RC=43
#     so run_and_log records a SKIPPED(no-op) line in the per-package
#     summary). main_setup.sh therefore invokes the script
#     unconditionally on every sweep -- the script decides its own fate.
#   * --replace is INTENTIONALLY NOT THREADED (the two exceptions): no
#     ${REPLACE_OPTS} on these calls and no --replace argument parsing
#     in either setup script. Forcing a rebuild is a manual operator
#     action: `rm -rf ${TOP_INSTALL_PATH}/miniconda3-v<version>` (or
#     the miniforge3 equivalent) followed by re-running main_setup.sh.
#     This matches the SHARED-across-ROCm-versions intent: a multi-
#     version sweep should never silently nuke a working conda/mamba
#     env that other ROCm passes also depend on.
# Multi-version coexistence works because the install path and the
# .lua modulefile are both keyed on the leaf script's MINICONDA3_VERSION
# / MINIFORGE3_VERSION default; bumping the version inside the leaf
# script leaves the prior version's install + module in place;
# `module load miniconda3` continues to load the default version per
# Lmod's usual rules. main_setup.sh threads only --install-path (the
# parent dir, here ${TOP_INSTALL_PATH} since miniconda3 / miniforge3
# live OUTSIDE the rocmplus tree) and the leaf scripts append the
# versioned subdir themselves, matching the --install-path = parent +
# version-append convention used by the migrated leaf scripts.
run_and_log miniconda3 extras/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniconda3 ${BUILD_MINICONDA3} --python-version ${PYTHON_VERSION} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH} --module-path ${TOP_MODULE_PATH}/LinuxPlus/miniconda3")

run_and_log miniforge3 extras/scripts/miniforge3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniforge3 ${BUILD_MINIFORGE3} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${TOP_INSTALL_PATH} --module-path ${TOP_MODULE_PATH}/LinuxPlus/miniforge3")

run_and_log hipfort extras/scripts/hipfort_setup.sh ${COMMON_OPTIONS} --build-hipfort ${BUILD_HIPFORT} ${REPLACE_OPTS} \
   $(path_args hipfort rocmplus-${ROCMPLUS_SUFFIX}/hipfort_from_source)

run_and_log hipifly extras/scripts/hipifly_setup.sh --rocm-version ${ROCM_VERSION} --build-hipifly ${BUILD_HIPIFLY} --hipifly-module ${HIPIFLY_MODULE} ${REPLACE_OPTS} \
   $(path_args hipifly rocmplus-${ROCMPLUS_SUFFIX}/hipifly)

run_and_log hdf5 extras/scripts/hdf5_setup.sh ${COMMON_OPTIONS} --build-hdf5 ${BUILD_HDF5} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/hdf5)

run_and_log netcdf extras/scripts/netcdf_setup.sh ${COMMON_OPTIONS} --build-netcdf ${BUILD_NETCDF} ${REPLACE_OPTS} \
   $([ "${USE_CUSTOM_PATHS}" == 1 ] && echo "--install-path ${ROCMPLUS} --netcdf-c-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/netcdf-c --netcdf-f-module-path ${TOP_MODULE_PATH}/rocmplus-${ROCMPLUS_SUFFIX}/netcdf-fortran")

run_and_log fftw extras/scripts/fftw_setup.sh ${COMMON_OPTIONS} --build-fftw ${BUILD_FFTW} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/fftw)

#run_and_log x11vnc extras/scripts/x11vnc_setup.sh --build-x11vnc ${BUILD_X11VNC}

run_and_log petsc extras/scripts/petsc_setup.sh ${COMMON_OPTIONS} --build-petsc ${BUILD_PETSC} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/petsc)

run_and_log hypre extras/scripts/hypre_setup.sh ${COMMON_OPTIONS} --build-hypre ${BUILD_HYPRE} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/hypre)

# ─── Long-pole ML builds (jax, tensorflow, pytorch, ftorch) ───────────
#
# Placed here so that the long bazel/cmake builds are done last. This
# is so that there is rapid progress and most package problems are hit early.
#
#   jax BEFORE tensorflow -- jax is the shorter of the two bazel builds,
#   pytorch BEFORE ftorch -- ftorch_setup.sh has a preflight that

run_and_log jax extras/scripts/jax_setup.sh ${COMMON_OPTIONS} --build-jax ${BUILD_JAX} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/jax)

run_and_log tensorflow extras/scripts/tensorflow_setup.sh ${COMMON_OPTIONS} --build-tensorflow ${BUILD_TENSORFLOW} ${REPLACE_OPTS} \
   $(path_args tensorflow rocmplus-${ROCMPLUS_SUFFIX}/tensorflow)

run_and_log pytorch extras/scripts/pytorch_setup.sh ${COMMON_OPTIONS} --build-pytorch ${BUILD_PYTORCH} --python-version ${PYTHON_VERSION} ${REPLACE_OPTS} \
   $(rocmplus_args rocmplus-${ROCMPLUS_SUFFIX}/pytorch)

run_and_log ftorch extras/scripts/ftorch_setup.sh ${COMMON_OPTIONS} --build-ftorch ${BUILD_FTORCH} ${REPLACE_OPTS} \
   $(path_args ftorch rocmplus-${ROCMPLUS_SUFFIX}/ftorch)

#If ROCm should be installed in a different location
#if [ "${ROCM_INSTALLPATH}" != "/opt/" ]; then
#   ${SUDO} mv /opt/rocm-${ROCM_VERSION} ${ROCM_INSTALLPATH}
#   ${SUDO} mv /opt/rocmplus-${ROCMPLUS_SUFFIX} ${ROCM_INSTALLPATH}
#   ${SUDO} ln -sfn ${ROCM_INSTALLPATH}/rocm-${ROCM_VERSION} /etc/alternatives/rocm
#   ${SUDO} sed -i "s|\/opt\/|${ROCM_INSTALLPATH}|" /etc/lmod/modules/ROCm/*/*.lua
#fi

#run_and_log hpctrainingexamples git clone https://github.com/AMD/HPCTrainingExamples.git
