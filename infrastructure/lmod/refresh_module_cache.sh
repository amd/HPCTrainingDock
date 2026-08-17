#!/usr/bin/env bash
#
# Rebuild the Lmod system spider cache for a module tree.
#
# The spider is seeded from the base only; it recurses the rocm/rocmplus hierarchy
# automatically (each rocm/X.Y.Z modulefile's prepend_path MODULEPATH), so one cache
# covers every version scope. The companion timestamp is bumped on every rebuild,
# which invalidates any client cache built before it.
#
# Usage:
#   refresh_module_cache.sh            # conditional: rebuild only if a modulefile
#                                      # is newer than the current cache
#   refresh_module_cache.sh --force    # always rebuild (use from the deploy path)
#
# Tree selection (all optional; default to the Ubuntu 24.04 stable tree so
# existing callers -- the deploy path and run_rocmplus_install.sbatch step 5 --
# keep byte-identical behavior):
#   --module-root DIR   module tree root (contains base/); the sibling
#                       moduleData/ under its parent supplies cache-dir + timestamp
#                       unless those are given explicitly.
#   --cache-dir DIR     spider cache output dir   (default: <root>/../moduleData/cacheDir)
#   --timestamp FILE    companion timestamp file  (default: <root>/../moduleData/timestamp)
# Env overrides (lower precedence than flags): MODULE_ROOT / CACHE_DIR / TS.
# This makes the script reusable for the nightlies tree
# (/nfsapps/ubuntu-24.04-nightlies/modules) so a freshly written nightly
# rocm/<date> modulefile lands in a registered cache and bumps a timestamp
# that invalidates stale client caches (the failure mode that stranded the
# first 7.15 nightly rocmplus build).
#
# Must run as root (writes to the cache dir on /nfsapps). Build it with the SAME
# Lmod version the clients run (fleet is uniform on 8.6.19); if the fleet engine is
# ever upgraded, rebuild with --force using the new engine.
set -euo pipefail

MODULE_ROOT="${MODULE_ROOT:-/nfsapps/ubuntu-24.04/modules}"
CACHE_DIR="${CACHE_DIR:-}"
TS="${TS:-}"
FORCE=0
while [ "$#" -gt 0 ]; do
   case "${1}" in
      --force)       FORCE=1 ;;
      --module-root) shift; MODULE_ROOT="${1}" ;;
      --cache-dir)   shift; CACHE_DIR="${1}" ;;
      --timestamp)   shift; TS="${1}" ;;
      *) echo "[refresh] WARNING: ignoring unknown argument '${1}'" >&2 ;;
   esac
   shift
done

MODULE_BASE="${MODULE_ROOT}/base"
# Derive cache-dir + timestamp from the tree's sibling moduleData/ when not
# set explicitly (mirrors the layout the deploy path and lmodrc.lua use).
_MODDATA="$(dirname "${MODULE_ROOT}")/moduleData"
CACHE_DIR="${CACHE_DIR:-${_MODDATA}/cacheDir}"
TS="${TS:-${_MODDATA}/timestamp}"

# Locate the cache builder from the running Lmod (fall back to the system path).
UPDATER="${LMOD_DIR:-/usr/share/lmod/lmod/libexec}/update_lmod_system_cache_files"
[ -x "${UPDATER}" ] || UPDATER=/usr/share/lmod/lmod/libexec/update_lmod_system_cache_files
[ -x "${UPDATER}" ] || { echo "[refresh] ERROR: update_lmod_system_cache_files not found" >&2; exit 1; }

mkdir -p "${CACHE_DIR}"

# ── root-vs-group-writable spider safeguard ──────────────────────────
# update_lmod_system_cache_files, run AS ROOT, silently refuses to cache any
# module tree that is group- or other-writable (an Lmod privilege-escalation
# safeguard: a non-root user could otherwise inject a modulefile that root's
# shared cache would then serve). The result is a valid-but-EMPTY spiderT.lua,
# which is worse than no cache -- cache-using clients then resolve every module
# as "unknown". The nightlies tree is intentionally group-writable
# (root:nightlies, chmod g+rwX by the build), so when we are root we must run
# the spider as a NON-root member of the tree's group instead. World-readable,
# not-group-writable trees (e.g. the stable /nfsapps/ubuntu-24.04 tree,
# drwxr-xr-x root:root) are spidered by root exactly as before.
#   CACHE_BUILD_USER: optional explicit account to drop to (must be in the
#   tree's group). Empty -> auto-detect the first non-root member of the group.
SPIDER_PREFIX=()
# Group- or other-writable? Test the actual mode bits (022): `find -perm /022`
# is unusable here because its EXIT status is 0 whether or not the path matches
# (it is a filter, not a test), so it would fire for every tree when root and
# make even a root:root world-readable tree take the privilege-drop path.
# `stat -c %a` yields 3- or 4-digit octal (e.g. 755 or 2770); the leading 0
# forces octal in the arithmetic.
_base_mode="$(stat -c %a "${MODULE_BASE}" 2>/dev/null || echo 0)"
if [ "$(id -u)" -eq 0 ] && [ "$(( 0${_base_mode} & 022 ))" -ne 0 ]; then
   _tree_grp="$(stat -c %G "${MODULE_BASE}" 2>/dev/null)"
   _cache_user="${CACHE_BUILD_USER:-}"
   if [ -z "${_cache_user}" ] && [ -n "${_tree_grp}" ]; then
      _cache_user="$(getent group "${_tree_grp}" 2>/dev/null | awk -F: '{print $4}' \
                     | tr ',' '\n' | grep -vE '^(root)?$' | head -n1)"
   fi
   if [ -n "${_cache_user}" ] && id "${_cache_user}" >/dev/null 2>&1; then
      echo "[refresh] tree ${MODULE_BASE} is group-writable; running spider as '${_cache_user}' (group '${_tree_grp}') because root would produce an empty cache"
      SPIDER_PREFIX=(runuser -u "${_cache_user}" -g "${_tree_grp}" --)
   else
      # Running the spider as root here would silently emit an EMPTY cache and
      # then mv it over the live spiderT.lua, stranding every cache-using client
      # (the exact failure that made the 7.15 nightlies skip every test). Refuse
      # rather than clobber: leave the existing cache in place for clients and
      # let the operator supply CACHE_BUILD_USER / a group member.
      echo "[refresh] ERROR: ${MODULE_BASE} is group-writable and no non-root ${_tree_grp:-group} member was found to run the spider (set CACHE_BUILD_USER). Refusing to run as root -- that would overwrite the live cache with an EMPTY one. Leaving the existing cache untouched." >&2
      exit 1
   fi
   unset _tree_grp _cache_user
fi
unset _base_mode

if [ "${FORCE}" -eq 0 ] && [ -f "${CACHE_DIR}/spiderT.lua" ]; then
   # Any modulefile newer than the cache -> stale. (Module tree only; small + fast.)
   newer="$(find "${MODULE_ROOT}" -type f -newer "${CACHE_DIR}/spiderT.lua" -print -quit 2>/dev/null || true)"
   if [ -z "${newer}" ]; then
      echo "[refresh] cache is up to date; nothing to do"
      exit 0
   fi
   echo "[refresh] change detected (${newer}); rebuilding"
fi

echo "[refresh] rebuilding spider cache from ${MODULE_BASE} using ${UPDATER}"

# ── build in a LOCAL staging dir, then publish to the NFS cache ──────────
# update_lmod_system_cache_files installs its freshly-built cache with, in this
# order (install_new_cache()):  cp -p spiderT.lua spiderT.old.lua (backup) then
# mv spiderT.new.lua spiderT.lua (swap-in) -- and it runs under its own `set -e`.
# On this NFS export (vers=3, no ACL support) the backup `cp -p` cannot preserve
# the file's ACL/mode and exits non-zero with
#   cp: preserving permissions for '.../spiderT.old.lua': Operation not supported
# so `set -e` aborts the updater *before* the swap-in mv. That leaves a freshly
# built but never-installed spiderT.new.lua orphaned in the cache dir while the
# live spiderT.lua stays stale -- and the old `-s + grep MODULE_ROOT` test could
# not tell those apart, so such runs reported success while the shared cache
# silently went stale. (Seen on the build nodes; the cron host, where cp -p
# happens to succeed, only advanced the cache by luck.)
#
# Fix: point the updater at a LOCAL staging dir, where its internal cp -p works
# and it completes end-to-end. Then validate the staged artefact and publish it
# into the NFS cache dir with plain cp (no -p -> no ACL preservation to fail) +
# an atomic same-dir mv. Bump the timestamp *before* publishing so it stays
# older than the cache (a timestamp newer than spiderT.lua marks the system
# cache itself stale).
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lmod-spider.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
# When we drop privileges to spider a group-writable tree (SPIDER_PREFIX set),
# that account must be able to write the staged cache into STAGE.
[ "${#SPIDER_PREFIX[@]}" -gt 0 ] && chmod 0777 "${STAGE}"

set +e
"${SPIDER_PREFIX[@]}" "${UPDATER}" -d "${STAGE}" -t "${STAGE}/timestamp" "${MODULE_BASE}"
_updater_rc=$?
set -e

# Validate the STAGED artefact (not the live one). A healthy cache references
# actual modulefile locations under ${MODULE_ROOT}; an empty spider yields a
# valid-Lua-but-empty `spiderT = {}` with no such paths, which is worse than no
# cache (clients then resolve every module as "unknown"). Refuse to publish
# that -- leave the existing live cache untouched for clients.
if [ ! -s "${STAGE}/spiderT.lua" ] || ! grep -q "${MODULE_ROOT}" "${STAGE}/spiderT.lua" 2>/dev/null; then
   echo "[refresh] ERROR: spider produced an empty/invalid cache at ${STAGE}/spiderT.lua (updater rc=${_updater_rc}); it references no modulefiles under ${MODULE_ROOT}. Leaving the existing live cache untouched." >&2
   exit 1
fi
if [ "${_updater_rc}" -ne 0 ]; then
   echo "[refresh] note: staging updater exited ${_updater_rc} (non-fatal on the local staging FS); the staged spiderT.lua is valid, publishing it."
fi

# Publish helper: plain copy (no ACL/ownership preservation) to a temp name in
# the target dir, then atomic same-dir rename over the live file.
_publish() {  # $1=src  $2=dst
   local _tmp
   _tmp="$(dirname "${2}")/.$(basename "${2}").$$"
   cp "${1}" "${_tmp}"
   chmod 644 "${_tmp}"
   mv -f "${_tmp}" "${2}"
}

# Bump the timestamp first so it ends up OLDER than the cache we publish next.
: > "${TS}"

# Publish the plain-text cache, then the compiled cache(s) built from it.
_publish "${STAGE}/spiderT.lua" "${CACHE_DIR}/spiderT.lua"
_have_luac=0
for _c in "${STAGE}"/spiderT.luac_*; do
   [ -e "${_c}" ] || continue
   _publish "${_c}" "${CACHE_DIR}/$(basename "${_c}")"
   _have_luac=1
done
# If this build produced no compiled cache, drop any stale compiled cache in the
# target: Lmod prefers .luac_* over .lua, so a stale compiled file left next to
# a fresh .lua would be served in preference to it.
if [ "${_have_luac}" -eq 0 ]; then
   rm -f "${CACHE_DIR}"/spiderT.luac_* 2>/dev/null || true
fi

# Prove THIS rebuild actually landed: no modulefile in the tree may be newer
# than the cache we just published. This is exactly what a silent no-op used to
# fail, so catch it here and make the exit status trustworthy.
_still_newer="$(find "${MODULE_ROOT}" -type f -newer "${CACHE_DIR}/spiderT.lua" -print -quit 2>/dev/null || true)"
if [ -n "${_still_newer}" ]; then
   echo "[refresh] ERROR: published spiderT.lua is still older than ${_still_newer}; the cache did not update as expected." >&2
   exit 1
fi

echo "[refresh] done:"
{ ls -la "${CACHE_DIR}/spiderT.lua" "${TS}"; ls -la "${CACHE_DIR}"/spiderT.luac_* 2>/dev/null; } 2>&1 | sed 's/^/[refresh]   /'
