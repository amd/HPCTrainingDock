#!/bin/bash
#
# run_rocm_extract_sweep.sh - Phase B (run ON AAC7, the Cray login node).
#
# Pulls the staged tarballs produced by Phase A (run_rocm_stage_sweep on AAC6)
# and, for each manifest entry, extracts + creates the Cray modulefiles
# (PrgEnv-amd-new ecosystem + rocm-<v>.pc) into the operator's home tree --
# exactly the treatment the local 7.13.0 install received.
#
# Transfer: AAC7 PULLS from AAC6 over ssh/rsync (AAC7 can reach aac6:22; the
# AAC6 build nodes cannot reach the AAC7 uan). --from is HOST:DIR.
#
# Dispatch (by manifest 'kind'):
#   numeric -> run_rocm_craywrap_install.sh   (extract tree + Cray wrap)
#   therock -> run_rocm_therock_install.sh --local-tarball
#   afar    -> run_rocm_therock_afar_install.sh --local-tarball
# All run --cray-modules --no-sudo 1 into the home install/module tree.

set -uo pipefail

: ${TOP_INSTALL_PATH:="${HOME}/apps/rhel9.6/opt"}
: ${TOP_MODULE_PATH:="${HOME}/modulefiles"}
: ${LOCAL_STAGE:="${HOME}/rocm-stage"}     # local landing dir for the pull
: ${AMDGPU_FAMILY:="gfx94X-dcgpu"}
: ${REPLACE_EXISTING:="0"}
: ${PE_VERSION:=""}                        # "" => installers auto-detect PrgEnv-amd
FROM=""
DRY_RUN=0

usage() {
   cat <<EOF
Usage: $0 --from HOST:DIR [opts]
  --from HOST:DIR          rsync source on AAC6, e.g. admin@aac6.amd.com:/shared/.../rocm-stage
                          (must contain manifest.tsv + the tarballs). REQUIRED
                          unless --local-stage already holds a manifest.tsv.
  --local-stage DIR        local landing dir for the pull (default ${LOCAL_STAGE})
  --top-install-path PATH  default ${TOP_INSTALL_PATH}
  --top-module-path  PATH  default ${TOP_MODULE_PATH}
  --amdgpu-family FAM      default ${AMDGPU_FAMILY}
  --replace-existing 0|1   default ${REPLACE_EXISTING}
  --pe-version VER         PrgEnv-amd version to wrap (default: auto-detect)
  --dry-run                pull + parse manifest, print the per-token commands, do not install
  --help
EOF
   exit 1
}

while [[ $# -gt 0 ]]; do
   case "${1}" in
      --from)             shift; FROM=${1} ;;
      --local-stage)      shift; LOCAL_STAGE=${1} ;;
      --top-install-path) shift; TOP_INSTALL_PATH=${1} ;;
      --top-module-path)  shift; TOP_MODULE_PATH=${1} ;;
      --amdgpu-family)    shift; AMDGPU_FAMILY=${1} ;;
      --replace-existing) shift; REPLACE_EXISTING=${1} ;;
      --pe-version)       shift; PE_VERSION=${1} ;;
      --dry-run)          DRY_RUN=1 ;;
      --help|-h)          usage ;;
      *) echo "Unknown arg: ${1}" >&2; usage ;;
   esac
   shift
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BS="${REPO_ROOT}/bare_system"

mkdir -p "${LOCAL_STAGE}"
if [[ -n "${FROM}" ]]; then
   echo "[extract-sweep] rsync pull: ${FROM}/  ->  ${LOCAL_STAGE}/"
   # -z for the manifest/text; tarballs are already compressed (rsync skips
   # re-compressing). --partial so a dropped link resumes next run.
   rsync -aH --partial --info=progress2 "${FROM}/" "${LOCAL_STAGE}/"
fi

MANIFEST="${LOCAL_STAGE}/manifest.tsv"
[[ -f "${MANIFEST}" ]] || { echo "ERROR: ${MANIFEST} not found (did Phase A run / did the pull succeed?)" >&2; exit 1; }

echo "=================================================================="
echo " ROCm EXTRACT sweep (Phase B, AAC7) on $(hostname)"
echo " Stage:           ${LOCAL_STAGE}"
echo " TOP_INSTALL_PATH:${TOP_INSTALL_PATH}"
echo " TOP_MODULE_PATH: ${TOP_MODULE_PATH}"
echo " Manifest:"
sed 's/^/   /' "${MANIFEST}"
echo "=================================================================="

PE_OPT=(); [[ -n "${PE_VERSION}" ]] && PE_OPT=(--pe-version "${PE_VERSION}")
OK=(); FAIL=()

# Skip the header (#token...) and blank lines. Phase A writes a '-' placeholder
# for empty fields (tab is IFS-whitespace, so empty fields would otherwise
# collapse and shift columns); map '-' back to "" here.
while IFS=$'\t' read -r token kind filename numeric release; do
   [[ -z "${token}" || "${token}" == \#* ]] && continue
   [[ "${numeric}" == "-" ]] && numeric=""
   [[ "${release}" == "-" ]] && release=""
   [[ "${filename}" == "-" ]] && filename=""
   tarball="${LOCAL_STAGE}/${filename}"
   echo ""
   echo "[$(date)] EXTRACT ${token}  (kind=${kind}, file=${filename})"
   if [[ -z "${filename}" || ! -f "${tarball}" ]]; then
      echo "  ERROR: tarball '${tarball}' missing for ${token}; skipping" >&2
      FAIL+=("${token}"); continue
   fi

   case "${kind}" in
      numeric)
         cmd=( "${BS}/run_rocm_craywrap_install.sh"
               --rocm-version "${token}"
               --local-tarball "${tarball}"
               --amdgpu-family "${AMDGPU_FAMILY}"
               --top-install-path "${TOP_INSTALL_PATH}"
               --top-module-path  "${TOP_MODULE_PATH}"
               --replace-existing "${REPLACE_EXISTING}"
               --cray-modules --no-sudo 1 "${PE_OPT[@]}" ) ;;
      therock)
         cmd=( "${BS}/run_rocm_therock_install.sh"
               --therock-release "${release}"
               --amdgpu-family "${AMDGPU_FAMILY}"
               --local-tarball "${tarball}"
               --top-install-path "${TOP_INSTALL_PATH}"
               --top-module-path  "${TOP_MODULE_PATH}"
               --replace-existing "${REPLACE_EXISTING}"
               --cray-modules --no-sudo 1 "${PE_OPT[@]}" ) ;;
      afar)
         cmd=( "${BS}/run_rocm_therock_afar_install.sh"
               --therock-afar-release "${release}"
               --amdgpu-gfxmodel "${AMDGPU_FAMILY}"
               --local-tarball "${tarball}"
               --top-install-path "${TOP_INSTALL_PATH}"
               --top-module-path  "${TOP_MODULE_PATH}"
               --replace-existing "${REPLACE_EXISTING}"
               --cray-modules --no-sudo 1 "${PE_OPT[@]}" ) ;;
      *) echo "  ERROR: unknown kind '${kind}' for ${token}" >&2; FAIL+=("${token}"); continue ;;
   esac

   if (( DRY_RUN == 1 )); then
      printf '   %q ' "${cmd[@]}"; echo
      OK+=("${token}"); continue
   fi
   if "${cmd[@]}"; then
      echo "[$(date)] OK   ${token}"; OK+=("${token}")
   else
      echo "[$(date)] FAIL ${token} (rc=$?)"; FAIL+=("${token}")
   fi
done < "${MANIFEST}"

echo ""
echo "=================================================================="
echo " Extract sweep finished at $(date)"
echo " OK   (${#OK[@]}):   ${OK[*]:-}"
echo " FAIL (${#FAIL[@]}): ${FAIL[*]:-}"
[[ ${#OK[@]} -gt 0 && "${DRY_RUN}" == 0 ]] && {
   echo " Cray modules: module use ${TOP_MODULE_PATH}/cray"
   echo "               module avail PrgEnv-amd-new"
}
echo "=================================================================="
[[ ${#FAIL[@]} -eq 0 ]]
