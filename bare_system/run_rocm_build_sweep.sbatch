#!/bin/bash
#SBATCH --job-name=rocm_build_sweep
#SBATCH --partition=sh5_cpx_admin_long
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=48
#SBATCH --exclusive
#SBATCH --output=slurm-%j-rocm-sweep.out
#SBATCH --error=slurm-%j-rocm-sweep.err
#
# Single-job ROCm sweep: loops over all requested versions sequentially on one
# sh5 compute node. --time is set by the submitter (run_rocm_build_sweep.sh)
# based on the version count, so it is intentionally NOT hardcoded here.
#
# Required env (passed via sbatch --export=ALL,...):
#   ROCM_VERSIONS     space-separated list of ROCm versions to install
# Optional env:
#   REPLACE_EXISTING  0|1 (default 0) -- consistent with run_rocmplus_install_sweep.sh.
#                     FORCE_EXTRACT is still honoured as a deprecated alias.
#   SKIP_PATCHES      0|1 (default 0) -- skip Phase 3.6 (rocm_patches.sh)
#   KEEP_TARBALLS     N   (default 3)
#   TOP_INSTALL_PATH  on-host SDK extract destination (default /nfsapps/opt)
#   TOP_MODULE_PATH   on-host Lmod root for deployed modulefiles (default /nfsapps/modules)
#   DISTRO, DISTRO_VERSION, AMDGPU_GFXMODEL

set -uo pipefail

cd "${SLURM_SUBMIT_DIR}"

ROCM_VERSIONS_RAW="${ROCM_VERSIONS:?ROCM_VERSIONS must be set via --export=ALL,ROCM_VERSIONS=...}"
ROCM_VERSIONS_RAW="${ROCM_VERSIONS_RAW//,/ }"
read -r -a VERSIONS <<< "${ROCM_VERSIONS_RAW}"

# Accept either the new name (REPLACE_EXISTING) or the deprecated old one
# (FORCE_EXTRACT); the new name wins if both are set.
if [ -z "${REPLACE_EXISTING:-}" ] && [ -n "${FORCE_EXTRACT:-}" ]; then
   echo "[rocm_sweep] NOTE: FORCE_EXTRACT is deprecated; map to REPLACE_EXISTING=${FORCE_EXTRACT}"
   REPLACE_EXISTING="${FORCE_EXTRACT}"
fi
REPLACE_EXISTING="${REPLACE_EXISTING:-0}"
SKIP_PATCHES="${SKIP_PATCHES:-0}"
KEEP_TARBALLS="${KEEP_TARBALLS:-3}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_VERSION="${DISTRO_VERSION:-24.04}"
AMDGPU_GFXMODEL="${AMDGPU_GFXMODEL:-gfx942;gfx90a}"
TOP_INSTALL_PATH="${TOP_INSTALL_PATH:-/nfsapps/opt}"

# Defensive remount of /nfsapps as rw on this compute node. The login node
# exports it rw to sh5 admin nodes via /etc/exports.d/nfsapps_sh5_rw.exports,
# but the warewulf-managed fstab still says ro by default.
INSTALL_PARENT="${TOP_INSTALL_PATH%/*}"   # e.g. /nfsapps
if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
   echo "Attempting to remount ${INSTALL_PARENT} rw..."
   sudo mount -o remount,rw "${INSTALL_PARENT}" 2>/dev/null || \
      { sudo umount "${INSTALL_PARENT}" 2>/dev/null && \
        sudo mount -o rw,defaults,_netdev,nofail -t nfs warewulf:/nfsapps "${INSTALL_PARENT}"; } || true
fi

if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
   echo "ERROR: ${INSTALL_PARENT} is not writable on $(hostname); aborting." >&2
   mount | grep nfsapps || true
   exit 1
fi

# Self-heal: if the install destinations were cleaned up, recreate them so the
# build script's pre-checks (and ${TOP_INSTALL_PATH}/${TOP_MODULE_PATH}/* extracts)
# don't trip on a missing parent. Owner root:root, mode 0755 to match prior
# layout.
TOP_MODULE_PATH="${TOP_MODULE_PATH:-/nfsapps/modules}"
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}"; do
   if ! sudo -n test -d "${d}" 2>/dev/null; then
      echo "Creating missing ${d}"
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

if ! sudo -n test -w "${TOP_INSTALL_PATH}" 2>/dev/null; then
   echo "ERROR: ${TOP_INSTALL_PATH} still not writable after self-heal on $(hostname); aborting." >&2
   sudo ls -la "${INSTALL_PARENT}" 2>&1 || true
   mount | grep nfsapps || true
   exit 1
fi

# Delta-release registry: bare_system/rocm_delta_releases.conf maps version
# to base (e.g. 7.2.2=7.2.1). run_rocm_build.sh auto-consults this file too,
# so no explicit --base-rocm-version flag is needed here; we just surface the
# detected delta versions in the summary for visibility.
DELTA_CONF="${SLURM_SUBMIT_DIR}/bare_system/rocm_delta_releases.conf"
delta_base_for() {
   local _v="$1"
   [[ -f "${DELTA_CONF}" ]] || return 1
   awk -F= -v v="${_v}" '
      /^[[:space:]]*#/ {next}
      /^[[:space:]]*$/ {next}
      $1 == v {print $2; found=1; exit}
      END {exit !found}
   ' "${DELTA_CONF}"
}

SUMMARY="sweep_summary_$(date +%Y%m%d_%H%M%S)_job${SLURM_JOB_ID}.out"
{
   echo "=================================================================="
   echo " ROCm sweep job ${SLURM_JOB_ID} starting at $(date) on $(hostname)"
   echo " Versions:        ${VERSIONS[*]}"
   echo " Distro:          ${DISTRO} ${DISTRO_VERSION}"
   echo " AMDGPU_GFXMODEL: ${AMDGPU_GFXMODEL}"
   echo " REPLACE_EXISTING: ${REPLACE_EXISTING}"
   echo " SKIP_PATCHES:     ${SKIP_PATCHES}"
   echo " KEEP_TARBALLS:    ${KEEP_TARBALLS}"
   echo " TOP_INSTALL_PATH: ${TOP_INSTALL_PATH}"
   echo " TOP_MODULE_PATH:  ${TOP_MODULE_PATH}"
   echo " DELTA_CONF:       ${DELTA_CONF}"
   for _v in "${VERSIONS[@]}"; do
      if _b=$(delta_base_for "${_v}"); then
         echo "    delta release: ${_v} (base ${_b})"
      fi
   done
   unset _v _b
   echo "=================================================================="
} | tee "${SUMMARY}"

OK=(); SKIP=(); FAIL=()
for v in "${VERSIONS[@]}"; do
   if [[ -d "${TOP_INSTALL_PATH}/rocm-${v}" && "${REPLACE_EXISTING}" != "1" ]]; then
      echo "[$(date)] SKIP rocm-${v} (already in ${TOP_INSTALL_PATH})" | tee -a "${SUMMARY}"
      SKIP+=("${v}")
      continue
   fi
   BASE_TAG=""
   if BASE_FOR_V=$(delta_base_for "${v}"); then
      BASE_TAG="  [DELTA: base=${BASE_FOR_V}]"
   fi
   {
      echo ""
      echo "=================================================================="
      echo " [$(date)] BEGIN rocm-${v}${BASE_TAG}"
      echo "=================================================================="
   } | tee -a "${SUMMARY}"

   if bare_system/run_rocm_build.sh \
         --rocm-version "${v}" \
         --distro "${DISTRO}" --distro-version "${DISTRO_VERSION}" \
         --amdgpu-gfxmodel "${AMDGPU_GFXMODEL}" \
         --use-makefile 1 \
         --replace-existing "${REPLACE_EXISTING}" \
         --skip-patches "${SKIP_PATCHES}" \
         --keep-tarballs "${KEEP_TARBALLS}" \
         --top-install-path "${TOP_INSTALL_PATH}" \
         --top-module-path  "${TOP_MODULE_PATH}"
   then
      echo "[$(date)] OK   rocm-${v}" | tee -a "${SUMMARY}"
      OK+=("${v}")
   else
      rc=$?
      echo "[$(date)] FAIL rocm-${v} (rc=${rc})" | tee -a "${SUMMARY}"
      FAIL+=("${v}")
   fi
done

{
   echo ""
   echo "=================================================================="
   echo " Sweep finished at $(date)"
   echo " OK   (${#OK[@]}):   ${OK[*]:-}"
   echo " SKIP (${#SKIP[@]}): ${SKIP[*]:-}"
   echo " FAIL (${#FAIL[@]}): ${FAIL[*]:-}"
   echo "=================================================================="
} | tee -a "${SUMMARY}"

[[ ${#FAIL[@]} -eq 0 ]]
