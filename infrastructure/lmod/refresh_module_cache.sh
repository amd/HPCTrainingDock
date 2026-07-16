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
