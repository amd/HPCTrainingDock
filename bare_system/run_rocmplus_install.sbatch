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
# ROCM_VERSION accepts both regular numeric tokens (e.g. '7.2.1') and
# release-candidate flavor tokens (e.g. 'therock-7.13.0',
# 'afar-22.2.0-7.2.0', 'afar-23.2.1-7.13.0'); whatever token is passed
# is what `module load rocm/<token>` consumes. Post-load we derive
# three distinct values from ${ROCM_PATH}:
#   * ROCM_NUMERIC -- the SDK version from .info/version, used as
#     --rocm-version downstream so version-comparison logic in
#     rocm_setup.sh and friends keeps working.
#   * ROCM_RC_PREFIX -- empty for regular releases, 'therock' / 'afar' /
#     ... for RC trees.
#   * ROCM_RC_COMPILER -- set ONLY for afar trees: the compiler/AFAR
#     release number embedded in the install-dir basename (e.g. '22.2.0'
#     for rocm-afar-22.2.0, '23.2.1' for rocm-afar-23.2.1). Used by
#     main_setup.sh to construct rocmplus-afar-<compiler>-<rocm_numeric>/
#     install dirs so two AFAR drops with the same SDK numeric but
#     different compiler releases don't collide on the rocmplus side.
#     Empty for non-afar trees (in which case the rocmplus suffix
#     reduces to the legacy <prefix>-<numeric> shape).
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
# Path knobs: the sweep submitter
# (bare_system/run_rocmplus_install_sweep.sh) is responsible for
# resolving --site presets and legacy /nfsapps defaults, so by the
# time we get here, TOP_INSTALL_PATH / TOP_MODULE_PATH / ROCM_INSTALLPATH
# are either the operator's CLI values, the --site preset values, or
# the legacy /nfsapps defaults -- in all three cases NON-EMPTY. The
# ":-" defaults here only matter for the rare case of a direct
# `sbatch run_rocmplus_install.sbatch` invocation that bypasses the
# sweep submitter; for that path we still fall back to /nfsapps to
# preserve byte-identical historical behavior (operators who hit this
# path will keep getting /nfsapps writes until they migrate).
TOP_INSTALL_PATH="${TOP_INSTALL_PATH:-/nfsapps/opt}"
TOP_MODULE_PATH="${TOP_MODULE_PATH:-/nfsapps/modules}"
ROCM_INSTALLPATH="${ROCM_INSTALLPATH:-/nfsapps/opt}"
# SITE and ROCM_PATH are optional pass-throughs; when set, they are
# forwarded to main_setup.sh as --site / --rocm-path. When unset,
# main_setup.sh will auto-derive ROCM_PATH from `module show rocm/<v>`
# (and TOP_INSTALL_PATH from its dirname) -- but only if the operator
# also did not pass --top-install-path, which the sweep always does.
SITE="${SITE:-}"
ROCM_PATH="${ROCM_PATH:-}"
PYTHON_VERSION="${PYTHON_VERSION:-}"
QUICK_INSTALLS="${QUICK_INSTALLS:-0}"
REPLACE_EXISTING="${REPLACE_EXISTING:-0}"
KEEP_FAILED_INSTALLS="${KEEP_FAILED_INSTALLS:-0}"
PACKAGES_LIST="${PACKAGES_LIST:-}"
# PnetCDF version pass-through (2026-05-20). Empty = leaf default;
# non-empty -> forwarded to main_setup.sh --pnetcdf-version, which
# threads it to extras/scripts/netcdf_setup.sh. Same shape as the
# optional SITE / ROCM_PATH pass-throughs below.
PNETCDF_VERSION="${PNETCDF_VERSION:-}"
# ROCMPLUS_FLAVOR / PRGENV_MODULE: programming-environment selector (set by
# run_rocmplus_install_sweep.sh --program-environments). Defaults preserve
# byte-identical legacy behavior for plain --rocm-versions submissions.
#   ROCMPLUS_FLAVOR  amd (default) -> rocmplus-<v> (AMD compiler + mpich-wrappers)
#                    cray          -> rocmplus-cray-<v> (CCE + cray-mpich)
#   PRGENV_MODULE    optional module to load BEFORE main_setup so the build
#                    links the right MPI (e.g. PrgEnv-cray-new/8.7.0). For the
#                    cray flavor this is what brings cray-mpich onto the env
#                    ($MPICH_DIR), which main_setup.sh keys off to build
#                    mpi4py/rocshmem/hdf5/... against cray-mpich.
ROCMPLUS_FLAVOR="${ROCMPLUS_FLAVOR:-amd}"
PRGENV_MODULE="${PRGENV_MODULE:-}"

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

# ── Outbound proxy for compute-node fetches ───────────────────────────
# Some leaf installers still download from the internet on the compute node
# (e.g. fetching source tarballs with wget/git). AAC7 compute nodes have NO
# direct internet; they egress through a SITE proxy that the node's own
# /etc/profile sets (e.g. http://172.23.0.12:3128). A non-login sbatch like
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
   echo "[rocmplus] proxy for compute-node fetches: https='${HTTPS_PROXY_URL}' http='${HTTP_PROXY_URL}'"
else
   # No usable proxy and (typically) no direct internet -> internet fetches will fail.
   export https_proxy="" HTTPS_PROXY="" http_proxy="" HTTP_PROXY=""
   echo "[rocmplus] NOTE: no usable (non-loopback) proxy found on $(hostname);"
   echo "[rocmplus]       internet fetches (e.g. source tarball downloads)"
   echo "[rocmplus]       will fail unless this node has direct internet."
   echo "[rocmplus]       Override with: run_rocmplus_install_sweep.sh --https-proxy URL"
fi

echo "=================================================================="
echo " rocmplus install job ${SLURM_JOB_ID} starting at $(date) on $(hostname)"
echo " ROCM_VERSION:     ${ROCM_VERSION}"
echo " SITE preset:      ${SITE:-<unset>}"
echo " TOP_INSTALL_PATH: ${TOP_INSTALL_PATH}"
echo " TOP_MODULE_PATH:  ${TOP_MODULE_PATH}"
echo " ROCM_INSTALLPATH: ${ROCM_INSTALLPATH}"
echo " ROCM_PATH:        ${ROCM_PATH:-<auto-derive on compute node>}"
echo " AMDGPU_GFXMODEL:  ${AMDGPU_GFXMODEL}"
echo " PYTHON_VERSION:   3.${PYTHON_VERSION}"
echo " QUICK_INSTALLS:   ${QUICK_INSTALLS}"
echo " REPLACE_EXISTING: ${REPLACE_EXISTING}"
echo " KEEP_FAILED:      ${KEEP_FAILED_INSTALLS}"
echo " PACKAGES_LIST:    ${PACKAGES_LIST:-<all>}"
echo " PNETCDF_VERSION:  ${PNETCDF_VERSION:-<leaf default>}"
echo " ROCMPLUS_FLAVOR:  ${ROCMPLUS_FLAVOR}  (amd -> rocmplus-<v>; cray -> rocmplus-cray-<v>)"
echo " PRGENV_MODULE:    ${PRGENV_MODULE:-<none>}"
echo " HTTPS proxy:      ${HTTPS_PROXY_URL:-<none>}"
echo " HTTP proxy:       ${HTTP_PROXY_URL:-<none>}"
echo "=================================================================="

# ── AAC7 (HPE/Cray) no-passwordless-sudo support ──────────────────────
# AAC6 compute nodes have passwordless sudo and a root-owned /nfsapps tree;
# AAC7 (HPE/Cray) has NO passwordless sudo but the /shareddata install tree is
# user-writable. A session "no-sudo" shim (~/.nosudo-shim/sudo) strips sudo's
# own options and runs the wrapped command AS THE USER (no-oping chown/chgrp).
# If passwordless sudo is unavailable and the shim exists, prepend it to PATH
# so every `sudo ...` in this job (the self-heal below AND the downstream
# install/patch scripts, e.g. rocm_patches.sh) runs without ever hitting an
# interactive password prompt. `sudo -n true` returns non-zero WITHOUT
# prompting, so this never hangs.
if ! sudo -n true 2>/dev/null; then
   if [[ -x "${HOME}/.nosudo-shim/sudo" ]]; then
      echo "[rocmplus] no passwordless sudo on $(hostname); using ${HOME}/.nosudo-shim (run-as-user)"
      export PATH="${HOME}/.nosudo-shim:${PATH}"
   else
      echo "[rocmplus] WARNING: no passwordless sudo and no ${HOME}/.nosudo-shim;" >&2
      echo "[rocmplus]          sudo calls may prompt/fail. Ensure the install tree" >&2
      echo "[rocmplus]          (${TOP_INSTALL_PATH}, ${TOP_MODULE_PATH}) is user-writable." >&2
   fi
fi

# ── 1. Ensure /nfsapps is writable on this compute node ──────────────
# The login node exports /nfsapps rw to sh5 nodes via
# /etc/exports.d/nfsapps_sh5_rw.exports, but the warewulf-managed fstab
# still says ro by default, so this defensive remount is required.
# Only run this block when at least one of the target dirs actually
# lives under /nfsapps; --site opt and --site shared-apps targets do
# not need it and the abort-on-non-writable would be a false-positive
# failure for those targets.
if [[ "${TOP_INSTALL_PATH}" == "${NFSAPPS_PARENT}"* || \
      "${TOP_MODULE_PATH}"  == "${NFSAPPS_PARENT}"* || \
      "${ROCM_INSTALLPATH}" == "${NFSAPPS_PARENT}"* ]]; then
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
else
   echo "Skipping /nfsapps remount: install/module/SDK targets are not under ${NFSAPPS_PARENT}."
fi

# ── 2. Self-heal install/module roots if missing ─────────────────────
# Prefer a plain user mkdir (works when the parent tree is user-writable,
# e.g. /shareddata on AAC7). Only fall back to sudo when that fails (e.g. the
# root-owned /nfsapps tree on AAC6, where sudo is passwordless or the nosudo
# shim is on PATH).
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}"; do
   [[ -d "${d}" ]] && continue
   echo "Creating missing ${d}"
   if ! mkdir -p "${d}" 2>/dev/null; then
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

# ── 3. Initialize the module system + load rocm/${ROCM_VERSION} ──────
# Slurm runs the batch script under a non-login shell, so /etc/profile.d
# is not sourced automatically and the `module` function is usually not
# defined yet.
# Initialize a module system that works on BOTH Lmod (AAC6 Ubuntu) AND
# classic Tcl environment-modules. AAC7 (HPE/Cray) uses Cray PE "Tmod"
# 3.2.x via /opt/cray/pe/modules -- LMOD_DIR is unset and there is no
# /etc/profile.d/lmod.sh there, so the prior Lmod-only block hard-failed
# on Cray. We prefer an already-defined `module` function (Cray exports it
# via `export -f`, and sbatch --export=ALL can carry it across), else
# source whichever init exists. MODULESHOME is propagated by --export=ALL
# on Cray, so it is tried early. The Cray init PRESERVES an existing
# MODULEPATH (only prepends system paths), so the inherited site tree
# survives; we re-prepend ${TOP_MODULE_PATH}/base below regardless.
if ! type module >/dev/null 2>&1; then
   _module_inited=0
   for _minit in \
         /etc/profile.d/lmod.sh \
         "${MODULESHOME:+${MODULESHOME}/init/bash}" \
         /opt/cray/pe/modules/*/init/bash \
         /etc/profile.d/modules.sh \
         /usr/share/lmod/lmod/init/profile \
         /usr/share/Modules/init/bash; do
      [[ -n "${_minit}" && -r "${_minit}" ]] || continue
      # shellcheck disable=SC1090
      if source "${_minit}" && type module >/dev/null 2>&1; then
         echo "Sourced module init: ${_minit}"
         _module_inited=1
         break
      fi
   done
   if [[ "${_module_inited}" != 1 ]]; then
      echo "ERROR: could not initialize a module system (tried Lmod + Cray/Tcl env-modules)." >&2
      echo "       Checked: /etc/profile.d/{lmod,modules}.sh, \${MODULESHOME}/init/bash," >&2
      echo "       /opt/cray/pe/modules/*/init/bash, /usr/share/{lmod/lmod/init/profile,Modules/init/bash}" >&2
      exit 1
   fi
   unset _minit _module_inited
else
   echo "module function already defined (inherited); using it"
fi
# Lmod-via-profile fallback may leave MODULEPATH empty; the Cray/Tcl inits
# populate it themselves. Only backstop the documented system path when it
# is still empty (preserves prior Lmod behavior, no-op on Cray).
export MODULEPATH="${MODULEPATH:-/shared/apps/modules/ubuntu/lmodfiles/base}"

# Reproducibility: shed any modules the submitter carried in via sbatch
# --export=ALL. HOW we shed depends on the module system:
#
#   * Cray PE (Tmod 3.2.x): NEVER `module purge`. The craype /
#     craype-network-* / craype-<cpu> / PrgEnv-* modules are load-order
#     sensitive and do NOT survive a purge -- afterwards even the node's
#     default PrgEnv-cray can no longer re-resolve `craype` ("Conflicting
#     PrgEnv-* is loading" / "requirement craype is not loaded"), which
#     then fails EVERY PrgEnv load below (observed on the MI300A RHEL9
#     nodes: a purged shell could not reload craype at all). Instead we
#     leave the stock Cray PE intact and unload only the APPLICATION
#     modules -- everything whose modulefile is NOT under /opt/cray (the
#     inherited stock rocm + any openmpi/pytorch/magma/openblas/... a
#     submitter had loaded). PrgEnv-* is kept on purpose: it is the swap
#     source for PRGENV_MODULE below (these PrgEnv-{amd,cray}-new modules
#     `conflict PrgEnv-cray`, so they must be SWAPPED in, not loaded onto
#     a still-loaded default PrgEnv).
#
#   * Lmod / classic Tcl (non-Cray): a full purge is safe and simplest.
#     --force tolerates modulefiles whose .lua was removed from disk
#     after the submitter loaded them (plain purge errors on missing
#     files and leaves the rest loaded).
#
# This worker-side shed is still INCOMPLETE for Lmod because the
# __LMOD_REF_COUNT_* shell vars are not propagated via --export=ALL, so
# it cannot fully reverse PATH/LD_LIBRARY_PATH/MPICC additions made
# submitter-side -- but the sweep wrapper now does the matching shed
# before sbatch, so this is belt-and-suspenders.
#
# History: slurm 8385 (2026-05-05) failed because the submitter had
# openmpi/5.0.10 + pytorch/2.9.1 + magma + openblas loaded; UCX picked
# up the stale $MPICC and tried to link against a libucc.so.1 that the
# build was about to delete via --replace 1. Both paths clear that.
_is_cray_pe=0
if [[ -d /opt/cray/pe || -n "${CRAYPE_VERSION:-}" || -n "${PE_ENV:-}" ]]; then
   _is_cray_pe=1
fi
if [[ "${_is_cray_pe}" == 1 ]]; then
   echo "Cray PE detected: NOT purging; shedding application modules only (keeping stock Cray PE for swap)."
   # LOADEDMODULES and _LMFILES_ are parallel ':'-lists in Tmod. Unload
   # in reverse (dependents before prereqs); keep anything under /opt/cray
   # and keep PrgEnv-* (the swap source for PRGENV_MODULE below).
   IFS=':' read -ra _lm_arr <<< "${LOADEDMODULES:-}"
   IFS=':' read -ra _lf_arr <<< "${_LMFILES_:-}"
   for (( _i=${#_lm_arr[@]}-1; _i>=0; _i-- )); do
      _lm="${_lm_arr[_i]:-}"
      [[ -z "${_lm}" ]] && continue
      _lf="${_lf_arr[_i]:-}"
      case "${_lm}" in PrgEnv-*) continue ;; esac
      case "${_lf}" in */opt/cray/*) continue ;; esac
      module unload "${_lm}" 2>/dev/null || true
   done
   unset _lm_arr _lf_arr _lm _lf _i
else
   module --force purge 2>/dev/null || module purge 2>/dev/null || true
fi

# When the operator passed --site / --top-module-path to point at a
# segregated tree (e.g. /nfsapps/ubuntu-22.04/modules), prepend that
# tree's base/ to MODULEPATH so `module load rocm/<v>` resolves there
# first. Falls through to the system tree (added by /etc/profile.d/
# lmod.sh above) when the site tree has no matching modulefile.
#
# This replaces the older "do NOT add /nfsapps/modules/base" rule,
# which was correct for the legacy distro-mixed /nfsapps tree but
# overbroad now that --site allows distro-segregated subtrees. The
# 22.04-vs-24.04 GLIBC safety check (below, after `module load`) still
# fires; it's now scoped to "ROCM_PATH lives under /nfsapps but NOT
# under ${TOP_INSTALL_PATH}" rather than blanket-rejecting /nfsapps/*.
if [[ -n "${TOP_MODULE_PATH:-}" && -d "${TOP_MODULE_PATH}/base" ]]; then
   case ":${MODULEPATH:-}:" in
      *":${TOP_MODULE_PATH}/base:"*) ;;   # already on MODULEPATH
      *) export MODULEPATH="${TOP_MODULE_PATH}/base${MODULEPATH:+:${MODULEPATH}}" ;;
   esac
   echo "Augmented MODULEPATH with site tree: ${TOP_MODULE_PATH}/base"
fi
echo "Effective MODULEPATH: ${MODULEPATH}"

# Load the rocm module. Lmod resolves it from the first MODULEPATH
# entry that contains the matching modulefile.
module load "rocm/${ROCM_VERSION}"
echo "Loaded module rocm/${ROCM_VERSION}; ROCM_PATH=${ROCM_PATH:-<unset>}"

# ── Cray PrgEnv: load the full programming-environment module so the MPI
#    that main_setup.sh's leaves link against is live on the build env.
#    Both flavors rely on this:
#      * amd  -> PrgEnv-amd-new/<pe>-<tag> loads PrgEnv-amd/<pe> (cray-mpich ->
#                $MPICH_DIR) AND the from-source mpich-wrappers module (amdflang
#                mpi.mod). main_setup.sh keys off $MPICH_DIR to then thread
#                --mpi-module mpich-wrappers into the MPI-linked leaves.
#      * cray -> PrgEnv-cray-new/<pe>-<tag> loads cray-mpich (CCE).
#    Without it, $MPICH_DIR is unset and every MPI-linked leaf
#    (mpi4py/rocshmem/hdf5/netcdf/fftw/petsc/hypre/elpa/magma/tau) falls back to
#    the leaf default "openmpi", which does not exist on Cray -> SKIP/fail.
#    The PrgEnv module also swaps the just-loaded rocm/<token> to its matching
#    rocm-new/<numeric> (same SDK install, same ROCM_PATH). A load failure is a
#    hard error: a silent fall-through would mis-build against the wrong MPI.
if [[ -n "${PRGENV_MODULE}" ]]; then
   echo "Loading programming-environment module: ${PRGENV_MODULE}"
   # NB: do NOT pipe `module load`/`module swap` through sed/tee -- the pipe
   # runs it in a subshell and the env changes ($MPICH_DIR, MODULEPATH,
   # PATH, ...) would be lost. Run directly, then echo a confirmation.
   #
   # On Cray PE the PrgEnv-{amd,cray}-new modules declare `conflict
   # PrgEnv-cray` (etc.), so a plain `module load` ABORTS while the node's
   # default PrgEnv is still loaded -- and it IS, because we deliberately
   # did not purge it above. Swap from whatever PrgEnv-* is active instead;
   # that is exactly how these modulefiles are meant to be entered (see
   # their header: `module swap PrgEnv-cray <this>`). Fall back to a plain
   # load when no PrgEnv is active (non-Cray, or an already-clean Cray env).
   _prgenv_rc=0
   _active_prgenv=""
   if [[ "${_is_cray_pe}" == 1 ]]; then
      for _lm in ${LOADEDMODULES//:/ }; do
         case "${_lm}" in PrgEnv-*) _active_prgenv="${_lm}"; break ;; esac
      done
   fi
   if [[ "${_is_cray_pe}" == 1 && -n "${_active_prgenv}" ]]; then
      echo "  Cray PE: swapping ${_active_prgenv} -> ${PRGENV_MODULE}"
      module swap "${_active_prgenv}" "${PRGENV_MODULE}" || _prgenv_rc=$?
   else
      module load "${PRGENV_MODULE}" || _prgenv_rc=$?
   fi
   if [[ "${_prgenv_rc}" != 0 ]]; then
      echo "ERROR: failed to load PRGENV_MODULE='${PRGENV_MODULE}'" >&2
      exit 1
   fi
   unset _prgenv_rc _active_prgenv _lm
   echo "Loaded ${PRGENV_MODULE}; MPICH_DIR=${MPICH_DIR:-<unset>}"
   if [[ -z "${MPICH_DIR:-}" || ! -d "${MPICH_DIR}/bin" ]]; then
      echo "WARNING: \$MPICH_DIR is unset/missing after loading ${PRGENV_MODULE};" >&2
      echo "         MPI-linked packages will fall back to the leaf default (openmpi)" >&2
      echo "         rather than the PrgEnv MPI (mpich-wrappers / cray-mpich)." >&2
      echo "         Ensure ${PRGENV_MODULE} is loadable and brings cray-mpich on this node." >&2
   fi
fi
module list 2>&1 | sed 's/^/  /'

# Sanity check: the resolved ROCM_PATH must exist. Historically we
# also blanket-rejected ROCM_PATH=/nfsapps/* because the legacy
# /nfsapps tree was 24.04-built and produced GLIBC_2.38 / GLIBCXX_3.4.32
# errors when used on the 22.04 compute nodes (those errors typically
# masquerade as "HIP not found" inside dependent package builds).
#
# That blanket block is now scoped: if the operator explicitly pointed
# this sweep at a segregated /nfsapps subtree via --site /
# --top-install-path (and ROCM_PATH falls under it), the SDK was built
# for that subtree's distro by the matching run_rocm_build_sweep call,
# so trust the operator. Only reject /nfsapps paths that are OUTSIDE
# the chosen TOP_INSTALL_PATH (i.e. the legacy distro-mixed tree).
if [[ -z "${ROCM_PATH:-}" || ! -d "${ROCM_PATH}" ]]; then
   echo "ERROR: ROCM_PATH is unset or missing after module load: '${ROCM_PATH:-}'" >&2
   exit 1
fi
case "${ROCM_PATH}" in
   /nfsapps/*)
      # Allow it only when the operator's TOP_INSTALL_PATH is also
      # under /nfsapps AND ROCM_PATH is a prefix-match for it. Anything
      # else is the legacy /nfsapps tree leaking through.
      _allow_nfsapps=0
      if [[ -n "${TOP_INSTALL_PATH:-}" ]]; then
         case "${TOP_INSTALL_PATH}" in
            /nfsapps/*)
               case "${ROCM_PATH}" in
                  ${TOP_INSTALL_PATH}/*) _allow_nfsapps=1 ;;
               esac
               ;;
         esac
      fi
      if [[ "${_allow_nfsapps}" != 1 ]]; then
         echo "ERROR: rocm/${ROCM_VERSION} resolved to ${ROCM_PATH}, which is the" >&2
         echo "       legacy distro-mixed /nfsapps tree. The current nodes are Ubuntu" >&2
         echo "       22.04; that tree was 24.04-built and produces GLIBC errors at" >&2
         echo "       runtime. Either:" >&2
         echo "       (a) load a system rocm module under" >&2
         echo "           /shared/apps/modules/ubuntu/lmodfiles/base, or" >&2
         echo "       (b) pass --site /nfsapps/<distro>/... so this sweep targets a" >&2
         echo "           distro-segregated subtree (TOP_INSTALL_PATH='${TOP_INSTALL_PATH:-<unset>}')." >&2
         exit 1
      fi
      echo "Accepting /nfsapps ROCM_PATH: under operator-chosen TOP_INSTALL_PATH=${TOP_INSTALL_PATH}"
      unset _allow_nfsapps
      ;;
esac
echo "ROCm SDK in use: ${ROCM_PATH}"

# ── 3b. Derive ROCM_NUMERIC + ROCM_RC_PREFIX from ROCM_PATH ──────────
# ROCM_NUMERIC: SDK version from .info/version (e.g. 7.2.1 for a
#   regular release, 7.13.0 for rocm-therock-23.2.0). main_setup.sh
#   gets this as --rocm-version so its loaded-vs-requested numeric
#   cross-check below still works.
# ROCM_RC_PREFIX: '' for a regular release, family name for an RC
#   tree (e.g. 'therock' for rocm-therock-23.2.0). Drives the
#   rocmplus-${PREFIX}-${NUMERIC}/ install-dir naming so RC trees
#   never collide with a future official release of the same numeric.
if [[ ! -f "${ROCM_PATH}/.info/version" ]]; then
   echo "ERROR: ${ROCM_PATH}/.info/version missing; cannot derive ROCM_NUMERIC" >&2
   exit 1
fi
ROCM_NUMERIC=$(cut -f1 -d- "${ROCM_PATH}/.info/version")
ROCM_RC_PREFIX=""
ROCM_RC_COMPILER=""
_bn="${ROCM_PATH##*/}"; _sx="${_bn#rocm-}"
# Strip the trailing -<X.Y.Z> or -<X.Y> from the install-dir suffix to get
# the family prefix + (for afar trees only) the compiler/AFAR-release
# number. The naive ${_sx%%-*} (first-dash cut) would collapse
# multi-segment family prefixes -- 'therock-afar' would become 'therock',
# which then collides in the rocmplus-${PREFIX}-${NUMERIC} install-dir
# namespace with a future legacy therock-* install of the same numeric.
# Examples (post unified-AFAR naming, 2026-05-26):
#   rocm-afar-22.2.0    -> _sx=afar-22.2.0    -> prefix='afar', compiler='22.2.0'
#                          (AFAR proper from flang/)
#   rocm-afar-23.2.1    -> _sx=afar-23.2.1    -> prefix='afar', compiler='23.2.1'
#                          (TheRock-AFAR from flang/, was rocm-therock-afar-7.13.0)
#   rocm-therock-7.13.0 -> _sx=therock-7.13.0 -> prefix='therock', compiler=''
#                          (TheRock from repo.amd.com)
#   rocm-7.2.1          -> _sx=7.2.1          -> prefix='', compiler=''
#                          (regular release)
# The compiler segment is captured only when prefix='afar' (single-segment
# afar family); for other prefixes the captured tail IS the SDK numeric
# (e.g. 'therock-7.13.0' -> tail='7.13.0' is the rocm version, NOT a
# distinct compiler number) so we leave ROCM_RC_COMPILER empty -- the
# rocmplus suffix in those cases reduces to the legacy
# '${ROCM_RC_PREFIX}-${ROCM_NUMERIC}' shape.
if [[ "${_sx}" =~ ^(.+)-([0-9]+(\.[0-9]+){1,2})$ ]]; then
   ROCM_RC_PREFIX="${BASH_REMATCH[1]}"
   if [[ "${ROCM_RC_PREFIX}" == "afar" ]]; then
      ROCM_RC_COMPILER="${BASH_REMATCH[2]}"
   fi
elif [[ ! "${_sx}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
   # Tree name doesn't end in a numeric segment (unusual). Fall back to
   # the legacy first-dash-cut so this still degrades to something sensible.
   ROCM_RC_PREFIX="${_sx%%-*}"
fi
unset _bn _sx

# Compose the rocmplus install/module suffix:
#   * afar trees:    afar-<compiler>-<rocm_numeric>   (e.g. afar-22.2.0-7.2.0)
#   * other RC:      <prefix>-<rocm_numeric>          (legacy shape)
#   * regular:       <rocm_numeric>                   (legacy shape)
if [[ "${ROCM_RC_PREFIX}" == "afar" && -n "${ROCM_RC_COMPILER}" ]]; then
   ROCMPLUS_SUFFIX_PREVIEW="afar-${ROCM_RC_COMPILER}-${ROCM_NUMERIC}"
else
   ROCMPLUS_SUFFIX_PREVIEW="${ROCM_RC_PREFIX:+${ROCM_RC_PREFIX}-}${ROCM_NUMERIC}"
fi
echo "  ROCM_VERSION (token):    ${ROCM_VERSION}"
echo "  ROCM_NUMERIC:            ${ROCM_NUMERIC}"
echo "  ROCM_RC_PREFIX:          '${ROCM_RC_PREFIX}'"
echo "  ROCM_RC_COMPILER:        '${ROCM_RC_COMPILER}'"
echo "  rocmplus install suffix: rocmplus-${ROCMPLUS_SUFFIX_PREVIEW}"

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

# --site / --rocm-path / --pnetcdf-version are optional pass-throughs
# (forwarded only when the operator set them at sweep submission time).
# Omitted args let main_setup.sh's auto-derivation rungs (or, for
# --pnetcdf-version, the netcdf leaf's internal default) fire on the
# compute node.
SITE_ARGS=()
[[ -n "${SITE}"            ]] && SITE_ARGS+=( --site            "${SITE}"            )
[[ -n "${ROCM_PATH}"       ]] && SITE_ARGS+=( --rocm-path       "${ROCM_PATH}"       )
[[ -n "${PNETCDF_VERSION}" ]] && SITE_ARGS+=( --pnetcdf-version "${PNETCDF_VERSION}" )

bare_system/main_setup.sh \
   --rocm-version         "${ROCM_NUMERIC}" \
   --rocm-rc-prefix       "${ROCM_RC_PREFIX}" \
   --rocm-rc-compiler     "${ROCM_RC_COMPILER}" \
   --rocmplus-flavor      "${ROCMPLUS_FLAVOR}" \
   --rocm-install-path    "${ROCM_INSTALLPATH}" \
   --top-install-path     "${TOP_INSTALL_PATH}" \
   --top-module-path      "${TOP_MODULE_PATH}" \
   "${SITE_ARGS[@]}" \
   --amdgpu-gfxmodel      "${AMDGPU_GFXMODEL}" \
   --python-version       "${PYTHON_VERSION}" \
   --quick-installs       "${QUICK_INSTALLS}" \
   --replace-existing     "${REPLACE_EXISTING}" \
   --keep-failed-installs "${KEEP_FAILED_INSTALLS}" \
   --skip-patches         "${SKIP_PATCHES:-0}" \
   "${PACKAGES_ARGS[@]}" \
   </dev/null
rc=$?

echo ""
echo "=================================================================="
echo " [$(date)] END main_setup.sh for rocm-${ROCM_VERSION} (rc=${rc})"
echo "=================================================================="

exit ${rc}
