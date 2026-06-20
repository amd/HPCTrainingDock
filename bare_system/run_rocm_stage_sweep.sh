#!/bin/bash
#
# run_rocm_stage_sweep.sh - Phase A submitter (run ON AAC6).
#
# Submits run_rocm_stage_sweep.sbatch to sh5_cpx_admin_long, sizing --time by
# token count: numeric tokens are full almalinux-9.6 docker builds (~95 min);
# therock/afar tokens are just a download into STAGE_DIR (~5 min).
#
# After it completes, run Phase B on AAC7:
#   run_rocm_extract_sweep.sh --from <aac6-host>:<STAGE_DIR>

set -uo pipefail

: ${PARTITION:="sh5_cpx_admin_long"}
: ${MIN_PER_NUMERIC:="95"}
: ${MIN_PER_DOWNLOAD:="6"}
: ${MARGIN_MIN:="60"}
: ${MAX_TIME_MIN:="2880"}
: ${AMDGPU_GFXMODEL:="gfx942;gfx90a"}
: ${THEROCK_AMDGPU_FAMILY:="gfx94X-dcgpu"}
: ${DISTRO:="almalinux"}
: ${DISTRO_VERSION:="9.6"}
: ${BUILD_TOP_INSTALL_PATH:="/nfsapps/opt"}
: ${BUILD_TOP_MODULE_PATH:="/nfsapps/modules"}
: ${REPLACE_EXISTING:="0"}
: ${SKIP_PATCHES:="0"}
: ${KEEP_TARBALLS:="3"}
ROCM_VERSIONS_RAW=""
STAGE_DIR=""
DRY_RUN=0

usage() {
   cat <<EOF
Usage: $0 --rocm-versions "v1 v2 ..." --stage-dir DIR [opts]
  --rocm-versions "..."        space/comma list of tokens (7.2.3, therock-7.12.0,
                               therock-afar-23.2.1, therock-afar-23.3.0, ...). REQUIRED.
  --stage-dir DIR              where tarballs + manifest.tsv are deposited (must be
                               reachable by AAC7's rsync pull). REQUIRED.
  --partition NAME             default ${PARTITION}
  --distro/--distro-version    numeric-build distro (default ${DISTRO} ${DISTRO_VERSION}; AAC7-ABI)
  --amdgpu-gfxmodel GFX        default ${AMDGPU_GFXMODEL}
  --therock-amdgpu-family FAM  default ${THEROCK_AMDGPU_FAMILY}
  --build-top-install-path P   numeric build install root (default ${BUILD_TOP_INSTALL_PATH})
  --replace-existing 0|1       default ${REPLACE_EXISTING}
  --skip-patches 0|1           default ${SKIP_PATCHES}
  --dry-run                    print the sbatch command without submitting
  --help
EOF
   exit 1
}

while [[ $# -gt 0 ]]; do
   case "${1}" in
      --rocm-versions) shift; ROCM_VERSIONS_RAW=${1} ;;
      --stage-dir)     shift; STAGE_DIR=${1} ;;
      --partition)     shift; PARTITION=${1} ;;
      --distro)        shift; DISTRO=${1} ;;
      --distro-version) shift; DISTRO_VERSION=${1} ;;
      --amdgpu-gfxmodel) shift; AMDGPU_GFXMODEL=${1} ;;
      --therock-amdgpu-family) shift; THEROCK_AMDGPU_FAMILY=${1} ;;
      --build-top-install-path) shift; BUILD_TOP_INSTALL_PATH=${1} ;;
      --replace-existing) shift; REPLACE_EXISTING=${1} ;;
      --skip-patches)  shift; SKIP_PATCHES=${1} ;;
      --keep-tarballs) shift; KEEP_TARBALLS=${1} ;;
      --dry-run)       DRY_RUN=1 ;;
      --help|-h)       usage ;;
      *) echo "Unknown arg: ${1}" >&2; usage ;;
   esac
   shift
done

[[ -z "${ROCM_VERSIONS_RAW}" ]] && { echo "ERROR: --rocm-versions required" >&2; usage; }
[[ -z "${STAGE_DIR}" ]]        && { echo "ERROR: --stage-dir required" >&2; usage; }

ROCM_VERSIONS_NORM="${ROCM_VERSIONS_RAW//,/ }"
read -r -a ARR <<< "${ROCM_VERSIONS_NORM}"
N_NUM=0; N_DL=0
for v in "${ARR[@]}"; do
   case "${v}" in therock-*|afar-*) N_DL=$((N_DL+1)) ;; *) N_NUM=$((N_NUM+1)) ;; esac
done
TOTAL_MIN=$(( N_NUM*MIN_PER_NUMERIC + N_DL*MIN_PER_DOWNLOAD + MARGIN_MIN ))
(( TOTAL_MIN > MAX_TIME_MIN )) && TOTAL_MIN=${MAX_TIME_MIN}
TIME_STR=$(printf '%02d:%02d:00' $((TOTAL_MIN/60)) $((TOTAL_MIN%60)))

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBATCH_FILE="${REPO_ROOT}/bare_system/run_rocm_stage_sweep.sbatch"
[[ -f "${SBATCH_FILE}" ]] || { echo "ERROR: ${SBATCH_FILE} not found" >&2; exit 1; }

cat <<EOF
==================================================================
 ROCm STAGE sweep submitter (Phase A, AAC6)
==================================================================
 Tokens (${#ARR[@]}):  ${ARR[*]}
   numeric (${N_NUM}), download (${N_DL})
 Partition:        ${PARTITION}
 --time:           ${TIME_STR}
 STAGE_DIR:        ${STAGE_DIR}
 Numeric distro:   ${DISTRO} ${DISTRO_VERSION}
 GFX:              ${AMDGPU_GFXMODEL}  (therock/afar family ${THEROCK_AMDGPU_FAMILY})
 sbatch file:      ${SBATCH_FILE}
==================================================================
EOF

EXPORT_VARS="ALL,ROCM_VERSIONS=${ROCM_VERSIONS_NORM},STAGE_DIR=${STAGE_DIR},AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL},THEROCK_AMDGPU_FAMILY=${THEROCK_AMDGPU_FAMILY},DISTRO=${DISTRO},DISTRO_VERSION=${DISTRO_VERSION},BUILD_TOP_INSTALL_PATH=${BUILD_TOP_INSTALL_PATH},BUILD_TOP_MODULE_PATH=${BUILD_TOP_MODULE_PATH},REPLACE_EXISTING=${REPLACE_EXISTING},SKIP_PATCHES=${SKIP_PATCHES},KEEP_TARBALLS=${KEEP_TARBALLS}"

CMD=( sbatch --time="${TIME_STR}" --partition="${PARTITION}" --export="${EXPORT_VARS}" "${SBATCH_FILE}" )
if (( DRY_RUN == 1 )); then printf '%q ' "${CMD[@]}"; echo; exit 0; fi
cd "${REPO_ROOT}"
"${CMD[@]}"
