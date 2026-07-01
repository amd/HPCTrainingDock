#!/bin/bash
#SBATCH --job-name=rocm_stage_sweep
#SBATCH --partition=sh5_cpx_admin_long
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=48
#SBATCH --exclusive
#SBATCH --output=slurm-%j-rocm-stage.out
#SBATCH --error=slurm-%j-rocm-stage.err
#
# Phase A of the AAC6-build -> transfer -> AAC7-extract pipeline.
#
# Runs on AAC6 (sh5_cpx_admin_long). For each requested token it produces a
# single TRANSFERABLE TARBALL in ${STAGE_DIR} and appends a line to
# ${STAGE_DIR}/manifest.tsv that Phase B (run_rocm_extract_sweep.sh on AAC7)
# consumes. Nothing is module-wrapped here -- the Cray PrgEnv-amd-new ecosystem
# is created on AAC7 where the craype wrappers live.
#
# Token routing:
#   numeric (7.2.3)        -> run_rocm_build.sh --distro almalinux 9.6  (FULL
#                             docker build, ABI-compatible with AAC7), then tar
#                             the resulting rocm-<v> tree.   kind=numeric
#   therock-X.Y[.Z]        -> run_rocm_therock_install.sh --stage-only (download
#                             the distro-agnostic tarball).  kind=therock
#   therock-afar-X.Y.Z     -> run_rocm_therock_afar_install.sh --stage-only
#                             (download, incl. the .pre/ fallback). kind=afar
#
# Required env (via sbatch --export):
#   ROCM_VERSIONS   space/comma list of tokens
#   STAGE_DIR       dir to deposit tarballs + manifest.tsv (must be readable by
#                   AAC7's rsync pull; e.g. /shared/.../rocm-stage)
# Optional env:
#   AMDGPU_GFXMODEL (default "gfx942;gfx90a")  numeric build target
#   THEROCK_AMDGPU_FAMILY (default gfx94X-dcgpu) therock/afar family segment
#   DISTRO/DISTRO_VERSION (default almalinux / 9.6)  numeric build distro
#   BUILD_TOP_INSTALL_PATH (default /nfsapps/opt)  where the numeric build lands
#                          before it is tarred into STAGE_DIR
#   BUILD_TOP_MODULE_PATH  (default /nfsapps/modules)
#   REPLACE_EXISTING (0|1), SKIP_PATCHES (0|1), KEEP_TARBALLS (N)

set -uo pipefail
cd "${SLURM_SUBMIT_DIR:-$(pwd)}"

ROCM_VERSIONS_RAW="${ROCM_VERSIONS:?ROCM_VERSIONS must be set}"
STAGE_DIR="${STAGE_DIR:?STAGE_DIR must be set}"
ROCM_VERSIONS_RAW="${ROCM_VERSIONS_RAW//,/ }"
read -r -a VERSIONS <<< "${ROCM_VERSIONS_RAW}"

AMDGPU_GFXMODEL="${AMDGPU_GFXMODEL:-gfx942;gfx90a}"
THEROCK_AMDGPU_FAMILY="${THEROCK_AMDGPU_FAMILY:-gfx94X-dcgpu}"
DISTRO="${DISTRO:-almalinux}"
DISTRO_VERSION="${DISTRO_VERSION:-9.6}"
BUILD_TOP_INSTALL_PATH="${BUILD_TOP_INSTALL_PATH:-/nfsapps/opt}"
BUILD_TOP_MODULE_PATH="${BUILD_TOP_MODULE_PATH:-/nfsapps/modules}"
REPLACE_EXISTING="${REPLACE_EXISTING:-0}"
SKIP_PATCHES="${SKIP_PATCHES:-0}"
KEEP_TARBALLS="${KEEP_TARBALLS:-3}"

mkdir -p "${STAGE_DIR}"
MANIFEST="${STAGE_DIR}/manifest.tsv"
# Fresh manifest header (Phase B reads token<TAB>kind<TAB>filename<TAB>numeric<TAB>release).
{ echo -e "#token\tkind\tfilename\tnumeric\trelease"; } > "${MANIFEST}"

SUMMARY="stage_summary_$(date +%Y%m%d_%H%M%S)_job${SLURM_JOB_ID:-local}.out"
{
   echo "=================================================================="
   echo " ROCm STAGE sweep (Phase A, AAC6) job ${SLURM_JOB_ID:-local} on $(hostname)"
   echo " Tokens:          ${VERSIONS[*]}"
   echo " STAGE_DIR:       ${STAGE_DIR}"
   echo " Numeric distro:  ${DISTRO} ${DISTRO_VERSION}  (AAC7-ABI target)"
   echo " GFX:             ${AMDGPU_GFXMODEL}   therock/afar family ${THEROCK_AMDGPU_FAMILY}"
   echo " Build tree:      ${BUILD_TOP_INSTALL_PATH}"
   echo "=================================================================="
} | tee "${SUMMARY}"

OK=(); FAIL=()
# Empty fields must NOT be written: the manifest is tab-separated and Phase B
# reads it with IFS=$'\t', where tab is an IFS-whitespace char so RUNS of tabs
# collapse and empty fields vanish (shifting later columns left). Substitute a
# '-' placeholder for any empty field; Phase B maps '-' back to "".
manifest_add() {
   local a; local out=""
   for a in "$1" "$2" "$3" "$4" "$5"; do out+="${a:--}"$'\t'; done
   printf '%s\n' "${out%$'\t'}" >> "${MANIFEST}"
}

# A bare numeric >= 7.10.0 is only available as a TheRock tarball (the docker
# numeric line ends below 7.10.0); stage it via the TheRock download path with
# kind=therock so Phase B installs it with numeric naming. Mirrors
# _is_therock_numeric in run_rocm_build_sweep.{sh,sbatch}.
_is_therock_numeric() {
   local _t="$1"
   [[ "${_t}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
   [ "$(printf '%s\n' "7.10.0" "${_t}" | sort -V | head -n1)" = "7.10.0" ]
}

for v in "${VERSIONS[@]}"; do
   echo "" | tee -a "${SUMMARY}"
   echo "[$(date)] STAGE ${v}" | tee -a "${SUMMARY}"

   if [[ "${v}" == therock-afar-* ]]; then
      rel="${v#therock-afar-}"
      before=$(ls -1 "${STAGE_DIR}" 2>/dev/null)
      if bare_system/run_rocm_therock_afar_install.sh \
            --therock-afar-release "${rel}" \
            --amdgpu-gfxmodel "${AMDGPU_GFXMODEL}" \
            --stage-only "${STAGE_DIR}" \
            --skip-patches "${SKIP_PATCHES}"
      then
         f=$(comm -13 <(echo "${before}"|sort) <(ls -1 "${STAGE_DIR}"|sort) | grep -E '\.tar\.bz2$' | head -1)
         [[ -z "${f}" ]] && f=$(ls -1t "${STAGE_DIR}"/therock-afar-${rel}-*.tar.bz2 2>/dev/null | head -1 | xargs -r basename)
         manifest_add "${v}" afar "${f}" "" "${rel}"
         echo "[$(date)] OK   ${v} -> ${f}" | tee -a "${SUMMARY}"; OK+=("${v}")
      else
         echo "[$(date)] FAIL ${v}" | tee -a "${SUMMARY}"; FAIL+=("${v}")
      fi

   elif [[ "${v}" == therock-* ]] || _is_therock_numeric "${v}"; then
      # Explicit therock-<rel> token OR a bare numeric >= 7.10.0 (TheRock-only);
      # ${v#therock-} yields the numeric release either way.
      rel="${v#therock-}"
      before=$(ls -1 "${STAGE_DIR}" 2>/dev/null)
      if bare_system/run_rocm_therock_install.sh \
            --therock-release "${rel}" \
            --amdgpu-family "${THEROCK_AMDGPU_FAMILY}" \
            --stage-only "${STAGE_DIR}"
      then
         f=$(comm -13 <(echo "${before}"|sort) <(ls -1 "${STAGE_DIR}"|sort) | grep -E '\.tar\.gz$' | head -1)
         [[ -z "${f}" ]] && f=$(ls -1t "${STAGE_DIR}"/therock-dist-linux-${THEROCK_AMDGPU_FAMILY}-*.tar.gz 2>/dev/null | head -1 | xargs -r basename)
         manifest_add "${v}" therock "${f}" "" "${rel}"
         echo "[$(date)] OK   ${v} -> ${f}" | tee -a "${SUMMARY}"; OK+=("${v}")
      else
         echo "[$(date)] FAIL ${v}" | tee -a "${SUMMARY}"; FAIL+=("${v}")
      fi

   else
      # ── numeric: full almalinux-9.6 docker build, then tar the tree ──
      if bare_system/run_rocm_build.sh \
            --rocm-version "${v}" \
            --distro "${DISTRO}" --distro-version "${DISTRO_VERSION}" \
            --amdgpu-gfxmodel "${AMDGPU_GFXMODEL}" \
            --use-makefile 1 \
            --replace-existing "${REPLACE_EXISTING}" \
            --skip-patches "${SKIP_PATCHES}" \
            --keep-tarballs "${KEEP_TARBALLS}" \
            --top-install-path "${BUILD_TOP_INSTALL_PATH}" \
            --top-module-path  "${BUILD_TOP_MODULE_PATH}"
      then
         tree="${BUILD_TOP_INSTALL_PATH}/rocm-${v}"
         if [[ ! -d "${tree}" ]]; then
            echo "[$(date)] FAIL ${v}: built but ${tree} missing" | tee -a "${SUMMARY}"; FAIL+=("${v}"); continue
         fi
         f="rocm-numeric-${v}.tar.gz"
         echo "  tarring ${tree} -> ${STAGE_DIR}/${f}" | tee -a "${SUMMARY}"
         # sudo because the built tree is root-owned; --no-same-owner side is
         # handled by craywrap on extract. tar from the parent so the archive
         # carries the rocm-<v>/ wrapper dir (craywrap's WRAPPER layout).
         if sudo tar -czpf "${STAGE_DIR}/${f}" -C "${BUILD_TOP_INSTALL_PATH}" "rocm-${v}"; then
            sudo chmod 644 "${STAGE_DIR}/${f}" 2>/dev/null || true
            manifest_add "${v}" numeric "${f}" "${v}" ""
            echo "[$(date)] OK   ${v} -> ${f}" | tee -a "${SUMMARY}"; OK+=("${v}")
         else
            echo "[$(date)] FAIL ${v}: tar failed" | tee -a "${SUMMARY}"; FAIL+=("${v}")
         fi
      else
         echo "[$(date)] FAIL ${v} (build)" | tee -a "${SUMMARY}"; FAIL+=("${v}")
      fi
   fi
done

{
   echo ""
   echo "=================================================================="
   echo " Stage sweep finished at $(date)"
   echo " OK   (${#OK[@]}):   ${OK[*]:-}"
   echo " FAIL (${#FAIL[@]}): ${FAIL[*]:-}"
   echo " Manifest: ${MANIFEST}"
   echo " Transfer with Phase B (on AAC7):"
   echo "   run_rocm_extract_sweep.sh --from \$(hostname):${STAGE_DIR}"
   echo "=================================================================="
   echo "--- manifest.tsv ---"; cat "${MANIFEST}"
} | tee -a "${SUMMARY}"

[[ ${#FAIL[@]} -eq 0 ]]
