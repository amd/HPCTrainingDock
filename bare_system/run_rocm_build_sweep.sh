#!/bin/bash
#
# run_rocm_build_sweep.sh - LOGIN-side submitter.
#
# Computes a single Slurm --time based on the requested ROCm version count
# (default 30 minutes per version + a 60 minute margin) and submits ONE sbatch
# job that loops through the versions on a single sh5 node. Per-version
# success/failure is logged inside the job; the sbatch returns 0 only if every
# version succeeded.

set -uo pipefail

: ${PARTITION:="sh5_cpx_admin_long"}
: ${MIN_PER_VERSION:="95"}        # estimated minutes per ROCm build (cold docker
                                  # cache; ~35 min with warm cache). Includes
                                  # the slow chown -R sysadmin pass (~11 min)
                                  # plus make rocm + rocm_package + module pkg
                                  # (~60 min total) plus Phase 3.6
                                  # rocm_patches.sh (~30 min: rocprof-compute
                                  # nuitka on 6.3.x-7.1.x, rocprof-sys-1.3.0
                                  # cmake on 7.2.x). Versions with no
                                  # vendored fix (NOOP_RC=43) skip the
                                  # patches wall in under a second; set
                                  # --skip-patches 1 to opt out entirely.
: ${AFAR_MIN_PER_VERSION:="15"}   # AFAR tokens (afar-X.Y.Z) bypass the docker
                                  # build entirely -- run_rocm_afar_install.sh
                                  # just does a wget + tar -xjpf of the AFAR
                                  # drop on repo.radeon.com and writes a
                                  # GPUSDK-shaped modulefile. Measured wall
                                  # for afar-22.2.0 (~4.4GB compressed,
                                  # ~15GB extracted): ~11 min on sh5,
                                  # dominated by tar -xjpf over NFS (~9 min);
                                  # download itself was ~40s for 4.4GB.
                                  # See slurm-9710-rocm-sweep.{out,err} for
                                  # the timing baseline. 15-min default
                                  # leaves ~30% headroom for a slower NFS
                                  # day; bump via --afar-min-per-version
                                  # if your cluster is consistently slower.
: ${THEROCK_MIN_PER_VERSION:="15"} # TheRock tokens (therock-X.Y[.Z]) follow
                                  # the same wget+tar shape as AFAR --
                                  # run_rocm_therock_install.sh curls a
                                  # pre-built distro-agnostic tarball from
                                  # https://repo.amd.com/rocm/tarball/ and
                                  # extracts it directly into the install
                                  # dir. Tarballs are gfx-family-specific
                                  # (gfx94X-dcgpu for MI300A/X / MI250 /
                                  # MI210). Compressed size is comparable
                                  # to AFAR (~4-5GB), and extract is over
                                  # NFS, so the AFAR walltime baseline
                                  # applies: ~11 min on sh5. 15-min default
                                  # leaves the same ~30% headroom; bump via
                                  # --therock-min-per-version if needed.
: ${MARGIN_MIN:="60"}             # global margin (minutes)
: ${MAX_TIME_MIN:="2880"}         # MaxTime of sh5_cpx_admin_long = 48h
# --replace-existing is the rocm-sweep analog of run_rocmplus_install_sweep.sh's
# flag of the same name (semantics: when set, the existing /opt/rocm-<v> tree
# and the matching modulefiles are deleted and re-extracted from a fresh
# tarball).  FORCE_EXTRACT is still honoured as a deprecated env-var alias.
if [ -z "${REPLACE_EXISTING:-}" ] && [ -n "${FORCE_EXTRACT:-}" ]; then
   echo "[rocm_sweep] NOTE: FORCE_EXTRACT is deprecated; map to REPLACE_EXISTING=${FORCE_EXTRACT}" >&2
   REPLACE_EXISTING="${FORCE_EXTRACT}"
fi
: ${REPLACE_EXISTING:="0"}
: ${SKIP_PATCHES:="0"}
: ${KEEP_TARBALLS:="3"}
: ${DISTRO:="ubuntu"}
: ${DISTRO_VERSION:="24.04"}
: ${AMDGPU_GFXMODEL:="gfx942;gfx90a"}
# TOP_INSTALL_PATH / TOP_MODULE_PATH defaults are LEGACY (Ubuntu-24.04
# /nfsapps test tree). Sentinel-track explicit-vs-default so the
# --site preset below can fill them in *without* clobbering an
# operator-supplied value. New invocations should prefer
# `--site <preset>` or `--site /ABS/PATH/PREFIX` over passing the two
# flags individually (same shape as run_rocmplus_install_sweep.sh).
: ${TOP_INSTALL_PATH:="/nfsapps/opt"}     # on-host SDK extract destination (mirrors run_rocmplus_install_sweep.sh)
: ${TOP_MODULE_PATH:="/nfsapps/modules"}  # on-host Lmod root for the deployed modulefiles
TOP_INSTALL_PATH_CLI=0
TOP_MODULE_PATH_CLI=0
SITE=""
: ${THEROCK_AMDGPU_FAMILY:="gfx94X-dcgpu"} # TheRock tarballs are gfx-family-specific;
                                          # default covers gfx942 + gfx90a (MI300A/X/MI250/210).
                                          # Override for other families (gfx908, gfx110X-all,
                                          # gfx120X-all, gfx1150/51/52, ...). See
                                          # https://repo.amd.com/rocm/tarball/ for the full list.

ROCM_VERSIONS_RAW=""

usage() {
   cat <<EOF
Usage: $0 [opts]
   --rocm-versions "v1 v2 ..."   space- or comma-separated list (default: 7.1.0 7.0.2 7.0.1 7.0.0 6.4.3 6.4.2 6.4.1 6.4.0).
                                 Accepts FOUR token shapes mixed in any order:
                                   * regular numeric        e.g. 7.2.1, 6.4.3
                                       Drives the full docker-build + make-rocm-package pipeline
                                       via run_rocm_build.sh.
                                       Install: rocm-<v>, Module: base/rocm/<v>.lua
                                   * AFAR drops             e.g. afar-22.1.0, afar-22.2.0
                                       Skip docker entirely and just wget + tar -xjpf the drop
                                       from https://repo.radeon.com/rocm/misc/flang/ via
                                       run_rocm_afar_install.sh; the AMD-internal build number
                                       that distinguishes reposts (e.g. 8873 for afar-22.2.0)
                                       is auto-discovered from the directory listing.
                                       Install: rocm-afar-<N>, Module:
                                       base/rocm/afar-<N>-<rocm>.lua (loaded as
                                       rocm/afar-<N>-<rocm>). <rocm> is derived from
                                       .info/version inside the extracted tree.
                                   * TheRock-AFAR drops     e.g. therock-afar-23.1.0, therock-afar-23.2.1
                                       Same flang/ site (https://repo.radeon.com/rocm/misc/flang/)
                                       as AFAR proper but the file shape is
                                       (therock-afar|therock)-<REL>-<FAMILY>-<NUMERIC>-<SHA>.tar.bz2
                                       (the "afar" infix is optional in the upstream filename;
                                       both shapes are matched). Driven by
                                       run_rocm_therock_afar_install.sh.
                                       UNIFIED naming with AFAR proper:
                                       Install: rocm-afar-<N>, Module:
                                       base/rocm/afar-<N>-<rocm>.lua (loaded as
                                       rocm/afar-<N>-<rocm>). <rocm> is derived from
                                       .info/version (or the tarball filename's NUMERIC
                                       segment).
                                   * TheRock releases       e.g. therock-7.13, therock-7.13.0
                                       NON-flang channel: source is the distro-agnostic
                                       pre-built tarball at https://repo.amd.com/rocm/tarball/
                                       (NOT the flang/ site). Driven by
                                       run_rocm_therock_install.sh. Both X.Y (matching the
                                       github release tag therock-X.Y) and X.Y.Z forms are
                                       accepted; the install dir uses the .info/version-derived
                                       numeric (rocm-therock-X.Y.Z), the modulefile uses the
                                       user-supplied token (base/rocm/therock-X.Y.lua or
                                       base/rocm/therock-X.Y.Z.lua) -- this channel keeps
                                       its pre-unified naming because it sources from a
                                       different upstream.
   --partition NAME              Slurm partition (default $PARTITION)
   --min-per-version N           estimated minutes per numeric ROCm build (default $MIN_PER_VERSION)
   --afar-min-per-version N      estimated minutes per AFAR token (default $AFAR_MIN_PER_VERSION)
   --therock-min-per-version N   estimated minutes per TheRock token (default $THEROCK_MIN_PER_VERSION)
   --therock-amdgpu-family FAM   gfx-family token in the TheRock tarball filename
                                 (default $THEROCK_AMDGPU_FAMILY -- covers gfx942/gfx90a)
   --margin-min N                margin minutes added to total (default $MARGIN_MIN)
   --replace-existing 0|1        overwrite existing \${TOP_INSTALL_PATH}/rocm-<v> (default $REPLACE_EXISTING)
                                 (alias: --force-extract -- deprecated, kept for backward compat)
   --skip-patches 0|1            skip Phase 3.6 (rocm_patches.sh) (default $SKIP_PATCHES)
   --keep-tarballs N             prune policy (default $KEEP_TARBALLS)
   --distro NAME                 default $DISTRO
   --distro-version VER          default $DISTRO_VERSION
   --amdgpu-gfxmodel GFX         default $AMDGPU_GFXMODEL
   --top-install-path PATH       on-host SDK extract destination (default $TOP_INSTALL_PATH; legacy /nfsapps/opt -- prefer --site)
   --top-module-path  PATH       on-host Lmod root for deployed modulefiles (default $TOP_MODULE_PATH; legacy /nfsapps/modules -- prefer --site)
   --site PRESET|/ABS/PATH       shorthand for the two path flags above.
                                   Named presets:
                                     opt          -> /opt + /opt/modules
                                     nfsapps      -> /nfsapps/opt + /nfsapps/modules           (Ubuntu 24.04 NFS test tree)
                                     shared-apps  -> /shared/apps/ubuntu/opt + /shared/apps/modules/ubuntu/lmodfiles  (LIVE cluster tree, Ubuntu 22.04)
                                   Absolute path form: any value starting with '/' is treated as a parent prefix, expanded to PREFIX/opt + PREFIX/modules.
                                     e.g. --site /nfsapps/ubuntu-22.04 -> /nfsapps/ubuntu-22.04/opt + /nfsapps/ubuntu-22.04/modules
                                 Explicit --top-install-path / --top-module-path flags override the corresponding preset value.
   --dry-run                     print sbatch command without submitting
   --help
EOF
   exit 1
}

DRY_RUN=0
while [[ $# -gt 0 ]]; do
   case "${1}" in
      --rocm-versions)    shift; ROCM_VERSIONS_RAW=${1} ;;
      --partition)        shift; PARTITION=${1} ;;
      --min-per-version)  shift; MIN_PER_VERSION=${1} ;;
      --afar-min-per-version) shift; AFAR_MIN_PER_VERSION=${1} ;;
      --therock-min-per-version) shift; THEROCK_MIN_PER_VERSION=${1} ;;
      --therock-amdgpu-family)   shift; THEROCK_AMDGPU_FAMILY=${1} ;;
      --margin-min)       shift; MARGIN_MIN=${1} ;;
      --replace-existing) shift; REPLACE_EXISTING=${1} ;;
      --force-extract)    shift; REPLACE_EXISTING=${1}
                          echo "[rocm_sweep] NOTE: --force-extract is deprecated; use --replace-existing" >&2 ;;
      --skip-patches)     shift; SKIP_PATCHES=${1} ;;
      --keep-tarballs)    shift; KEEP_TARBALLS=${1} ;;
      --distro)           shift; DISTRO=${1} ;;
      --distro-version)   shift; DISTRO_VERSION=${1} ;;
      --amdgpu-gfxmodel)  shift; AMDGPU_GFXMODEL=${1} ;;
      --top-install-path) shift; TOP_INSTALL_PATH=${1}; TOP_INSTALL_PATH_CLI=1 ;;
      --top-module-path)  shift; TOP_MODULE_PATH=${1};  TOP_MODULE_PATH_CLI=1  ;;
      --site)             shift; SITE=${1} ;;
      --dry-run)          DRY_RUN=1 ;;
      --help|-h)          usage ;;
      *)                  echo "Unknown arg: ${1}" >&2; usage ;;
   esac
   shift
done

# ── --site preset application ─────────────────────────────────────────
# Mirror the priority chain in run_rocmplus_install_sweep.sh: explicit
# --top-install-path / --top-module-path always wins; otherwise --site
# (named preset or /ABS/PATH form) fills in the gap. If neither was
# given, the legacy /nfsapps defaults from the `: ${...:=}` block above
# remain in effect -- byte-identical behaviour for all in-flight
# invocations of this script that predate the --site flag.
TOP_INSTALL_PATH_SOURCE=""
TOP_MODULE_PATH_SOURCE=""
[ "${TOP_INSTALL_PATH_CLI}" = "1" ] && TOP_INSTALL_PATH_SOURCE="--top-install-path"
[ "${TOP_MODULE_PATH_CLI}"  = "1" ] && TOP_MODULE_PATH_SOURCE="--top-module-path"

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
      /*)
         # Absolute-path PREFIX form (e.g. --site /nfsapps/ubuntu-22.04):
         # symmetric layout PREFIX/opt + PREFIX/modules.
         _SITE_PREFIX="${SITE%/}"
         _SITE_TOP_INSTALL="${_SITE_PREFIX}/opt"
         _SITE_TOP_MODULE="${_SITE_PREFIX}/modules"
         unset _SITE_PREFIX
         ;;
      *)
         echo "ERROR: --site must be a named preset (opt | nfsapps | shared-apps) or an absolute path starting with '/' (got '${SITE}')" >&2
         exit 1
         ;;
   esac
   if [ "${TOP_INSTALL_PATH_CLI}" = "0" ]; then
      TOP_INSTALL_PATH="${_SITE_TOP_INSTALL}"
      TOP_INSTALL_PATH_SOURCE="--site ${SITE}"
   fi
   if [ "${TOP_MODULE_PATH_CLI}" = "0" ]; then
      TOP_MODULE_PATH="${_SITE_TOP_MODULE}"
      TOP_MODULE_PATH_SOURCE="--site ${SITE}"
   fi
   unset _SITE_TOP_INSTALL _SITE_TOP_MODULE
fi

# Tag legacy-default origins so the summary block below shows them
# explicitly rather than as anonymous "preset defaults".
[ -z "${TOP_INSTALL_PATH_SOURCE}" ] && TOP_INSTALL_PATH_SOURCE="legacy default (/nfsapps/opt)"
[ -z "${TOP_MODULE_PATH_SOURCE}"  ] && TOP_MODULE_PATH_SOURCE="legacy default (/nfsapps/modules)"

[[ -z "${ROCM_VERSIONS_RAW}" ]] && \
   ROCM_VERSIONS_RAW="7.1.0 7.0.2 7.0.1 7.0.0 6.4.3 6.4.2 6.4.1 6.4.0"

# Normalize to space-separated.
ROCM_VERSIONS_NORM="${ROCM_VERSIONS_RAW//,/ }"
read -r -a VERSIONS_ARR <<< "${ROCM_VERSIONS_NORM}"
N=${#VERSIONS_ARR[@]}
(( N == 0 )) && { echo "ERROR: no ROCm versions parsed from '${ROCM_VERSIONS_RAW}'" >&2; exit 1; }

# ---------------- AFAR / TheRock / numeric-token partition -----------
# Each token shape takes a completely different code path on the
# compute node:
#   * AFAR tokens (afar-X.Y.Z) -> run_rocm_afar_install.sh
#       wget + tar from repo.radeon.com/rocm/misc/flang/, ~11 min wall.
#   * TheRock tokens (therock-X.Y[.Z]) -> run_rocm_therock_install.sh
#       curl + tar from repo.amd.com/rocm/tarball/, ~11 min wall (same
#       order of magnitude as AFAR; both NFS-bound on the extract).
#   * Numeric tokens (X.Y.Z) -> run_rocm_build.sh
#       docker + make + extract + patches, ~95 min wall.
# Split here so the time budget reflects reality and the submitter
# banner surfaces the per-bucket counts.
AFAR_VERSIONS=()
THEROCK_VERSIONS=()
NUMERIC_VERSIONS=()
for _v in "${VERSIONS_ARR[@]}"; do
   if [[ "${_v}" == afar-* ]]; then
      AFAR_VERSIONS+=("${_v}")
   elif [[ "${_v}" == therock-* ]]; then
      THEROCK_VERSIONS+=("${_v}")
   else
      NUMERIC_VERSIONS+=("${_v}")
   fi
done
unset _v
N_AFAR=${#AFAR_VERSIONS[@]}
N_THEROCK=${#THEROCK_VERSIONS[@]}
N_NUMERIC=${#NUMERIC_VERSIONS[@]}

# ---------------- Delta-release time-budget adjustment ----------------
# Delta releases (e.g. 7.2.2) require installing both the base version and
# the delta inside the container before merging, taking ~1.5x the wall time
# of a regular version. Read bare_system/rocm_delta_releases.conf to identify
# any delta versions in this sweep and pad the time budget accordingly.
# Only numeric versions can be delta releases; AFAR drops are never
# registered there (their .info/version numeric is incidental to the
# install, not a base on which an apt delta is layered).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DELTA_CONF="${REPO_ROOT}/bare_system/rocm_delta_releases.conf"
DELTA_VERSIONS=()
if [[ -f "${DELTA_CONF}" ]]; then
   for _v in "${NUMERIC_VERSIONS[@]}"; do
      _base=$(awk -F= -v v="${_v}" '
         /^[[:space:]]*#/ {next}
         /^[[:space:]]*$/ {next}
         $1 == v {print $2; exit}
      ' "${DELTA_CONF}")
      [[ -n "${_base}" ]] && DELTA_VERSIONS+=("${_v}=>${_base}")
   done
   unset _v _base
fi

# Each delta version adds an extra MIN_PER_VERSION/2 minutes to the budget
# (the base install is roughly half the wall of a full SDK install).
DELTA_EXTRA_MIN=$(( ${#DELTA_VERSIONS[@]} * MIN_PER_VERSION / 2 ))

TOTAL_MIN=$(( N_NUMERIC * MIN_PER_VERSION + N_AFAR * AFAR_MIN_PER_VERSION + N_THEROCK * THEROCK_MIN_PER_VERSION + DELTA_EXTRA_MIN + MARGIN_MIN ))
if (( TOTAL_MIN > MAX_TIME_MIN )); then
   echo "WARNING: requested ${TOTAL_MIN}min exceeds partition MaxTime ${MAX_TIME_MIN}min; capping."
   TOTAL_MIN=${MAX_TIME_MIN}
fi
HH=$(( TOTAL_MIN / 60 ))
MM=$(( TOTAL_MIN % 60 ))
TIME_STR=$(printf '%02d:%02d:00' "${HH}" "${MM}")

SBATCH_FILE="${REPO_ROOT}/bare_system/run_rocm_build_sweep.sbatch"
[[ -f "${SBATCH_FILE}" ]] || { echo "ERROR: ${SBATCH_FILE} not found" >&2; exit 1; }

cat <<EOF
==================================================================
 ROCm sweep submitter
==================================================================
 Partition:        ${PARTITION}
 Versions (${N}):  ${VERSIONS_ARR[*]}
   numeric (${N_NUMERIC}):  ${NUMERIC_VERSIONS[*]:-<none>}
   AFAR    (${N_AFAR}):     ${AFAR_VERSIONS[*]:-<none>}
   TheRock (${N_THEROCK}):  ${THEROCK_VERSIONS[*]:-<none>}
 Delta versions:   ${DELTA_VERSIONS[*]:-<none>}
 Per-version est:  numeric=${MIN_PER_VERSION} min, AFAR=${AFAR_MIN_PER_VERSION} min, TheRock=${THEROCK_MIN_PER_VERSION} min (+${DELTA_EXTRA_MIN} min for ${#DELTA_VERSIONS[@]} delta(s))
 Margin:           ${MARGIN_MIN} min
 Total --time:     ${TIME_STR}
 Replace existing: ${REPLACE_EXISTING}
 Skip patches:     ${SKIP_PATCHES}
 Keep tarballs:    ${KEEP_TARBALLS}
 Distro:           ${DISTRO} ${DISTRO_VERSION}
 GFX:              ${AMDGPU_GFXMODEL}
 Site preset:      ${SITE:-<none>}
 TOP_INSTALL_PATH: ${TOP_INSTALL_PATH}   [source: ${TOP_INSTALL_PATH_SOURCE}]
 TOP_MODULE_PATH:  ${TOP_MODULE_PATH}   [source: ${TOP_MODULE_PATH_SOURCE}]
 TheRock family:   ${THEROCK_AMDGPU_FAMILY}
 Delta registry:   ${DELTA_CONF}
 sbatch file:      ${SBATCH_FILE}
==================================================================
EOF

EXPORT_VARS="ALL,ROCM_VERSIONS=${ROCM_VERSIONS_NORM},REPLACE_EXISTING=${REPLACE_EXISTING},SKIP_PATCHES=${SKIP_PATCHES},KEEP_TARBALLS=${KEEP_TARBALLS},DISTRO=${DISTRO},DISTRO_VERSION=${DISTRO_VERSION},AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL},TOP_INSTALL_PATH=${TOP_INSTALL_PATH},TOP_MODULE_PATH=${TOP_MODULE_PATH},THEROCK_AMDGPU_FAMILY=${THEROCK_AMDGPU_FAMILY}"
# Pass --site through so the sbatch banner can echo it for traceability
# (the sbatch itself uses the already-resolved TOP_INSTALL_PATH /
# TOP_MODULE_PATH; SITE is informational on the compute-node side).
if [[ -n "${SITE}" ]]; then
   EXPORT_VARS="${EXPORT_VARS},SITE=${SITE}"
fi

CMD=( sbatch
      --time="${TIME_STR}"
      --partition="${PARTITION}"
      --export="${EXPORT_VARS}"
      "${SBATCH_FILE}" )

if (( DRY_RUN == 1 )); then
   printf '%q ' "${CMD[@]}"; echo
   exit 0
fi

cd "${REPO_ROOT}"
"${CMD[@]}"
