#!/bin/bash
#
# run_rocmplus_install_sweep.sh - LOGIN-side submitter for the rocm-plus
# install sweep. For each ROCm version in the list, submits ONE sbatch job
# that runs bare_system/main_setup.sh (which lays down rocmplus-<v> on
# /nfsapps). Jobs are chained with --dependency=afterany:<prev_jobid> so
# they run sequentially and unattended — and so a single failed version
# does not stall the rest of the chain.
#
# Each job is given its own --time (default 24h, capped at the partition
# MaxTime of 48h) and writes to slurm-<jobid>-rocmplus-<v>.{out,err}.

set -uo pipefail

: ${PARTITION:="sh5_cpx_admin_long"}
: ${TIME_PER_JOB:="24:00:00"}        # walltime per version
: ${MAX_TIME_MIN:="2880"}            # MaxTime of sh5_cpx_admin_long = 48h
# Order matters: kokkos_setup.sh's multi-arch->single-arch fallback uses
# the FIRST gfx model in the list when cmake configure fails. This cluster's
# build node is MI300A (gfx942), so gfx942 must come first to ensure the
# fallback produces a binary that runs on the build hardware. The list as
# a whole is also passed verbatim to GPU_TARGETS / --offload-arch in other
# packages (openmpi, ucx, ucc, scorep), where order is irrelevant.
# Cross-compiling note: if you change the build host or target a different
# cluster, set AMDGPU_GFXMODEL explicitly via --amdgpu-gfxmodel; do NOT
# autodetect from rocminfo (the build node may not have the target hardware).
: ${AMDGPU_GFXMODEL:="gfx942;gfx90a"}
: ${TOP_INSTALL_PATH:="/nfsapps/opt"}
: ${TOP_MODULE_PATH:="/nfsapps/modules"}
: ${ROCM_INSTALLPATH:="/nfsapps/opt"}
# PYTHON_VERSION: empty -> auto-detect on the compute node from /etc/os-release
# (Ubuntu 22.04 -> 10, 24.04 -> 12). Passed through verbatim if user supplies it.
: ${PYTHON_VERSION:=""}
: ${QUICK_INSTALLS:="0"}
: ${REPLACE_EXISTING:="0"}
: ${KEEP_FAILED_INSTALLS:="0"}  # 1 = preserve partial install dirs / modulefiles for post-mortem
: ${PACKAGES_LIST:=""}     # whitelist passed through to main_setup.sh --packages
# MAX_PARALLEL: cap on simultaneously-RUNNING jobs across the chain.
#   1 (default) = strict serial: each job depends on the previous one.
#   N > 1       = sliding window: first N jobs all start concurrently (subject
#                 to slurm node availability); each subsequent job depends
#                 afterany on the jobid N positions earlier in submission
#                 order, so at most N jobs are RUNNING at once.
# Each per-version sbatch is --nodes=1 --exclusive (see run_rocmplus_install.sbatch),
# so MAX_PARALLEL maps 1:1 to nodes occupied. Pick MAX_PARALLEL to leave
# headroom on the partition for other users (e.g. 3 nodes available -> use 2
# to keep one free; bump to 3 once a 4th node comes online).
: ${MAX_PARALLEL:=1}

ROCM_VERSIONS_RAW=""
START_AFTER=""
DRY_RUN=0

usage() {
   cat <<EOF
Usage: $0 [opts]
   --rocm-versions "v1 v2 ..."   space- or comma-separated list of ROCm modulefile tokens (REQUIRED).
                                 Accepts BOTH regular numeric (e.g. 7.2.1) AND release-candidate
                                 flavor (e.g. therock-23.2.0, afar-22.2.0, afar-7.0.5) tokens
                                 in the same list. Each token must resolve to an existing
                                 modulefile under /shared/apps/modules/ubuntu/lmodfiles/base/rocm
                                 (the pre-flight check below enforces this). For RC tokens, the
                                 sbatch derives ROCM_RC_PREFIX (e.g. 'therock') and the install
                                 lands at \${TOP_INSTALL_PATH}/rocmplus-\${PREFIX}-\${NUMERIC}/
                                 (e.g. /nfsapps/opt/rocmplus-therock-7.13.0/) so it cannot
                                 collide with a future official rocm release of the same numeric.
   --partition NAME              Slurm partition (default ${PARTITION})
   --time HH:MM:SS               walltime per version (default ${TIME_PER_JOB})
   --amdgpu-gfxmodel GFX         default ${AMDGPU_GFXMODEL}
   --top-install-path PATH       default ${TOP_INSTALL_PATH}
   --top-module-path PATH        default ${TOP_MODULE_PATH}
   --rocm-install-path PATH      default ${ROCM_INSTALLPATH}
   --python-version N            python3 minor release (default: distro-native -- 10 on Ubuntu 22.04, 12 on 24.04)
   --quick-installs 0|1          skip long-pole packages (default ${QUICK_INSTALLS})
   --replace-existing 0|1        replace existing rocmplus-<v> packages per-pkg (default ${REPLACE_EXISTING})
   --keep-failed-installs 0|1    on per-package failure, keep partial install dirs / modulefiles for post-mortem (default ${KEEP_FAILED_INSTALLS}; default 0 wipes them so retries start clean)
   --packages "name1 name2 ..."  whitelist (passed verbatim to main_setup.sh --packages); empty = all
   --max-parallel N              cap on simultaneously-RUNNING jobs (default ${MAX_PARALLEL}).
                                 1 = strict serial chain (each job depends on the previous; today's
                                 default behavior). N>1 = sliding window: first N jobs run in parallel
                                 (subject to slurm node availability), each subsequent job depends on
                                 the jobid N positions earlier so at most N are RUNNING at once. Each
                                 sbatch is --nodes=1 --exclusive, so N maps 1:1 to nodes occupied --
                                 pick N to leave headroom for other users (e.g. 3 nodes available ->
                                 --max-parallel 2 reserves 1 for others; --max-parallel 3 once a 4th
                                 node is online).
   --start-after JOBID           chain the first wave (first MAX_PARALLEL versions) after an existing job
   --dry-run                     print sbatch commands without submitting
   --help

Each per-version job's dependency is computed from MAX_PARALLEL (default 1 =
strict --dependency=afterany:<prev_jobid> chain). The chain proceeds even
if a single version fails (afterany, not afterok). Per-job logs land in
slurm-<jobid>-rocmplus-<v>.{out,err} in the submit directory.
EOF
   exit 1
}

while [[ $# -gt 0 ]]; do
   case "${1}" in
      --rocm-versions)     shift; ROCM_VERSIONS_RAW=${1} ;;
      --partition)         shift; PARTITION=${1} ;;
      --time)              shift; TIME_PER_JOB=${1} ;;
      --amdgpu-gfxmodel)   shift; AMDGPU_GFXMODEL=${1} ;;
      --top-install-path)  shift; TOP_INSTALL_PATH=${1} ;;
      --top-module-path)   shift; TOP_MODULE_PATH=${1} ;;
      --rocm-install-path) shift; ROCM_INSTALLPATH=${1} ;;
      --python-version)    shift; PYTHON_VERSION=${1} ;;
      --quick-installs)    shift; QUICK_INSTALLS=${1} ;;
      --replace-existing)  shift; REPLACE_EXISTING=${1} ;;
      --keep-failed-installs) shift; KEEP_FAILED_INSTALLS=${1} ;;
      --packages)          shift; PACKAGES_LIST=${1} ;;
      --max-parallel)      shift; MAX_PARALLEL=${1} ;;
      --start-after)       shift; START_AFTER=${1} ;;
      --dry-run)           DRY_RUN=1 ;;
      --help|-h)           usage ;;
      *)                   echo "Unknown arg: ${1}" >&2; usage ;;
   esac
   shift
done

[[ -z "${ROCM_VERSIONS_RAW}" ]] && { echo "ERROR: --rocm-versions is required" >&2; usage; }

# Walltime sanity check vs partition MaxTime.
IFS=':' read -r THH TMM TSS <<< "${TIME_PER_JOB}"
TIME_MIN=$(( 10#${THH} * 60 + 10#${TMM} + (10#${TSS} > 0 ? 1 : 0) ))
if (( TIME_MIN > MAX_TIME_MIN )); then
   echo "ERROR: --time ${TIME_PER_JOB} exceeds partition MaxTime ${MAX_TIME_MIN}min." >&2
   exit 1
fi

# MAX_PARALLEL must be a positive integer; the sliding-window dep math
# below assumes >=1 (1 = current strict-chain behavior).
if ! [[ "${MAX_PARALLEL}" =~ ^[1-9][0-9]*$ ]]; then
   echo "ERROR: --max-parallel must be a positive integer (got '${MAX_PARALLEL}')" >&2
   exit 1
fi

# Normalize version list.
ROCM_VERSIONS_NORM="${ROCM_VERSIONS_RAW//,/ }"
read -r -a VERSIONS_ARR <<< "${ROCM_VERSIONS_NORM}"
N=${#VERSIONS_ARR[@]}
(( N == 0 )) && { echo "ERROR: no ROCm versions parsed from '${ROCM_VERSIONS_RAW}'" >&2; exit 1; }

# Pre-flight: every version must have a system rocm modulefile so the
# compute-node sbatch can `module load rocm/<v>`. We check the canonical
# 22.04 module tree on the login node (NFS-mounted on sh5 too). When the
# cluster moves to 24.04, switch SYS_ROCM_MODDIR below.
SYS_ROCM_MODDIR="/shared/apps/modules/ubuntu/lmodfiles/base/rocm"
MISSING=()
for v in "${VERSIONS_ARR[@]}"; do
   # Lmod accepts modulefiles either with or without a .lua suffix.
   if [[ ! -f "${SYS_ROCM_MODDIR}/${v}.lua" && ! -f "${SYS_ROCM_MODDIR}/${v}" ]]; then
      MISSING+=("${v}")
   fi
done
if (( ${#MISSING[@]} > 0 )); then
   echo "ERROR: the following rocm versions have no module in ${SYS_ROCM_MODDIR}:" >&2
   for v in "${MISSING[@]}"; do echo "    rocm/${v}" >&2; done
   echo "Install the rocm SDK + module on the system tree (or update SYS_ROCM_MODDIR)." >&2
   exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBATCH_FILE="${REPO_ROOT}/bare_system/run_rocmplus_install.sbatch"
[[ -f "${SBATCH_FILE}" ]] || { echo "ERROR: ${SBATCH_FILE} not found" >&2; exit 1; }

cat <<EOF
==================================================================
 ROCm-plus install sweep submitter
==================================================================
 Partition:         ${PARTITION}
 Time per version:  ${TIME_PER_JOB}
 Versions (${N}):     ${VERSIONS_ARR[*]}   (mixed numeric + RC-flavor tokens OK; RC trees install to rocmplus-<prefix>-<numeric>/)
 GFX:               ${AMDGPU_GFXMODEL}
 TOP_INSTALL_PATH:  ${TOP_INSTALL_PATH}
 TOP_MODULE_PATH:   ${TOP_MODULE_PATH}
 ROCM_INSTALLPATH:  ${ROCM_INSTALLPATH}
 PYTHON_VERSION:    ${PYTHON_VERSION:+3.}${PYTHON_VERSION:-<auto: distro-native on compute node>}
 QUICK_INSTALLS:    ${QUICK_INSTALLS}
 REPLACE_EXISTING:  ${REPLACE_EXISTING}
 KEEP_FAILED:       ${KEEP_FAILED_INSTALLS}
 PACKAGES:          ${PACKAGES_LIST:-<all>}
 MAX_PARALLEL:      ${MAX_PARALLEL}   $( (( MAX_PARALLEL == 1 )) && echo "(strict serial chain)" || echo "(sliding window: up to ${MAX_PARALLEL} jobs RUNNING simultaneously)")
 sbatch file:       ${SBATCH_FILE}
 Dry run:           ${DRY_RUN}
 Start after:       ${START_AFTER:-<none>}
==================================================================
EOF

cd "${REPO_ROOT}"

# Sliding-window dependency wiring (controlled by MAX_PARALLEL):
#   - First MAX_PARALLEL jobs (the "first wave") all depend on START_AFTER
#     (or have no dependency if START_AFTER is empty), so they're free to
#     start as soon as slurm has nodes for them.
#   - Subsequent jobs depend afterany on the jobid MAX_PARALLEL positions
#     earlier in submission order. Since each sbatch is --nodes=1 --exclusive,
#     a finishing job releases exactly one node, which is what the next
#     waiting job needs to start.
# Net effect: at most MAX_PARALLEL jobs are RUNNING simultaneously, regardless
# of how many free nodes the partition has at any moment.
#
# JOBIDS_ONLY tracks submission-order jobids so we can index back N positions
# without parsing them out of SUBMITTED's "v=jobid" pairs.
JOBIDS_ONLY=()
SUBMITTED=()
i=0
for v in "${VERSIONS_ARR[@]}"; do
   EXPORT_VARS="ALL,ROCM_VERSION=${v}"
   EXPORT_VARS+=",AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL}"
   EXPORT_VARS+=",TOP_INSTALL_PATH=${TOP_INSTALL_PATH}"
   EXPORT_VARS+=",TOP_MODULE_PATH=${TOP_MODULE_PATH}"
   EXPORT_VARS+=",ROCM_INSTALLPATH=${ROCM_INSTALLPATH}"
   EXPORT_VARS+=",PYTHON_VERSION=${PYTHON_VERSION}"
   EXPORT_VARS+=",QUICK_INSTALLS=${QUICK_INSTALLS}"
   EXPORT_VARS+=",REPLACE_EXISTING=${REPLACE_EXISTING}"
   EXPORT_VARS+=",KEEP_FAILED_INSTALLS=${KEEP_FAILED_INSTALLS}"
   # PACKAGES_LIST may contain spaces; sbatch --export uses commas as separators,
   # so leave the value un-comma'd. Spaces survive verbatim through to the sbatch.
   EXPORT_VARS+=",PACKAGES_LIST=${PACKAGES_LIST}"

   # Compute this job's dependency:
   #   i  < MAX_PARALLEL : honor START_AFTER (may be empty -> no dep)
   #   i >= MAX_PARALLEL : depend on the jobid MAX_PARALLEL slots back
   if (( i < MAX_PARALLEL )); then
      DEP="${START_AFTER}"
   else
      DEP="${JOBIDS_ONLY[$((i - MAX_PARALLEL))]}"
   fi

   CMD=( sbatch
         --job-name="rocmplus_${v}"
         --time="${TIME_PER_JOB}"
         --partition="${PARTITION}"
         --output="slurm-%j-rocmplus-${v}.out"
         --error="slurm-%j-rocmplus-${v}.err"
         --export="${EXPORT_VARS}" )

   if [[ -n "${DEP}" ]]; then
      CMD+=( --dependency="afterany:${DEP}" )
   fi
   CMD+=( "${SBATCH_FILE}" )

   if (( DRY_RUN == 1 )); then
      printf '[DRY] (depends on %s) ' "${DEP:-<none>}"; printf '%q ' "${CMD[@]}"; echo
      JOBID="<would-be-jobid-${v}>"
      SUBMITTED+=( "${v}=${JOBID}" )
      JOBIDS_ONLY+=( "${JOBID}" )
      i=$((i + 1))
      continue
   fi

   echo "Submitting rocmplus install for ${v} (depends on ${DEP:-<none>})..."
   OUT=$("${CMD[@]}") || { echo "ERROR: sbatch failed for ${v}" >&2; exit 1; }
   echo "  ${OUT}"
   # "Submitted batch job NNN" -> NNN
   JOBID=$(awk '{print $NF}' <<< "${OUT}")
   if ! [[ "${JOBID}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: could not parse jobid from sbatch output: ${OUT}" >&2
      exit 1
   fi
   SUBMITTED+=( "${v}=${JOBID}" )
   JOBIDS_ONLY+=( "${JOBID}" )
   i=$((i + 1))
done

echo ""
echo "=================================================================="
echo " Submitted chain (${#SUBMITTED[@]} jobs):"
for entry in "${SUBMITTED[@]}"; do
   echo "   rocm-${entry%=*}  ->  jobid ${entry#*=}"
done
echo ""
echo " Monitor:"
echo "   squeue -u \$USER --sort=i"
echo "   tail -f slurm-<jobid>-rocmplus-<v>.out"
echo "=================================================================="
