#!/bin/bash
#SBATCH --job-name=rocmplus_install
#SBATCH --partition=sh5_cpx_admin_long
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=48
#SBATCH --exclusive
# --time, --output, --error are set per-version by the submitter
# (run_rocmplus_install_sweep.sh) so each job logs to a versioned file.
#
# Single-version rocm-plus install: loads rocm/${ROCM_VERSION} from the
# system Lmod tree (/shared/apps/modules/ubuntu/lmodfiles/base on Ubuntu
# 22.04) and runs bare_system/main_setup.sh, which lays down the
# rocmplus-${ROCM_VERSION} install + module category on /nfsapps.
#
# Why the system tree (not /nfsapps/modules/base/rocm)?  The /nfsapps SDKs
# were built for Ubuntu 24.04 (GLIBC 2.38, libstdc++.so.6 GLIBCXX_3.4.32+)
# and will not run on the current sh5 nodes, which are 22.04 (GLIBC 2.35).
# When the cluster moves to 24.04, switch the module load below to point
# at /nfsapps/modules/base.
#
# The submitter chains one of these per ROCm version with --dependency=afterany
# so the chain proceeds even if a single version fails.
#
# Required env (passed via sbatch --export=ALL,...):
#   ROCM_VERSION         single ROCm version this job targets (e.g. 7.0.2)
# Optional env (with defaults):
#   AMDGPU_GFXMODEL      gfx942;gfx90a  (order matters: first arch is the
#                                        kokkos fallback target; see the
#                                        comment in run_rocmplus_install_sweep.sh)
#   TOP_INSTALL_PATH     /nfsapps/opt
#   TOP_MODULE_PATH      /nfsapps/modules
#   ROCM_INSTALLPATH     /nfsapps/opt
#   PYTHON_VERSION       (empty -> auto-detect from /etc/os-release;
#                        Ubuntu 22.04 -> 10, 24.04 -> 12)
#   QUICK_INSTALLS       0|1   (default 0)
#   REPLACE_EXISTING     0|1   (default 0)
#   KEEP_FAILED_INSTALLS 0|1   (default 0; 1 = preserve partial install
#                               artifacts of a failed package for forensics)
#   PACKAGES_LIST        space-separated whitelist (default: empty = all)

set -uo pipefail

cd "${SLURM_SUBMIT_DIR}"

ROCM_VERSION="${ROCM_VERSION:?ROCM_VERSION must be set via --export=ALL,ROCM_VERSION=...}"
AMDGPU_GFXMODEL="${AMDGPU_GFXMODEL:-gfx942;gfx90a}"
TOP_INSTALL_PATH="${TOP_INSTALL_PATH:-/nfsapps/opt}"
TOP_MODULE_PATH="${TOP_MODULE_PATH:-/nfsapps/modules}"
ROCM_INSTALLPATH="${ROCM_INSTALLPATH:-/nfsapps/opt}"
PYTHON_VERSION="${PYTHON_VERSION:-}"
QUICK_INSTALLS="${QUICK_INSTALLS:-0}"
REPLACE_EXISTING="${REPLACE_EXISTING:-0}"
KEEP_FAILED_INSTALLS="${KEEP_FAILED_INSTALLS:-0}"
PACKAGES_LIST="${PACKAGES_LIST:-}"

# Auto-detect python minor version from the compute node's distro when the
# caller did not pin one. Ubuntu 22.04 ships /usr/bin/python3.10 by default;
# 24.04 ships 3.12. Picking the distro-native python avoids dragging in a
# parallel toolchain (e.g. deadsnakes 3.12 on 22.04) that has no matching
# system-built ROCm wheels.
if [[ -z "${PYTHON_VERSION}" ]]; then
   if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      case "${VERSION_ID:-}" in
         22.04) PYTHON_VERSION="10" ;;
         24.04) PYTHON_VERSION="12" ;;
         *)
            echo "WARNING: unrecognized VERSION_ID='${VERSION_ID:-}'; defaulting PYTHON_VERSION=10" >&2
            PYTHON_VERSION="10"
            ;;
      esac
      echo "Auto-detected PYTHON_VERSION=3.${PYTHON_VERSION} from ${PRETTY_NAME:-/etc/os-release}"
   else
      echo "WARNING: /etc/os-release not readable; defaulting PYTHON_VERSION=10" >&2
      PYTHON_VERSION="10"
   fi
fi

NFSAPPS_PARENT="/nfsapps"

echo "=================================================================="
echo " rocmplus install job ${SLURM_JOB_ID} starting at $(date) on $(hostname)"
echo " ROCM_VERSION:     ${ROCM_VERSION}"
echo " TOP_INSTALL_PATH: ${TOP_INSTALL_PATH}"
echo " TOP_MODULE_PATH:  ${TOP_MODULE_PATH}"
echo " ROCM_INSTALLPATH: ${ROCM_INSTALLPATH}"
echo " AMDGPU_GFXMODEL:  ${AMDGPU_GFXMODEL}"
echo " PYTHON_VERSION:   3.${PYTHON_VERSION}"
echo " QUICK_INSTALLS:   ${QUICK_INSTALLS}"
echo " REPLACE_EXISTING: ${REPLACE_EXISTING}"
echo " KEEP_FAILED:      ${KEEP_FAILED_INSTALLS}"
echo " PACKAGES_LIST:    ${PACKAGES_LIST:-<all>}"
echo "=================================================================="

# ── 1. Ensure /nfsapps is writable on this compute node ──────────────
# The login node exports /nfsapps rw to sh5 nodes via
# /etc/exports.d/nfsapps_sh5_rw.exports, but the warewulf-managed fstab
# still says ro by default, so this defensive remount is required.
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

# ── 2. Self-heal install/module roots if missing ─────────────────────
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}"; do
   if ! sudo -n test -d "${d}" 2>/dev/null; then
      echo "Creating missing ${d}"
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

# ── 3. Source Lmod and load rocm/${ROCM_VERSION} ─────────────────────
# Slurm runs the batch script under a non-login shell, so /etc/profile.d
# is not sourced automatically. /etc/profile.d/lmod.sh is the canonical
# init: it sets MODULEPATH from /etc/lmod/modulespath *and* defines the
# `module` function. /etc/profile.d/z00_lmod.sh only defines the function,
# so MODULEPATH would stay empty if we only sourced that one.
if [[ -r /etc/profile.d/lmod.sh ]]; then
   # shellcheck disable=SC1091
   source /etc/profile.d/lmod.sh
elif [[ -r /usr/share/lmod/lmod/init/profile ]]; then
   # shellcheck disable=SC1091
   source /usr/share/lmod/lmod/init/profile
   # MODULEPATH wasn't set by the init; fall back to the documented system path.
   export MODULEPATH="${MODULEPATH:-/shared/apps/modules/ubuntu/lmodfiles/base}"
else
   echo "ERROR: Cannot find Lmod init script (/etc/profile.d/lmod.sh)." >&2
   exit 1
fi

# Load the *system* rocm module (22.04-native tree). Do NOT add
# /nfsapps/modules/base to MODULEPATH here; see header comment.
module load "rocm/${ROCM_VERSION}"
echo "Loaded module rocm/${ROCM_VERSION}; ROCM_PATH=${ROCM_PATH:-<unset>}"
module list 2>&1 | sed 's/^/  /'

# Sanity check: the resolved ROCM_PATH must exist and must NOT be a
# /nfsapps SDK (those are 24.04-built; running them on 22.04 hits
# GLIBC_2.38 / GLIBCXX_3.4.32 errors that masquerade as "HIP not found"
# during dependent package builds).
if [[ -z "${ROCM_PATH:-}" || ! -d "${ROCM_PATH}" ]]; then
   echo "ERROR: ROCM_PATH is unset or missing after module load: '${ROCM_PATH:-}'" >&2
   exit 1
fi
case "${ROCM_PATH}" in
   /nfsapps/*)
      echo "ERROR: rocm/${ROCM_VERSION} resolved to ${ROCM_PATH}, which is the" >&2
      echo "       24.04-built SDK on /nfsapps. The current nodes are Ubuntu 22.04;" >&2
      echo "       use the system rocm modules under /shared/apps/modules/ubuntu/lmodfiles/base." >&2
      exit 1
      ;;
esac
echo "ROCm SDK in use: ${ROCM_PATH} (22.04-native)"

# ── 4. Run main_setup.sh ─────────────────────────────────────────────
# Stdin from /dev/null so the 30-second confirm prompt times out cleanly
# instead of blocking forever on a non-interactive sbatch.
echo ""
echo "=================================================================="
echo " [$(date)] BEGIN main_setup.sh for rocm-${ROCM_VERSION}"
echo "=================================================================="

# --packages must only be passed when non-empty; passing --packages "" would
# trigger the unknown-name validation since "" isn't in PKG_FLAG.
PACKAGES_ARGS=()
if [[ -n "${PACKAGES_LIST}" ]]; then
   PACKAGES_ARGS=( --packages "${PACKAGES_LIST}" )
fi

bare_system/main_setup.sh \
   --rocm-version       "${ROCM_VERSION}" \
   --rocm-install-path  "${ROCM_INSTALLPATH}" \
   --top-install-path   "${TOP_INSTALL_PATH}" \
   --top-module-path    "${TOP_MODULE_PATH}" \
   --amdgpu-gfxmodel    "${AMDGPU_GFXMODEL}" \
   --python-version     "${PYTHON_VERSION}" \
   --quick-installs     "${QUICK_INSTALLS}" \
   --replace-existing   "${REPLACE_EXISTING}" \
   --keep-failed-installs "${KEEP_FAILED_INSTALLS}" \
   "${PACKAGES_ARGS[@]}" \
   </dev/null
rc=$?

echo ""
echo "=================================================================="
echo " [$(date)] END main_setup.sh for rocm-${ROCM_VERSION} (rc=${rc})"
echo "=================================================================="

exit ${rc}
