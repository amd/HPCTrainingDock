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
# The Lmod updater backs up the previous cache with `cp -p` (preserve
# ownership) before mv'ing the new one into place (install_new_cache() in
# update_lmod_system_cache_files). On an NFS export with root_squash that
# `cp -p` cannot preserve ownership and fails with "Operation not supported",
# which makes the updater return non-zero EVEN WHEN the new spiderT.lua was
# written correctly by the mv that follows. Under `set -e` that false failure
# aborts the refresh and callers log a scary "spider-cache refresh failed".
# So capture the exit code instead of dying on it, then decide success from the
# cache we actually produced.
set +e
"${SPIDER_PREFIX[@]}" "${UPDATER}" -d "${CACHE_DIR}" -t "${TS}" "${MODULE_BASE}"
_updater_rc=$?
set -e

# Validate the real artefact. A healthy cache references actual modulefile
# locations under ${MODULE_ROOT}; an empty spider yields a valid-Lua-but-empty
# `spiderT = {}` with no such paths, which is worse than no cache (clients then
# resolve every module as "unknown"). Fail loudly on that so the exit status is
# trustworthy and the periodic backstop / next run retries.
if [ ! -s "${CACHE_DIR}/spiderT.lua" ] || ! grep -q "${MODULE_ROOT}" "${CACHE_DIR}/spiderT.lua" 2>/dev/null; then
   echo "[refresh] ERROR: spider produced an empty/invalid cache at ${CACHE_DIR}/spiderT.lua (updater rc=${_updater_rc}); it references no modulefiles under ${MODULE_ROOT}." >&2
   exit 1
fi
if [ "${_updater_rc}" -ne 0 ]; then
   echo "[refresh] note: updater exited ${_updater_rc} -- typically the NFS 'cp -p' backup of spiderT.old.lua under root_squash; the new spiderT.lua is valid, so treating this as success."
fi
echo "[refresh] done:"
ls -la "${CACHE_DIR}/spiderT.lua" "${TS}" 2>&1 | sed 's/^/[refresh]   /'
