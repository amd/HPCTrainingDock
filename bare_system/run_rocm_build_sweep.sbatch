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
#   ROCM_VERSIONS    space-separated list of ROCm versions to install
# Optional env:
#   FORCE_EXTRACT    0|1 (default 0)
#   KEEP_TARBALLS    N   (default 3)
#   DISTRO, DISTRO_VERSION, AMDGPU_GFXMODEL

set -uo pipefail

cd "${SLURM_SUBMIT_DIR}"

ROCM_VERSIONS_RAW="${ROCM_VERSIONS:?ROCM_VERSIONS must be set via --export=ALL,ROCM_VERSIONS=...}"
ROCM_VERSIONS_RAW="${ROCM_VERSIONS_RAW//,/ }"
read -r -a VERSIONS <<< "${ROCM_VERSIONS_RAW}"

FORCE_EXTRACT="${FORCE_EXTRACT:-0}"
KEEP_TARBALLS="${KEEP_TARBALLS:-3}"
DISTRO="${DISTRO:-ubuntu}"
DISTRO_VERSION="${DISTRO_VERSION:-24.04}"
AMDGPU_GFXMODEL="${AMDGPU_GFXMODEL:-gfx942;gfx90a}"
NFSAPPS_OPT="${NFSAPPS_OPT:-/nfsapps/opt}"

# Defensive remount of /nfsapps as rw on this compute node. The login node
# exports it rw to sh5 admin nodes via /etc/exports.d/nfsapps_sh5_rw.exports,
# but the warewulf-managed fstab still says ro by default.
NFSAPPS_PARENT="${NFSAPPS_OPT%/*}"   # e.g. /nfsapps
if ! sudo -n test -w "${NFSAPPS_PARENT}" 2>/dev/null; then
   echo "Attempting to remount ${NFSAPPS_PARENT} rw..."
   sudo mount -o remount,rw "${NFSAPPS_PARENT}" 2>/dev/null || \
      { sudo umount "${NFSAPPS_PARENT}" 2>/dev/null && \
        sudo mount -o rw,defaults,_netdev,nofail -t nfs warewulf:/nfsapps "${NFSAPPS_PARENT}"; } || true
fi

if ! sudo -n test -w "${NFSAPPS_PARENT}" 2>/dev/null; then
   echo "ERROR: ${NFSAPPS_PARENT} is not writable on $(hostname); aborting." >&2
   mount | grep nfsapps || true
   exit 1
fi

# Self-heal: if the install destinations were cleaned up, recreate them so the
# build script's pre-checks (and ${NFSAPPS_OPT}/${NFSAPPS_MODULES}/* extracts)
# don't trip on a missing parent. Owner root:root, mode 0755 to match prior
# layout.
NFSAPPS_MODULES="${NFSAPPS_MODULES:-/nfsapps/modules}"
for d in "${NFSAPPS_OPT}" "${NFSAPPS_MODULES}"; do
   if ! sudo -n test -d "${d}" 2>/dev/null; then
      echo "Creating missing ${d}"
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

if ! sudo -n test -w "${NFSAPPS_OPT}" 2>/dev/null; then
   echo "ERROR: ${NFSAPPS_OPT} still not writable after self-heal on $(hostname); aborting." >&2
   sudo ls -la "${NFSAPPS_PARENT}" 2>&1 || true
   mount | grep nfsapps || true
   exit 1
fi

SUMMARY="sweep_summary_$(date +%Y%m%d_%H%M%S)_job${SLURM_JOB_ID}.out"
{
   echo "=================================================================="
   echo " ROCm sweep job ${SLURM_JOB_ID} starting at $(date) on $(hostname)"
   echo " Versions:        ${VERSIONS[*]}"
   echo " Distro:          ${DISTRO} ${DISTRO_VERSION}"
   echo " AMDGPU_GFXMODEL: ${AMDGPU_GFXMODEL}"
   echo " FORCE_EXTRACT:   ${FORCE_EXTRACT}"
   echo " KEEP_TARBALLS:   ${KEEP_TARBALLS}"
   echo " NFSAPPS_OPT:     ${NFSAPPS_OPT}"
   echo "=================================================================="
} | tee "${SUMMARY}"

OK=(); SKIP=(); FAIL=()
for v in "${VERSIONS[@]}"; do
   if [[ -d "${NFSAPPS_OPT}/rocm-${v}" && "${FORCE_EXTRACT}" != "1" ]]; then
      echo "[$(date)] SKIP rocm-${v} (already in ${NFSAPPS_OPT})" | tee -a "${SUMMARY}"
      SKIP+=("${v}")
      continue
   fi
   {
      echo ""
      echo "=================================================================="
      echo " [$(date)] BEGIN rocm-${v}"
      echo "=================================================================="
   } | tee -a "${SUMMARY}"

   if bare_system/run_rocm_build.sh \
         --rocm-version "${v}" \
         --distro "${DISTRO}" --distro-version "${DISTRO_VERSION}" \
         --amdgpu-gfxmodel "${AMDGPU_GFXMODEL}" \
         --use-makefile 1 \
         --force-extract "${FORCE_EXTRACT}" \
         --keep-tarballs "${KEEP_TARBALLS}"
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
