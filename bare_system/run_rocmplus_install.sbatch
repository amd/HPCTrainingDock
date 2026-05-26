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
echo "=================================================================="

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

# Reproducibility: belt-and-suspenders purge in case the submitter
# forgot to clean their interactive env (the proper purge is now done
# in the submitter, see run_rocmplus_install_sweep.sh top-of-script).
# This worker-side purge is INCOMPLETE because Lmod's __LMOD_REF_COUNT_*
# shell vars are not propagated via sbatch --export=ALL (only env vars
# are), so it cannot fully reverse PATH/LD_LIBRARY_PATH/MPICC/MPI_PATH
# additions made on the submitter side -- but it is a no-op when the
# submitter already purged (no modules to unload), so it costs nothing.
#
# History: slurm 8385 (2026-05-05) failed because the submitter had
# openmpi/5.0.10 + pytorch/2.9.1 + magma + openblas loaded; UCX picked
# up the stale $MPICC and tried to link against a libucc.so.1 that the
# build was about to delete via --replace 1. Fix: do `module purge` on
# the submitter side BEFORE invoking sbatch (or via the sweep script
# wrapper, which now does it automatically).
#
# --force tolerates modulefiles whose .lua was removed from disk after
# the submitter loaded them (otherwise plain `module purge` errors out
# on missing files and leaves the rest loaded).
module --force purge 2>/dev/null || module purge 2>/dev/null || true

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
   --rocm-install-path    "${ROCM_INSTALLPATH}" \
   --top-install-path     "${TOP_INSTALL_PATH}" \
   --top-module-path      "${TOP_MODULE_PATH}" \
   "${SITE_ARGS[@]}" \
   --amdgpu-gfxmodel      "${AMDGPU_GFXMODEL}" \
   --python-version       "${PYTHON_VERSION}" \
   --quick-installs       "${QUICK_INSTALLS}" \
   --replace-existing     "${REPLACE_EXISTING}" \
   --keep-failed-installs "${KEEP_FAILED_INSTALLS}" \
   "${PACKAGES_ARGS[@]}" \
   </dev/null
rc=$?

echo ""
echo "=================================================================="
echo " [$(date)] END main_setup.sh for rocm-${ROCM_VERSION} (rc=${rc})"
echo "=================================================================="

exit ${rc}
