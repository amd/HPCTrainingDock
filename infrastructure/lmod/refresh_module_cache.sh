#!/usr/bin/env bash
#
# Rebuild the Lmod system spider cache for the Ubuntu 24.04 module tree.
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
# Must run as root (writes to the cache dir on /nfsapps). Build it with the SAME
# Lmod version the clients run (fleet is uniform on 8.6.19); if the fleet engine is
# ever upgraded, rebuild with --force using the new engine.
set -euo pipefail

MODULE_ROOT=/nfsapps/ubuntu-24.04/modules
MODULE_BASE="${MODULE_ROOT}/base"
CACHE_DIR=/nfsapps/ubuntu-24.04/moduleData/cacheDir
TS=/nfsapps/ubuntu-24.04/moduleData/timestamp

# Locate the cache builder from the running Lmod (fall back to the system path).
UPDATER="${LMOD_DIR:-/usr/share/lmod/lmod/libexec}/update_lmod_system_cache_files"
[ -x "${UPDATER}" ] || UPDATER=/usr/share/lmod/lmod/libexec/update_lmod_system_cache_files
[ -x "${UPDATER}" ] || { echo "[refresh] ERROR: update_lmod_system_cache_files not found" >&2; exit 1; }

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "${CACHE_DIR}"

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
"${UPDATER}" -d "${CACHE_DIR}" -t "${TS}" "${MODULE_BASE}"
echo "[refresh] done:"
ls -la "${CACHE_DIR}/spiderT.lua" "${TS}" 2>&1 | sed 's/^/[refresh]   /'
