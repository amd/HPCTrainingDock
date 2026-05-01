#!/bin/bash
#
# run_rocm_build_sweep.sh - LOGIN-side submitter.
#
# Computes a single Slurm --time based on the requested ROCm version count
# (default 30 minutes per version + a 60 minute margin) and submits ONE sbatch
# job that loops through the versions on a single sh5 node. Per-version
# success/failure is logged inside the job; the sbatch returns 0 only if every
# version succeeded.

set -uo pipefail

: ${PARTITION:="sh5_cpx_admin_long"}
: ${MIN_PER_VERSION:="60"}        # estimated minutes per ROCm build (cold docker
                                  # cache; ~35 min with warm cache). Includes
                                  # the slow chown -R sysadmin pass (~11 min)
                                  # plus make rocm + rocm_package + module pkg.
: ${MARGIN_MIN:="60"}             # global margin (minutes)
: ${MAX_TIME_MIN:="2880"}         # MaxTime of sh5_cpx_admin_long = 48h
: ${FORCE_EXTRACT:="0"}
: ${KEEP_TARBALLS:="3"}
: ${DISTRO:="ubuntu"}
: ${DISTRO_VERSION:="24.04"}
: ${AMDGPU_GFXMODEL:="gfx942;gfx90a"}

ROCM_VERSIONS_RAW=""

usage() {
   cat <<EOF
Usage: $0 [opts]
   --rocm-versions "v1 v2 ..."   space- or comma-separated list (default: 7.1.0 7.0.2 7.0.1 7.0.0 6.4.3 6.4.2 6.4.1 6.4.0)
   --partition NAME              Slurm partition (default $PARTITION)
   --min-per-version N           estimated minutes per build (default $MIN_PER_VERSION)
   --margin-min N                margin minutes added to total (default $MARGIN_MIN)
   --force-extract 0|1           overwrite existing /nfsapps/opt/rocm-<v> (default $FORCE_EXTRACT)
   --keep-tarballs N             prune policy (default $KEEP_TARBALLS)
   --distro NAME                 default $DISTRO
   --distro-version VER          default $DISTRO_VERSION
   --amdgpu-gfxmodel GFX         default $AMDGPU_GFXMODEL
   --dry-run                     print sbatch command without submitting
   --help
EOF
   exit 1
}

DRY_RUN=0
while [[ $# -gt 0 ]]; do
   case "${1}" in
      --rocm-versions)    shift; ROCM_VERSIONS_RAW=${1} ;;
      --partition)        shift; PARTITION=${1} ;;
      --min-per-version)  shift; MIN_PER_VERSION=${1} ;;
      --margin-min)       shift; MARGIN_MIN=${1} ;;
      --force-extract)    shift; FORCE_EXTRACT=${1} ;;
      --keep-tarballs)    shift; KEEP_TARBALLS=${1} ;;
      --distro)           shift; DISTRO=${1} ;;
      --distro-version)   shift; DISTRO_VERSION=${1} ;;
      --amdgpu-gfxmodel)  shift; AMDGPU_GFXMODEL=${1} ;;
      --dry-run)          DRY_RUN=1 ;;
      --help|-h)          usage ;;
      *)                  echo "Unknown arg: ${1}" >&2; usage ;;
   esac
   shift
done

[[ -z "${ROCM_VERSIONS_RAW}" ]] && \
   ROCM_VERSIONS_RAW="7.1.0 7.0.2 7.0.1 7.0.0 6.4.3 6.4.2 6.4.1 6.4.0"

# Normalize to space-separated.
ROCM_VERSIONS_NORM="${ROCM_VERSIONS_RAW//,/ }"
read -r -a VERSIONS_ARR <<< "${ROCM_VERSIONS_NORM}"
N=${#VERSIONS_ARR[@]}
(( N == 0 )) && { echo "ERROR: no ROCm versions parsed from '${ROCM_VERSIONS_RAW}'" >&2; exit 1; }

TOTAL_MIN=$(( N * MIN_PER_VERSION + MARGIN_MIN ))
if (( TOTAL_MIN > MAX_TIME_MIN )); then
   echo "WARNING: requested ${TOTAL_MIN}min exceeds partition MaxTime ${MAX_TIME_MIN}min; capping."
   TOTAL_MIN=${MAX_TIME_MIN}
fi
HH=$(( TOTAL_MIN / 60 ))
MM=$(( TOTAL_MIN % 60 ))
TIME_STR=$(printf '%02d:%02d:00' "${HH}" "${MM}")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBATCH_FILE="${REPO_ROOT}/bare_system/run_rocm_build_sweep.sbatch"
[[ -f "${SBATCH_FILE}" ]] || { echo "ERROR: ${SBATCH_FILE} not found" >&2; exit 1; }

cat <<EOF
==================================================================
 ROCm sweep submitter
==================================================================
 Partition:        ${PARTITION}
 Versions (${N}):  ${VERSIONS_ARR[*]}
 Per-version est:  ${MIN_PER_VERSION} min
 Margin:           ${MARGIN_MIN} min
 Total --time:     ${TIME_STR}
 Force extract:    ${FORCE_EXTRACT}
 Keep tarballs:    ${KEEP_TARBALLS}
 Distro:           ${DISTRO} ${DISTRO_VERSION}
 GFX:              ${AMDGPU_GFXMODEL}
 sbatch file:      ${SBATCH_FILE}
==================================================================
EOF

EXPORT_VARS="ALL,ROCM_VERSIONS=${ROCM_VERSIONS_NORM},FORCE_EXTRACT=${FORCE_EXTRACT},KEEP_TARBALLS=${KEEP_TARBALLS},DISTRO=${DISTRO},DISTRO_VERSION=${DISTRO_VERSION},AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL}"

CMD=( sbatch
      --time="${TIME_STR}"
      --partition="${PARTITION}"
      --export="${EXPORT_VARS}"
      "${SBATCH_FILE}" )

if (( DRY_RUN == 1 )); then
   printf '%q ' "${CMD[@]}"; echo
   exit 0
fi

cd "${REPO_ROOT}"
"${CMD[@]}"
