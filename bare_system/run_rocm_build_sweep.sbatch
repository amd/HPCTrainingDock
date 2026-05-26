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
TOP_MODULE_PATH="${TOP_MODULE_PATH:-/nfsapps/modules}"
THEROCK_AMDGPU_FAMILY="${THEROCK_AMDGPU_FAMILY:-gfx94X-dcgpu}"
SITE="${SITE:-}"

# ── Defensive /nfsapps remount block (compute-node side) ──────────────
# Only relevant when TOP_INSTALL_PATH or TOP_MODULE_PATH actually live
# under /nfsapps. Previously this block computed
# `INSTALL_PARENT="${TOP_INSTALL_PATH%/*}"` and unconditionally tried to
# remount it -- which works for the legacy /nfsapps/opt layout
# (INSTALL_PARENT=/nfsapps == the real NFS mount), but breaks for
# nested test trees like /nfsapps/ubuntu-22.04/opt (INSTALL_PARENT
# becomes /nfsapps/ubuntu-22.04, which is NOT a mount point, so the
# `mount -o remount` call no-ops/fails and the subsequent `umount`
# attempt is unsafe).
#
# Correct shape:
#   * Detect whether TOP_INSTALL_PATH or TOP_MODULE_PATH starts with
#     /nfsapps. If neither does, skip remount entirely (e.g. --site
#     opt or --site shared-apps installs don't touch /nfsapps).
#   * If they do, remount the /nfsapps mount root itself -- not the
#     directly-enclosing dir -- since /nfsapps is the only mount point
#     in the chain; everything below it is just directories on the
#     same NFS export.
NEED_NFSAPPS_RW=0
case "${TOP_INSTALL_PATH}" in /nfsapps|/nfsapps/*) NEED_NFSAPPS_RW=1 ;; esac
case "${TOP_MODULE_PATH}"  in /nfsapps|/nfsapps/*) NEED_NFSAPPS_RW=1 ;; esac

if [[ ${NEED_NFSAPPS_RW} -eq 1 ]]; then
   NFS_MOUNT_ROOT="/nfsapps"
   if ! sudo -n test -w "${NFS_MOUNT_ROOT}" 2>/dev/null; then
      echo "Attempting to remount ${NFS_MOUNT_ROOT} rw..."
      sudo mount -o remount,rw "${NFS_MOUNT_ROOT}" 2>/dev/null || \
         { sudo umount "${NFS_MOUNT_ROOT}" 2>/dev/null && \
           sudo mount -o rw,defaults,_netdev,nofail -t nfs warewulf:/nfsapps "${NFS_MOUNT_ROOT}"; } || true
   fi

   if ! sudo -n test -w "${NFS_MOUNT_ROOT}" 2>/dev/null; then
      echo "ERROR: ${NFS_MOUNT_ROOT} is not writable on $(hostname); aborting." >&2
      mount | grep nfsapps || true
      exit 1
   fi
fi

# Self-heal: if the install destinations were cleaned up, recreate them so the
# build script's pre-checks (and ${TOP_INSTALL_PATH}/${TOP_MODULE_PATH}/* extracts)
# don't trip on a missing parent. Walks the path from / down and `install -d`s
# every missing intermediate component, so nested layouts like
# /nfsapps/ubuntu-22.04/opt work without pre-staging the parent dirs.
# Owner root:root, mode 0755 to match prior layout.
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}"; do
   if ! sudo -n test -d "${d}" 2>/dev/null; then
      echo "Creating missing ${d} (with parents)"
      # `install -d` already creates all parent components per coreutils.
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

if ! sudo -n test -w "${TOP_INSTALL_PATH}" 2>/dev/null; then
   echo "ERROR: ${TOP_INSTALL_PATH} still not writable after self-heal on $(hostname); aborting." >&2
   sudo ls -la "$(dirname "${TOP_INSTALL_PATH}")" 2>&1 || true
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
   echo " SITE:             ${SITE:-<none>}"
   echo " TOP_INSTALL_PATH: ${TOP_INSTALL_PATH}"
   echo " TOP_MODULE_PATH:  ${TOP_MODULE_PATH}"
   echo " NFSAPPS_REMOUNT:  ${NEED_NFSAPPS_RW}  (1 = at least one path is under /nfsapps)"
   echo " THEROCK_FAMILY:   ${THEROCK_AMDGPU_FAMILY}"
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
   # The skip-if-installed pre-check has FOUR shapes here, one per
   # token bucket -- the install-dir + modulefile basename rule differs:
   #   * numeric (v=7.2.1)       -> rocm-7.2.1            (token verbatim)
   #   * AFAR    (v=afar-22.2.0) -> rocm-afar-22.2.0      (release-keyed)
   #                                + base/rocm/afar-22.2.0-<ROCM>.lua
   #                                (unified flang-site naming, 2026-05-26)
   #   * TheRock-AFAR (v=therock-afar-23.2.1)
   #                             -> rocm-afar-23.2.1      (release-keyed,
   #                                shares the same rocm-afar-* namespace
   #                                as AFAR proper; compiler numbers
   #                                don't overlap in practice -- AFAR
   #                                uses 22.x.y, TheRock-AFAR uses
   #                                23.x.y)
   #                                + base/rocm/afar-23.2.1-<ROCM>.lua
   #   * TheRock (v=therock-7.13 OR therock-7.13.0; non-flang channel)
   #                             -> rocm-therock-${.info/version}
   #                                e.g. rocm-therock-7.13.0 for both inputs.
   # We don't read .info/version here (we'd have to download the tarball
   # to learn it), so the modulefile-side check for AFAR / TheRock-AFAR
   # uses a glob (afar-<REL>-*.lua). The TheRock pre-check is a glob
   # match against both the literal token and the X.Y -> X.Y.0 auto-
   # extension. All three pre-checks mirror the Phase 0 logic in the
   # respective install helpers so the sweep and the helpers agree on
   # what counts as "already installed".
   _skip_match=""
   if [[ "${v}" == therock-afar-* ]]; then
      # therock-afar-<REL> installs to rocm-afar-<REL> + emits
      # base/rocm/afar-<REL>-<ROCM_NUMERIC>.lua. The install dir
      # basename is known directly (release-tag-keyed); the modulefile
      # uses a glob since ROCM_NUMERIC lives inside the tarball.
      _afar_rel="${v#therock-afar-}"
      if [[ -d "${TOP_INSTALL_PATH}/rocm-afar-${_afar_rel}" ]]; then
         shopt -s nullglob
         _mf_glob=( "${TOP_MODULE_PATH}/base/rocm/afar-${_afar_rel}"-*.lua )
         shopt -u nullglob
         [[ ${#_mf_glob[@]} -gt 0 ]] \
            && _skip_match="${TOP_INSTALL_PATH}/rocm-afar-${_afar_rel} + ${_mf_glob[0]}"
         unset _mf_glob
      fi
      unset _afar_rel
   elif [[ "${v}" == afar-* ]]; then
      # AFAR proper: install dir rocm-afar-<REL> + modulefile
      # base/rocm/afar-<REL>-<ROCM>.lua (unified naming). The legacy
      # base/rocm/afar-<REL>.lua (no -<ROCM> suffix) is NOT treated as
      # "installed" so a sweep against a pre-unified-naming tree
      # naturally upgrades the modulefile to the new shape.
      _afar_rel="${v#afar-}"
      if [[ -d "${TOP_INSTALL_PATH}/rocm-afar-${_afar_rel}" ]]; then
         shopt -s nullglob
         _mf_glob=( "${TOP_MODULE_PATH}/base/rocm/afar-${_afar_rel}"-*.lua )
         shopt -u nullglob
         [[ ${#_mf_glob[@]} -gt 0 ]] \
            && _skip_match="${TOP_INSTALL_PATH}/rocm-afar-${_afar_rel} + ${_mf_glob[0]}"
         unset _mf_glob
      fi
      unset _afar_rel
   elif [[ "${v}" == therock-* ]]; then
      _trel="${v#therock-}"
      for _cand in "${TOP_INSTALL_PATH}/rocm-therock-${_trel}" \
                   "${TOP_INSTALL_PATH}/rocm-therock-${_trel}.0"; do
         if [[ -d "${_cand}" ]]; then
            _skip_match="${_cand}"
            break
         fi
      done
      unset _cand _trel
   else
      [[ -d "${TOP_INSTALL_PATH}/rocm-${v}" ]] && _skip_match="${TOP_INSTALL_PATH}/rocm-${v}"
   fi
   if [[ -n "${_skip_match}" && "${REPLACE_EXISTING}" != "1" ]]; then
      echo "[$(date)] SKIP rocm-${v} (already at ${_skip_match})" | tee -a "${SUMMARY}"
      SKIP+=("${v}")
      unset _skip_match
      continue
   fi
   unset _skip_match

   # ── TheRock-AFAR branch: radeon flang/ extract-only ───────────────
   # therock-afar-<REL> tokens (e.g. therock-afar-23.2.1) live on the
   # AFAR site (https://repo.radeon.com/rocm/misc/flang/) under the
   # filename shape therock-afar-<REL>-<FAMILY>-<NUMERIC>-<SHA>.tar.bz2.
   # The helper run_rocm_therock_afar_install.sh:
   #   * derives <FAMILY> from the first gfx model in AMDGPU_GFXMODEL
   #     (e.g. gfx942 -> gfx94X) via a built-in mapping table;
   #   * scrapes the listing to discover the matching tarball;
   #   * extracts into rocm-therock-afar-<NUMERIC> (NUMERIC =
   #     .info/version);
   #   * emits the modulefile at base/rocm/therock-afar-<REL>.lua with
   #     MODULEPATH prepends for rocm-therock-afar-<NUMERIC> and
   #     rocmplus-therock-afar-<NUMERIC>.
   # This branch MUST come BEFORE the legacy `therock-*` branch below,
   # since `therock-afar-X.Y.Z` also matches the `therock-*` glob.
   if [[ "${v}" == therock-afar-* ]]; then
      THEROCK_AFAR_REL="${v#therock-afar-}"
      {
         echo ""
         echo "=================================================================="
         echo " [$(date)] BEGIN rocm-${v}  [TheRock-AFAR extract-only, gfxmodel=${AMDGPU_GFXMODEL}]"
         echo "=================================================================="
      } | tee -a "${SUMMARY}"

      if bare_system/run_rocm_therock_afar_install.sh \
            --therock-afar-release "${THEROCK_AFAR_REL}" \
            --amdgpu-gfxmodel      "${AMDGPU_GFXMODEL}" \
            --distro "${DISTRO}" --distro-version "${DISTRO_VERSION}" \
            --top-install-path "${TOP_INSTALL_PATH}" \
            --top-module-path  "${TOP_MODULE_PATH}" \
            --replace-existing "${REPLACE_EXISTING}"
      then
         echo "[$(date)] OK   rocm-${v}" | tee -a "${SUMMARY}"
         OK+=("${v}")
      else
         rc=$?
         echo "[$(date)] FAIL rocm-${v} (rc=${rc})" | tee -a "${SUMMARY}"
         FAIL+=("${v}")
      fi
      continue
   fi

   # ── TheRock branch: download + extract, no docker/make/patches ───
   # TheRock releases are pre-built distro-agnostic ROCm SDK tarballs
   # at https://repo.amd.com/rocm/tarball/ (legacy URL_BASE) OR
   # https://rocm.nightlies.amd.com/tarball-multi-arch/ (current upstream
   # channel; see RELEASES.md on github.com/ROCm/TheRock). The helper
   # handles URL auto-discovery (X.Y -> X.Y.0 extension + listing
   # fallback for alpha/RC tarballs), extracts directly into the install
   # dir (no wrapper segment to drop), reads .info/version to derive the
   # final install-dir basename (rocm-therock-<numeric>), and writes
   # a GPUSDK-shaped modulefile under base/rocm/therock-<token>.lua.
   if [[ "${v}" == therock-* ]]; then
      THEROCK_REL="${v#therock-}"
      {
         echo ""
         echo "=================================================================="
         echo " [$(date)] BEGIN rocm-${v}  [TheRock extract-only, family=${THEROCK_AMDGPU_FAMILY}]"
         echo "=================================================================="
      } | tee -a "${SUMMARY}"

      if bare_system/run_rocm_therock_install.sh \
            --therock-release "${THEROCK_REL}" \
            --amdgpu-family   "${THEROCK_AMDGPU_FAMILY}" \
            --distro "${DISTRO}" --distro-version "${DISTRO_VERSION}" \
            --top-install-path "${TOP_INSTALL_PATH}" \
            --top-module-path  "${TOP_MODULE_PATH}" \
            --replace-existing "${REPLACE_EXISTING}"
      then
         echo "[$(date)] OK   rocm-${v}" | tee -a "${SUMMARY}"
         OK+=("${v}")
      else
         rc=$?
         echo "[$(date)] FAIL rocm-${v} (rc=${rc})" | tee -a "${SUMMARY}"
         FAIL+=("${v}")
      fi
      continue
   fi

   # ── AFAR branch: extract-only, no docker/make/patches ────────────
   # AFAR drops are pre-built ROCm SDK tarballs that we download from
   # repo.radeon.com/rocm/misc/flang/ and untar in place; there is no
   # apt/dnf install path the docker-build pipeline could use. The
   # helper auto-discovers the AMD-internal AFAR build number from the
   # upstream directory listing and writes a GPUSDK-shaped modulefile.
   if [[ "${v}" == afar-* ]]; then
      AFAR_VER="${v#afar-}"
      {
         echo ""
         echo "=================================================================="
         echo " [$(date)] BEGIN rocm-${v}  [AFAR extract-only]"
         echo "=================================================================="
      } | tee -a "${SUMMARY}"

      if bare_system/run_rocm_afar_install.sh \
            --flang-release-number "${AFAR_VER}" \
            --distro "${DISTRO}" --distro-version "${DISTRO_VERSION}" \
            --top-install-path "${TOP_INSTALL_PATH}" \
            --top-module-path  "${TOP_MODULE_PATH}" \
            --replace-existing "${REPLACE_EXISTING}"
      then
         echo "[$(date)] OK   rocm-${v}" | tee -a "${SUMMARY}"
         OK+=("${v}")
      else
         rc=$?
         echo "[$(date)] FAIL rocm-${v} (rc=${rc})" | tee -a "${SUMMARY}"
         FAIL+=("${v}")
      fi
      continue
   fi

   # ── Numeric ROCm branch: full docker + make + extract + patches ──
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
