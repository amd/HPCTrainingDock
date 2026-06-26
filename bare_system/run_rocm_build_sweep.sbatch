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
# AAC7 high-level interface (see run_rocm_build_sweep.sh --program-environments).
# When PROGRAM_ENVIRONMENTS is non-empty the sweep runs the Cray PrgEnv flow
# (build-or-cache + per-flavor module emission) instead of the legacy
# ROCM_VERSIONS loop below.
PROGRAM_ENVIRONMENTS="${PROGRAM_ENVIRONMENTS:-}"
PACKAGE_CACHE="${PACKAGE_CACHE:-/shareddata/rocm-package-cache}"
PE_VERSION="${PE_VERSION:-}"

# ── Outbound proxy for compute-node fetches ───────────────────────────
# Some leaf installers still download from the internet on the compute node
# (e.g. mpich-wrappers fetches the MPICH source tarball with wget). AAC7 compute
# nodes have NO direct internet; they egress through a SITE proxy that the node's
# own /etc/profile sets (e.g. http://172.23.0.12:3128). A non-login sbatch like
# this one does NOT source /etc/profile, so we must derive that proxy explicitly.
#
# Priority:
#   1. An explicit operator override (submitter --https-proxy -> HTTPS_PROXY_URL).
#   2. The compute node's own login-shell proxy (sources /etc/profile here).
#   3. Inherited env -- but ONLY if it is not a loopback proxy.
# Loopback proxies (http://127.0.0.1:PORT, localhost, [::1]) are login-node SSH
# tunnels that compute nodes cannot reach; using one is worse than none, so we
# reject it everywhere (it would override the node's working site proxy).
_is_loopback_proxy() { case "${1}" in *127.0.0.1*|*localhost*|*'[::1]'*) return 0 ;; *) return 1 ;; esac; }

# (2) what does a login shell on THIS node resolve the proxy to?
_node_https="$(bash -lc 'printf %s "${https_proxy:-${HTTPS_PROXY:-}}"' 2>/dev/null || true)"
_node_http="$(bash -lc 'printf %s "${http_proxy:-${HTTP_PROXY:-}}"' 2>/dev/null || true)"

HTTPS_PROXY_URL="${HTTPS_PROXY_URL:-}"
HTTP_PROXY_URL="${HTTP_PROXY_URL:-}"
if [[ -z "${HTTPS_PROXY_URL}" ]]; then
   if [[ -n "${_node_https}" ]] && ! _is_loopback_proxy "${_node_https}"; then
      HTTPS_PROXY_URL="${_node_https}"
   elif [[ -n "${https_proxy:-}" ]] && ! _is_loopback_proxy "${https_proxy}"; then
      HTTPS_PROXY_URL="${https_proxy}"
   fi
fi
if [[ -z "${HTTP_PROXY_URL}" ]]; then
   if [[ -n "${_node_http}" ]] && ! _is_loopback_proxy "${_node_http}"; then
      HTTP_PROXY_URL="${_node_http}"
   elif [[ -n "${http_proxy:-}" ]] && ! _is_loopback_proxy "${http_proxy}"; then
      HTTP_PROXY_URL="${http_proxy}"
   fi
fi
[[ -z "${HTTP_PROXY_URL}" && -n "${HTTPS_PROXY_URL}" ]] && HTTP_PROXY_URL="${HTTPS_PROXY_URL}"
# Final guard: never propagate a loopback proxy (even if explicitly forwarded).
_is_loopback_proxy "${HTTPS_PROXY_URL}" && HTTPS_PROXY_URL=""
_is_loopback_proxy "${HTTP_PROXY_URL}"  && HTTP_PROXY_URL=""
unset _node_https _node_http

if [[ -n "${HTTPS_PROXY_URL}" || -n "${HTTP_PROXY_URL}" ]]; then
   export https_proxy="${HTTPS_PROXY_URL}" HTTPS_PROXY="${HTTPS_PROXY_URL}"
   export http_proxy="${HTTP_PROXY_URL}"   HTTP_PROXY="${HTTP_PROXY_URL}"
   echo "[rocm_sweep] proxy for compute-node fetches: https='${HTTPS_PROXY_URL}' http='${HTTP_PROXY_URL}'"
else
   # No usable proxy and (typically) no direct internet -> internet fetches like
   # the mpich-wrappers MPICH download will fail. Make that explicit.
   export https_proxy="" HTTPS_PROXY="" http_proxy="" HTTP_PROXY=""
   echo "[rocm_sweep] NOTE: no usable (non-loopback) proxy found on $(hostname);"
   echo "[rocm_sweep]       internet fetches (e.g. mpich-wrappers MPICH download)"
   echo "[rocm_sweep]       will fail unless this node has direct internet."
   echo "[rocm_sweep]       Override with: run_rocm_build_sweep.sh --https-proxy URL"
fi

# ── AAC7 (HPE/Cray) no-passwordless-sudo support ──────────────────────
# AAC6 compute nodes have passwordless sudo and a root-owned /nfsapps tree;
# AAC7 (HPE/Cray) has NO passwordless sudo but the /shareddata build tree is
# user-writable. A session "no-sudo" shim (~/.nosudo-shim/sudo) strips sudo's
# own options and runs the wrapped command AS THE USER (no-oping chown/chgrp).
# If passwordless sudo is unavailable and the shim exists, prepend it to PATH
# so every `sudo ...` in this job (the self-heal below AND the downstream
# install scripts) runs without ever hitting an interactive password prompt.
# `sudo -n true` returns non-zero WITHOUT prompting, so this never hangs.
if ! sudo -n true 2>/dev/null; then
   if [[ -x "${HOME}/.nosudo-shim/sudo" ]]; then
      echo "[rocm_sweep] no passwordless sudo on $(hostname); using ${HOME}/.nosudo-shim (run-as-user)"
      export PATH="${HOME}/.nosudo-shim:${PATH}"
   else
      echo "[rocm_sweep] WARNING: no passwordless sudo and no ${HOME}/.nosudo-shim;" >&2
      echo "[rocm_sweep]          sudo calls may prompt/fail. Ensure the install tree" >&2
      echo "[rocm_sweep]          (${TOP_INSTALL_PATH}, ${TOP_MODULE_PATH}) is user-writable." >&2
   fi
fi

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
   # Already present (AAC7 /shareddata case, or a prior run) -> nothing to do.
   [[ -d "${d}" ]] && continue
   echo "Creating missing ${d} (with parents)"
   # Prefer a plain user mkdir (works when the parent tree is user-writable,
   # e.g. /shareddata). Only fall back to sudo when that fails (e.g. the
   # root-owned /nfsapps tree on AAC6, where sudo is passwordless or the
   # nosudo shim is on PATH). `install -d` creates all parent components.
   if ! mkdir -p "${d}" 2>/dev/null; then
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

# Writability gate: a plain `test -w` is authoritative for the user-writable
# /shareddata case; fall back to `sudo -n test -w` for root-owned trees.
if ! { [[ -w "${TOP_INSTALL_PATH}" ]] || sudo -n test -w "${TOP_INSTALL_PATH}" 2>/dev/null; }; then
   echo "ERROR: ${TOP_INSTALL_PATH} still not writable after self-heal on $(hostname); aborting." >&2
   ls -la "$(dirname "${TOP_INSTALL_PATH}")" 2>&1 || true
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

# =====================================================================
#  AAC7 high-level --program-environments flow
# =====================================================================
# When PROGRAM_ENVIRONMENTS is set, drive the sweep from Cray PrgEnv tokens
# (<flavor>/<pe>-<rocm-suffix>) instead of the legacy ROCM_VERSIONS loop. For
# each de-duplicated canonical rocm token: skip if already installed in the
# site location; otherwise build the rocm package when docker/podman is present
# or extract a pre-built tarball from PACKAGE_CACHE when it is not; then emit
# only the requested PrgEnv flavor(s). OpenMPI flavors are a WIP skeleton: the
# rocm SDK is installed (no PrgEnv ecosystem) and a work-in-progress message is
# printed.
if [[ -n "${PROGRAM_ENVIRONMENTS}" ]]; then
   KIND_MAP_CONF="${SLURM_SUBMIT_DIR}/bare_system/rocm_kind_map.conf"
   [[ -f "${KIND_MAP_CONF}" ]] || { echo "ERROR: kind map ${KIND_MAP_CONF} not found" | tee -a "${SUMMARY}"; exit 1; }

   resolve_kind() {
      awk -F= -v s="$1" '
         /^[[:space:]]*#/ {next}
         /^[[:space:]]*$/ {next}
         $1 == s {print $2; found=1; exit}
         END {exit !found}
      ' "${KIND_MAP_CONF}"
   }

   # ── Usable container-builder detection ────────────────────────────
   # A builder is only useful if it can ACTUALLY build, not merely be on PATH.
   # Two cases:
   #   * Real docker daemon (AAC6): `docker info` must succeed.
   #   * Rootless podman (AAC7): the binary alone is not enough --
   #       - the user needs subuid/subgid ranges (else image unpacking fails
   #         with "insufficient UIDs/GIDs ... lchown ...: invalid argument"), and
   #       - the overlay store must live on an xattr-capable, node-local FS
   #         (/localnvme/$USER); the podman default ($HOME/.local/... on NFS)
   #         cannot do overlay xattrs ("lsetxattr ...: operation not supported").
   # On these Cray nodes `docker` is a podman shim, so if podman exists we treat
   # podman as THE builder (and ignore the shim). detect_builder() sets BUILDER
   # and, for podman, PODMAN_ROOT/PODMAN_RUNROOT to the node-local store.
   BUILDER=""
   PODMAN_ROOT=""
   PODMAN_RUNROOT=""
   PODMAN_STORAGE_CONF=""

   _podman_usable() {
      # (a) rootless ID ranges present?
      grep -q "^${USER}:" /etc/subuid 2>/dev/null && grep -q "^${USER}:" /etc/subgid 2>/dev/null || return 1
      # (b) node-local, writable, xattr-capable store base?
      local _base=""
      if   [[ -d "/localnvme/${USER}" && -w "/localnvme/${USER}" ]]; then _base="/localnvme/${USER}"
      elif [[ -d /localnvme && -w /localnvme ]];                    then _base="/localnvme/${USER}"
      else return 1; fi
      PODMAN_ROOT="${_base}/containers/storage"
      PODMAN_RUNROOT="${_base}/containers/run"
      mkdir -p "${PODMAN_ROOT}" "${PODMAN_RUNROOT}" 2>/dev/null || return 1
      # (c) podman actually operational against that store?
      podman --root "${PODMAN_ROOT}" --runroot "${PODMAN_RUNROOT}" info >/dev/null 2>&1 || return 1
      return 0
   }

   detect_builder() {
      BUILDER=""
      if command -v podman >/dev/null 2>&1; then
         # podman is the (rootless) builder on this node; docker (if present) is
         # just a shim to it. Only usable when fully configured.
         _podman_usable && { BUILDER="podman"; return 0; }
         return 1
      fi
      if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
         BUILDER="docker"; return 0
      fi
      return 1
   }

   # Write a per-job storage.conf so every podman/docker-shim call in the build
   # uses the node-local overlay store, and export it. Idempotent.
   prepare_podman_storage() {
      [[ "${BUILDER}" == "podman" ]] || return 0
      [[ -n "${PODMAN_ROOT}" ]] || return 1
      PODMAN_STORAGE_CONF="${PODMAN_ROOT%/storage}/storage.conf"
      cat > "${PODMAN_STORAGE_CONF}" <<EOF
[storage]
driver = "overlay"
graphroot = "${PODMAN_ROOT}"
runroot = "${PODMAN_RUNROOT}"
EOF
      export CONTAINERS_STORAGE_CONF="${PODMAN_STORAGE_CONF}"
   }

   # Back-compat predicate (used in the cache-miss message + build gate).
   have_builder() { detect_builder; }

   # Re-parse the PrgEnv tokens into a per-canonical-token flavor set + PE
   # version. (The submitter already validated the shapes; we re-derive here so
   # the compute node knows which flavor(s) each token wants.)
   declare -A PE_FLAVORS=() PE_PE=()
   PE_CANON=()
   PE_PARSE_OK=1
   for _petok in ${PROGRAM_ENVIRONMENTS}; do
      _flavor="${_petok%%/*}"
      _rest="${_petok#*/}"
      _pe="${_rest%%-*}"
      _suffix="${_rest#*-}"
      if ! _canon="$(resolve_kind "${_suffix}")" || [[ -z "${_canon}" ]]; then
         echo "ERROR: rocm-suffix '${_suffix}' (token '${_petok}') not in ${KIND_MAP_CONF}" | tee -a "${SUMMARY}"
         PE_PARSE_OK=0; continue
      fi
      # Map the PrgEnv flavor to an internal emit-flavor token.
      case "${_flavor}" in
         PrgEnv-amd-new)          _ef="amd-new" ;;
         PrgEnv-cray-new)         _ef="cray-new" ;;
         PrgEnv-amd-openmpi)      _ef="openmpi" ;;
         PrgEnv-amd-openmpi-ucx)  _ef="openmpi-ucx" ;;
         *) echo "ERROR: unknown flavor '${_flavor}' (token '${_petok}')" | tee -a "${SUMMARY}"; PE_PARSE_OK=0; continue ;;
      esac
      if [[ -z "${PE_FLAVORS[${_canon}]:-}" ]]; then
         PE_CANON+=("${_canon}")
         PE_FLAVORS[${_canon}]="${_ef}"
      else
         case " ${PE_FLAVORS[${_canon}]} " in *" ${_ef} "*) : ;; *) PE_FLAVORS[${_canon}]+=" ${_ef}" ;; esac
      fi
      [[ -z "${PE_PE[${_canon}]:-}" ]] && PE_PE[${_canon}]="${_pe}"
   done
   unset _petok _flavor _rest _pe _suffix _canon _ef
   [[ "${PE_PARSE_OK}" -eq 1 ]] || { echo "ERROR: PrgEnv token parse failed; aborting" | tee -a "${SUMMARY}"; exit 1; }

   {
      echo ""
      echo "=================================================================="
      echo " AAC7 program-environments flow"
      echo " Canonical tokens: ${PE_CANON[*]}"
      echo " Package cache:    ${PACKAGE_CACHE}  (TheRock/AFAR: optional; downloaded from repo.amd.com if absent)"
      if detect_builder; then
         if [[ "${BUILDER}" == "podman" ]]; then
            echo " builder:          podman (usable; node-local store ${PODMAN_ROOT})"
         else
            echo " builder:          ${BUILDER} (usable)"
         fi
      else
         echo " builder:          none usable (will extract from cache; numeric tokens need a staged package)"
      fi
      for _t in "${PE_CANON[@]}"; do
         echo "   ${_t}  ->  flavors='${PE_FLAVORS[${_t}]}'  pe='${PE_PE[${_t}]:-${PE_VERSION}}'"
      done
      unset _t
      echo "=================================================================="
   } | tee -a "${SUMMARY}"

   # Find a pre-built tarball for a canonical token in the package cache. Echoes
   # the path on success (rc 0), nothing on miss (rc 1). Accepts the stage-sweep
   # naming plus a couple of common aliases.
   find_cached_tarball() {
      local _tok="$1" _kind="$2" _c
      shopt -s nullglob
      local -a _cands=()
      case "${_kind}" in
         numeric)
            _cands=( "${PACKAGE_CACHE}/rocm-numeric-${_tok}".tar.gz \
                     "${PACKAGE_CACHE}/rocm-${_tok}".tgz \
                     "${PACKAGE_CACHE}/rocm-${_tok}".tar.gz ) ;;
         therock)
            local _rel="${_tok#therock-}"
            _cands=( "${PACKAGE_CACHE}/therock-dist-linux-${THEROCK_AMDGPU_FAMILY}-${_rel}".tar.gz \
                     "${PACKAGE_CACHE}/therock-dist-linux-${THEROCK_AMDGPU_FAMILY}-${_rel}".0.tar.gz \
                     "${PACKAGE_CACHE}/therock-dist-linux-${THEROCK_AMDGPU_FAMILY}-${_rel}"*.tar.gz ) ;;
         therock-afar)
            local _rel="${_tok#therock-afar-}"
            _cands=( "${PACKAGE_CACHE}/therock-afar-${_rel}"-*.tar.bz2 \
                     "${PACKAGE_CACHE}/therock-${_rel}"-*.tar.bz2 ) ;;
      esac
      shopt -u nullglob
      for _c in "${_cands[@]}"; do
         [[ -f "${_c}" ]] && { echo "${_c}"; return 0; }
      done
      return 1
   }

   PE_OK=(); PE_SKIP=(); PE_FAIL=()
   for tok in "${PE_CANON[@]}"; do
      flavors="${PE_FLAVORS[${tok}]}"
      pe="${PE_PE[${tok}]:-${PE_VERSION}}"

      # Derive the emit-flavor subset for the cray ecosystem + whether OpenMPI
      # was requested for this token.
      emit_set=""; want_openmpi=0
      for f in ${flavors}; do
         case "${f}" in
            amd-new)  case " ${emit_set} " in *" amd-new "*) : ;; *) emit_set+=" amd-new" ;; esac ;;
            cray-new) case " ${emit_set} " in *" cray-new "*) : ;; *) emit_set+=" cray-new" ;; esac ;;
            openmpi|openmpi-ucx) want_openmpi=1 ;;
         esac
      done
      emit_set="${emit_set# }"
      # PRGENV_FLAVORS for the installer: the requested {amd-new,cray-new} subset,
      # or "none" for an OpenMPI-only token (install rocm, emit no PrgEnv).
      if [[ -n "${emit_set}" ]]; then
         PRGENV_FLAVORS_VAL="${emit_set}"
      else
         PRGENV_FLAVORS_VAL="none"
      fi
      # mpich-wrappers are only consumed by PrgEnv-amd-new; build them only then.
      case " ${emit_set} " in *" amd-new "*) BUILD_MW=1 ;; *) BUILD_MW=0 ;; esac

      # Determine the canonical token's install kind.
      if [[ "${tok}" == therock-afar-* ]]; then kind="therock-afar"
      elif [[ "${tok}" == therock-* ]];   then kind="therock"
      elif [[ "${tok}" == afar-* ]];      then kind="afar"
      else kind="numeric"; fi

      {
         echo ""
         echo "=================================================================="
         echo " [$(date)] PROGRAM-ENV ${tok}  (kind=${kind}, emit='${PRGENV_FLAVORS_VAL}', pe=${pe})"
         echo "=================================================================="
      } | tee -a "${SUMMARY}"

      # ── Skip-if-installed in the site location ─────────────────────────
      _skip_match=""
      case "${kind}" in
         therock-afar)
            _rel="${tok#therock-afar-}"
            if [[ -d "${TOP_INSTALL_PATH}/rocm-afar-${_rel}" ]]; then
               shopt -s nullglob
               _mf=( "${TOP_MODULE_PATH}/base/rocm/afar-${_rel}"-*.lua "${TOP_MODULE_PATH}/base/rocm/afar-${_rel}"-* )
               shopt -u nullglob
               [[ ${#_mf[@]} -gt 0 ]] && _skip_match="${TOP_INSTALL_PATH}/rocm-afar-${_rel}"
            fi ;;
         afar)
            _rel="${tok#afar-}"
            [[ -d "${TOP_INSTALL_PATH}/rocm-afar-${_rel}" ]] && _skip_match="${TOP_INSTALL_PATH}/rocm-afar-${_rel}" ;;
         therock)
            _rel="${tok#therock-}"
            for _cand in "${TOP_INSTALL_PATH}/rocm-therock-${_rel}" "${TOP_INSTALL_PATH}/rocm-therock-${_rel}.0"; do
               [[ -d "${_cand}" ]] && { _skip_match="${_cand}"; break; }
            done ;;
         numeric)
            [[ -d "${TOP_INSTALL_PATH}/rocm-${tok}" ]] && _skip_match="${TOP_INSTALL_PATH}/rocm-${tok}" ;;
      esac
      if [[ -n "${_skip_match}" && "${REPLACE_EXISTING}" != "1" ]]; then
         echo "[$(date)] SKIP install rocm-${tok} (already at ${_skip_match})" | tee -a "${SUMMARY}"
      else
         # ── Install: docker-build (numeric) or extract a PRE-BUILT package ──
         # from the package cache. There are NO internet downloads here: the
         # ROCm package must be either already present in ${PACKAGE_CACHE} or
         # buildable on this node with docker/podman (numeric kind only). If it
         # is neither, print a clear "not in the cache, create it and rerun"
         # message and fail the token.
         _rc=0
         _afar_wip=0
         _common=( --top-install-path "${TOP_INSTALL_PATH}"
                   --top-module-path  "${TOP_MODULE_PATH}"
                   --replace-existing "${REPLACE_EXISTING}"
                   --cray-modules --pe-version "${pe}" )

         if [[ "${kind}" == "afar" ]]; then
            # Legacy AFAR (22.x flang drop): run_rocm_afar_install.sh emits
            # Lmod-only modulefiles with no Cray PrgEnv ecosystem / --pe-version
            # support, so the AAC7 PrgEnv flow cannot wire it up yet. AFAR rocm
            # versions WILL be needed; for now just print a WIP message and move
            # on (no install, not a failure). The proper implementation will
            # either teach run_rocm_afar_install.sh the Cray ecosystem or map
            # AFAR releases to therock-afar-* in rocm_kind_map.conf.
            {
               echo "------------------------------------------------------------------"
               echo " [WIP] Legacy AFAR token '${tok}' is a WORK IN PROGRESS for the"
               echo "       --program-environments Cray flow; skipping for now."
               echo "       (Map the suffix to 'therock-afar-<rel>' in"
               echo "        ${KIND_MAP_CONF} to install it via the TheRock-AFAR path.)"
               echo "------------------------------------------------------------------"
            } | tee -a "${SUMMARY}"
            _afar_wip=1
         else
            _cached="$(find_cached_tarball "${tok}" "${kind}" || true)"
            _download=0   # therock/therock-afar: fetch directly from repo.amd.com

            if [[ -z "${_cached}" ]]; then
               case "${kind}" in
                  numeric)
                     # Numeric ROCm is a docker/podman-BUILT artifact (not a
                     # downloadable tarball): it must be built here or pre-staged
                     # in the cache. Build now iff a usable builder exists.
                     if detect_builder; then
                        # Point rootless podman at the node-local overlay store
                        # (CONTAINERS_STORAGE_CONF) to avoid NFS xattr failures.
                        prepare_podman_storage
                        echo "[$(date)] building rocm package for ${tok} (builder=${BUILDER}${PODMAN_ROOT:+, store=${PODMAN_ROOT}})" | tee -a "${SUMMARY}"
                        AMDGPU_GFXMODEL_STRING="${AMDGPU_GFXMODEL//;/_}"
                        _cachetb="CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${tok}-${AMDGPU_GFXMODEL_STRING}/rocm-${tok}.tgz"
                        if bare_system/run_rocm_build.sh \
                              --rocm-version "${tok}" \
                              --distro "${DISTRO}" --distro-version "${DISTRO_VERSION}" \
                              --amdgpu-gfxmodel "${AMDGPU_GFXMODEL}" \
                              --use-makefile 1 \
                              --replace-existing "${REPLACE_EXISTING}" \
                              --skip-patches "${SKIP_PATCHES}" \
                              --keep-tarballs "${KEEP_TARBALLS}" \
                              --skip-extract 1 \
                              --top-install-path "${TOP_INSTALL_PATH}" \
                              --top-module-path  "${TOP_MODULE_PATH}"; then
                           _cached="${_cachetb}"
                        else
                           _rc=$?
                        fi
                     fi
                     ;;
                  therock|therock-afar)
                     # TheRock / TheRock-AFAR are PRE-BUILT tarballs hosted on
                     # repo.amd.com. The package cache is only an optimization
                     # here: when the tarball is not pre-staged, download it
                     # directly -- the compute node reaches repo.amd.com through
                     # the site proxy. The installer's own discovery+curl handles
                     # the fetch when we omit --local-tarball.
                     _download=1
                     echo "[$(date)] ${tok}: not pre-staged in cache; downloading directly from repo.amd.com (via proxy)" | tee -a "${SUMMARY}"
                     ;;
               esac
            fi

            # Build the optional --local-tarball arg (present only when cached).
            _lt_args=()
            [[ -n "${_cached}" ]] && _lt_args=( --local-tarball "${_cached}" )

            if [[ ${_rc} -eq 0 && "${kind}" == "numeric" && ( -z "${_cached}" || ! -f "${_cached}" ) ]]; then
               # ── Numeric cache miss we cannot recover on-node ────────────
               # (numeric is not downloadable, and could not be built here).
               # TheRock/AFAR never reach this: they always have the download
               # fallback above.
               _expect="${PACKAGE_CACHE}/rocm-numeric-${tok}.tar.gz"
               _expect_base="$(basename "${_expect}")"
               {
                  echo "------------------------------------------------------------------"
                  echo " ERROR: the numeric ROCm package for '${tok}' is not in the AAC7"
                  echo "        rocm-package-cache and could not be built on this node:"
                  echo "            ${PACKAGE_CACHE}"
                  if detect_builder; then
                     echo "        (builder '${BUILDER}' is usable but the package build failed)"
                  elif command -v podman >/dev/null 2>&1; then
                     echo "        (podman is installed but NOT usable for builds on this"
                     echo "         node: needs subuid/subgid ranges for ${USER} in /etc/subuid"
                     echo "         + /etc/subgid, and a node-local /localnvme/${USER} store)"
                  else
                     echo "        (no container builder is available here)"
                  fi
                  echo "        Expected cache file, e.g.:"
                  echo "            ${_expect}"
                  echo ""
                  echo "      Step 1 — on a system that HAS docker/podman (e.g. AAC6),"
                  echo "      build the package into a LOCAL ./rocm-package-cache directory:"
                  echo ""
                  echo "            bare_system/run_rocm_stage_sweep.sh \\"
                  echo "               --rocm-versions \"${tok}\" \\"
                  echo "               --stage-dir ./rocm-package-cache \\"
                  echo "               --distro \"${DISTRO}\" \\"
                  echo "               --distro-version ${DISTRO_VERSION} \\"
                  echo "               --amdgpu-gfxmodel \"${AMDGPU_GFXMODEL}\""
                  echo ""
                  echo "      Step 2 — transfer the staged tarball from AAC6 into the AAC7"
                  echo "      cache (run on AAC7, pulling from the AAC6 login node):"
                  echo ""
                  echo "            mkdir -p ${PACKAGE_CACHE}"
                  echo "            rsync -av <aac6-login>:<path-to-repo>/rocm-package-cache/${_expect_base} \\"
                  echo "               ${PACKAGE_CACHE}/"
                  echo ""
                  echo "      Step 3 — re-run this --program-environments sweep."
                  echo "------------------------------------------------------------------"
               } | tee -a "${SUMMARY}"
               unset _expect_base _expect
               _rc=1
            elif [[ ${_rc} -eq 0 ]]; then
               # ── Install: extract cached/built tarball OR download directly,
               #    then emit the Cray modules. ──
               if [[ ${_download} -eq 1 ]]; then
                  echo "[$(date)] installing ${kind} ${tok} (download-direct from repo.amd.com)" | tee -a "${SUMMARY}"
               else
                  echo "[$(date)] extracting ${kind} ${tok} from ${_cached}" | tee -a "${SUMMARY}"
               fi
               case "${kind}" in
                  numeric)
                     PRGENV_FLAVORS="${PRGENV_FLAVORS_VAL}" BUILD_MPICH_WRAPPERS="${BUILD_MW}" \
                     bare_system/run_rocm_craywrap_install.sh \
                        --rocm-version "${tok}" \
                        --local-tarball "${_cached}" \
                        --amdgpu-family "${THEROCK_AMDGPU_FAMILY}" \
                        "${_common[@]}" || _rc=$? ;;
                  therock)
                     PRGENV_FLAVORS="${PRGENV_FLAVORS_VAL}" BUILD_MPICH_WRAPPERS="${BUILD_MW}" \
                     bare_system/run_rocm_therock_install.sh \
                        --therock-release "${tok#therock-}" \
                        --amdgpu-family "${THEROCK_AMDGPU_FAMILY}" \
                        "${_lt_args[@]}" \
                        "${_common[@]}" || _rc=$? ;;
                  therock-afar)
                     PRGENV_FLAVORS="${PRGENV_FLAVORS_VAL}" BUILD_MPICH_WRAPPERS="${BUILD_MW}" \
                     bare_system/run_rocm_therock_afar_install.sh \
                        --therock-afar-release "${tok#therock-afar-}" \
                        --amdgpu-gfxmodel "${AMDGPU_GFXMODEL}" \
                        --skip-patches "${SKIP_PATCHES}" \
                        "${_lt_args[@]}" \
                        "${_common[@]}" || _rc=$? ;;
               esac
            fi
         fi

         if [[ ${_rc} -ne 0 ]]; then
            echo "[$(date)] FAIL install ${tok} (rc=${_rc})" | tee -a "${SUMMARY}"
            PE_FAIL+=("${tok}")
            unset _skip_match _rel _cand _cached _cachetb _lt _lt_args _download _rc _common _afar_wip
            continue
         fi
         [[ "${_afar_wip:-0}" -eq 1 ]] || echo "[$(date)] OK install ${tok}" | tee -a "${SUMMARY}"
      fi
      unset _skip_match _rel _cand _cached _cachetb _lt _lt_args _download _rc _common _mf _afar_wip

      # ── OpenMPI WIP message (rocm is installed above either way) ───────
      if [[ "${want_openmpi}" -eq 1 ]]; then
         {
            echo "------------------------------------------------------------------"
            echo " [WIP] OpenMPI PrgEnv is a WORK IN PROGRESS for ${tok} (pe=${pe})."
            echo "       The underlying ROCm ${tok} is installed, but the"
            echo "       PrgEnv-amd-openmpi / PrgEnv-amd-openmpi-ucx modules are not"
            echo "       generated yet. The proper implementation will copy/rename"
            echo "       existing modules under /shared/apps/modules/rhel9/modulefiles,"
            echo "       e.g. for -openmpi (libfabric):"
            echo "         openmpi/5.0.10-libfabric2.2.0rc1-xpmem-2.7.4-rocm-7.2.0"
            echo "       and for -openmpi-ucx (ucc/ucx):"
            echo "         openmpi/5.0.10-ucc1.6.0-ucx1.19.1-xpmem-2.7.4-rocm-7.2.0"
            echo "       and integrate the script that builds those installations."
            echo "------------------------------------------------------------------"
         } | tee -a "${SUMMARY}"
      fi

      PE_OK+=("${tok}")
   done

   {
      echo ""
      echo "=================================================================="
      echo " program-environments sweep finished at $(date)"
      echo " OK   (${#PE_OK[@]}):   ${PE_OK[*]:-}"
      echo " FAIL (${#PE_FAIL[@]}): ${PE_FAIL[*]:-}"
      echo " Cray modules: module use ${TOP_MODULE_PATH}/base"
      echo "               module avail PrgEnv-amd-new PrgEnv-cray-new"
      echo "=================================================================="
   } | tee -a "${SUMMARY}"

   [[ ${#PE_FAIL[@]} -eq 0 ]]
   exit $?
fi

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
            --replace-existing "${REPLACE_EXISTING}" \
            --skip-patches     "${SKIP_PATCHES}"
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
            --replace-existing "${REPLACE_EXISTING}" \
            --skip-patches     "${SKIP_PATCHES}"
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
