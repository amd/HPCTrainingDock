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
#   4. Move staging dir to the final ${TOP_INSTALL_PATH}/rocm-therock-
#      ${ROCM_NUMERIC} (the .info/version-derived install dir; this
#      is the authoritative naming -- the github-tag form `therock-7.13`
#      is a label only).
#   5. Emit ${TOP_MODULE_PATH}/base/rocm/therock-${THEROCK_RELEASE}.lua
#      using THE USER-SUPPLIED DOWNLOAD TAG as the module name (e.g.
#      `therock-7.13.lua` for the github tag `therock-7.13`,
#      `therock-23.2.1.lua` for the older 23.x.y scheme). This makes
#      provenance obvious to operators -- the module name they load
#      maps 1:1 to the github release tag they (or a prior sweep)
#      asked for. Inside the modulefile, ROCM_PATH and the two
#      MODULEPATH prepends use the .info/version-derived form
#      (rocm-therock-${ROCM_NUMERIC} / rocmplus-therock-${ROCM_NUMERIC})
#      so runtime version comparisons -- which read either
#      ${ROCM_PATH}/.info/version or the basename of ${ROCM_PATH} --
#      see the authoritative SDK numeric (e.g. 7.13.0) and not the
#      github tag form. This is the SAME pattern used by the existing
#      cluster-deployed therock-23.x.y.lua modules; mirror it exactly.
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
: ${URL_BASE:="https://repo.amd.com/rocm/tarball"}

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
  --replace-existing 0|1        overwrite existing rocm-therock-<numeric>
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
      "--therock-release")      shift; THEROCK_RELEASE=${1};      reset-last ;;
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

MODULE_DIR="${TOP_MODULE_PATH}/base/rocm"
# Module file basename uses the USER-SUPPLIED DOWNLOAD TAG verbatim
# (e.g. therock-7.13.lua for github tag therock-7.13). This makes
# provenance obvious -- the loaded module name maps 1:1 to what was
# fetched from upstream. The install dir name (and ROCM_PATH inside
# the modulefile) is the .info/version-derived form, derived in
# Phase 3 below. The two intentionally diverge: that's the whole
# point of separating "where did this come from" (module name) from
# "what version does the SDK report itself as" (install dir + ROCM_PATH).
MODULE_FILE="${MODULE_DIR}/therock-${THEROCK_RELEASE}.lua"

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
SKIP_CANDIDATES=( "${TOP_INSTALL_PATH}/rocm-therock-${THEROCK_RELEASE}" )
[[ "${THEROCK_RELEASE}" =~ ^[0-9]+\.[0-9]+$ ]] \
   && SKIP_CANDIDATES+=( "${TOP_INSTALL_PATH}/rocm-therock-${THEROCK_RELEASE}.0" )
if [[ "${REPLACE_EXISTING}" != "1" ]]; then
   for _cand in "${SKIP_CANDIDATES[@]}"; do
      if [[ -d "${_cand}" ]]; then
         echo "[$(date)] SKIP therock-${THEROCK_RELEASE}: ${_cand} already exists"
         echo "         Pass --replace-existing 1 to re-download + re-extract."
         exit 0
      fi
   done
   unset _cand
fi

# ---------------- Defensive remount of /nfsapps as rw -----------------
# /etc/exports.d/nfsapps_sh5_rw.exports grants rw to sh5 admin nodes,
# but the warewulf-managed fstab still mounts /nfsapps ro by default.
# Mirrors the same block in run_rocm_afar_install.sh:117-125.
INSTALL_PARENT="${TOP_INSTALL_PATH%/*}"
if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
   echo "Attempting to remount ${INSTALL_PARENT} rw..."
   sudo mount -o remount,rw "${INSTALL_PARENT}" 2>/dev/null || true
fi
if ! sudo -n test -w "${INSTALL_PARENT}" 2>/dev/null; then
   echo "ERROR: ${INSTALL_PARENT} is not writable on $(hostname); aborting." >&2
   mount | grep nfsapps || true
   exit 1
fi

# Self-heal install/module roots if missing (mirrors the sweep sbatch).
for d in "${TOP_INSTALL_PATH}" "${TOP_MODULE_PATH}" "${MODULE_DIR}"; do
   if ! sudo -n test -d "${d}" 2>/dev/null; then
      echo "Creating missing ${d}"
      sudo install -d -o root -g root -m 0755 "${d}"
   fi
done

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
echo "  Phase 1: discover tarball for therock-${THEROCK_RELEASE} (${AMDGPU_FAMILY})"
echo "============================================================"

curl_head_ok() {
   # 1 = URL responds 200/302; 0 = otherwise. Avoids downloading on probe.
   local _u="$1"
   curl -fsI -o /dev/null --max-time 30 "${_u}" 2>/dev/null
}

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
STAGING_DIR="${TOP_INSTALL_PATH}/rocm-therock-${ACTUAL_VERSION}.staging.$$"

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
echo "  Module file          : ${MODULE_FILE}"
# Predicted install dir assumes ROCM_NUMERIC == ACTUAL_VERSION
# (the common case); Phase 4 finalizes from .info/version and may
# differ for alpha/RC tarballs.
echo "  Predicted install    : ${TOP_INSTALL_PATH}/rocm-therock-${ACTUAL_VERSION}"
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
if [[ "${REPLACE_EXISTING}" == "1" ]]; then
   for _cand in "${SKIP_CANDIDATES[@]}"; do
      if [[ -d "${_cand}" ]]; then
         echo "[--replace-existing 1] removing ${_cand}"
         sudo rm -rf "${_cand}"
      fi
   done
   if [[ -f "${MODULE_FILE}" ]]; then
      echo "[--replace-existing 1] removing ${MODULE_FILE}"
      sudo rm -f "${MODULE_FILE}"
   fi
   unset _cand
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
      sudo rm -rf "${STAGING_DIR}" 2>/dev/null || true
      [ -n "${INSTALL_DIR}" ] && sudo rm -rf "${INSTALL_DIR}" 2>/dev/null || true
      sudo rm -f "${MODULE_FILE}" 2>/dev/null || true
   elif [ ${rc} -ne 0 ]; then
      echo "[therock fail-cleanup] rc=${rc} but KEEP_FAILED_INSTALLS=1: leaving artifacts on disk"
   fi
   # Always reap the local tarball -- it's regenerated next run.
   rm -f "${LOCAL_TARBALL}" 2>/dev/null || true
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
echo "  Phase 2: curl + tar -xzpf -> ${STAGING_DIR}"
echo "============================================================"
rm -f "${LOCAL_TARBALL}"
# curl is preferred over wget here because it's what install_rocm_tarball.sh
# upstream uses, and the AMD tarball server (repo.amd.com) returns the
# same redirects either way. -fSL == fail on errors, follow redirects,
# show errors but no progress meter (we're in a slurm log).
curl -fSL --output "${LOCAL_TARBALL}" "${TARBALL_URL}"

# Pre-empt a stale staging dir from an earlier interrupted run that the
# fail-cleanup didn't reach (e.g. SIGKILL). Same-PID collision is
# implausible (we're in $$) but defense in depth costs nothing.
sudo rm -rf "${STAGING_DIR}"
sudo install -d -o root -g root -m 0755 "${STAGING_DIR}"
sudo tar -xzpf "${LOCAL_TARBALL}" -C "${STAGING_DIR}"
echo "Extracted into staging: ${STAGING_DIR}"

# ---------------- Phase 3: derive ROCM_NUMERIC from .info/version -----
# .info/version is the authoritative version label inside the tarball
# (e.g. `7.13.0`). The github tag form `therock-7.13` is just a label;
# the install dir name comes from .info/version per the user's spec.
if [[ ! -f "${STAGING_DIR}/.info/version" ]]; then
   echo "ERROR: ${STAGING_DIR}/.info/version missing; cannot derive ROCM_NUMERIC" >&2
   echo "       (Did the TheRock tarball layout change?)" >&2
   sudo find "${STAGING_DIR}" -maxdepth 2 -type f -name version -printf '       found: %p\n' || true
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
   echo "      .info/version-derived form (rocm-therock-${ROCM_NUMERIC})."
fi

# ---------------- Phase 4: promote staging to final install dir -------
INSTALL_DIR="${TOP_INSTALL_PATH}/rocm-therock-${ROCM_NUMERIC}"
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
      sudo rm -rf "${INSTALL_DIR}"
   else
      echo "ERROR: ${INSTALL_DIR} already exists but --replace-existing is 0;" >&2
      echo "       Phase 0 should have caught this. Either pass --replace-existing 1" >&2
      echo "       or remove the existing install manually." >&2
      exit 1
   fi
fi
sudo mv "${STAGING_DIR}" "${INSTALL_DIR}"
sudo chown -R root:root "${INSTALL_DIR}"
sudo chmod 755 "${INSTALL_DIR}"
rm -f "${LOCAL_TARBALL}"
echo "Installed: ${INSTALL_DIR}"

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

echo "============================================================"
echo "  Phase 5: write modulefile ${MODULE_FILE}"
echo "============================================================"
sudo mkdir -p "${MODULE_DIR}"

# Heredoc-pipe into sudo tee so the modulefile is created root-owned
# even when this script runs as a non-root user. Shape matches the
# existing cluster-deployed therock-23.x.y.lua modules and
# run_rocm_afar_install.sh:282-312:
#   * Module basename uses THEROCK_RELEASE (the github release tag
#     the user asked for) so provenance is obvious.
#   * `local base = "${INSTALL_DIR}"` and `setenv("ROCM_PATH", base)`
#     point at the .info/version-derived install dir so runtime
#     version checks (which read either ${ROCM_PATH}/.info/version or
#     basename ${ROCM_PATH}) see the authoritative SDK numeric (e.g.
#     7.13.0), NOT the github tag form (7.13).
#   * Two MODULEPATH prepends (rocm-therock-<numeric> for SDK
#     packages, rocmplus-therock-<numeric> for the rocmplus stack)
#     also use the numeric so all downstream package modules
#     organize under the same authoritative version key.
sudo tee "${MODULE_FILE}" >/dev/null <<EOF
whatis("Name: ROCm")
whatis("Version: therock-${THEROCK_RELEASE}")
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
setenv("HIPCC_COMPILE_FLAGS_APPEND", "--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/11")
setenv("HIPCC_LINK_FLAGS_APPEND",    "--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/11")
setenv("ROCM_PATH", base)
prepend_path("MODULEPATH", pathJoin(mbase, "rocm-therock-${ROCM_NUMERIC}"))
prepend_path("MODULEPATH", pathJoin(mbase, "rocmplus-therock-${ROCM_NUMERIC}"))
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
echo "  Done: therock-${THEROCK_RELEASE} (ROCM_NUMERIC=${ROCM_NUMERIC})"
echo "  Install: ${INSTALL_DIR}"
echo "  Module : ${MODULE_FILE}  (loads rocm/therock-${THEROCK_RELEASE},"
echo "                            ROCM_PATH=rocm-therock-${ROCM_NUMERIC})"
echo "============================================================"
