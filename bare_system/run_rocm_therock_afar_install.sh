#!/bin/bash
#
# run_rocm_therock_afar_install.sh - non-interactive extract + module-write
# for a single TheRock-AFAR fused tarball published on the radeon flang/
# site (https://repo.radeon.com/rocm/misc/flang/).
#
# TheRock-AFAR drops are pre-built ROCm SDK trees co-published with the
# AFAR compiler drops. They are distinct from BOTH of:
#   * AFAR proper          (rocm-afar-<BUILD>-drop-<REL>-<DISTRO>.tar.bz2)
#                          - handled by run_rocm_afar_install.sh
#   * TheRock proper       (therock-dist-linux-<FAMILY>-<NUMERIC>.tar.gz
#                          at rocm.nightlies.amd.com/tarball-multi-arch/)
#                          - handled by run_rocm_therock_install.sh
#                          - this channel is partially-implemented; legacy
#                            URL_BASE (repo.amd.com/rocm/tarball) is dead
#                            for the 7.13.x line as of 2026-05.
#
# TheRock-AFAR tarball naming on the radeon flang/ site:
#   therock-afar-<REL>-<FAMILY>-<NUMERIC>-<SHA8>.tar.bz2
# Example (live as of 2026-05-15):
#   therock-afar-23.2.1-gfx94X-7.13.0-7357b5084b.tar.bz2  (3.5 GiB)
#   therock-afar-23.2.1-gfx90a-7.13.0-7357b5084b.tar.bz2
#   ...etc for gfx103X, gfx110X, gfx1150, gfx1151, gfx120X, gfx950.
#
# Naming-scheme decisions (unified flang-site naming, 2026-05-26):
#   * Token shape passed in by the sweep / operator:   therock-afar-<REL>
#                                                       (e.g. therock-afar-23.2.1)
#     The `--therock-afar-release` flag accepts the bare <REL> (e.g. 23.2.1)
#     OR the prefixed form (the helper strips the `therock-afar-` prefix).
#   * Upstream filename shape:                          (therock-afar|therock)-<REL>-<FAMILY>-<NUMERIC>-<SHA>.tar.bz2
#     The "afar" infix is optional in the upstream filename -- the 23.1.x
#     line on the flang/ listing publishes `therock-<REL>-...` (without
#     the infix) while the 23.2.x line publishes `therock-afar-<REL>-...`.
#     Phase 1 below tries the "afar"-infix shape first, then falls back
#     to the bare shape for the same <REL>.
#   * Install dir:                                      rocm-afar-<REL>
#                                                       (e.g. rocm-afar-23.2.1)
#     -- keyed on the compiler/AFAR release tag (NOT the SDK numeric).
#     This is the UNIFIED naming shared with the AFAR-proper channel
#     (run_rocm_afar_install.sh), so a single `rocm-afar-<N>` namespace
#     covers both `afar-<N>` and `therock-afar-<N>` tokens.
#   * Modulefile basename:                              afar-<REL>-<NUMERIC>.lua
#                                                       (e.g. afar-23.2.1-7.13.0.lua)
#     -- loaded as `module load rocm/afar-23.2.1-7.13.0`. Embeds BOTH the
#     compiler release tag AND the SDK numeric (from .info/version).
#   * Per-package rocmplus tree (downstream packages):  rocmplus-afar-<NUMERIC>
#                                                       (e.g. rocmplus-afar-7.13.0)
#     -- numeric-keyed, shared with the AFAR-proper channel; rocmplus
#     modules built against ROCm 7.13.0 work for any flang-site drop
#     that reports `.info/version == 7.13.0` regardless of which
#     compiler release tag it carries.
#
# Phases:
#   0. Pre-check: skip cleanly (exit 0) if BOTH the install dir
#      (rocm-afar-<REL>) AND any matching afar-<REL>-*.lua modulefile
#      already exist and --replace-existing is not set. The install dir
#      basename is known at Phase 0 (it's keyed on the user-supplied
#      release tag, NOT on the SDK numeric which is only learned in
#      Phase 3), so this is a literal -d check; the modulefile side
#      uses a glob because ROCM_NUMERIC is not yet known.
#   1. Tarball URL discovery: scrape the flang/ listing for the matching
#      filename. Two filename shapes are accepted for the same <REL>:
#        (a) therock-afar-<REL>-<FAMILY>-<NUMERIC>-<SHA>.tar.bz2
#        (b) therock-<REL>-<FAMILY>-<NUMERIC>-<SHA>.tar.bz2
#      Shape (a) wins when both exist; (b) is the fallback (used by the
#      23.1.x line on the flang listing).
#      TWO directories are scanned, in order: the public listing
#        https://repo.radeon.com/rocm/misc/flang/
#      first, then the HIDDEN pre-release / release-candidate subdir
#        https://repo.radeon.com/rocm/misc/flang/.pre/
#      The .pre/ subdir is not linked from the public index, so RC drops
#      (e.g. therock-afar-23.3.0, RC'd 2026-06) are invisible there until
#      AMD promotes them; checking the public dir first means a promoted
#      GA drop always wins over a lingering .pre/ copy. The download URL
#      below is built from whichever directory the match was found in.
#      AMDGPU_FAMILY is derived from the FIRST gfx model in
#      AMDGPU_GFXMODEL (per operator decision 2026-05-15) unless
#      --amdgpu-family was passed explicitly. The script's
#      gfx_to_family() table maps the common per-model gfx IDs to the
#      family-segment AMD uses in the filename (e.g. gfx942 -> gfx94X,
#      gfx1100 -> gfx110X).
#   2. wget the tarball to /tmp, sudo tar -xjpf into a staging dir
#      under ${TOP_INSTALL_PATH}/. Both wrapper-segment and flat layouts
#      are accepted by Phase 3; we don't pin a specific top-level
#      directory name in the tarball.
#   3. Read .info/version (at depth 0 OR a single wrapper subdir of
#      depth 1) -> ROCM_NUMERIC. Finalize MODULE_FILE.
#   4. Move the .info/version-bearing dir to the final
#      ${TOP_INSTALL_PATH}/rocm-afar-${THEROCK_AFAR_RELEASE}.
#   5. Emit ${TOP_MODULE_PATH}/base/rocm/afar-${REL}-${ROCM_NUMERIC}.lua
#      matching the GPUSDK-shaped modulefile schema (same family("GPUSDK")
#      + MODULEPATH-prepend pattern as run_rocm_afar_install.sh, with
#      rocm-afar-<REL> + rocmplus-afar-<NUMERIC> prepends).

set -eo pipefail

# Capture this script's absolute path BEFORE any cd so the modulefile's
# whatis() provenance line below can git-resolve us even if a downstream
# wget/tar chdir's us out of the repo.
LEAF_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

: ${THEROCK_AFAR_RELEASE:=""}
: ${AMDGPU_GFXMODEL:="gfx942;gfx90a"}
: ${AMDGPU_FAMILY:=""}           # if empty, auto-derived from AMDGPU_GFXMODEL
: ${DISTRO:="ubuntu"}
: ${DISTRO_VERSION:="22.04"}
: ${TOP_INSTALL_PATH:="/nfsapps/opt"}
: ${TOP_MODULE_PATH:="/nfsapps/modules"}
: ${REPLACE_EXISTING:="0"}
: ${KEEP_FAILED_INSTALLS:="0"}
: ${URL_BASE:="https://repo.radeon.com/rocm/misc/flang"}
# Phase 6 (rocm_patches.sh) controls -- mirror the numeric branch's
# run_rocm_build.sh:31 SKIP_PATCHES default of 0 (run patches by default).
# PATCHES_LOG is finalized after THEROCK_AFAR_RELEASE is parsed below so
# the on-disk filename reflects the actual release.
: ${SKIP_PATCHES:="0"}
PATCHES_LOG=""

usage() {
   cat <<EOF
Usage: $0 [opts]
  --therock-afar-release VER    TheRock-AFAR release tag (e.g. 23.2.1, or the
                                fully-prefixed form therock-afar-23.2.1). REQUIRED.
  --amdgpu-gfxmodel GFX         semi-colon- or comma-separated gfx model list
                                (e.g. "gfx942;gfx90a"). The FIRST entry drives
                                the upstream filename's family segment.
                                Default ${AMDGPU_GFXMODEL}.
  --amdgpu-family FAM           explicit override of the family segment in the
                                upstream filename (e.g. gfx94X, gfx110X, gfx90a).
                                Skips the gfx_to_family() auto-derivation if set.
                                Default: empty (auto-derive from --amdgpu-gfxmodel).
  --distro NAME                 default ${DISTRO}  (informational only -- the
                                TheRock-AFAR URL has no distro-version segment)
  --distro-version VER          default ${DISTRO_VERSION}  (informational only)
  --top-install-path PATH       SDK extract destination; default ${TOP_INSTALL_PATH}
  --top-module-path  PATH       Lmod root for modulefile; default ${TOP_MODULE_PATH}
  --url-base URL                tarball listing base; default ${URL_BASE}
  --replace-existing 0|1        overwrite existing rocm-afar-<REL> install
                                + afar-<REL>-*.lua modulefile (default ${REPLACE_EXISTING}).
                                Also reaps legacy rocm-therock-afar-* dirs +
                                therock-afar-<REL>.lua modulefiles from the
                                pre-unified-naming layout.
  --keep-failed-installs 0|1    on failure, keep partial install + modulefile
                                for post-mortem (default ${KEEP_FAILED_INSTALLS})
  --skip-patches 0|1            skip Phase 6 (rocm_patches.sh on the TheRock-AFAR
                                tree; mirrors run_rocm_build.sh's --skip-patches).
                                Default ${SKIP_PATCHES} (run patches).
  --patches-log PATH            log file for the Phase 6 rocm_patches.sh tee;
                                default patches_afar-\${THEROCK_AFAR_RELEASE}.out
  --help
EOF
   exit 1
}

send-error() { usage; echo -e "\nError: ${@}" >&2; exit 1; }
reset-last() { last() { send-error "Unsupported argument :: ${1}"; }; }

n=0
while [[ $# -gt 0 ]]; do
   case "${1}" in
      "--therock-afar-release") shift; THEROCK_AFAR_RELEASE=${1}; reset-last ;;
      "--amdgpu-gfxmodel")      shift; AMDGPU_GFXMODEL=${1};      reset-last ;;
      "--amdgpu-family")        shift; AMDGPU_FAMILY=${1};        reset-last ;;
      "--distro")               shift; DISTRO=${1};               reset-last ;;
      "--distro-version")       shift; DISTRO_VERSION=${1};       reset-last ;;
      "--top-install-path")     shift; TOP_INSTALL_PATH=${1};     reset-last ;;
      "--top-module-path")      shift; TOP_MODULE_PATH=${1};      reset-last ;;
      "--url-base")             shift; URL_BASE=${1};             reset-last ;;
      "--replace-existing")     shift; REPLACE_EXISTING=${1};     reset-last ;;
      "--keep-failed-installs") shift; KEEP_FAILED_INSTALLS=${1}; reset-last ;;
      "--skip-patches")         shift; SKIP_PATCHES=${1};         reset-last ;;
      "--patches-log")          shift; PATCHES_LOG=${1};          reset-last ;;
      "--help"|"-h")            usage ;;
      *)                        last ${1} ;;
   esac
   n=$((n + 1))
   shift
done

[[ -z "${THEROCK_AFAR_RELEASE}" ]] && send-error "--therock-afar-release is required"
# Tolerate `therock-afar-` prefix in the input value (e.g. operator
# copy-pastes the full token straight in).
THEROCK_AFAR_RELEASE="${THEROCK_AFAR_RELEASE#therock-afar-}"
# Strict X.Y or X.Y.Z form -- anything else propagates into URL + dir +
# module names, so loose parsing here would produce confusing errors.
if [[ ! "${THEROCK_AFAR_RELEASE}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
   send-error "--therock-afar-release must be X.Y or X.Y.Z (got '${THEROCK_AFAR_RELEASE}')"
fi

# Phase 6 default log basename. Set AFTER THEROCK_AFAR_RELEASE is parsed
# + sanitized so the filename reflects the actual release. An explicit
# --patches-log on the command line still wins (the parse loop set
# PATCHES_LOG to that value, which short-circuits the default below).
: ${PATCHES_LOG:="patches_afar-${THEROCK_AFAR_RELEASE}.out"}

# ---------------- gfx-model -> family mapping -------------------------
# Maps a per-model gfx ID (what `rocminfo` reports, e.g. gfx942) to the
# family segment AMD uses in the upstream tarball filename
# (e.g. gfx94X). Built from the observed naming on
# https://repo.radeon.com/rocm/misc/flang/ (2026-05-15 snapshot):
#   therock-afar-23.2.1-gfx94X-...     (covers gfx940/gfx941/gfx942)
#   therock-afar-23.2.1-gfx103X-...    (covers gfx1030..gfx1036)
#   therock-afar-23.2.1-gfx110X-...    (covers gfx1100..gfx1103)
#   therock-afar-23.2.1-gfx120X-...    (covers gfx1200/gfx1201)
#   therock-afar-23.2.1-gfx90a-...     (singular)
#   therock-afar-23.2.1-gfx950-...     (singular -- MI350)
#   therock-afar-23.2.1-gfx1150-...    (singular -- Strix Halo)
#   therock-afar-23.2.1-gfx1151-...    (singular)
# Unknown forms pass through unchanged; operators can override with
# --amdgpu-family if needed.
gfx_to_family() {
   local _g="$1"
   case "${_g}" in
      gfx940|gfx941|gfx942)                                    echo "gfx94X"  ;;
      gfx1030|gfx1031|gfx1032|gfx1033|gfx1034|gfx1035|gfx1036) echo "gfx103X" ;;
      gfx1100|gfx1101|gfx1102|gfx1103)                         echo "gfx110X" ;;
      gfx1200|gfx1201)                                         echo "gfx120X" ;;
      gfx90a|gfx900|gfx906|gfx908|gfx950|gfx1150|gfx1151|gfx1152|gfx1153) echo "${_g}" ;;
      *)                                                       echo "${_g}"   ;;
   esac
}

if [[ -z "${AMDGPU_FAMILY}" ]]; then
   # First entry in AMDGPU_GFXMODEL drives the family choice. The string
   # may use `;`, `,`, or whitespace as separators; we cut at any of those.
   _first_gfx="${AMDGPU_GFXMODEL%%[;, ]*}"
   _first_gfx="$(echo "${_first_gfx}" | tr -d '[:space:]')"
   if [[ -z "${_first_gfx}" ]]; then
      send-error "could not parse a first gfx model from AMDGPU_GFXMODEL='${AMDGPU_GFXMODEL}'"
   fi
   AMDGPU_FAMILY="$(gfx_to_family "${_first_gfx}")"
   echo "Derived AMDGPU_FAMILY='${AMDGPU_FAMILY}' from AMDGPU_GFXMODEL='${AMDGPU_GFXMODEL}' (first model: '${_first_gfx}')"
   unset _first_gfx
fi

MODULE_DIR="${TOP_MODULE_PATH}/base/rocm"
# Unified flang-site naming: install dir is keyed on the compiler/AFAR
# release number (not the ROCm SDK numeric), and the modulefile basename
# embeds BOTH the release tag and the SDK numeric (afar-<REL>-<ROCM>.lua).
# The install dir is known at Phase 0 (it doesn't depend on .info/version);
# MODULE_FILE is finalized after Phase 3 once ROCM_NUMERIC is known. Phase
# 0 uses a glob match (afar-${REL}-*.lua) to detect any rocm version that
# may have been installed for this THEROCK_AFAR_RELEASE.
INSTALL_DIR="${TOP_INSTALL_PATH}/rocm-afar-${THEROCK_AFAR_RELEASE}"
MODULE_FILE=""   # set after Phase 3

# Legacy paths from the pre-unified-naming scheme are tracked separately
# so --replace-existing 1 can reap them on the migration run.
LEGACY_MODULE_FILE="${MODULE_DIR}/therock-afar-${THEROCK_AFAR_RELEASE}.lua"
LEGACY_INSTALL_GLOB="${TOP_INSTALL_PATH}/rocm-therock-afar-*"

# ---------------- Phase 0: skip-if-installed pre-check ----------------
# Skip only if BOTH the install dir AND a new-shape modulefile
# (afar-${REL}-<rocm>.lua) already exist. If only the install dir is
# present (e.g. a SIGKILL between Phase 4 and Phase 5, OR a legacy
# install before unified naming), fall through and rebuild.
_skip_match=""
if [[ -d "${INSTALL_DIR}" ]]; then
   shopt -s nullglob
   _existing_modules=( "${MODULE_DIR}"/afar-${THEROCK_AFAR_RELEASE}-*.lua )
   shopt -u nullglob
   [[ ${#_existing_modules[@]} -gt 0 ]] && _skip_match="${INSTALL_DIR} + ${_existing_modules[0]}"
   unset _existing_modules
fi
if [[ -n "${_skip_match}" && "${REPLACE_EXISTING}" != "1" ]]; then
   echo "[$(date)] SKIP therock-afar-${THEROCK_AFAR_RELEASE}: ${_skip_match} already exist"
   echo "         Pass --replace-existing 1 to re-download + re-extract."
   exit 0
fi
unset _skip_match

# ---------------- Defensive remount of /nfsapps as rw -----------------
# Identical to run_rocm_afar_install.sh:117-125 -- /etc/exports.d/
# nfsapps_sh5_rw.exports grants rw to sh5 admin nodes, but the
# warewulf-managed fstab still mounts /nfsapps ro by default. Skipped
# unless TOP_INSTALL_PATH actually lives under /nfsapps.
case "${TOP_INSTALL_PATH}" in
   /nfsapps|/nfsapps/*)
      NFS_MOUNT_ROOT="/nfsapps"
      if ! sudo -n test -w "${NFS_MOUNT_ROOT}" 2>/dev/null; then
         echo "Attempting to remount ${NFS_MOUNT_ROOT} rw..."
         sudo mount -o remount,rw "${NFS_MOUNT_ROOT}" 2>/dev/null || true
      fi
      if ! sudo -n test -w "${NFS_MOUNT_ROOT}" 2>/dev/null; then
         echo "ERROR: ${NFS_MOUNT_ROOT} is not writable on $(hostname); aborting." >&2
         mount | grep nfsapps || true
         exit 1
      fi
      ;;
esac

# Self-heal install/module roots if missing.
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}" "${MODULE_DIR}"; do
   if ! sudo -n test -d "${d}" 2>/dev/null; then
      echo "Creating missing ${d} (with parents)"
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

# ---------------- Phase 1: tarball URL discovery ----------------------
# Scrape the radeon flang/ Apache directory listing. The page is plain
# HTML with href= the bare filename; a single grep against the body
# works the same way it does for run_rocm_afar_install.sh's
# AFAR_NUMBER discovery (this script's sibling installer).
#
# The expected filename shape is:
#   therock-afar-<REL>-<FAMILY>-<NUMERIC>-<SHA8>.tar.bz2
# SHA is the abbreviated commit hash, length-variable (observed 8 chars
# on 23.2.1 builds -- 7357b5084b -- but use a generous [a-f0-9]{4,}
# pattern in case AMD shortens or lengthens it).
echo "============================================================"
echo "  Phase 1: discover TheRock-AFAR tarball at ${URL_BASE}/ (then .pre/)"
echo "============================================================"
# Filename pattern (regex). Per the unified-naming spec (2026-05-26), the
# upstream flang/ listing carries TWO equivalent shapes for the same REL:
#   therock-afar-<REL>-<FAMILY>-<X.Y.Z>-<SHA>.tar.bz2   (23.2.x line)
#   therock-<REL>-<FAMILY>-<X.Y.Z>-<SHA>.tar.bz2        (23.1.x line; no "afar" infix)
# We don't pin <X.Y.Z> in the regex (only the operator-supplied REL +
# FAMILY) so AMD reposts (different SHA + same .info/version) auto-pick
# the latest. Preference order when BOTH shapes exist for the same REL:
# the explicit `therock-afar-` form wins (operator named the token with
# the afar infix); fall back to the bare `therock-` form otherwise. This
# lets `therock-afar-23.1.0` reach the existing `therock-23.1.0-*` files
# on the flang site without needing a separate token shape.
_pattern_afar="therock-afar-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-[0-9]+\.[0-9]+(\.[0-9]+)?-[a-f0-9]{4,}\.tar\.bz2"
_pattern_bare="therock-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-[0-9]+\.[0-9]+(\.[0-9]+)?-[a-f0-9]{4,}\.tar\.bz2"

# Search directories, in priority order. Pre-release / release-candidate
# drops (e.g. therock-afar-23.3.0, RC'd 2026-06) land in the HIDDEN .pre/
# subdir FIRST -- it isn't linked from the public flang/ index, so it
# stays invisible to anyone browsing https://repo.radeon.com/rocm/misc/flang/
# until AMD promotes it to the top-level listing. We therefore check the
# public dir first (so promoted/GA drops win) and fall back to .pre/ for
# RCs. The directory where the match is found drives the download URL
# below (a .pre/ match must wget from .pre/, not the public root).
# NOTE: trailing slash is required on each entry -- Apache directory
# listings 301-redirect a dir request without it, and curl -fsSL would
# need --location; keeping the slash avoids the round-trip.
_search_dirs=( "${URL_BASE}/" "${URL_BASE}/.pre/" )

# `|| true` is REQUIRED on each discovery pipeline: this script runs under
# `set -eo pipefail` (see top of file), so a grep that finds nothing returns
# 1, pipefail propagates that to the command substitution, errexit kills the
# script silently, and the operator never sees the "no tarball matching..."
# diagnostic block below. The 23.1.x line on the flang/ listing publishes
# ONLY the bare `therock-<REL>-...` shape (no afar infix), so the afar
# pipeline MUST be allowed to return empty so the bare pipeline gets a
# chance. Discovered 2026-05-26 via job 10698 (therock-afar-23.1.0 FAIL).
_matched=""
_matched_shape=""
EFFECTIVE_URL_DIR=""
for _dir in "${_search_dirs[@]}"; do
   echo "  scanning ${_dir}"
   _listing="$(curl -fsSL --max-time 60 "${_dir}" 2>/dev/null || true)"
   if [[ -z "${_listing}" ]]; then
      echo "  (no directory listing at ${_dir}; skipping)"
      continue
   fi
   # afar-infix shape first ...
   _cand=$(echo "${_listing}" | grep -oE "${_pattern_afar}" | sort -V -u | tail -n1 || true)
   if [[ -n "${_cand}" ]]; then
      _matched="${_cand}"; _matched_shape="therock-afar"; EFFECTIVE_URL_DIR="${_dir}"
      break
   fi
   # ... then the bare `therock-<REL>-...` fallback. grep -v excludes
   # anything matching the afar-infix shape so we don't double-count
   # (greedy regex protection). Brace group + `|| true` on the whole
   # pipeline (not just `tail`) so pipefail from the inner greps doesn't
   # trip errexit on no-match.
   _cand=$( { echo "${_listing}" \
      | grep -oE "${_pattern_bare}" \
      | grep -v -E "^therock-afar-" \
      | sort -V -u | tail -n1; } || true)
   if [[ -n "${_cand}" ]]; then
      _matched="${_cand}"; _matched_shape="therock"; EFFECTIVE_URL_DIR="${_dir}"
      break
   fi
done
unset _cand _dir
if [[ -z "${_matched}" ]]; then
   echo "ERROR: no tarball matching 'therock-afar-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-*.tar.bz2'" >&2
   echo "       or 'therock-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-*.tar.bz2' in any of:" >&2
   for _dir in "${_search_dirs[@]}"; do echo "         ${_dir}" >&2; done
   echo "       Verify the release tag + gfx-family combination exists upstream." >&2
   echo "       Available therock[-afar]-${THEROCK_AFAR_RELEASE} families on the listings:" >&2
   for _dir in "${_search_dirs[@]}"; do
      curl -fsSL --max-time 60 "${_dir}" 2>/dev/null \
         | grep -oE "therock(-afar)?-${THEROCK_AFAR_RELEASE}-gfx[A-Za-z0-9]+-[0-9.]+-[a-f0-9]+\.tar\.bz2" \
         | sed "s|^|         ${_dir} |" >&2 || true
   done
   unset _dir
   exit 1
fi
echo "Matched upstream filename shape: ${_matched_shape}-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-...tar.bz2"
echo "Found in directory: ${EFFECTIVE_URL_DIR}"

# EFFECTIVE_URL_DIR already carries a trailing slash (public root or
# .pre/), so just concatenate the matched filename.
TARBALL_URL="${EFFECTIVE_URL_DIR}${_matched}"
LOCAL_TARBALL="/tmp/${_matched}"
# Parse expected NUMERIC + SHA from the chosen filename (we'll
# cross-check against .info/version after extract in Phase 3). The sed
# pattern uses _matched_shape so the prefix segment matches whatever we
# actually selected above.
EXPECTED_NUMERIC="$(echo "${_matched}" \
   | sed -E "s|^${_matched_shape}-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-([0-9]+\.[0-9]+(\.[0-9]+)?)-[a-f0-9]+\.tar\.bz2$|\1|")"
THEROCK_SHA="$(echo "${_matched}" \
   | sed -E "s|^${_matched_shape}-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-[0-9]+\.[0-9]+(\.[0-9]+)?-([a-f0-9]+)\.tar\.bz2$|\2|")"

# Staging dir lives next to the final install dir so the Phase 4 mv is
# rename-only (same filesystem == atomic, no NFS cross-mount copy). Keyed
# on the THEROCK_AFAR_RELEASE so two parallel sweeps of different
# releases can't collide on the staging name.
STAGING_DIR="${TOP_INSTALL_PATH}/rocm-afar-${THEROCK_AFAR_RELEASE}.staging.$$"

echo ""
echo "============================================================"
echo "  TheRock-AFAR install plan"
echo "============================================================"
echo "  THEROCK_AFAR_RELEASE : ${THEROCK_AFAR_RELEASE}"
echo "  AMDGPU_GFXMODEL      : ${AMDGPU_GFXMODEL}  (informational; only first model drives family)"
echo "  AMDGPU_FAMILY        : ${AMDGPU_FAMILY}"
echo "  Filename shape       : ${_matched_shape}-<REL>-<FAMILY>-<NUMERIC>-<SHA>.tar.bz2"
echo "  Expected NUMERIC     : ${EXPECTED_NUMERIC}"
echo "  Upstream SHA prefix  : ${THEROCK_SHA}"
echo "  Found in dir         : ${EFFECTIVE_URL_DIR}$([[ "${EFFECTIVE_URL_DIR}" == */.pre/ ]] && echo '  (pre-release / RC channel)')"
echo "  Tarball URL          : ${TARBALL_URL}"
echo "  Local tarball        : ${LOCAL_TARBALL}"
echo "  Staging dir          : ${STAGING_DIR}"
echo "  Module file          : (set after Phase 3, shape afar-${THEROCK_AFAR_RELEASE}-<rocm>.lua)"
echo "  Install dir          : ${INSTALL_DIR}"
echo "  REPLACE_EXISTING     : ${REPLACE_EXISTING}"
echo "  KEEP_FAILED_INSTALLS : ${KEEP_FAILED_INSTALLS}"
echo "============================================================"
echo ""

# ---------------- --replace-existing cleanup --------------------------
# Runs AFTER URL discovery so we don't blow away an existing install for
# a release that doesn't actually exist upstream. Reap BOTH the legacy
# layout (rocm-therock-afar-* install dirs + therock-afar-<REL>.lua
# modulefile) AND the new unified layout (rocm-afar-<REL> install dir +
# any afar-<REL>-*.lua modulefile glob), so a single --replace-existing
# 1 cleanly migrates an in-place legacy install.
if [[ "${REPLACE_EXISTING}" == "1" ]]; then
   shopt -s nullglob
   for _cand in ${LEGACY_INSTALL_GLOB}; do
      if [[ -d "${_cand}" ]]; then
         echo "[--replace-existing 1] removing legacy ${_cand}"
         sudo rm -rf "${_cand}"
      fi
   done
   if [[ -d "${INSTALL_DIR}" ]]; then
      echo "[--replace-existing 1] removing ${INSTALL_DIR}"
      sudo rm -rf "${INSTALL_DIR}"
   fi
   if [[ -f "${LEGACY_MODULE_FILE}" ]]; then
      echo "[--replace-existing 1] removing legacy ${LEGACY_MODULE_FILE}"
      sudo rm -f "${LEGACY_MODULE_FILE}"
   fi
   for _stale in "${MODULE_DIR}"/afar-${THEROCK_AFAR_RELEASE}-*.lua; do
      echo "[--replace-existing 1] removing ${_stale}"
      sudo rm -f "${_stale}"
   done
   shopt -u nullglob
   unset _cand _stale
fi

# ---------------- EXIT-trap fail-cleanup ------------------------------
# Mirrors run_rocm_therock_install.sh:330-344: on non-zero exit blow away
# the staging dir + (if promoted) the partial install dir + modulefile
# so the next run starts clean. INSTALL_DIR is set after Phase 4 -- the
# guard with -n no-ops when unset.
# PROMOTED_INSTALL tracks whether Phase 4 has run (and thus whether
# INSTALL_DIR is a real on-disk install we should rm on failure). Phase
# 0's early-bail sets it to 0; Phase 4 sets it to 1 after the mv.
PROMOTED_INSTALL=0
_therock_afar_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[therock-afar fail-cleanup] rc=${rc}: removing staging + partial install"
      sudo rm -rf "${STAGING_DIR}" 2>/dev/null || true
      [ "${PROMOTED_INSTALL}" = "1" ] && sudo rm -rf "${INSTALL_DIR}" 2>/dev/null || true
      [ -n "${MODULE_FILE}" ] && sudo rm -f "${MODULE_FILE}" 2>/dev/null || true
   elif [ ${rc} -ne 0 ]; then
      echo "[therock-afar fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Always reap the local tarball -- it's regenerated next run.
   rm -f "${LOCAL_TARBALL}" 2>/dev/null || true
   return ${rc}
}
trap _therock_afar_on_exit EXIT

# ---------------- Phase 2: download + extract -------------------------
echo "============================================================"
echo "  Phase 2: wget + tar -xjpf -> ${STAGING_DIR}"
echo "============================================================"
rm -f "${LOCAL_TARBALL}"
wget -q --show-progress "${TARBALL_URL}" -O "${LOCAL_TARBALL}"

# Staging dir under TOP_INSTALL_PATH so the final mv in Phase 4 is
# rename-only (same filesystem == atomic, no NFS cross-mount copy).
sudo rm -rf "${STAGING_DIR}"
sudo install -d -o root -g root -m 0755 "${STAGING_DIR}"
sudo tar -xjpf "${LOCAL_TARBALL}" -C "${STAGING_DIR}"
echo "Extracted into staging: ${STAGING_DIR}"

# ---------------- Phase 3: locate .info/version + derive ROCM_NUMERIC -
# Two valid extracted layouts:
#   (a) FLAT  -- .info/version is at depth 0 of STAGING_DIR.
#   (b) WRAPPER -- the tarball has a single top-level subdir (the
#                 "wrapper") whose .info/version is at depth 1.
# AFAR proper is layout (b); TheRock proper (the run_rocm_therock_install.sh
# path) is (a). We probe both shapes so neither is hardcoded.
echo "============================================================"
echo "  Phase 3: locate .info/version + derive ROCM_NUMERIC"
echo "============================================================"

SOURCE_DIR=""
WRAPPER=""
if sudo test -f "${STAGING_DIR}/.info/version" 2>/dev/null; then
   SOURCE_DIR="${STAGING_DIR}"
   echo "Tarball layout: FLAT (.info/version at depth 0)"
else
   # Look for a single top-level subdir whose .info/version exists.
   _wrappers=()
   while IFS= read -r -d $'\0' _d; do _wrappers+=("${_d}"); done \
      < <(sudo find "${STAGING_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
   if [[ ${#_wrappers[@]} -eq 1 ]] && sudo test -f "${_wrappers[0]}/.info/version" 2>/dev/null; then
      SOURCE_DIR="${_wrappers[0]}"
      WRAPPER="${_wrappers[0]##*/}"
      echo "Tarball layout: WRAPPER (.info/version inside wrapper dir '${WRAPPER}')"
   fi
   unset _wrappers _d
fi
if [[ -z "${SOURCE_DIR}" ]]; then
   echo "ERROR: could not find .info/version at depth 0 or 1 of ${STAGING_DIR}" >&2
   echo "       (Did the TheRock-AFAR tarball layout change?)" >&2
   sudo find "${STAGING_DIR}" -maxdepth 2 -type f -name version -printf '       found: %p\n' 2>/dev/null || true
   sudo ls -la "${STAGING_DIR}" 2>&1 | sed 's/^/       /' || true
   exit 1
fi

ROCM_NUMERIC=$(sudo cut -f1 -d- "${SOURCE_DIR}/.info/version" 2>/dev/null || true)
if [[ -z "${ROCM_NUMERIC}" ]]; then
   echo "ERROR: ${SOURCE_DIR}/.info/version is empty or unreadable" >&2
   exit 1
fi
echo "ROCM_NUMERIC (from .info/version): ${ROCM_NUMERIC}"

# Sanity-check against filename-embedded version.
if [[ "${EXPECTED_NUMERIC}" != "${ROCM_NUMERIC}" ]]; then
   echo "NOTE: tarball-filename version (${EXPECTED_NUMERIC}) differs from"
   echo "      .info/version (${ROCM_NUMERIC}); modulefile name will use"
   echo "      the .info/version-derived form (afar-${THEROCK_AFAR_RELEASE}-${ROCM_NUMERIC}.lua)."
fi

# Finalize MODULE_FILE now that ROCM_NUMERIC is known. INSTALL_DIR was
# set at the top of the script (keyed on THEROCK_AFAR_RELEASE, not on
# ROCM_NUMERIC) per the unified flang-site naming.
MODULE_FILE="${MODULE_DIR}/afar-${THEROCK_AFAR_RELEASE}-${ROCM_NUMERIC}.lua"

# ---------------- Phase 4: promote staging to final install dir -------
echo "============================================================"
echo "  Phase 4: promote -> ${INSTALL_DIR}"
echo "============================================================"

if [[ -d "${INSTALL_DIR}" ]]; then
   if [[ "${REPLACE_EXISTING}" == "1" ]]; then
      echo "[--replace-existing 1] removing pre-existing ${INSTALL_DIR}"
      sudo rm -rf "${INSTALL_DIR}"
   else
      echo "ERROR: ${INSTALL_DIR} already exists but --replace-existing is 0;" >&2
      echo "       Phase 0 should have caught this. Pass --replace-existing 1" >&2
      echo "       or remove the existing install manually." >&2
      exit 1
   fi
fi

if [[ -n "${WRAPPER}" ]]; then
   # Move just the wrapper subtree to the final install dir, then reap
   # the (now-empty) staging container.
   sudo mv "${SOURCE_DIR}" "${INSTALL_DIR}"
   sudo rmdir "${STAGING_DIR}" 2>/dev/null || true
else
   sudo mv "${STAGING_DIR}" "${INSTALL_DIR}"
fi
PROMOTED_INSTALL=1
sudo chown -R root:root "${INSTALL_DIR}"
sudo chmod 755 "${INSTALL_DIR}"
rm -f "${LOCAL_TARBALL}"
echo "Installed: ${INSTALL_DIR}"

# ---------------- Phase 5: emit GPUSDK modulefile ---------------------
# Provenance: git-resolve this leaf script so the modulefile's whatis()
# records the exact commit + dirty/clean state that produced it.
# Identical shape to run_rocm_afar_install.sh:254-269 and
# run_rocm_therock_install.sh:434-447.
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

echo "============================================================"
echo "  Phase 5: write modulefile ${MODULE_FILE}"
echo "============================================================"
sudo mkdir -p "${MODULE_DIR}"

# Modulefile shape matches the unified flang-site naming-scheme decision
# (2026-05-26):
#   * Module basename:   afar-${REL}-${ROCM_NUMERIC}.lua
#                        (compiler/AFAR release tag + SDK numeric, same
#                         shape used by run_rocm_afar_install.sh for the
#                         AFAR-proper channel; loaded as
#                         `module load rocm/afar-<REL>-<ROCM>`)
#   * ROCM_PATH:         ${INSTALL_DIR}  (release-tag-keyed install dir,
#                         e.g. /nfsapps/opt/rocm-afar-23.2.1)
#   * Two MODULEPATH prepends:
#       rocm-afar-${REL}            (release-tag-keyed; per-package
#                                    modules from the SDK side, matches
#                                    install dir basename)
#       rocmplus-afar-${REL}-${ROCM_NUMERIC}
#                                   (compiler-AND-rocm-keyed rocmplus
#                                   stack, matches the AFAR-proper
#                                   modulefile shape; two flang-site
#                                   drops with different compiler
#                                   release tags can't collide on the
#                                   rocmplus side even if they happen
#                                   to ship the same SDK numeric).
sudo tee "${MODULE_FILE}" >/dev/null <<EOF
whatis("Name: ROCm")
whatis("Version: afar-${THEROCK_AFAR_RELEASE}-${ROCM_NUMERIC}")
whatis("Category: AMD")
whatis("ROCm")
whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")
whatis("autoBLAS: link with -lautoBLAS-ilp64 or -lautoBLAS-lp64 (Michael Klemm's autoBLAS ships in this drop)")
whatis("PIE: TheRock is built -DCLANG_DEFAULT_PIE_ON_LINUX=ON (defaults to -fPIE/-pie). Do NOT link objects/libs built with ROCm <= 7.2.4 (PIE OFF) or you hit: relocation R_X86_64_32S against .rodata can not be used when making a PIE object; recompile with -fPIE")
whatis("Source: TheRock-AFAR ${THEROCK_AFAR_RELEASE} (family ${AMDGPU_FAMILY}, tarball ${_matched}, from ${EFFECTIVE_URL_DIR})")
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
setenv("HIPCC_COMPILE_FLAGS_APPEND", "--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/11")
setenv("HIPCC_LINK_FLAGS_APPEND",    "--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/11")
setenv("ROCM_PATH", base)
prepend_path("MODULEPATH", pathJoin(mbase, "rocm-afar-${THEROCK_AFAR_RELEASE}"))
prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-afar-${THEROCK_AFAR_RELEASE}-${ROCM_NUMERIC}"))
family("GPUSDK")

-- Place the rocprof-sys-run wrapper (which applies a libbfd LD_PRELOAD
-- workaround when the system libbfd is older than the one rocprof-sys
-- statically links) first in PATH. The wrapper is a no-op on systems
-- where the system libbfd is new enough.
prepend_path("PATH", pathJoin(base, "share/rocprofiler-systems/bin"))
EOF
sudo chown root:root "${MODULE_FILE}"
sudo chmod 644 "${MODULE_FILE}"

# ---------------- Phase 5b: per-package secondary modulefiles ---------
# Mirror what the regular numeric pipeline emits via deploy_module_package.sh
# (amdclang / hipfort / opencl modulefiles under the rocm-afar-<REL>/
# MODULEPATH prepended above). TheRock-AFAR drops typically ship
# llvm/bin/amdclang but NOT include/hipfort and NOT opencl/bin -- the
# helper feature-gates each emission on disk presence so absent
# components don't produce broken modulefiles.
echo "============================================================"
echo "  Phase 5b: per-package modulefiles under ${TOP_MODULE_PATH}/rocm-afar-${THEROCK_AFAR_RELEASE}/"
echo "============================================================"
# shellcheck source=bare_system/leaf_modulefile_helpers.sh
source "$(dirname "${LEAF_SCRIPT_PATH}")/leaf_modulefile_helpers.sh"
emit_per_package_modulefiles \
   "${TOP_MODULE_PATH}/rocm-afar-${THEROCK_AFAR_RELEASE}" \
   "${ROCM_NUMERIC}" \
   "rocm/afar-${THEROCK_AFAR_RELEASE}-${ROCM_NUMERIC}" \
   "${INSTALL_DIR}" \
   "${LEAF_SCRIPT_NAME}" \
   "${LEAF_SCRIPT_COMMIT:0:12}" \
   "${LEAF_SCRIPT_DIRTY}"

# ---------------- Phase 6: rocm_patches.sh on the TheRock-AFAR tree ----
# Mirror Phase 3.6 of bare_system/run_rocm_build.sh:483-512 (the numeric
# branch's patch-overlay step). rocm_patches.sh's dispatch table has
# entries for afar-23.{1.0,2.1} (TheRock-AFAR rocprof-compute overlay);
# for releases without a registered bundle the script returns NOOP_RC=43
# and we treat that as success.
#
# Note: TheRock-AFAR and AFAR-proper share the unified `afar-<REL>` key
# in rocm_version_to_patches() -- the release-tag namespaces don't
# collide (AFAR-proper = 22.x.y, TheRock-AFAR = 23.x.y). The matching
# overlay sits at rocm-patches-afar-<REL> (sibling of the unified
# rocm-afar-<REL> install dir). See the dispatch-table comment in
# rocm_patches.sh for the full naming rationale.
#
# Path conventions:
#   --rocm-version    afar-${THEROCK_AFAR_RELEASE}
#   --rocm-path       ${INSTALL_DIR}
#                     (= ${TOP_INSTALL_PATH}/rocm-afar-${REL})
#   --install-prefix  auto-derived by rocm_patches.sh:371-379 from
#                     ${ROCM_PATH} to ${TOP_INSTALL_PATH}/rocm-patches-afar-${REL}
#   --module-file     ${MODULE_FILE}  (afar-${REL}-${ROCM_NUMERIC}.lua)
#
# Exit codes (rocm_patches.sh):
#   0  -- patches applied (or already up to date)
#   43 -- intentional no-op (no vendored fix for this version)
#   *  -- hard error -- propagate to the EXIT trap
#
# Gated by --skip-patches (operator opt-out), mirrors the numeric
# branch's SKIP_PATCHES flag in run_rocm_build.sh:31.
if [[ "${SKIP_PATCHES}" != "1" ]]; then
   echo "============================================================"
   echo "  Phase 6: rocm_patches.sh on ${INSTALL_DIR} (-> ${PATCHES_LOG})"
   echo "============================================================"
   _patches_sh="$(dirname "${LEAF_SCRIPT_PATH}")/../rocm/scripts/rocm_patches.sh"
   if [[ ! -x "${_patches_sh}" ]]; then
      echo "[Phase 6] WARNING: rocm_patches.sh not found / not executable at ${_patches_sh}; skipping"
   else
      PATCHES_RC=0
      set +e
      "${_patches_sh}" \
            --rocm-version    "afar-${THEROCK_AFAR_RELEASE}" \
            --rocm-path       "${INSTALL_DIR}" \
            --module-path     "${TOP_MODULE_PATH}/base" \
            --module-file     "${MODULE_FILE}" \
            2>&1 | tee "${PATCHES_LOG}"
      PATCHES_RC=${PIPESTATUS[0]}
      set -e
      if [[ "${PATCHES_RC}" -eq 43 ]]; then
         echo "[Phase 6] rocm_patches.sh returned 43 (NOOP_RC) -- no vendored fix for afar-${THEROCK_AFAR_RELEASE}; treating as success"
      elif [[ "${PATCHES_RC}" -ne 0 ]]; then
         echo "ERROR: rocm_patches.sh failed for afar-${THEROCK_AFAR_RELEASE} (rc=${PATCHES_RC})" >&2
         exit "${PATCHES_RC}"
      else
         _overlay="${TOP_INSTALL_PATH}/rocm-patches-afar-${THEROCK_AFAR_RELEASE}"
         if [[ -d "${_overlay}" ]]; then
            sudo chown -R root:root "${_overlay}"
            sudo find "${_overlay}" -type d -exec chmod 755 {} +
         fi
         unset _overlay
         echo "[Phase 6] patches applied for afar-${THEROCK_AFAR_RELEASE}"
      fi
   fi
   unset _patches_sh
fi

echo ""
echo "============================================================"
echo "  Done: afar-${THEROCK_AFAR_RELEASE}-${ROCM_NUMERIC} (TheRock-AFAR drop)"
echo "  Install: ${INSTALL_DIR}"
echo "  Module : ${MODULE_FILE}  (loads rocm/afar-${THEROCK_AFAR_RELEASE}-${ROCM_NUMERIC},"
echo "                            ROCM_PATH=${INSTALL_DIR})"
echo "============================================================"
