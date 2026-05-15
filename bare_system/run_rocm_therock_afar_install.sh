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
# Naming-scheme decisions (locked in 2026-05-15 chat):
#   * Token shape passed in by the sweep / operator:   therock-afar-<REL>
#                                                       (e.g. therock-afar-23.2.1)
#     The `--therock-afar-release` flag accepts the bare <REL> (e.g. 23.2.1)
#     OR the prefixed form (the helper strips the `therock-afar-` prefix).
#   * Install dir:                                      rocm-therock-afar-<NUMERIC>
#                                                       (e.g. rocm-therock-afar-7.13.0)
#     -- keyed on .info/version-derived SDK numeric, not the AFAR release tag.
#   * Modulefile basename:                              therock-afar-<REL>.lua
#                                                       (e.g. therock-afar-23.2.1.lua)
#     -- keyed on the user-supplied AFAR release tag for provenance.
#   * Per-package rocmplus tree (downstream packages):  rocmplus-therock-afar-<NUMERIC>
#                                                       (e.g. rocmplus-therock-afar-7.13.0)
#     -- separate from `rocmplus-therock-<NUMERIC>` (which would correspond to
#     the (deferred) TheRock-proper channel).
#
# Phases:
#   0. Pre-check: skip cleanly (exit 0) if both the modulefile AND any
#      matching rocm-therock-afar-* install dir for this REL already
#      exist and --replace-existing is not set. We don't yet know
#      ROCM_NUMERIC at Phase 0 (that's Phase 3), so the install-dir
#      side of the pre-check is a glob match plus the modulefile
#      existence check (which IS keyed on REL directly).
#   1. Tarball URL discovery: scrape the flang/ listing for the matching
#      filename (therock-afar-<REL>-<FAMILY>-<NUMERIC>-<SHA>.tar.bz2).
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
#      depth 1) -> ROCM_NUMERIC.
#   4. Move the .info/version-bearing dir to the final
#      ${TOP_INSTALL_PATH}/rocm-therock-afar-${ROCM_NUMERIC}.
#   5. Emit ${TOP_MODULE_PATH}/base/rocm/therock-afar-${REL}.lua matching
#      the GPUSDK-shaped modulefile schema (same family("GPUSDK") +
#      MODULEPATH-prepend pattern as run_rocm_afar_install.sh and
#      run_rocm_therock_install.sh, with the family-tagged tree names).

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
  --replace-existing 0|1        overwrite existing rocm-therock-afar-<numeric>
                                install + modulefile (default ${REPLACE_EXISTING})
  --keep-failed-installs 0|1    on failure, keep partial install + modulefile
                                for post-mortem (default ${KEEP_FAILED_INSTALLS})
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
MODULE_FILE="${MODULE_DIR}/therock-afar-${THEROCK_AFAR_RELEASE}.lua"

# ---------------- Phase 0: skip-if-installed pre-check ----------------
# We don't know ROCM_NUMERIC until Phase 3 (it's inside the tarball's
# .info/version), so the install-dir side of this pre-check is a glob
# match against rocm-therock-afar-*. Combined with the modulefile
# existence check (which IS keyed directly on THEROCK_AFAR_RELEASE),
# this gives a conservative "is this same token already installed?"
# signal -- a stale install-dir without the matching modulefile (e.g.
# from a SIGKILL between Phase 4 and Phase 5) is NOT treated as
# "already installed" and will rebuild.
_skip_match=""
if [[ -f "${MODULE_FILE}" ]]; then
   shopt -s nullglob
   for _cand in "${TOP_INSTALL_PATH}"/rocm-therock-afar-*; do
      if [[ -d "${_cand}" ]]; then
         _skip_match="${_cand}"
         break
      fi
   done
   shopt -u nullglob
fi
if [[ -n "${_skip_match}" && "${REPLACE_EXISTING}" != "1" ]]; then
   echo "[$(date)] SKIP therock-afar-${THEROCK_AFAR_RELEASE}: ${_skip_match} + ${MODULE_FILE} already exist"
   echo "         Pass --replace-existing 1 to re-download + re-extract."
   exit 0
fi
unset _skip_match _cand

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
echo "  Phase 1: discover TheRock-AFAR tarball at ${URL_BASE}/"
echo "============================================================"
_listing="$(curl -fsSL --max-time 60 "${URL_BASE}/" 2>/dev/null || true)"
if [[ -z "${_listing}" ]]; then
   echo "ERROR: could not fetch directory listing at ${URL_BASE}/" >&2
   exit 1
fi
# Filename pattern (regex):
#   therock-afar-<REL>-<FAMILY>-<X.Y.Z>-<SHA>.tar.bz2
# We don't pin <X.Y.Z> in the regex (only the operator-supplied REL +
# FAMILY) so that AMD reposts (which we'd see as a different SHA + the
# same .info/version) auto-pick the latest. sort -V -u | tail -n1 picks
# the largest matching version then takes the most recent repost.
_pattern="therock-afar-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-[0-9]+\.[0-9]+(\.[0-9]+)?-[a-f0-9]{4,}\.tar\.bz2"
_matched=$(echo "${_listing}" | grep -oE "${_pattern}" | sort -V -u | tail -n1)
if [[ -z "${_matched}" ]]; then
   echo "ERROR: no tarball matching 'therock-afar-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-*.tar.bz2' at ${URL_BASE}/" >&2
   echo "       Verify the release tag + gfx-family combination exists upstream." >&2
   echo "       Available therock-afar-${THEROCK_AFAR_RELEASE} families on the listing:" >&2
   echo "${_listing}" | grep -oE "therock-afar-${THEROCK_AFAR_RELEASE}-gfx[A-Za-z0-9]+-[0-9.]+-[a-f0-9]+\.tar\.bz2" | sed 's/^/         /' >&2 || true
   exit 1
fi

TARBALL_URL="${URL_BASE}/${_matched}"
LOCAL_TARBALL="/tmp/${_matched}"
# Parse expected NUMERIC + SHA from the chosen filename (we'll
# cross-check against .info/version after extract in Phase 3).
EXPECTED_NUMERIC="$(echo "${_matched}" \
   | sed -E "s|^therock-afar-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-([0-9]+\.[0-9]+(\.[0-9]+)?)-[a-f0-9]+\.tar\.bz2$|\1|")"
THEROCK_SHA="$(echo "${_matched}" \
   | sed -E "s|^therock-afar-${THEROCK_AFAR_RELEASE}-${AMDGPU_FAMILY}-[0-9]+\.[0-9]+(\.[0-9]+)?-([a-f0-9]+)\.tar\.bz2$|\2|")"

STAGING_DIR="${TOP_INSTALL_PATH}/rocm-therock-afar-${EXPECTED_NUMERIC}.staging.$$"

echo ""
echo "============================================================"
echo "  TheRock-AFAR install plan"
echo "============================================================"
echo "  THEROCK_AFAR_RELEASE : ${THEROCK_AFAR_RELEASE}"
echo "  AMDGPU_GFXMODEL      : ${AMDGPU_GFXMODEL}  (informational; only first model drives family)"
echo "  AMDGPU_FAMILY        : ${AMDGPU_FAMILY}"
echo "  Expected NUMERIC     : ${EXPECTED_NUMERIC}"
echo "  Upstream SHA prefix  : ${THEROCK_SHA}"
echo "  Tarball URL          : ${TARBALL_URL}"
echo "  Local tarball        : ${LOCAL_TARBALL}"
echo "  Staging dir          : ${STAGING_DIR}"
echo "  Module file          : ${MODULE_FILE}"
echo "  Predicted install    : ${TOP_INSTALL_PATH}/rocm-therock-afar-${EXPECTED_NUMERIC}"
echo "  REPLACE_EXISTING     : ${REPLACE_EXISTING}"
echo "  KEEP_FAILED_INSTALLS : ${KEEP_FAILED_INSTALLS}"
echo "============================================================"
echo ""

# ---------------- --replace-existing cleanup --------------------------
# Runs AFTER URL discovery so we don't blow away an existing install for
# a release that doesn't actually exist upstream. The install-dir cleanup
# glob mirrors Phase 0 (we still don't know ROCM_NUMERIC); the modulefile
# basename is unambiguous so we just rm it.
if [[ "${REPLACE_EXISTING}" == "1" ]]; then
   shopt -s nullglob
   for _cand in "${TOP_INSTALL_PATH}"/rocm-therock-afar-*; do
      if [[ -d "${_cand}" ]]; then
         echo "[--replace-existing 1] removing ${_cand}"
         sudo rm -rf "${_cand}"
      fi
   done
   shopt -u nullglob
   if [[ -f "${MODULE_FILE}" ]]; then
      echo "[--replace-existing 1] removing ${MODULE_FILE}"
      sudo rm -f "${MODULE_FILE}"
   fi
   unset _cand
fi

# ---------------- EXIT-trap fail-cleanup ------------------------------
# Mirrors run_rocm_therock_install.sh:330-344: on non-zero exit blow away
# the staging dir + (if promoted) the partial install dir + modulefile
# so the next run starts clean. INSTALL_DIR is set after Phase 4 -- the
# guard with -n no-ops when unset.
INSTALL_DIR=""
_therock_afar_on_exit() {
   local rc=$?
   if [ ${rc} -ne 0 ] && [ "${KEEP_FAILED_INSTALLS}" != "1" ]; then
      echo "[therock-afar fail-cleanup] rc=${rc}: removing staging + partial install"
      sudo rm -rf "${STAGING_DIR}" 2>/dev/null || true
      [ -n "${INSTALL_DIR}" ] && sudo rm -rf "${INSTALL_DIR}" 2>/dev/null || true
      sudo rm -f "${MODULE_FILE}" 2>/dev/null || true
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
   echo "      .info/version (${ROCM_NUMERIC}); install dir will use the"
   echo "      .info/version-derived form (rocm-therock-afar-${ROCM_NUMERIC})."
fi

# ---------------- Phase 4: promote staging to final install dir -------
INSTALL_DIR="${TOP_INSTALL_PATH}/rocm-therock-afar-${ROCM_NUMERIC}"
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

# Modulefile shape matches the negotiated naming-scheme decision:
#   * Module basename:   therock-afar-${REL}.lua  (release-tag-keyed)
#   * ROCM_PATH:         ${INSTALL_DIR}  (numeric-keyed install dir)
#   * Two MODULEPATH prepends, both numeric-keyed:
#       rocm-therock-afar-${NUMERIC}        (per-package modules from SDK)
#       rocmplus-therock-afar-${NUMERIC}    (rocmplus per-package modules)
# This mirrors the layout of run_rocm_afar_install.sh's modulefile,
# just with the `-therock-afar-` infix instead of the bare `-afar-`.
sudo tee "${MODULE_FILE}" >/dev/null <<EOF
whatis("Name: ROCm")
whatis("Version: therock-afar-${THEROCK_AFAR_RELEASE}")
whatis("Category: AMD")
whatis("ROCm")
whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")
whatis("Source: TheRock-AFAR ${THEROCK_AFAR_RELEASE} (family ${AMDGPU_FAMILY}, tarball ${_matched})")
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
prepend_path("MODULEPATH", pathJoin(mbase, "rocm-therock-afar-${ROCM_NUMERIC}"))
prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-therock-afar-${ROCM_NUMERIC}"))
family("GPUSDK")

-- Place the rocprof-sys-run wrapper (which applies a libbfd LD_PRELOAD
-- workaround when the system libbfd is older than the one rocprof-sys
-- statically links) first in PATH. The wrapper is a no-op on systems
-- where the system libbfd is new enough.
prepend_path("PATH", pathJoin(base, "share/rocprofiler-systems/bin"))
EOF
sudo chown root:root "${MODULE_FILE}"
sudo chmod 644 "${MODULE_FILE}"

echo ""
echo "============================================================"
echo "  Done: therock-afar-${THEROCK_AFAR_RELEASE} (ROCM_NUMERIC=${ROCM_NUMERIC})"
echo "  Install: ${INSTALL_DIR}"
echo "  Module : ${MODULE_FILE}  (loads rocm/therock-afar-${THEROCK_AFAR_RELEASE},"
echo "                            ROCM_PATH=${INSTALL_DIR})"
echo "============================================================"
