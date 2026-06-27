#!/bin/bash
#
# run_rocmplus_install_sweep.sh - LOGIN-side submitter for the rocm-plus
# install sweep. For each ROCm version in the list, submits ONE sbatch job
# that runs bare_system/main_setup.sh (which lays down rocmplus-<v> on
# /nfsapps). Jobs are chained with --dependency=afterany:<prev_jobid> so
# they run sequentially and unattended — and so a single failed version
# does not stall the rest of the chain.
#
# Each job is given its own --time (default 24h, capped at the partition
# MaxTime of 48h) and writes to slurm-<jobid>-rocmplus-<v>.{out,err}.

set -uo pipefail

# Reproducibility: discard any modules the submitter happened to have
# loaded interactively before running this sweep. Doing the purge HERE
# (in the submitter's process tree) instead of in the per-job sbatch is
# strictly better for two reasons:
#   (1) The submitter shell has Lmods full state (LOADEDMODULES,
#       _LMFILES_, and any per-shell __LMOD_REF_COUNT_* tracking) so the
#       purge can fully reverse PATH/LD_LIBRARY_PATH/MPICC/MPI_PATH/etc.
#       The sbatch worker's --export=ALL inherits env vars but NOT
#       Lmod's internal shell-only ref counters, so a worker-side purge
#       is incomplete (slurm 8385/8386/8387, 2026-05-05: openmpi rebuild
#       failed because UCX picked up a stale $MPICC pointing at a
#       --replace 1-deleted /shared/.../openmpi-.../bin/mpicc).
#   (2) Once the submitter env is clean, every sbatch we launch from
#       here propagates a clean env BY CONSTRUCTION -- no env-scrub
#       gymnastics in the per-job script.
# Initialize a module system so we can purge inherited modules. This must
# work on BOTH Lmod (AAC6 Ubuntu, /etc/profile.d/lmod.sh) AND classic Tcl
# environment-modules -- in particular AAC7 (HPE/Cray) uses Cray PE "Tmod"
# 3.2.x via /opt/cray/pe/modules (LMOD_DIR unset, MODULESHOME points there).
# This script may be invoked as a fresh `./run_rocmplus_install_sweep.sh`
# process, so the `module` function from the parent shell may not be
# inherited; source whichever init exists. (Cray exports the `module`
# function via `export -f`, so it is sometimes already defined -- in which
# case we skip sourcing.)
if ! type module >/dev/null 2>&1; then
   for _minit in \
         /etc/profile.d/lmod.sh \
         "${MODULESHOME:+${MODULESHOME}/init/bash}" \
         /opt/cray/pe/modules/*/init/bash \
         /etc/profile.d/modules.sh \
         /usr/share/lmod/lmod/init/profile \
         /usr/share/Modules/init/bash; do
      [[ -n "${_minit}" && -r "${_minit}" ]] || continue
      # shellcheck disable=SC1090
      source "${_minit}" && type module >/dev/null 2>&1 && { echo "sweep: sourced module init ${_minit}"; break; }
   done
   unset _minit
fi
if type module >/dev/null 2>&1; then
   # --force is Lmod-only (tolerates modulefiles removed from disk after
   # load); Tcl/Cray modulecmd rejects it, so fall back to plain purge.
   module --force purge 2>/dev/null || module purge 2>/dev/null || true
   echo "sweep: module purge done; LOADEDMODULES='${LOADEDMODULES:-<empty>}'"
else
   echo "sweep: WARNING no module system found (tried Lmod + Cray/Tcl env-modules); skipping module purge -- inherited modules may leak into sbatch jobs" >&2
fi

: ${PARTITION:="sh5_cpx_admin_long"}
: ${TIME_PER_JOB:="24:00:00"}        # walltime per version
: ${MAX_TIME_MIN:="2880"}            # MaxTime of sh5_cpx_admin_long = 48h
# Order matters: kokkos_setup.sh's multi-arch->single-arch fallback uses
# the FIRST gfx model in the list when cmake configure fails. This cluster's
# build node is MI300A (gfx942), so gfx942 must come first to ensure the
# fallback produces a binary that runs on the build hardware. The list as
# a whole is also passed verbatim to GPU_TARGETS / --offload-arch in other
# packages (openmpi, ucx, ucc, scorep), where order is irrelevant.
# Cross-compiling note: if you change the build host or target a different
# cluster, set AMDGPU_GFXMODEL explicitly via --amdgpu-gfxmodel; do NOT
# autodetect from rocminfo (the build node may not have the target hardware).
: ${AMDGPU_GFXMODEL:="gfx942;gfx90a"}
# Path knobs. Resolution priority (also documented in main_setup.sh:
# search for "Path resolution"):
#   1. CLI primitive (--top-install-path, --top-module-path,
#      --rocm-install-path, --rocm-path) -- always wins.
#   2. --site preset (opt | nfsapps | shared-apps) -- applied below
#      after CLI parsing, only fills values the operator did not set
#      explicitly.
#   3. Legacy /nfsapps default -- fires when neither (1) nor (2) was
#      given, so existing sweep commands that pass nothing keep working
#      exactly as before. Migrate via `--site nfsapps` (explicit) or
#      `--site shared-apps` (live tree) or `--site opt` (vanilla /opt).
#   4. (only when the operator picks --site / explicit paths that
#      resolve to /opt) main_setup.sh's MODULEPATH-derive + module-show
#      ROCM_PATH derive kicks in on the compute node before any build.
# Initial values left empty; the legacy default is applied conditionally
# at the bottom of this block.
: ${TOP_INSTALL_PATH:=""}
: ${TOP_MODULE_PATH:=""}
: ${ROCM_INSTALLPATH:=""}
: ${ROCM_PATH:=""}
: ${SITE:=""}
# PYTHON_VERSION: empty -> auto-detect on the compute node from /etc/os-release
# (Ubuntu 22.04 -> 10, 24.04 -> 12). Passed through verbatim if user supplies it.
: ${PYTHON_VERSION:=""}
: ${QUICK_INSTALLS:="0"}
: ${REPLACE_EXISTING:="0"}
: ${KEEP_FAILED_INSTALLS:="0"}  # 1 = preserve partial install dirs / modulefiles for post-mortem
# SKIP_PATCHES: operator opt-out for the rocm-patches step inside
# main_setup.sh (the install-time patches call, lines ~1651 / ~1670
# there). Default 0 runs the step; for most ROCm versions rocm_patches.sh
# self-no-ops via NOOP_RC=43 and the cost is nil. Set to 1 to bypass
# entirely -- useful when the patches overlay would mismatch the
# runtime (e.g. 7.2.0 / 7.2.1 patches binaries compiled for a newer
# GLIBC than the target nodes). Mirrors the same-named flag on
# bare_system/run_rocm_build_sweep.sh which covers the build-time
# (Phase 3.6) call; this flag covers the install-time call.
: ${SKIP_PATCHES:="0"}
: ${PACKAGES_LIST:=""}     # whitelist passed through to main_setup.sh --packages
# PnetCDF version (2026-05-20). Empty -> netcdf_setup.sh's internal
# default. Non-empty -> threaded to main_setup.sh --pnetcdf-version,
# which forwards to the netcdf leaf. The leaf versions the install
# path (pnetcdf-v${PNETCDF_VERSION}/) and emits a first-class
# pnetcdf/${PNETCDF_VERSION} modulefile, so multiple PnetCDF versions
# coexist per rocmplus-<v> tree.
: ${PNETCDF_VERSION:=""}
# MAX_PARALLEL: cap on simultaneously-RUNNING jobs across the chain.
#   1 (default) = strict serial: each job depends on the previous one.
#   N > 1       = sliding window: first N jobs all start concurrently (subject
#                 to slurm node availability); each subsequent job's dependency
#                 is an OR (Slurm `?` separator) over the previous N jobids in
#                 submission order, so the next-in-line job becomes eligible
#                 the moment ANY one of its window-of-N parents terminates --
#                 not the specific jobid N positions earlier.
# Each per-version sbatch is --nodes=1 --exclusive (see run_rocmplus_install.sbatch),
# and the partition itself caps RUNNING jobs at the node count, so OR-of-window
# is safe: even if the dependency formally allows N+1 jobs to be eligible, slurm
# queues the surplus on `Resources` rather than over-allocating. The OR form
# eliminates the "head-of-line waiting for the wrong specific ancestor" stall
# that the prior single-jobid AND chain exhibited when wall-clocks were uneven.
# Pick MAX_PARALLEL to leave headroom on the partition for other users (e.g. 3
# nodes available -> use 2 to keep one free; bump to 3 once a 4th node comes
# online).
: ${MAX_PARALLEL:=1}

ROCM_VERSIONS_RAW=""
# PROGRAM_ENVIRONMENTS_RAW: AAC7 (Cray) high-level interface, mirroring
# run_rocm_build_sweep.sh. Space-/comma-separated Cray PrgEnv tokens of the
# form <flavor>/<pe>-<rocm-modulefile-token>, e.g.
#   PrgEnv-amd-new/8.7.0-7.2.3            -> rocmplus-7.2.3       (amd tree)
#   PrgEnv-cray-new/8.7.0-7.2.3          -> rocmplus-cray-7.2.3  (cray tree)
#   PrgEnv-amd-new/8.7.0-afar-23.2.1-7.13.0 -> rocmplus-afar-...  (amd tree)
# Unlike the build sweep, flavors are NOT collapsed to a canonical token:
# each (flavor, rocm) pair is a DISTINCT job writing a DISTINCT rocmplus
# tree, so PrgEnv-amd-new and PrgEnv-cray-new for the same ROCm numeric
# never clobber each other. Mutually exclusive with --rocm-versions.
PROGRAM_ENVIRONMENTS_RAW=""
# START_AFTER and START_AFTER_ANY: optional pre-wired dependencies for the
# first wave (the first MAX_PARALLEL jobs in submission order):
#   START_AFTER       single jobid, treated as afterany:JID
#   START_AFTER_ANY   space- or comma-separated list of jobids, OR'd
#                     together as afterany:JID1?afterany:JID2?...
# When both are set, START_AFTER's jobid is OR-joined with START_AFTER_ANY's
# list, so the first-wave dep becomes
#   afterany:${START_AFTER}?afterany:JID1?afterany:JID2?...
# Use START_AFTER_ANY when an existing sweep / unrelated long job COULD free a
# node before the canonical START_AFTER target finishes -- e.g., chaining a
# 6.3.x sweep behind both an in-flight afar-22.2.0 sweep AND an in-flight
# rocm-7.1.1 full sweep. The 6.3.x first wave then starts on whichever of
# those two parents finishes first.
START_AFTER=""
START_AFTER_ANY=""
DRY_RUN=0

# Outbound proxy for compute-node fetches. Leave EMPTY by default: the sbatch
# worker auto-derives the compute node's own /etc/profile site proxy (AAC7
# nodes egress through it; e.g. http://172.23.0.12:3128). Use --https-proxy/
# --http-proxy/--proxy ONLY to override that auto-derivation.
HTTPS_PROXY_URL="${HTTPS_PROXY_URL:-}"
HTTP_PROXY_URL="${HTTP_PROXY_URL:-}"

usage() {
   cat <<EOF
Usage: $0 [opts]
   --program-environments "p1 p2 ..."  AAC7 (Cray) high-level interface mirroring
                                 run_rocm_build_sweep.sh. Space-/comma-separated Cray
                                 PrgEnv tokens of the form <flavor>/<pe>-<rocm-token>:
                                   PrgEnv-amd-new/8.7.0-7.2.3       -> rocmplus-7.2.3       (amd tree)
                                   PrgEnv-cray-new/8.7.0-7.2.3      -> rocmplus-cray-7.2.3  (cray tree)
                                   PrgEnv-amd-new/8.7.0-afar-23.2.1-7.13.0
                                 <flavor> is one of PrgEnv-amd-new, PrgEnv-cray-new,
                                 PrgEnv-amd-openmpi, PrgEnv-amd-openmpi-ucx; only
                                 PrgEnv-cray-new maps to the separate rocmplus-cray-<v>
                                 tree (all amd flavors share rocmplus-<v>). <rocm-token>
                                 is the rocm modulefile token (same validation as
                                 --rocm-versions). For the cray flavor the job loads
                                 <flavor>/<pe> on the compute node so the MPI-linked
                                 packages build against cray-mpich. Pair with --packages
                                 to install a curated subset into the cray tree.
                                 Mutually exclusive with --rocm-versions.
   --rocm-versions "v1 v2 ..."   space- or comma-separated list of ROCm modulefile tokens (REQUIRED unless --program-environments is used).
                                 Accepts BOTH regular numeric (e.g. 7.2.1) AND release-candidate
                                 flavor (e.g. therock-23.2.0, afar-22.2.0, afar-7.0.5) tokens
                                 in the same list. Each token must resolve to an existing
                                 modulefile under /shared/apps/modules/ubuntu/lmodfiles/base/rocm
                                 (the pre-flight check below enforces this). For RC tokens, the
                                 sbatch derives ROCM_RC_PREFIX (e.g. 'therock') and the install
                                 lands at \${TOP_INSTALL_PATH}/rocmplus-\${PREFIX}-\${NUMERIC}/
                                 (e.g. /nfsapps/opt/rocmplus-therock-7.13.0/) so it cannot
                                 collide with a future official rocm release of the same numeric.
   --partition NAME              Slurm partition (default ${PARTITION})
   --time HH:MM:SS               walltime per version (default ${TIME_PER_JOB})
   --amdgpu-gfxmodel GFX         default ${AMDGPU_GFXMODEL}
   --top-install-path PATH       parent dir for rocm-<v>/ + rocmplus-<v>/ installs. Default: --site preset (if given), else /nfsapps/opt (legacy default; will switch to /opt-derived once all commands have migrated to --site)
   --top-module-path PATH        parent dir for base/, rocm-<v>/, rocmplus-<v>/ modulefile trees. Default: --site preset (if given), else /nfsapps/modules (legacy default)
   --rocm-install-path PATH      parent dir for rocm SDK install (where amdgpu-install lays down rocm-<v>/). Default: --site preset (if given), else /nfsapps/opt (legacy default)
   --rocm-path PATH              full path to the rocm SDK (e.g. /shared/apps/ubuntu/opt/rocm-7.2.3); threaded through to main_setup.sh as --rocm-path. Default: auto-derived on the compute node from \`module show rocm/<v>\`.
   --site PRESET|/ABS/PATH       shorthand for the four path flags above.
                                   Named presets:
                                     opt          -> /opt + /opt/modules                       (standard system install; default for fresh /opt dev machines once legacy defaults are removed)
                                     nfsapps      -> /nfsapps/opt + /nfsapps/modules           (NFS test tree; Ubuntu 24.04 builds)
                                     shared-apps  -> /shared/apps/ubuntu/opt + /shared/apps/modules/ubuntu/lmodfiles  (LIVE cluster tree; Ubuntu 22.04 -- writes are visible to all users immediately)
                                     shareddata   -> /shareddata/opt + /shareddata/modules          (AAC7 Cray shared tree; mirrors run_rocm_build_sweep.sh)
                                   Absolute path form: any value starting with '/' is treated as a parent prefix, expanded to PREFIX/opt + PREFIX/modules.
                                     e.g. --site /nfsapps/ubuntu-22.04 -> /nfsapps/ubuntu-22.04/opt + /nfsapps/ubuntu-22.04/modules
                                     (useful for distro-segregated test trees that don't fit the named presets)
                                 Any explicit --top-* / --rocm-* flag overrides the corresponding preset value (so e.g. \`--site nfsapps --rocm-install-path /opt\` is valid).
   --https-proxy URL             override the compute-node site proxy for HTTPS
                                 (e.g. http://172.23.0.12:3128). Default: auto-derive
                                 the compute node's own /etc/profile proxy in the sbatch.
   --http-proxy URL              override the compute-node site proxy for HTTP
      --proxy URL                   shorthand: set BOTH --https-proxy and --http-proxy
   --python-version N            python3 minor release (default: distro-native -- 10 on Ubuntu 22.04, 12 on 24.04)
   --quick-installs 0|1          skip long-pole packages -- pytorch / tensorflow / jax / ftorch / julia
                                 (wall >= 20 min) PLUS the explicit always-skip set likwid + mdb
                                 (operator opt-out: not wall-driven; see QUICK_INSTALLS_PKGS in
                                 bare_system/main_setup.sh). Pass --packages "... likwid mdb ..."
                                 to override (--packages always wins over --quick-installs).
                                 (default ${QUICK_INSTALLS})
   --replace-existing 0|1        replace existing rocmplus-<v> packages per-pkg (default ${REPLACE_EXISTING})
   --keep-failed-installs 0|1    on per-package failure, keep partial install dirs / modulefiles for post-mortem (default ${KEEP_FAILED_INSTALLS}; default 0 wipes them so retries start clean)
   --skip-patches 0|1            operator opt-out for the rocm-patches step inside main_setup.sh
                                 (the install-time call -- skips rocm/scripts/rocm_patches.sh).
                                 Default 0 runs the step; for most ROCm versions rocm_patches.sh
                                 self-no-ops (NOOP_RC=43) so the cost is nil and the default is
                                 fine. Set to 1 to bypass entirely when the patches overlay would
                                 mismatch the runtime -- e.g. 7.2.0 / 7.2.1 patches binaries built
                                 for a newer GLIBC than the target nodes. When skipped, the
                                 per-package summary records 'rocm-patches(--skip-patches)' in the
                                 DESELECTED bucket. Symmetric with --skip-patches on
                                 bare_system/run_rocm_build_sweep.sh (which covers Phase 3.6 of the
                                 SDK build). (default ${SKIP_PATCHES})
   --packages "name1 name2 ..."  whitelist (passed verbatim to main_setup.sh --packages); empty = all.
                                 Versioned form name=VERSION is supported for the subset of packages whose
                                 leaf script accepts a single --<name>-version flag (pytorch, jax, cupy,
                                 magma, kokkos, ...; see main_setup.sh --help for the full list). Optional
                                 leading 'v' is stripped (cupy=v13.0.1 == cupy=13.0.1). Repeating the same
                                 name with different versions (e.g. "pytorch=2.7.1 pytorch=2.8.0") drives
                                 one build per version inside the same per-ROCm-version sbatch job; each
                                 lands in its own pkg-vVERSION/ install dir + VERSION.lua module so the
                                 versions coexist.
                                 Inline per-(name,version) overrides via name=VERSION:OK1=OV1[:OK2=OV2...]:
                                 append ":"-separated key=value pairs after the version to override
                                 per-package leaf-script flags (currently supported for pytorch only).
                                 PyTorch override keys: aotriton, torchvision (alias tv), torchaudio (ta),
                                 triton, flashattention (flash), pillow, sageattention (sage), deepspeed (ds).
                                 Example: "pytorch=2.8.0:aotriton=0.11.2b:flash=2.7.4" forces AOTriton 0.11.2b
                                 and flash-attention 2.7.4 for the 2.8.0 build, distinct from pytorch=2.9.1
                                 (which would resolve from PYTORCH_STACK_MANIFEST). See
                                 extras/scripts/pytorch_setup.sh PYTORCH_STACK_MANIFEST for the auto-derived
                                 (PT,ROCm)->stack-pin defaults; off-table combos warn and fall back leniently.
   --pnetcdf-version V           PnetCDF version threaded through main_setup.sh -> netcdf_setup.sh
                                 (default: leaf default 1.14.1). The leaf versions the install dir
                                 (pnetcdf-v\${V}/) and emits a first-class pnetcdf/\${V} modulefile,
                                 so multiple PnetCDF versions coexist per rocmplus-<v> tree.
   --max-parallel N              cap on simultaneously-RUNNING jobs (default ${MAX_PARALLEL}).
                                 1 = strict serial chain (each job depends on the previous; today's
                                 default behavior). N>1 = sliding window: first N jobs run in parallel
                                 (subject to slurm node availability), each subsequent job's dependency
                                 is an OR over the previous N submitted jobids (Slurm '?' separator),
                                 so it becomes eligible the moment ANY of its N parents finishes -- not
                                 the specific jobid N positions earlier. Each sbatch is --nodes=1
                                 --exclusive, so N maps 1:1 to nodes occupied; pick N to leave headroom
                                 for other users (e.g. 3 nodes available -> --max-parallel 2 reserves 1
                                 for others; --max-parallel 3 once a 4th node is online).
   --start-after JOBID           chain the first wave (first MAX_PARALLEL versions) after an existing job
                                 (single afterany:JOBID dep). May be combined with --start-after-any.
   --start-after-any "j1 j2 ..." chain the first wave after ANY of the listed jobids (OR-of-afterany).
                                 Useful when multiple in-flight sweeps could each free a node and you
                                 want this sweep to start on whichever one finishes first. Space- or
                                 comma-separated. May be combined with --start-after (the lists are
                                 OR-merged into a single afterany:J1?afterany:J2?... dep string).
   --dry-run                     print sbatch commands without submitting
   --help

Each per-version job's dependency is computed from MAX_PARALLEL (default 1 =
strict --dependency=afterany:<prev_jobid> chain; N>1 = OR over the previous N
submitted jobids). The chain proceeds even if a single version fails (afterany,
not afterok). Per-job logs land in slurm-<jobid>-rocmplus-<v>.{out,err} in the
submit directory.
EOF
   exit 1
}

while [[ $# -gt 0 ]]; do
   case "${1}" in
      --rocm-versions)     shift; ROCM_VERSIONS_RAW=${1} ;;
      --program-environments) shift; PROGRAM_ENVIRONMENTS_RAW=${1} ;;
      --partition)         shift; PARTITION=${1} ;;
      --time)              shift; TIME_PER_JOB=${1} ;;
      --amdgpu-gfxmodel)   shift; AMDGPU_GFXMODEL=${1} ;;
      --top-install-path)  shift; TOP_INSTALL_PATH=${1} ;;
      --top-module-path)   shift; TOP_MODULE_PATH=${1} ;;
      --rocm-install-path) shift; ROCM_INSTALLPATH=${1} ;;
      --rocm-path)         shift; ROCM_PATH=${1} ;;
      --site)              shift; SITE=${1} ;;
      --https-proxy)       shift; HTTPS_PROXY_URL=${1} ;;
      --http-proxy)        shift; HTTP_PROXY_URL=${1} ;;
      --proxy)             shift; HTTPS_PROXY_URL=${1}; HTTP_PROXY_URL=${1} ;;
      --python-version)    shift; PYTHON_VERSION=${1} ;;
      --quick-installs)    shift; QUICK_INSTALLS=${1} ;;
      --replace-existing)  shift; REPLACE_EXISTING=${1} ;;
      --keep-failed-installs) shift; KEEP_FAILED_INSTALLS=${1} ;;
      --skip-patches)      shift; SKIP_PATCHES=${1} ;;
      --packages)          shift; PACKAGES_LIST=${1} ;;
      --pnetcdf-version)   shift; PNETCDF_VERSION=${1} ;;
      --max-parallel)      shift; MAX_PARALLEL=${1} ;;
      --start-after)       shift; START_AFTER=${1} ;;
      --start-after-any)   shift; START_AFTER_ANY=${1} ;;
      --dry-run)           DRY_RUN=1 ;;
      --help|-h)           usage ;;
      *)                   echo "Unknown arg: ${1}" >&2; usage ;;
   esac
   shift
done

if [[ -n "${PROGRAM_ENVIRONMENTS_RAW}" && -n "${ROCM_VERSIONS_RAW}" ]]; then
   echo "ERROR: --program-environments and --rocm-versions are mutually exclusive" >&2
   usage
fi
if [[ -z "${PROGRAM_ENVIRONMENTS_RAW}" && -z "${ROCM_VERSIONS_RAW}" ]]; then
   echo "ERROR: one of --rocm-versions or --program-environments is required" >&2
   usage
fi

# ── --site preset application ─────────────────────────────────────────
# Same resolution shape as main_setup.sh (see "Path resolution" block
# there): CLI primitives win, --site preset fills the gaps, and a
# final legacy /nfsapps default fires when neither was specified so
# pre-existing sweep commands keep working byte-identically.
SITE_SUMMARY="<unset>"
if [[ -n "${SITE}" ]]; then
   case "${SITE}" in
      opt)
         _SITE_TOP_INSTALL="/opt"
         _SITE_TOP_MODULE="/opt/modules"
         ;;
      nfsapps)
         _SITE_TOP_INSTALL="/nfsapps/opt"
         _SITE_TOP_MODULE="/nfsapps/modules"
         ;;
      shared-apps)
         _SITE_TOP_INSTALL="/shared/apps/ubuntu/opt"
         _SITE_TOP_MODULE="/shared/apps/modules/ubuntu/lmodfiles"
         ;;
      shareddata)
         # AAC7 (HPE/Cray) shared tree -- mirrors run_rocm_build_sweep.sh
         # so the rocmplus install lands on the same tree the SDK build did.
         _SITE_TOP_INSTALL="/shareddata/opt"
         _SITE_TOP_MODULE="/shareddata/modules"
         ;;
      /*)
         # Absolute-path PREFIX form (e.g. --site /nfsapps/ubuntu-22.04):
         # symmetric layout PREFIX/opt + PREFIX/modules. See the matching
         # block in main_setup.sh for the design rationale.
         _SITE_PREFIX="${SITE%/}"
         _SITE_TOP_INSTALL="${_SITE_PREFIX}/opt"
         _SITE_TOP_MODULE="${_SITE_PREFIX}/modules"
         unset _SITE_PREFIX
         ;;
      *)
         echo "ERROR: --site must be a named preset (opt | nfsapps | shared-apps | shareddata) or an absolute path starting with '/' (got '${SITE}')" >&2
         exit 1
         ;;
   esac
   [[ -z "${TOP_INSTALL_PATH}" ]] && TOP_INSTALL_PATH="${_SITE_TOP_INSTALL}"
   [[ -z "${TOP_MODULE_PATH}"  ]] && TOP_MODULE_PATH="${_SITE_TOP_MODULE}"
   [[ -z "${ROCM_INSTALLPATH}" ]] && ROCM_INSTALLPATH="${_SITE_TOP_INSTALL}"
   SITE_SUMMARY="${SITE}"
   unset _SITE_TOP_INSTALL _SITE_TOP_MODULE
fi

# Legacy /nfsapps fallback — fires ONLY when both CLI primitives AND
# --site were absent. Preserves byte-identical behavior for current
# operator commands like `./run_rocmplus_install_sweep.sh --rocm-versions ...`.
: ${TOP_INSTALL_PATH:="/nfsapps/opt"}
: ${TOP_MODULE_PATH:="/nfsapps/modules"}
: ${ROCM_INSTALLPATH:="/nfsapps/opt"}

# Walltime sanity check vs partition MaxTime.
IFS=':' read -r THH TMM TSS <<< "${TIME_PER_JOB}"
TIME_MIN=$(( 10#${THH} * 60 + 10#${TMM} + (10#${TSS} > 0 ? 1 : 0) ))
if (( TIME_MIN > MAX_TIME_MIN )); then
   echo "ERROR: --time ${TIME_PER_JOB} exceeds partition MaxTime ${MAX_TIME_MIN}min." >&2
   exit 1
fi

# MAX_PARALLEL must be a positive integer; the sliding-window dep math
# below assumes >=1 (1 = current strict-chain behavior).
if ! [[ "${MAX_PARALLEL}" =~ ^[1-9][0-9]*$ ]]; then
   echo "ERROR: --max-parallel must be a positive integer (got '${MAX_PARALLEL}')" >&2
   exit 1
fi

# ── Build the per-job spec arrays: VERSIONS_ARR (rocm modulefile token),
#    FLAVORS_ARR (amd|cray), PES_ARR (stock PrgEnv version, or empty) ──
# Two input modes feed the same three parallel arrays so the submission
# loop below is mode-agnostic:
#   * legacy --rocm-versions : every job is flavor=amd, pe="" (byte-identical
#                              to the prior single-array behavior).
#   * --program-environments : each <flavor>/<pe>-<token> yields one job;
#                              PrgEnv-cray-new -> flavor=cray, everything
#                              else -> flavor=amd.
VERSIONS_ARR=()
FLAVORS_ARR=()
PES_ARR=()
if [[ -n "${PROGRAM_ENVIRONMENTS_RAW}" ]]; then
   PROGRAM_ENVIRONMENTS_NORM="${PROGRAM_ENVIRONMENTS_RAW//,/ }"
   read -r -a _PE_TOKENS <<< "${PROGRAM_ENVIRONMENTS_NORM}"
   (( ${#_PE_TOKENS[@]} == 0 )) && { echo "ERROR: no PrgEnv tokens parsed from '${PROGRAM_ENVIRONMENTS_RAW}'" >&2; exit 1; }
   for _pe_tok in "${_PE_TOKENS[@]}"; do
      # Split <flavor>/<pe>-<rocm-token>.
      if [[ "${_pe_tok}" != */* ]]; then
         echo "ERROR: PrgEnv token '${_pe_tok}' is not of the form <flavor>/<pe>-<rocm-token>" >&2
         exit 1
      fi
      _flavor="${_pe_tok%%/*}"
      _rest="${_pe_tok#*/}"
      if [[ "${_rest}" != *-* ]]; then
         echo "ERROR: PrgEnv token '${_pe_tok}' has no <pe>-<rocm-token> after the flavor" >&2
         exit 1
      fi
      _pe="${_rest%%-*}"        # stock PrgEnv version, e.g. 8.7.0
      _rocm_token="${_rest#*-}" # rocm modulefile token, e.g. 7.2.3 or afar-23.2.1-7.13.0
      case "${_flavor}" in
         PrgEnv-cray-new)                                  _rpflavor="cray" ;;
         PrgEnv-amd-new|PrgEnv-amd-openmpi|PrgEnv-amd-openmpi-ucx) _rpflavor="amd" ;;
         *) echo "ERROR: unknown PrgEnv flavor '${_flavor}' in token '${_pe_tok}'" >&2
            echo "       expected one of PrgEnv-amd-new, PrgEnv-cray-new, PrgEnv-amd-openmpi, PrgEnv-amd-openmpi-ucx" >&2
            exit 1 ;;
      esac
      VERSIONS_ARR+=("${_rocm_token}")
      FLAVORS_ARR+=("${_rpflavor}")
      PES_ARR+=("${_pe}")
   done
   unset _PE_TOKENS _pe_tok _flavor _rest _pe _rocm_token _rpflavor
else
   ROCM_VERSIONS_NORM="${ROCM_VERSIONS_RAW//,/ }"
   read -r -a VERSIONS_ARR <<< "${ROCM_VERSIONS_NORM}"
   for _ in "${VERSIONS_ARR[@]}"; do FLAVORS_ARR+=("amd"); PES_ARR+=(""); done
   unset _
fi
N=${#VERSIONS_ARR[@]}
(( N == 0 )) && { echo "ERROR: no ROCm versions parsed" >&2; exit 1; }

# Pre-flight: every version must have a rocm modulefile in EITHER the
# live system tree OR the operator-chosen ${TOP_MODULE_PATH}/base/rocm
# tree (typically a --site-resolved /nfsapps/<distro>/modules path).
# The compute-node sbatch prepends ${TOP_MODULE_PATH}/base to MODULEPATH
# before `module load rocm/<v>`, so a modulefile in either tree is
# resolvable. We check the union here so the operator gets a fast,
# login-side rejection for tokens that don't exist anywhere yet (instead
# of a slow per-job failure inside the sbatch).
SYS_ROCM_MODDIR="/shared/apps/modules/ubuntu/lmodfiles/base/rocm"
SITE_ROCM_MODDIR="${TOP_MODULE_PATH}/base/rocm"
MISSING=()
for v in "${VERSIONS_ARR[@]}"; do
   # Lmod accepts modulefiles either with or without a .lua suffix.
   _found=0
   for _dir in "${SITE_ROCM_MODDIR}" "${SYS_ROCM_MODDIR}"; do
      if [[ -f "${_dir}/${v}.lua" || -f "${_dir}/${v}" ]]; then
         _found=1
         break
      fi
   done
   if [[ "${_found}" != 1 ]]; then
      MISSING+=("${v}")
   fi
done
unset _found _dir
if (( ${#MISSING[@]} > 0 )); then
   echo "ERROR: the following rocm versions have no module in either" >&2
   echo "       ${SITE_ROCM_MODDIR} (site tree)" >&2
   echo "       ${SYS_ROCM_MODDIR} (live system tree):" >&2
   for v in "${MISSING[@]}"; do echo "    rocm/${v}" >&2; done
   # For afar / therock-afar SHORT-form tokens (e.g. afar-22.1.0,
   # therock-afar-23.1.0) the unified-naming refactor on 2026-05-26
   # renamed the modulefile to afar-<REL>-<ROCM>.lua (e.g.
   # afar-22.1.0-7.1.0). This sweep deliberately requires the full
   # modulefile name on input -- one canonical identifier from build
   # through install through module load through inventory column.
   # When the missing token looks like a short form, glob both module
   # trees for candidates and offer them as a copy-pasteable "Did you
   # mean:" suggestion so the operator can fix the command in place.
   _gave_hint=0
   for v in "${MISSING[@]}"; do
      case "${v}" in
         afar-*|therock-afar-*) _rel="afar-${v#*afar-}" ;;
         *) continue ;;
      esac
      shopt -s nullglob
      _cands=( "${SITE_ROCM_MODDIR}/${_rel}-"*.lua "${SYS_ROCM_MODDIR}/${_rel}-"*.lua )
      shopt -u nullglob
      # Dedup by basename: when SITE_ROCM_MODDIR == SYS_ROCM_MODDIR (e.g.
      # --site shared-apps, where the operator's chosen tree IS the live
      # system tree) the same file appears in both glob expansions.
      _seen_bns=""
      _unique_bns=()
      for _c in "${_cands[@]}"; do
         _bn="${_c##*/}"; _bn="${_bn%.lua}"
         case " ${_seen_bns} " in
            *" ${_bn} "*) continue ;;
         esac
         _seen_bns="${_seen_bns} ${_bn}"
         _unique_bns+=( "${_bn}" )
      done
      if (( ${#_unique_bns[@]} > 0 )); then
         if (( _gave_hint == 0 )); then
            echo "" >&2
            echo "Hint: afar / therock-afar modulefiles use the unified naming" >&2
            echo "      afar-<REL>-<ROCM>.lua (since 2026-05-26). Pass the full" >&2
            echo "      modulefile basename (no .lua, no 'therock-' prefix) on" >&2
            echo "      --rocm-versions; this sweep does NOT auto-resolve short forms." >&2
            _gave_hint=1
         fi
         echo "" >&2
         echo "      For rocm/${v}, did you mean one of:" >&2
         for _bn in "${_unique_bns[@]}"; do
            echo "          rocm/${_bn}" >&2
         done
      fi
   done
   unset _gave_hint _rel _cands _c _bn _seen_bns _unique_bns
   echo "" >&2
   echo "Install the rocm SDK + module on one of those trees (run_rocm_build_sweep.sh)" >&2
   echo "or update SYS_ROCM_MODDIR / pass --site / --top-module-path to point at the right tree." >&2
   exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SBATCH_FILE="${REPO_ROOT}/bare_system/run_rocmplus_install.sbatch"
[[ -f "${SBATCH_FILE}" ]] || { echo "ERROR: ${SBATCH_FILE} not found" >&2; exit 1; }

# ---------------- Partition validation / fallback --------------------
# The built-in default ($PARTITION) is an AAC6 partition (sh5_cpx_admin_long)
# that does not exist on AAC7. If sinfo is available and the requested
# partition is not one of this cluster's partitions, fall back to the
# cluster's DEFAULT partition (the one sinfo marks with a trailing '*')
# so e.g. `--site shareddata` runs on AAC7 don't have to spell out
# --partition. An explicit, valid --partition is always honoured; if it is
# invalid we still fall back (and say so) rather than failing at sbatch.
if command -v sinfo >/dev/null 2>&1; then
   _parts="$(sinfo -h -o '%P' 2>/dev/null)"
   if [[ -n "${_parts}" ]]; then
      # Names from sinfo may carry a trailing '*' on the default partition.
      _part_clean="$(printf '%s\n' "${_parts}" | sed 's/\*$//')"
      if ! printf '%s\n' "${_part_clean}" | grep -qxF "${PARTITION}"; then
         _default_part="$(printf '%s\n' "${_parts}" | sed -n 's/\*$//p' | head -n1)"
         if [[ -n "${_default_part}" ]]; then
            echo "NOTE: partition '${PARTITION}' not found on this cluster;" >&2
            echo "      falling back to the default partition '${_default_part}'." >&2
            echo "      (Available: $(printf '%s ' ${_part_clean}))" >&2
            PARTITION="${_default_part}"
         else
            echo "WARNING: partition '${PARTITION}' not found and no default" >&2
            echo "         partition is marked on this cluster. Available:" >&2
            echo "         $(printf '%s ' ${_part_clean})" >&2
            echo "         sbatch will likely reject this; pass --partition." >&2
         fi
      fi
      unset _part_clean _default_part
   fi
   unset _parts
fi

cat <<EOF
==================================================================
 ROCm-plus install sweep submitter
==================================================================
 Partition:         ${PARTITION}
 Time per version:  ${TIME_PER_JOB}
 Versions (${N}):     ${VERSIONS_ARR[*]}   (mixed numeric + RC-flavor tokens OK; RC trees install to rocmplus-<prefix>-<numeric>/)
 Flavors:           ${FLAVORS_ARR[*]}   (amd -> rocmplus-<v>; cray -> rocmplus-cray-<v>)$([[ -n "${PROGRAM_ENVIRONMENTS_RAW}" ]] && echo "
 ProgEnv tokens:    ${PROGRAM_ENVIRONMENTS_RAW}")
 GFX:               ${AMDGPU_GFXMODEL}
 Site preset:       ${SITE_SUMMARY}
 TOP_INSTALL_PATH:  ${TOP_INSTALL_PATH}
 TOP_MODULE_PATH:   ${TOP_MODULE_PATH}
 ROCM_INSTALLPATH:  ${ROCM_INSTALLPATH}
 ROCM_PATH:         ${ROCM_PATH:-<auto: module show rocm/<v> on compute node>}
 HTTPS proxy:       ${HTTPS_PROXY_URL:-<auto: compute-node site proxy>}
 HTTP proxy:        ${HTTP_PROXY_URL:-<auto: compute-node site proxy>}
 PYTHON_VERSION:    ${PYTHON_VERSION:+3.}${PYTHON_VERSION:-<auto: distro-native on compute node>}
 QUICK_INSTALLS:    ${QUICK_INSTALLS}
 REPLACE_EXISTING:  ${REPLACE_EXISTING}
 KEEP_FAILED:       ${KEEP_FAILED_INSTALLS}
 SKIP_PATCHES:      ${SKIP_PATCHES}
 PACKAGES:          ${PACKAGES_LIST:-<all>}
 PNETCDF_VERSION:   ${PNETCDF_VERSION:-<leaf default>}
 MAX_PARALLEL:      ${MAX_PARALLEL}   $( (( MAX_PARALLEL == 1 )) && echo "(strict serial chain)" || echo "(sliding window: up to ${MAX_PARALLEL} jobs RUNNING simultaneously)")
 sbatch file:       ${SBATCH_FILE}
 Dry run:           ${DRY_RUN}
 Start after:       ${START_AFTER:-<none>}
 Start after any:   ${START_AFTER_ANY:-<none>}
==================================================================
EOF

cd "${REPO_ROOT}"

# Normalize START_AFTER_ANY into a bash array of bare jobids (commas + whitespace
# both accepted as separators, matching --rocm-versions parsing convention).
read -r -a START_AFTER_ANY_ARR <<< "${START_AFTER_ANY//,/ }"

# join_or_deps: emit "afterany:J1?afterany:J2?..." from the bare jobids passed
# as positional args. Empty input -> empty string. The Slurm '?' separator is
# OR-semantics: the dependent job becomes eligible as soon as ANY one of the
# listed parents satisfies its afterany clause.
join_or_deps() {
   local -a parts=()
   local jid
   for jid in "$@"; do
      [[ -z "${jid}" ]] && continue
      parts+=( "afterany:${jid}" )
   done
   local IFS='?'
   echo "${parts[*]}"
}

# Sliding-window dependency wiring (controlled by MAX_PARALLEL):
#   - First MAX_PARALLEL jobs (the "first wave") all share the same dep:
#     OR-merge of START_AFTER (single jobid) and START_AFTER_ANY (list of
#     jobids) -- empty if both are unset, in which case the first wave has
#     no dep and starts as soon as slurm has nodes.
#   - Subsequent jobs depend on an OR over the previous MAX_PARALLEL jobids
#     in submission order (the "sliding window"). Since each sbatch is
#     --nodes=1 --exclusive and the partition itself caps the number of
#     RUNNING jobs by node count, OR-of-window cannot over-allocate -- it
#     just lets the next-in-line job start the moment ANY of its window-of-N
#     ancestors releases a node, which avoids the head-of-line stall the
#     prior single-jobid AND chain exhibited when the specific "N positions
#     earlier" jobid happened to outlive its window peers.
#
# JOBIDS_ONLY tracks submission-order jobids so we can slice the window
# without parsing them out of SUBMITTED's "v=jobid" pairs.
JOBIDS_ONLY=()
SUBMITTED=()
i=0
for v in "${VERSIONS_ARR[@]}"; do
   # Per-job programming-environment flavor (amd|cray) + stock PrgEnv version.
   # FLAVORS_ARR / PES_ARR are index-aligned with VERSIONS_ARR (built above).
   _flavor="${FLAVORS_ARR[i]}"
   _pe="${PES_ARR[i]}"
   # PRGENV_MODULE is only set for the cray flavor: the job loads it on the
   # compute node so cray-mpich ($MPICH_DIR) is live and main_setup.sh builds
   # the MPI-linked packages against it. amd flavor keeps legacy behavior
   # (no PrgEnv load; mpich-wrappers come from the SDK tree).
   _prgenv_module=""
   [[ "${_flavor}" == "cray" && -n "${_pe}" ]] && _prgenv_module="PrgEnv-cray-new/${_pe}"
   # Job/log label: byte-identical "<v>" for amd (legacy), "cray-<v>" for cray
   # so the two flavors of the same ROCm numeric don't collide in slurm
   # job names or slurm-<jobid>-rocmplus-<label>.{out,err} log filenames.
   _jlabel="${v}"
   [[ "${_flavor}" == "cray" ]] && _jlabel="cray-${v}"

   EXPORT_VARS="ALL,ROCM_VERSION=${v}"
   EXPORT_VARS+=",ROCMPLUS_FLAVOR=${_flavor}"
   [[ -n "${_prgenv_module}" ]] && EXPORT_VARS+=",PRGENV_MODULE=${_prgenv_module}"
   EXPORT_VARS+=",AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL}"
   EXPORT_VARS+=",TOP_INSTALL_PATH=${TOP_INSTALL_PATH}"
   EXPORT_VARS+=",TOP_MODULE_PATH=${TOP_MODULE_PATH}"
   EXPORT_VARS+=",ROCM_INSTALLPATH=${ROCM_INSTALLPATH}"
   # SITE / ROCM_PATH / PNETCDF_VERSION only added when set, so the
   # sbatch sees their absence as "not specified" (lets main_setup.sh's
   # auto-derive fire for SITE/ROCM_PATH, and netcdf_setup.sh's leaf
   # default fire for PNETCDF_VERSION).
   [[ -n "${SITE}"            ]] && EXPORT_VARS+=",SITE=${SITE}"
   [[ -n "${HTTPS_PROXY_URL}" ]] && EXPORT_VARS+=",HTTPS_PROXY_URL=${HTTPS_PROXY_URL}"
   [[ -n "${HTTP_PROXY_URL}"  ]] && EXPORT_VARS+=",HTTP_PROXY_URL=${HTTP_PROXY_URL}"
   [[ -n "${ROCM_PATH}"       ]] && EXPORT_VARS+=",ROCM_PATH=${ROCM_PATH}"
   [[ -n "${PNETCDF_VERSION}" ]] && EXPORT_VARS+=",PNETCDF_VERSION=${PNETCDF_VERSION}"
   EXPORT_VARS+=",PYTHON_VERSION=${PYTHON_VERSION}"
   EXPORT_VARS+=",QUICK_INSTALLS=${QUICK_INSTALLS}"
   EXPORT_VARS+=",REPLACE_EXISTING=${REPLACE_EXISTING}"
   EXPORT_VARS+=",KEEP_FAILED_INSTALLS=${KEEP_FAILED_INSTALLS}"
   EXPORT_VARS+=",SKIP_PATCHES=${SKIP_PATCHES}"
   # PACKAGES_LIST may contain spaces; sbatch --export uses commas as separators,
   # so leave the value un-comma'd. Spaces survive verbatim through to the sbatch.
   EXPORT_VARS+=",PACKAGES_LIST=${PACKAGES_LIST}"

   # Compute this job's dependency string (already includes "afterany:" tokens
   # and OR-separator '?' joins; empty string means no --dependency flag).
   #   i  < MAX_PARALLEL : OR-merge of START_AFTER + START_AFTER_ANY
   #   i >= MAX_PARALLEL : OR over the previous MAX_PARALLEL jobids
   if (( i < MAX_PARALLEL )); then
      DEP=$(join_or_deps "${START_AFTER}" "${START_AFTER_ANY_ARR[@]}")
   else
      WINDOW=( "${JOBIDS_ONLY[@]:i - MAX_PARALLEL:MAX_PARALLEL}" )
      DEP=$(join_or_deps "${WINDOW[@]}")
   fi

   CMD=( sbatch
         --job-name="rocmplus_${_jlabel}"
         --time="${TIME_PER_JOB}"
         --partition="${PARTITION}"
         --output="slurm-%j-rocmplus-${_jlabel}.out"
         --error="slurm-%j-rocmplus-${_jlabel}.err"
         --export="${EXPORT_VARS}" )

   if [[ -n "${DEP}" ]]; then
      CMD+=( --dependency="${DEP}" )
   fi
   CMD+=( "${SBATCH_FILE}" )

   if (( DRY_RUN == 1 )); then
      printf '[DRY] (depends on %s) ' "${DEP:-<none>}"; printf '%q ' "${CMD[@]}"; echo
      JOBID="<would-be-jobid-${_jlabel}>"
      SUBMITTED+=( "${_jlabel}=${JOBID}" )
      JOBIDS_ONLY+=( "${JOBID}" )
      i=$((i + 1))
      continue
   fi

   echo "Submitting rocmplus install for ${_jlabel} (flavor=${_flavor}${_prgenv_module:+, PrgEnv=${_prgenv_module}}; depends on ${DEP:-<none>})..."
   OUT=$("${CMD[@]}") || { echo "ERROR: sbatch failed for ${_jlabel}" >&2; exit 1; }
   echo "  ${OUT}"
   # "Submitted batch job NNN" -> NNN
   JOBID=$(awk '{print $NF}' <<< "${OUT}")
   if ! [[ "${JOBID}" =~ ^[0-9]+$ ]]; then
      echo "ERROR: could not parse jobid from sbatch output: ${OUT}" >&2
      exit 1
   fi
   SUBMITTED+=( "${_jlabel}=${JOBID}" )
   JOBIDS_ONLY+=( "${JOBID}" )
   i=$((i + 1))
done

echo ""
echo "=================================================================="
echo " Submitted chain (${#SUBMITTED[@]} jobs):"
for entry in "${SUBMITTED[@]}"; do
   # entry key is the job label: "<v>" (amd) or "cray-<v>" (cray), which is
   # exactly the rocmplus-<label> tree the job populates.
   echo "   rocmplus-${entry%=*}  ->  jobid ${entry#*=}"
done
echo ""
echo " Monitor:"
echo "   squeue -u \$USER --sort=i"
echo "   tail -f slurm-<jobid>-rocmplus-<v>.out"
echo "=================================================================="
