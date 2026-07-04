#!/bin/bash
#
# run_rocm_therock_install.sh - non-interactive download + extract +
# module-write for a single TheRock pre-built ROCm tarball.
#
# TheRock releases (https://github.com/ROCm/TheRock/releases) are
# pre-built, distro-agnostic ROCm SDK trees, NOT regular upstream ROCm
# .deb/.rpm packages:
#   * The github releases page is the version listing (tags like
#     `therock-7.13`, `therock-7.12`, ...). The actual binary tarballs
#     are not attached as github release assets -- they live at
#     https://repo.amd.com/rocm/tarball/, named
#     `therock-dist-linux-${AMDGPU_FAMILY}-${VERSION}.tar.gz`.
#   * The github tag's numeric (e.g. `7.13`) implicitly maps to a full
#     X.Y.Z version (e.g. `7.13.0`) on repo.amd.com. The auto-discovery
#     in Phase 1 below handles both forms transparently.
#   * The tarball expands DIRECTLY into the destination dir (no top-
#     level wrapper segment to drop, unlike the AFAR drops where we
#     have to rename `rocm-afar-<NUM>-drop-<REL>` -> `rocm-afar-<REL>`).
#   * There is no `make rocm`, no rocm_package, no rocm_patches.sh;
#     the docker pipeline that run_rocm_build.sh uses for official
#     numeric versions does not apply. This script is the TheRock-side
#     analogue: just curl + tar + write the GPUSDK-shaped modulefile.
#
# Phases:
#   0. Pre-check: skip cleanly (exit 0) if ${TOP_INSTALL_PATH}/
#      rocm-therock-${ROCM_NUMERIC} (or any rocm-therock-${THEROCK_RELEASE}*
#      candidate) already exists and --replace-existing is not set.
#      ROCM_NUMERIC is unknown until Phase 3, so the pre-check is a
#      conservative glob match against the user-supplied THEROCK_RELEASE.
#   1. Tarball URL discovery from repo.amd.com/rocm/tarball/. If
#      THEROCK_RELEASE is `X.Y` (matching the github tag form), the
#      script first tries the literal version, then `${VERSION}.0`,
#      then a fuzzy listing-grep. Any one of those found wins.
#   2. curl the tarball to /tmp, sudo mkdir + sudo tar -xzpf directly
#      into a staging dir under ${TOP_INSTALL_PATH}/. No rename of
#      a wrapper dir is needed (TheRock tarballs have no wrapper).
#   3. Read .info/version from the staged tree -> ROCM_NUMERIC.
#   4. Move staging dir to the final ${TOP_INSTALL_PATH}/rocm-
#      ${ROCM_NUMERIC} (the .info/version-derived install dir).
#   5. Emit ${TOP_MODULE_PATH}/base/rocm/${ROCM_NUMERIC}.lua using the
#      .info/version-derived SDK NUMERIC as the module name (e.g.
#      `7.13.0.lua`). NUMERIC NAMING (TheRock >= 7.10.0): a TheRock
#      release is registered exactly like a docker-built numeric
#      release -- module `rocm/${ROCM_NUMERIC}`, SDK tree
#      `rocm-${ROCM_NUMERIC}`, package tree `rocmplus-${ROCM_NUMERIC}`,
#      `PrgEnv-amd-new/<pe>-${ROCM_NUMERIC}` -- differing ONLY in source
#      (repo.amd.com tarball) and packaging (extract vs build). The
#      github-tag form `therock-7.13` remains a download label only
#      (${THEROCK_RELEASE}); it no longer appears in any output name.
#      Inside the modulefile, ROCM_PATH and the two MODULEPATH prepends
#      use the .info/version numeric so runtime version comparisons see
#      the authoritative SDK numeric (e.g. 7.13.0).
#
# This script is invoked one-per-token by bare_system/run_rocm_build_sweep.sbatch
# when the sweep loop sees a token of the form therock-X.Y[.Z]. The sweep's
# regular numeric path (run_rocm_build.sh) and AFAR path
# (run_rocm_afar_install.sh) are unchanged.

set -eo pipefail

# Capture this script's absolute path BEFORE any cd so the modulefile's
# whatis() provenance line below can git-resolve us even if a downstream
# curl/tar chdir's us out of the repo. Mirrors run_rocm_afar_install.sh.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

: ${THEROCK_RELEASE:=""}
# AMDGPU_FAMILY is the gfx-family token in the tarball filename. For the
# MI250 / MI300 / MI300A line (gfx90a / gfx942 / gfx94X) AMD ships a
# single combined `gfx94X-dcgpu` tarball. Other families (gfx908,
# gfx110X-all, gfx120X-all, gfx1150, gfx1151, gfx1152, ...) live under
# their own tarballs. Default keeps the sh5 cluster (gfx942 + gfx90a)
# happy out of the box; pass --amdgpu-family to override.
: ${AMDGPU_FAMILY:="gfx94X-dcgpu"}
: ${DISTRO:="ubuntu"}
: ${DISTRO_VERSION:="24.04"}
: ${TOP_INSTALL_PATH:="/nfsapps/opt"}
: ${TOP_MODULE_PATH:="/nfsapps/modules"}
: ${REPLACE_EXISTING:="0"}
: ${KEEP_FAILED_INSTALLS:="0"}
# MODULES_ONLY: 1 = keep the existing rocm-therock-<numeric> SDK tree and ONLY
# re-emit the modulefiles (base rocm/therock-<rel>, per-package, .pc, and the
# Cray PrgEnv-amd-new ecosystem + mpich-wrappers). Skips Phase 1 (discovery),
# Phase 2 (download/extract), Phase 3 (derive numeric from staging) and Phase 4
# (promote): the numeric is read from the existing install's .info/version
# instead. No tarball is needed. Use it to pick up modulefile-emitter changes
# (e.g. SUPPRESS_MODULEPATH) without a full multi-GB re-download/extract.
: ${MODULES_ONLY:="0"}
# WORLD_READABLE: 1 = make install + module trees group/other readable (o+rX)
# for a shared location (e.g. /shareddata); 0 = leave as-is; "auto" (default) =
# enable iff TOP_INSTALL_PATH is NOT under $HOME.
: ${WORLD_READABLE:="auto"}
: ${URL_BASE:="https://repo.amd.com/rocm/tarball"}
# LOCAL_TARBALL_INPUT: when set to an existing therock-dist-linux-*.tar.gz
# path, Phase 1 URL discovery + the Phase 2 curl are skipped and this file is
# extracted directly. This is the AAC6-build -> transfer -> AAC7-extract path:
# the build node stages the tarball, the Cray login node extracts it and
# writes the modulefiles + PrgEnv-amd-new ecosystem. ACTUAL_VERSION is parsed
# from the filename; .info/version is still authoritative for the install dir.
: ${LOCAL_TARBALL_INPUT:=""}
# STAGE_ONLY_DIR: when set, Phase 1 discovery + Phase 2 download run as usual
# but the tarball is saved into this dir and the script EXITS before extract.
# This is the AAC6 (build-host) half of the transfer pipeline: stage the
# distro-agnostic TheRock tarball, then ship it to AAC7 for extract+modules.
: ${STAGE_ONLY_DIR:=""}
# NO_SUDO: "" = auto-detect (no sudo when the install parent is directly
# user-writable, e.g. a $HOME install on a login node), 1 = force sudo-free,
# 0 = force the root-owned /nfsapps behavior. SUDO is derived from it below.
: ${NO_SUDO:=""}
# CRAY_SYSTEM: "" = auto-detect a Cray PE host, 1 = force Cray-style Tcl
# modulefiles instead of Lmod .lua (the classic Tcl `module` on Cray PE login
# nodes cannot read .lua). Mirrors rocm/scripts/rocm_setup.sh.
: ${CRAY_SYSTEM:=""}
# PE_VERSION: the stock PrgEnv-amd version that the generated
# PrgEnv-amd-new/<pe>-<rocm> module wraps. "" = auto-detect on a Cray box
# (highest PrgEnv-amd/<ver> available); override with --pe-version.
: ${PE_VERSION:=""}
# BUILD_MPICH_WRAPPERS: 1 = build+emit the from-source AMD-LLVM MPICH wrappers
# that PrgEnv-amd-new auto-loads (amdflang cannot read cray-mpich's mpi.mod);
# 0 = skip. Cray-only (no-op off-Cray). Override with --build-mpich-wrappers.
: ${BUILD_MPICH_WRAPPERS:="1"}
# MPI_FAMILY: mpich (default) builds+loads the wrappers; openmpi skips them
# (OpenMPI ships an amdflang-compatible mpi.mod). Override with --mpi-family.
: ${MPI_FAMILY:="mpich"}
SUDO="sudo"

# chown to root:root only when running with sudo; a plain user can't chown to
# root and doesn't need to (the files are theirs). No-op in no-sudo mode.
chown_root() { [ "${NO_SUDO}" = "1" ] && return 0; sudo chown "$@"; }
# Create a directory: root-owned 0755 when sudo is in play, else a plain
# user-owned mkdir -p.
make_dir_root() {
   if [ "${NO_SUDO}" = "1" ]; then mkdir -p "$1"; else sudo install -d -o root -g root -m 0755 "$1"; fi
}

usage() {
   cat <<EOF
Usage: $0 [opts]
  --therock-release VER         TheRock release version (e.g. 7.13.0, or 7.13
                                matching the github tag therock-7.13). REQUIRED.
                                The X.Y short form is auto-extended to X.Y.0 by
                                the URL discovery in Phase 1 if no literal X.Y
                                tarball exists upstream.
  --amdgpu-family FAM           gfx-family token in the tarball filename
                                (default: ${AMDGPU_FAMILY}). Common values:
                                  gfx94X-dcgpu  (MI300A / MI300X / MI250 / MI210)
                                  gfx908        (MI100)
                                  gfx110X-all   (RDNA3 dGPUs)
                                  gfx120X-all   (RDNA4 dGPUs)
                                  gfx1150 / gfx1151 / gfx1152 (Strix iGPUs)
                                See https://repo.amd.com/rocm/tarball/ for
                                the authoritative list of available families.
  --distro NAME                 default ${DISTRO}
                                (informational only -- TheRock tarballs are
                                distro-agnostic; the URL has no distro segment)
  --distro-version VER          default ${DISTRO_VERSION} (informational only)
  --top-install-path PATH       SDK extract destination; default ${TOP_INSTALL_PATH}
  --top-module-path  PATH       Lmod root for modulefile; default ${TOP_MODULE_PATH}
  --url-base URL                tarball listing/download base; default ${URL_BASE}
                                (use https://rocm.nightlies.amd.com/tarball
                                 for nightlies, https://rocm.prereleases.amd.com/tarball
                                 for prereleases, etc. See
                                 https://github.com/ROCm/TheRock/blob/main/dockerfiles/install_rocm_tarball.sh)
  --replace-existing 0|1        overwrite existing rocm-<numeric>
                                install + modulefile (default ${REPLACE_EXISTING})
  --keep-failed-installs 0|1    on failure, keep partial install + modulefile
                                for post-mortem (default ${KEEP_FAILED_INSTALLS})
  --modules-only 0|1            keep the existing rocm-<numeric> tree and
                                ONLY re-emit modulefiles (base + per-package +
                                .pc + PrgEnv-amd-new ecosystem + mpich-wrappers);
                                skips discovery/download/extract/promote so no
                                tarball is needed (default ${MODULES_ONLY})
  --local-tarball PATH          extract this already-downloaded
                                therock-dist-linux-<family>-<ver>.tar.gz
                                instead of discovering + curl-ing it (the
                                AAC6-build -> transfer -> AAC7-extract path).
                                --therock-release is still required.
  --stage-only DIR              discover + download the tarball into DIR and
                                EXIT before extract (the AAC6 build-host half
                                of the transfer pipeline). Mutually exclusive
                                with --local-tarball.
  --cray-modules                force Cray-style classic Tcl modulefiles +
                                the PrgEnv-amd-new ecosystem (auto-detected on
                                Cray PE hosts otherwise)
  --pe-version VER              stock PrgEnv-amd version the generated
                                PrgEnv-amd-new/<pe>-<rocm> wraps (Cray only).
                                Default: auto-detect the highest PrgEnv-amd.
  --build-mpich-wrappers 0|1    build+emit the from-source AMD-LLVM MPICH
                                wrappers PrgEnv-amd-new auto-loads (Cray only;
                                default ${BUILD_MPICH_WRAPPERS})
  --mpi-family mpich|openmpi    MPI family the PrgEnv-amd-new uses; openmpi skips
                                the mpich wrappers (build + load block).
                                Default ${MPI_FAMILY}
  --help
EOF
   exit 1
}

# Print the real error FIRST: usage() ends in `exit 1`, so anything echoed
# after usage() is unreachable and the true cause gets masked.
send-error() { echo -e "Error: ${*}\n" >&2; usage; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

n=0
while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--therock-release")      shift; THEROCK_RELEASE=${1};      reset-last ;;
      "--amdgpu-family")        shift; AMDGPU_FAMILY=${1};        reset-last ;;
      "--distro")               shift; DISTRO=${1};               reset-last ;;
      "--distro-version")       shift; DISTRO_VERSION=${1};       reset-last ;;
      "--top-install-path")     shift; TOP_INSTALL_PATH=${1};     reset-last ;;
      "--top-module-path")      shift; TOP_MODULE_PATH=${1};      reset-last ;;
      "--url-base")             shift; URL_BASE=${1};             reset-last ;;
      "--replace-existing")     shift; REPLACE_EXISTING=${1};     reset-last ;;
      "--keep-failed-installs") shift; KEEP_FAILED_INSTALLS=${1}; reset-last ;;
      "--modules-only")         shift; MODULES_ONLY=${1};         reset-last ;;
      "--no-sudo")              shift; NO_SUDO=${1};              reset-last ;;
      "--cray-modules")         CRAY_SYSTEM=1;                    reset-last ;;
      "--local-tarball")        shift; LOCAL_TARBALL_INPUT=${1};  reset-last ;;
      "--stage-only")           shift; STAGE_ONLY_DIR=${1};       reset-last ;;
      "--pe-version")           shift; PE_VERSION=${1};           reset-last ;;
      "--build-mpich-wrappers") shift; BUILD_MPICH_WRAPPERS=${1}; reset-last ;;
      "--mpi-family")           shift; MPI_FAMILY=${1};          reset-last ;;
      "--help"|"-h")            usage ;;
      *)                        last ${1} ;;
   esac
   n=$((n + 1))
   shift
done

[[ -z "${THEROCK_RELEASE}" ]] && send-error "--therock-release is required"
# Tolerate an accidental `therock-` prefix in the release flag value
# (e.g. operator copy-pastes the github tag `therock-7.13` straight in).
THEROCK_RELEASE="${THEROCK_RELEASE#therock-}"

# Strict X.Y or X.Y.Z form -- anything else is almost certainly a typo
# (the script downstream embeds this verbatim in URL + dir + module
# names, so loose parsing here would propagate confusing failures).
if [[ ! "${THEROCK_RELEASE}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
   send-error "--therock-release must be X.Y or X.Y.Z (got '${THEROCK_RELEASE}')"
fi
if [[ -n "${STAGE_ONLY_DIR}" && -n "${LOCAL_TARBALL_INPUT}" ]]; then
   send-error "--stage-only and --local-tarball are mutually exclusive"
fi
if [[ "${MODULES_ONLY}" == "1" ]]; then
   # modules-only re-emits modulefiles over an EXISTING install: there is no
   # download or extract, so --stage-only (download-only) is contradictory and
   # --local-tarball (extract a fresh tree) is meaningless.
   [[ -n "${STAGE_ONLY_DIR}" ]] && send-error "--modules-only and --stage-only are mutually exclusive"
   [[ -n "${LOCAL_TARBALL_INPUT}" ]] && \
      echo "[therock] NOTE: --modules-only set; ignoring --local-tarball '${LOCAL_TARBALL_INPUT}'"
   LOCAL_TARBALL_INPUT=""
fi

MODULE_DIR="${TOP_MODULE_PATH}/base/rocm"
# NUMERIC NAMING (TheRock >= 7.10.0): the module basename is the
# .info/version-derived SDK numeric (e.g. 7.13.0), matching the
# docker-built numeric releases -- a TheRock release differs from a
# numeric release ONLY in source (repo.amd.com tarball) and packaging
# (extract vs build), never in the module/tree names. ROCM_NUMERIC is
# not known until Phase 3, so MODULE_FILE is finalized there (see the
# "finalize MODULE_FILE" block just before Phase 5). The candidate
# list below -- built from the user-supplied release token, both X.Y
# and X.Y.0 forms, both flavors -- lets --replace-existing remove a
# stale numeric modulefile before ROCM_NUMERIC is derived.
MODULE_FILE=""
MODULE_FILE_CANDIDATES=(
   "${MODULE_DIR}/${THEROCK_RELEASE}"
   "${MODULE_DIR}/${THEROCK_RELEASE}.lua"
)
if [[ "${THEROCK_RELEASE}" =~ ^[0-9]+\.[0-9]+$ ]]; then
   MODULE_FILE_CANDIDATES+=(
      "${MODULE_DIR}/${THEROCK_RELEASE}.0"
      "${MODULE_DIR}/${THEROCK_RELEASE}.0.lua"
   )
fi

# ---------------- Phase 0: skip-if-installed pre-check ----------------
# We don't yet know the .info/version-derived install dir basename
# (that's Phase 3), so the pre-check is a glob match against the
# user-supplied THEROCK_RELEASE. Two candidates are considered:
#   * rocm-therock-${THEROCK_RELEASE}      (literal token -- matches when
#                                            user passed full X.Y.Z form)
#   * rocm-therock-${THEROCK_RELEASE}.0    (X.Y short form auto-extended)
# These cover the two real-world inputs (`therock-7.13` and
# `therock-7.13.0`) without us having to download the tarball to learn
# .info/version. If a directory matches AND --replace-existing is not
# set, exit 0 cleanly (the sweep counts this as SKIP).
SKIP_CANDIDATES=( "${TOP_INSTALL_PATH}/rocm-${THEROCK_RELEASE}" )
[[ "${THEROCK_RELEASE}" =~ ^[0-9]+\.[0-9]+$ ]] \
   && SKIP_CANDIDATES+=( "${TOP_INSTALL_PATH}/rocm-${THEROCK_RELEASE}.0" )
# In --stage-only mode we only download the tarball; an existing install
# is irrelevant and must NOT short-circuit the download.
# In --modules-only mode an existing install is REQUIRED (we re-emit modulefiles
# for it), so the skip-if-installed short-circuit is disabled; the modules-only
# branch below (after sudo/Cray resolution) locates the tree and derives the
# numeric.
if [[ -z "${STAGE_ONLY_DIR}" && "${REPLACE_EXISTING}" != "1" && "${MODULES_ONLY}" != "1" ]]; then
   for _cand in "${SKIP_CANDIDATES[@]}"; do
      if [[ -d "${_cand}" ]]; then
         echo "[$(date)] SKIP therock-${THEROCK_RELEASE}: ${_cand} already exists"
         echo "         Pass --replace-existing 1 to re-download + re-extract,"
         echo "         or --modules-only 1 to refresh modulefiles."
         exit 0
      fi
   done
   unset _cand
fi

# ---------------- Resolve sudo + Cray module flavor -------------------
INSTALL_PARENT="${TOP_INSTALL_PATH%/*}"

# no-sudo auto-detect: a $HOME install on a login node has a directly
# user-writable install parent and needs neither sudo nor root ownership.
#
# Do NOT rely on `test -w` here. Over NFSv4 (e.g. the sh5 compute nodes'
# `warewulf:/nfsapps` re-export) access(2) reports a root-owned 0755 directory
# as writable to an unprivileged user, yet the actual mkdir is denied with
# EACCES. That false-positive silently selected the sudo-free path, so the
# staging `mkdir` (make_dir_root) failed and every TheRock install on /nfsapps
# aborted. Probe with a REAL write (create+remove a temp dir) so the decision
# matches what the filesystem will actually allow.
_therock_can_write() {
   local _d="$1" _t
   [ -d "${_d}" ] || return 1
   _t="$(mktemp -d "${_d}/.wtest.XXXXXX" 2>/dev/null)" || return 1
   rmdir "${_t}" 2>/dev/null || true
   return 0
}
if [ -z "${NO_SUDO}" ]; then
   if _therock_can_write "${INSTALL_PARENT}" \
      || { [ ! -e "${INSTALL_PARENT}" ] && _therock_can_write "$(dirname "${INSTALL_PARENT}")"; }; then
      NO_SUDO=1
   else
      NO_SUDO=0
   fi
fi
[ "${NO_SUDO}" = "1" ] && SUDO="" || SUDO="sudo"

# Cray PE detection (override with --cray-modules / CRAY_SYSTEM=1).
if [ -z "${CRAY_SYSTEM}" ]; then
   if [ -d /opt/cray/pe ] || [ -f /etc/cray-release ] || [ -n "${CRAYPE_VERSION:-}" ]; then
      CRAY_SYSTEM=1
   else
      CRAY_SYSTEM=0
   fi
fi
echo "[therock] NO_SUDO=${NO_SUDO}  CRAY_SYSTEM=${CRAY_SYSTEM}  (sudo='${SUDO}')"

# Cray uses classic Tcl modulefiles (extensionless); Lmod uses .lua.
# MODULE_FILE itself is finalized once ROCM_NUMERIC is known (numeric
# basename); here we only record the flavor extension.
if [ "${CRAY_SYSTEM}" = "1" ]; then
   MODULE_EXT=""
else
   MODULE_EXT=".lua"
fi

if [ "${NO_SUDO}" = "1" ]; then
   # User-writable install: no remount, no root test -- just probe a real write
   # (see _therock_can_write above: NFSv4 `test -w` can't be trusted). This also
   # gives a clean early error if --no-sudo 1 was forced on a root-owned tree.
   if ! _therock_can_write "${INSTALL_PARENT}"; then
      echo "ERROR: ${INSTALL_PARENT} is not writable by $(id -un) on $(hostname); aborting." >&2
      echo "       (root-owned tree? drop --no-sudo 1 so the installer uses sudo.)" >&2
      exit 1
   fi
else
   # Defensive remount of a root-owned /nfsapps as rw (warewulf fstab mounts ro
   # by default; the sh5 admin export grants rw). Mirrors run_rocm_afar_install.sh.
   if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
      echo "Attempting to remount ${INSTALL_PARENT} rw..."
      sudo mount -o remount,rw "${INSTALL_PARENT}" 2>/dev/null || true
   fi
   if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
      echo "ERROR: ${INSTALL_PARENT} is not writable on $(hostname); aborting." >&2
      mount | grep nfsapps || true
      exit 1
   fi
fi

# Self-heal install/module roots if missing (mirrors the sweep sbatch).
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}" "${MODULE_DIR}"; do
   if [ ! -d "${d}" ]; then
      echo "Creating missing ${d}"
      make_dir_root "${d}"
   fi
done

# ---------------- --modules-only: locate install + derive numeric ----
# Keep the existing SDK tree and skip Phases 1-4 (discovery/download/extract/
# promote). The install dir is rocm-therock-<ROCM_NUMERIC>, but ROCM_NUMERIC is
# only knowable from .info/version, so locate the tree from the Phase 0
# candidates (and a final glob for alpha/RC dirs the literal candidates miss),
# then read .info/version (basename fallback) for the numeric.
if [[ "${MODULES_ONLY}" == "1" ]]; then
   INSTALL_DIR=""
   for _cand in "${SKIP_CANDIDATES[@]}"; do
      [[ -d "${_cand}" ]] && { INSTALL_DIR="${_cand}"; break; }
   done
   if [[ -z "${INSTALL_DIR}" ]]; then
      for _cand in "${TOP_INSTALL_PATH}"/rocm-"${THEROCK_RELEASE}"*; do
         [[ -d "${_cand}" ]] && { INSTALL_DIR="${_cand}"; break; }
      done
   fi
   unset _cand
   if [[ -z "${INSTALL_DIR}" || ! -d "${INSTALL_DIR}" ]]; then
      echo "ERROR: --modules-only set but no rocm-${THEROCK_RELEASE}* install" >&2
      echo "       exists under ${TOP_INSTALL_PATH}; there is no SDK tree to emit" >&2
      echo "       modulefiles for. Run a full install first (without --modules-only)." >&2
      exit 1
   fi
   ROCM_NUMERIC=""
   if ${SUDO} test -f "${INSTALL_DIR}/.info/version" 2>/dev/null; then
      ROCM_NUMERIC="$(${SUDO} cut -f1 -d- "${INSTALL_DIR}/.info/version" 2>/dev/null || true)"
   fi
   # Fallback: derive from the install dir basename (rocm-<numeric>).
   if [[ -z "${ROCM_NUMERIC}" ]]; then
      ROCM_NUMERIC="$(basename "${INSTALL_DIR}")"
      ROCM_NUMERIC="${ROCM_NUMERIC#rocm-}"
   fi
   if [[ -z "${ROCM_NUMERIC}" ]]; then
      echo "ERROR: --modules-only: cannot derive ROCM_NUMERIC from ${INSTALL_DIR}" >&2
      exit 1
   fi
   echo "============================================================"
   echo "  Phases 1-4 skipped (--modules-only): re-emitting modulefiles for"
   echo "  existing ${INSTALL_DIR} (ROCM_NUMERIC=${ROCM_NUMERIC})"
   echo "============================================================"
fi

if [[ "${MODULES_ONLY}" != "1" ]]; then
# ---------------- Phase 1: tarball URL discovery ----------------------
# The tarball name is therock-dist-linux-${AMDGPU_FAMILY}-${VERSION}.tar.gz
# at https://repo.amd.com/rocm/tarball/. We don't know which X.Y.Z to
# request without either trying or scraping the listing, so:
#   1. If THEROCK_RELEASE is X.Y.Z, just use it.
#   2. If THEROCK_RELEASE is X.Y, try literal first, then X.Y.0.
#   3. If both fail, scrape the listing for a fuzzy match
#      (largest version that starts with THEROCK_RELEASE).
# This mirrors the auto-discovery pattern in install_rocm_tarball.sh
# upstream (see WebFetch output committed in this script's history).
echo "============================================================"
echo "  Phase 1: ${LOCAL_TARBALL_INPUT:+use --local-tarball, skip discovery }${LOCAL_TARBALL_INPUT:-discover tarball for therock-${THEROCK_RELEASE} (${AMDGPU_FAMILY})}"
echo "============================================================"

# KEEP_LOCAL_TARBALL: 1 means ${LOCAL_TARBALL} is the operator's staged input
# (transfer path) and must NOT be reaped by the EXIT trap / post-extract rm.
KEEP_LOCAL_TARBALL=0

curl_head_ok() {
   # 1 = URL responds 200/302; 0 = otherwise. Avoids downloading on probe.
   local _u="$1"
   curl -fsI -o /dev/null --max-time 30 "${_u}" 2>/dev/null
}

if [[ -n "${LOCAL_TARBALL_INPUT}" ]]; then
   # ---- --local-tarball mode: AAC6-build -> transfer -> AAC7-extract ----
   if [[ ! -f "${LOCAL_TARBALL_INPUT}" ]]; then
      echo "ERROR: --local-tarball '${LOCAL_TARBALL_INPUT}' does not exist" >&2
      exit 1
   fi
   _abs="$(cd "$(dirname "${LOCAL_TARBALL_INPUT}")" && pwd -P)/$(basename "${LOCAL_TARBALL_INPUT}")"
   _bn="$(basename "${_abs}")"
   # Parse ACTUAL_VERSION from therock-dist-linux-<family>-<ver>.tar.gz. The
   # family segment in the filename wins over --amdgpu-family (the staged file
   # is authoritative). Fall back to THEROCK_RELEASE if the name is unusual.
   ACTUAL_VERSION="$(echo "${_bn}" | sed -nE 's|^therock-dist-linux-.*-([0-9]+\.[0-9]+(\.[0-9]+)?[a-z0-9]*)\.tar\.gz$|\1|p')"
   [[ -z "${ACTUAL_VERSION}" ]] && ACTUAL_VERSION="${THEROCK_RELEASE}"
   TARBALL_URL="file://${_abs}"
   LOCAL_TARBALL="${_abs}"
   KEEP_LOCAL_TARBALL=1
   STAGING_DIR="${TOP_INSTALL_PATH}/rocm-${ACTUAL_VERSION}.staging.$$"
   echo "Using local tarball: ${_abs}  (parsed version ${ACTUAL_VERSION})"
   unset _abs _bn
else

CANDIDATE_VERSIONS=( "${THEROCK_RELEASE}" )
[[ "${THEROCK_RELEASE}" =~ ^[0-9]+\.[0-9]+$ ]] \
   && CANDIDATE_VERSIONS+=( "${THEROCK_RELEASE}.0" )

ACTUAL_VERSION=""
TARBALL_URL=""
for _ver in "${CANDIDATE_VERSIONS[@]}"; do
   _try="${URL_BASE}/therock-dist-linux-${AMDGPU_FAMILY}-${_ver}.tar.gz"
   echo "  probing: ${_try}"
   if curl_head_ok "${_try}"; then
      ACTUAL_VERSION="${_ver}"
      TARBALL_URL="${_try}"
      break
   fi
done
unset _ver _try

# Listing-grep fallback: handles cases where AMD published e.g. 7.13.0a20260514
# (alpha/release-candidate suffix) under the X.Y short form the user passed.
# Sort -V picks the largest matching version so we get the latest repost.
if [[ -z "${ACTUAL_VERSION}" ]]; then
   echo "  literal probes failed; scraping listing at ${URL_BASE}/"
   _matched=$(curl -fsSL "${URL_BASE}/" \
      | grep -oE "therock-dist-linux-${AMDGPU_FAMILY}-[0-9]+\.[0-9]+(\.[0-9]+)?[a-z0-9]*\.tar\.gz" \
      | grep -E "therock-dist-linux-${AMDGPU_FAMILY}-${THEROCK_RELEASE}([.a-z0-9]|\.tar\.gz)" \
      | sort -V -u \
      | tail -n1)
   if [[ -n "${_matched}" ]]; then
      ACTUAL_VERSION=$(sed -E "s/^therock-dist-linux-${AMDGPU_FAMILY}-(.+)\.tar\.gz\$/\1/" <<<"${_matched}")
      TARBALL_URL="${URL_BASE}/${_matched}"
   fi
   unset _matched
fi

if [[ -z "${ACTUAL_VERSION}" ]]; then
   echo "ERROR: could not find a TheRock tarball for therock-${THEROCK_RELEASE} (${AMDGPU_FAMILY})" >&2
   echo "       Tried: ${CANDIDATE_VERSIONS[*]} under ${URL_BASE}/" >&2
   echo "       and a fuzzy listing-grep at ${URL_BASE}/" >&2
   echo "       Verify the release exists upstream, or pass --url-base for nightlies/prereleases." >&2
   exit 1
fi

LOCAL_TARBALL="/tmp/therock-dist-linux-${AMDGPU_FAMILY}-${ACTUAL_VERSION}.tar.gz"
# Staging dir under the install root so the final mv is rename-only
# (same filesystem == atomic, no NFS cross-mount data copy).
STAGING_DIR="${TOP_INSTALL_PATH}/rocm-${ACTUAL_VERSION}.staging.$$"
fi   # end discovery-vs-local-tarball

# --stage-only: redirect the download into the staging dir and protect it
# from the cleanup trap; Phase 2 will download then exit before extract.
if [[ -n "${STAGE_ONLY_DIR}" ]]; then
   make_dir_root "${STAGE_ONLY_DIR}"
   LOCAL_TARBALL="${STAGE_ONLY_DIR}/$(basename "${LOCAL_TARBALL}")"
   KEEP_LOCAL_TARBALL=1
fi

echo ""
echo "============================================================"
echo "  TheRock install plan"
echo "============================================================"
echo "  THEROCK_RELEASE      : ${THEROCK_RELEASE}"
echo "  ACTUAL_VERSION       : ${ACTUAL_VERSION}"
echo "  AMDGPU_FAMILY        : ${AMDGPU_FAMILY}"
echo "  DISTRO               : ${DISTRO} ${DISTRO_VERSION} (informational only)"
echo "  Tarball URL          : ${TARBALL_URL}"
echo "  Local tarball        : ${LOCAL_TARBALL}"
echo "  Staging dir          : ${STAGING_DIR}"
# MODULE_FILE is finalized from ROCM_NUMERIC before Phase 5; show the
# predicted numeric modulefile here (assumes ROCM_NUMERIC==ACTUAL_VERSION).
echo "  Predicted module     : ${MODULE_DIR}/${ACTUAL_VERSION}${MODULE_EXT}"
# Predicted install dir assumes ROCM_NUMERIC == ACTUAL_VERSION
# (the common case); Phase 4 finalizes from .info/version and may
# differ for alpha/RC tarballs.
echo "  Predicted install    : ${TOP_INSTALL_PATH}/rocm-${ACTUAL_VERSION}"
echo "  REPLACE_EXISTING     : ${REPLACE_EXISTING}"
echo "  KEEP_FAILED_INSTALLS : ${KEEP_FAILED_INSTALLS}"
echo "============================================================"
echo ""

# ---------------- --replace-existing cleanup --------------------------
# Run AFTER URL discovery so we don't blow away an existing install for
# a release that doesn't actually exist upstream. We don't yet know
# ROCM_NUMERIC, so the install-dir cleanup glob mirrors the Phase 0
# candidates. The modulefile is unambiguous (basename uses the user-
# supplied download tag verbatim) so just rm MODULE_FILE.
#
# Skipped entirely in --stage-only mode: staging only downloads the
# tarball into STAGE_ONLY_DIR and must never delete an install tree
# (which may be root-owned on the build host, causing a Permission
# denied abort before the download even starts).
if [[ -z "${STAGE_ONLY_DIR}" && "${REPLACE_EXISTING}" == "1" ]]; then
   for _cand in "${SKIP_CANDIDATES[@]}"; do
      if [[ -d "${_cand}" ]]; then
         echo "[--replace-existing 1] removing ${_cand}"
         ${SUDO} rm -rf "${_cand}"
      fi
   done
   # MODULE_FILE (numeric basename) isn't known until ROCM_NUMERIC is
   # derived, so remove any stale numeric modulefile via the candidate list
   # (both X.Y / X.Y.0 forms, both flavors) built from the release token.
   for _mcand in "${MODULE_FILE_CANDIDATES[@]}"; do
      if [[ -f "${_mcand}" ]]; then
         echo "[--replace-existing 1] removing ${_mcand}"
         ${SUDO} rm -f "${_mcand}"
      fi
   done
   unset _cand _mcand
fi

# ---------------- EXIT-trap fail-cleanup ------------------------------
# Mirrors run_rocm_afar_install.sh:151-162: on non-zero exit, blow away
# the staging dir + (if it had been promoted) the partial install dir +
# modulefile so the next run starts clean. INSTALL_DIR is set after
# Phase 4 -- guard the rm with -n to no-op when unset.
INSTALL_DIR=""
_therock_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[therock fail-cleanup] rc=${rc}: removing staging + partial install"
      ${SUDO} rm -rf "${STAGING_DIR}" 2>/dev/null || true
      [ -n "${INSTALL_DIR}" ] && ${SUDO} rm -rf "${INSTALL_DIR}" 2>/dev/null || true
      ${SUDO} rm -f "${MODULE_FILE}" 2>/dev/null || true
   elif [ ${rc} -ne 0 ]; then
      echo "[therock fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Reap the local tarball ONLY when we downloaded it ourselves. In
   # --local-tarball mode it's the operator's staged input and must survive.
   [ "${KEEP_LOCAL_TARBALL}" = "1" ] || rm -f "${LOCAL_TARBALL}" 2>/dev/null || true
   return ${rc}
}
trap _therock_on_exit EXIT

# ---------------- Phase 2: download + extract -------------------------
# TheRock tarballs have NO top-level wrapper segment (the .tar.gz
# expands directly into bin/, lib/, etc.). So we mkdir the staging
# dir first, then `tar -xzpf -C ${STAGING_DIR}` puts the contents
# straight into it -- no `mv extracted_subdir staging_dir` step like
# the AFAR installer needs.
echo "============================================================"
echo "  Phase 2: ${LOCAL_TARBALL_INPUT:+extract staged tarball }${LOCAL_TARBALL_INPUT:-curl} + tar -xzpf -> ${STAGING_DIR}"
echo "============================================================"
# curl is preferred over wget here because it's what install_rocm_tarball.sh
# upstream uses, and the AMD tarball server (repo.amd.com) returns the
# same redirects either way. -fSL == fail on errors, follow redirects,
# show errors but no progress meter (we're in a slurm log). In
# --local-tarball mode the file is already present; skip the download.
if [[ -z "${LOCAL_TARBALL_INPUT}" ]]; then
   rm -f "${LOCAL_TARBALL}"
   curl -fSL --output "${LOCAL_TARBALL}" "${TARBALL_URL}"
else
   echo "Skipping download; extracting staged ${LOCAL_TARBALL}"
fi

# --stage-only: tarball is now in STAGE_ONLY_DIR; we're done (no extract).
if [[ -n "${STAGE_ONLY_DIR}" ]]; then
   echo "STAGED: ${LOCAL_TARBALL}"
   echo "  token=therock-${THEROCK_RELEASE}  kind=therock  version=${ACTUAL_VERSION}"
   exit 0
fi

# Pre-empt a stale staging dir from an earlier interrupted run that the
# fail-cleanup didn't reach (e.g. SIGKILL). Same-PID collision is
# implausible (we're in $$) but defense in depth costs nothing.
${SUDO} rm -rf "${STAGING_DIR}"
make_dir_root "${STAGING_DIR}"
${SUDO} tar -xzpf "${LOCAL_TARBALL}" -C "${STAGING_DIR}"
echo "Extracted into staging: ${STAGING_DIR}"

# ---------------- Phase 3: derive ROCM_NUMERIC from .info/version -----
# .info/version is the authoritative version label inside the tarball
# (e.g. `7.13.0`). The github tag form `therock-7.13` is just a label;
# the install dir name comes from .info/version per the user's spec.
if [[ ! -f "${STAGING_DIR}/.info/version" ]]; then
   echo "ERROR: ${STAGING_DIR}/.info/version missing; cannot derive ROCM_NUMERIC" >&2
   echo "       (Did the TheRock tarball layout change?)" >&2
   ${SUDO} find "${STAGING_DIR}" -maxdepth 2 -type f -name version -printf '       found: %p\n' || true
   exit 1
fi
ROCM_NUMERIC=$(cut -f1 -d- "${STAGING_DIR}/.info/version")
if [[ -z "${ROCM_NUMERIC}" ]]; then
   echo "ERROR: ${STAGING_DIR}/.info/version is empty" >&2
   exit 1
fi
echo "ROCM_NUMERIC (from .info/version): ${ROCM_NUMERIC}"

# Sanity: ACTUAL_VERSION (from the tarball filename) should agree with
# ROCM_NUMERIC (.info/version inside the tarball). They CAN differ for
# alpha/RC tarballs (e.g. ACTUAL_VERSION=7.13.0a20260514, ROCM_NUMERIC=
# 7.13.0). Warn loudly but don't abort -- the install dir will use
# ROCM_NUMERIC per the user's spec, and that's what downstream
# rocfft_setup.sh / hipfft_setup.sh / rocprof-sys_setup.sh derive their
# loaded module name from.
if [[ "${ACTUAL_VERSION}" != "${ROCM_NUMERIC}" ]]; then
   echo "NOTE: tarball filename version (${ACTUAL_VERSION}) differs from"
   echo "      .info/version (${ROCM_NUMERIC}); install dir will use the"
      echo "      .info/version-derived form (rocm-${ROCM_NUMERIC})."
fi

# ---------------- Phase 4: promote staging to final install dir -------
INSTALL_DIR="${TOP_INSTALL_PATH}/rocm-${ROCM_NUMERIC}"
echo "============================================================"
echo "  Phase 4: promote staging -> ${INSTALL_DIR}"
echo "============================================================"

# If the final dir already exists at this point, --replace-existing was
# either not set, or the Phase 0/replace-existing block missed it
# (e.g. user passed therock-7.13 but a prior install used the X.Y.Z
# form `7.13.0` so it didn't match Phase 0's literal candidate). With
# REPLACE_EXISTING=1 we wipe; without it, we abort (Phase 0 should
# have skipped earlier, so reaching here without --replace-existing
# is a bug worth surfacing).
if [[ -d "${INSTALL_DIR}" ]]; then
   if [[ "${REPLACE_EXISTING}" == "1" ]]; then
      echo "[--replace-existing 1] removing pre-existing ${INSTALL_DIR}"
      ${SUDO} rm -rf "${INSTALL_DIR}"
   else
      echo "ERROR: ${INSTALL_DIR} already exists but --replace-existing is 0;" >&2
      echo "       Phase 0 should have caught this. Either pass --replace-existing 1" >&2
      echo "       or remove the existing install manually." >&2
      exit 1
   fi
fi
${SUDO} mv "${STAGING_DIR}" "${INSTALL_DIR}"
chown_root -R root:root "${INSTALL_DIR}"
${SUDO} chmod 755 "${INSTALL_DIR}"
[ "${KEEP_LOCAL_TARBALL}" = "1" ] || rm -f "${LOCAL_TARBALL}"
echo "Installed: ${INSTALL_DIR}"
fi   # end Phases 1-4 (skipped in --modules-only mode)

# ---------------- Phase 5: emit GPUSDK modulefile ---------------------
# Provenance: capture this leaf script's git state for the whatis() line.
# Same pattern as run_rocm_afar_install.sh:254-269.
LEAF_SCRIPT_NAME="$(basename "${LEAF_SCRIPT_PATH}")"
LEAF_SCRIPT_COMMIT=unknown
LEAF_SCRIPT_DIRTY=unknown
_leaf_dir="$(dirname "${LEAF_SCRIPT_PATH}")"
if [ -d "${_leaf_dir}" ] && command -v git >/dev/null 2>&1 \
   && git -C "${_leaf_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
   _commit="$(git -C "${_leaf_dir}" log -n 1 --pretty=format:%H -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)"
   [ -n "${_commit}" ] && LEAF_SCRIPT_COMMIT="${_commit}"
   unset _commit
   if [ -n "$(git -C "${_leaf_dir}" status --porcelain -- "${LEAF_SCRIPT_PATH}" 2>/dev/null)" ]; then
      LEAF_SCRIPT_DIRTY=dirty
   else
      LEAF_SCRIPT_DIRTY=clean
   fi
fi
unset _leaf_dir

# Finalize the numeric modulefile path now that ROCM_NUMERIC + MODULE_EXT
# are both known (both the normal and --modules-only flows have set them).
MODULE_FILE="${MODULE_DIR}/${ROCM_NUMERIC}${MODULE_EXT}"
echo "============================================================"
echo "  Phase 5: write modulefile ${MODULE_FILE}"
echo "============================================================"
${SUDO} mkdir -p "${MODULE_DIR}"

# The modulefile points `base` at the .info/version-derived install dir so
# runtime version checks see the authoritative SDK numeric (e.g. 7.13.0), not
# the github tag form (7.13). Two MODULEPATH prepends expose the per-package
# (rocm-therock-<numeric>) and rocmplus (rocmplus-therock-<numeric>) trees.

# ── Resolve the host GCC install dir for hipcc's --gcc-install-dir ───────
# Pinning HIPCC_{COMPILE,LINK}_FLAGS_APPEND points hipcc/clang++ (-x hip) at
# the OS GCC so it uses the system libstdc++ headers/libs instead of the newer
# libc++ bundled in the SDK's LLVM (that mismatch breaks HIP C++ builds). The
# dir is distro-specific (RHEL: /usr/lib/gcc/x86_64-redhat-linux/<ver>;
# Debian: .../x86_64-linux-gnu/<ver>), so DETECT it rather than hardcode a
# Debian path. Detection is based on g++ (the C++ driver) plus a real compile
# probe: on some hosts a newer gcc (e.g. gcc-13) is on PATH WITHOUT the matching
# g++/libstdc++-devel, which silently breaks every hipcc compile -- the probe
# rejects such a pick so we fall back to the default system C++ driver/GCC
# version for the OS.
GCC_INSTALL_DIR=""
for _cxx in g++ c++; do
   command -v "${_cxx}" >/dev/null 2>&1 || continue
   _d="$(dirname "$("${_cxx}" -print-libgcc-file-name 2>/dev/null)" 2>/dev/null)"
   { [ -n "${_d}" ] && [ -e "${_d}/crtbegin.o" ]; } || { _d=""; continue; }
   printf 'int main(){return 0;}\n' | "${_cxx}" -x c++ -c -o /dev/null - >/dev/null 2>&1 || { _d=""; continue; }
   GCC_INSTALL_DIR="${_d}"; break
done
unset _cxx _d
if [ -n "${GCC_INSTALL_DIR}" ]; then
   echo "[therock] host GCC install dir for hipcc: ${GCC_INSTALL_DIR} (g++ $(g++ -dumpversion 2>/dev/null), $(g++ -dumpmachine 2>/dev/null))"
   HIPCC_TCL_LINES="setenv HIPCC_COMPILE_FLAGS_APPEND \"--gcc-install-dir=${GCC_INSTALL_DIR}\"
setenv HIPCC_LINK_FLAGS_APPEND    \"--gcc-install-dir=${GCC_INSTALL_DIR}\"
setenv CCC_OVERRIDE_OPTIONS       \"+--gcc-install-dir=${GCC_INSTALL_DIR}\""
   HIPCC_LUA_LINES="setenv(\"HIPCC_COMPILE_FLAGS_APPEND\", \"--gcc-install-dir=${GCC_INSTALL_DIR}\")
setenv(\"HIPCC_LINK_FLAGS_APPEND\",    \"--gcc-install-dir=${GCC_INSTALL_DIR}\")
setenv(\"CCC_OVERRIDE_OPTIONS\",       \"+--gcc-install-dir=${GCC_INSTALL_DIR}\")"
else
   echo "[therock] WARNING: no working host g++/GCC install dir found (g++ missing or libstdc++-devel absent);" >&2
   echo "[therock]          HIPCC_*_FLAGS_APPEND will NOT be pinned -- HIP C++ builds may pick the wrong libc++." >&2
   HIPCC_TCL_LINES="# host GCC install dir not detected -- HIPCC_*_FLAGS_APPEND intentionally unset"
   HIPCC_LUA_LINES="-- host GCC install dir not detected -- HIPCC_*_FLAGS_APPEND intentionally unset"
fi

if [ "${CRAY_SYSTEM}" = "1" ]; then
# ---- Cray Tcl modulefile (classic environment-modules) ----
${SUDO} tee "${MODULE_FILE}" >/dev/null <<EOF
#%Module
#
# ROCm ${ROCM_NUMERIC} (TheRock source) -- Tcl modulefile.
# Source: TheRock tarball ${ACTUAL_VERSION} (release therock-${THEROCK_RELEASE}), family ${AMDGPU_FAMILY}
# SDK numeric: ${ROCM_NUMERIC} (.info/version) -> ROCM_PATH=${INSTALL_DIR}
# Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})

conflict rocm

module-whatis "ROCm ${ROCM_NUMERIC} (TheRock source, tarball ${ACTUAL_VERSION})"

set base  ${INSTALL_DIR}

setenv ROCM_PATH               \$base
setenv HSA_NO_SCRATCH_RECLAIM  1
${HIPCC_TCL_LINES}

prepend-path LD_LIBRARY_PATH    \$base/lib
prepend-path C_INCLUDE_PATH     \$base/include
prepend-path CPLUS_INCLUDE_PATH \$base/include
prepend-path CPATH              \$base/include
prepend-path INCLUDE            \$base/include
prepend-path PATH               \$base/bin
# rocprof-sys-run wrapper (libbfd LD_PRELOAD workaround; no-op when unneeded)
prepend-path PATH               \$base/share/rocprofiler-systems/bin

# Expose the per-package and rocmplus modulefile trees (self-locating: this
# file is at <module-root>/base/rocm/therock-<rel>, so three dirname's give
# the module-root that holds rocm-therock-<numeric>/ and rocmplus-...).
set _self    [file normalize \${ModulesCurrentModulefile}]
set _modroot [file dirname [file dirname [file dirname \$_self]]]
prepend-path MODULEPATH \$_modroot/rocm-${ROCM_NUMERIC}
prepend-path MODULEPATH \$_modroot/rocmplus-${ROCM_NUMERIC}
EOF
else
# ---- Lmod .lua modulefile ----
${SUDO} tee "${MODULE_FILE}" >/dev/null <<EOF
whatis("Name: ROCm")
whatis("Version: ${ROCM_NUMERIC}")
whatis("Category: AMD")
whatis("ROCm")
whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")
whatis("Source: TheRock release therock-${THEROCK_RELEASE} (tarball ${ACTUAL_VERSION}, family ${AMDGPU_FAMILY})")
whatis("SDK numeric: ${ROCM_NUMERIC} (from .info/version) -> ROCM_PATH=${INSTALL_DIR}")
whatis("Built by: ${LEAF_SCRIPT_NAME}@${LEAF_SCRIPT_COMMIT:0:12} (${LEAF_SCRIPT_DIRTY})")

local base  = "${INSTALL_DIR}"
local mbase = "${TOP_MODULE_PATH}"

prepend_path("LD_LIBRARY_PATH",    pathJoin(base, "lib"))
prepend_path("C_INCLUDE_PATH",     pathJoin(base, "include"))
prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
prepend_path("CPATH",              pathJoin(base, "include"))
prepend_path("PATH",               pathJoin(base, "bin"))
prepend_path("INCLUDE",            pathJoin(base, "include"))
setenv("HSA_NO_SCRATCH_RECLAIM", "1")
${HIPCC_LUA_LINES}
setenv("ROCM_PATH", base)
prepend_path("MODULEPATH", pathJoin(mbase, "rocm-${ROCM_NUMERIC}"))
prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-${ROCM_NUMERIC}"))
family("GPUSDK")

-- Place the rocprof-sys-run wrapper (which applies a libbfd LD_PRELOAD
-- workaround when the system libbfd is older than the one rocprof-sys
-- statically links) first in PATH. The wrapper is a no-op on systems
-- where the system libbfd is new enough.
prepend_path("PATH", pathJoin(base, "share/rocprofiler-systems/bin"))
EOF
fi
chown_root root:root "${MODULE_FILE}"
${SUDO} chmod 644 "${MODULE_FILE}"

# ---------------- Phase 5b: per-package secondary modulefiles ---------
# Mirror what the regular numeric pipeline emits via deploy_module_package.sh
# (amdclang / hipfort / opencl modulefiles under the rocm-therock-<ROCM>/
# MODULEPATH prepended above). The helper feature-gates each emission on
# disk presence (TheRock tarballs vary in what components ship).
echo "============================================================"
echo "  Phase 5b: per-package modulefiles under ${TOP_MODULE_PATH}/rocm-${ROCM_NUMERIC}/"
echo "============================================================"
# shellcheck source=bare_system/leaf_modulefile_helpers.sh
source "$(dirname "${LEAF_SCRIPT_PATH}")/leaf_modulefile_helpers.sh"
emit_per_package_modulefiles \
   "${TOP_MODULE_PATH}/rocm-${ROCM_NUMERIC}" \
   "${ROCM_NUMERIC}" \
   "rocm/${ROCM_NUMERIC}" \
   "${INSTALL_DIR}" \
   "${LEAF_SCRIPT_NAME}" \
   "${LEAF_SCRIPT_COMMIT:0:12}" \
   "${LEAF_SCRIPT_DIRTY}"

# ---------------- Phase 5c: rocm-<ver>.pc + Cray PrgEnv ecosystem -----
# The pkg-config file is generically useful and harmless, so emit it for every
# install. The PrgEnv-amd-new ecosystem (which wires PKG_CONFIG_PATH at it and
# exposes the craype cc/CC/ftn wrappers against this SDK) is Cray-only.
echo "============================================================"
echo "  Phase 5c: pkg-config file + (Cray) PrgEnv-amd-new ecosystem"
echo "============================================================"
emit_rocm_pc "${INSTALL_DIR}" "${ROCM_NUMERIC}"

if [ "${CRAY_SYSTEM}" = "1" ]; then
   # Resolve the stock PrgEnv-amd version to wrap (override: --pe-version).
   if [ -z "${PE_VERSION}" ]; then
      if [ -d /opt/cray/pe/modulefiles/PrgEnv-amd ]; then
         PE_VERSION=$(ls -1 /opt/cray/pe/modulefiles/PrgEnv-amd 2>/dev/null \
                      | grep -E '^[0-9]+\.' | sort -V | tail -n1)
      fi
      if [ -z "${PE_VERSION}" ] && command -v module >/dev/null 2>&1; then
         PE_VERSION=$(module -t avail PrgEnv-amd 2>&1 \
                      | grep -oE 'PrgEnv-amd/[0-9][^ ]*' \
                      | sed 's#PrgEnv-amd/##' | sort -V | tail -n1)
      fi
   fi
   if [ -z "${PE_VERSION}" ]; then
      echo "WARNING: could not auto-detect a stock PrgEnv-amd version; skipping"
      echo "         the PrgEnv-amd-new ecosystem. Re-run with --pe-version VER."
   else
      echo "  PrgEnv-amd version to wrap: ${PE_VERSION}"
      emit_cray_prgenv_ecosystem \
         "${TOP_MODULE_PATH}/base" \
         "${TOP_MODULE_PATH}/rocm-${ROCM_NUMERIC}" \
         "${TOP_MODULE_PATH}/rocmplus-${ROCM_NUMERIC}" \
         "${ROCM_NUMERIC}" \
         "${INSTALL_DIR}" \
         "${PE_VERSION}" \
         "${LEAF_SCRIPT_NAME}" \
         "${LEAF_SCRIPT_COMMIT:0:12}" \
         "${LEAF_SCRIPT_DIRTY}"
      # Build + emit the from-source AMD-LLVM MPICH wrappers that
      # PrgEnv-amd-new/<pe>-${ROCM_NUMERIC} auto-loads (amdflang cannot read
      # cray-mpich's mpi.mod). This is amd-new-specific: PrgEnv-cray-new uses
      # cray-mpich, so skip the (~10-min) build when only cray-new is requested.
      # Non-fatal: skips cleanly if it cannot build.
      case " ${PRGENV_FLAVORS:-amd-new cray-new} " in
         *" amd-new "*|*" PrgEnv-amd-new "*)
            build_and_emit_mpich_wrappers \
               "${TOP_MODULE_PATH}/rocmplus-${ROCM_NUMERIC}" \
               "${ROCM_NUMERIC}" \
               "${INSTALL_DIR}" \
               "${INSTALL_DIR}/mpich-wrappers" \
               "${LEAF_SCRIPT_NAME}" \
               "${LEAF_SCRIPT_COMMIT:0:12}" \
               "${LEAF_SCRIPT_DIRTY}" ;;
         *)
            echo "  (PrgEnv-amd-new not requested; skipping mpich-wrappers build -- cray-new uses cray-mpich)" ;;
      esac
      echo "  -> expose with: module use ${TOP_MODULE_PATH}/base"
      echo "  -> then:        module swap PrgEnv-cray PrgEnv-amd-new/${PE_VERSION}-${ROCM_NUMERIC}"
      echo "  -> or (CCE+ROCm): module swap PrgEnv-cray PrgEnv-cray-new/${PE_VERSION}-${ROCM_NUMERIC}"
   fi
fi

# ---------------- world-readable perms (shared install locations) -----
_world_ro=0
case "${WORLD_READABLE}" in
   1) _world_ro=1 ;;
   auto)
      if [ -n "${HOME}" ]; then
         case "${TOP_INSTALL_PATH}" in "${HOME}"/*|"${HOME}") _world_ro=0 ;; *) _world_ro=1 ;; esac
      else
         _world_ro=1
      fi ;;
esac
if [ "${_world_ro}" = "1" ]; then
   make_world_readable \
      "${INSTALL_DIR}" \
      "${TOP_MODULE_PATH}/base" \
      "${TOP_MODULE_PATH}/rocm-${ROCM_NUMERIC}" \
      "${TOP_MODULE_PATH}/rocmplus-${ROCM_NUMERIC}" \
      "${MODULE_FILE}"
fi
unset _world_ro

echo ""
echo "============================================================"
echo "  Done: ROCm ${ROCM_NUMERIC} (TheRock source, release therock-${THEROCK_RELEASE})"
echo "  Install: ${INSTALL_DIR}"
echo "  Module : ${MODULE_FILE}  (loads rocm/${ROCM_NUMERIC},"
echo "                            ROCM_PATH=rocm-${ROCM_NUMERIC})"
echo "============================================================"
