# Lmod standardization + spider-cache plan

Plan to (1) standardize the Lmod engine on a single version installed locally on
every node and in the Warewulf image, then (2) replace the blunt
`LMOD_IGNORE_CACHE=1` workaround with a proper system spider cache that is
refreshed whenever the module tree changes.

## How to read this report

Every claim is tagged so measured facts are distinguishable from interpretation:

- **[FACT]** — directly observed on this cluster (command output, file contents) and reproducible.
- **[INFERENCE]** — interpretation consistent with the facts, but not proven.
- **[OPINION]** — a recommendation / judgement call about what to do.

Companion artifacts: [`install_lmod_8.7.65.sh`](./install_lmod_8.7.65.sh) (optional Step 1);
[`lmodrc.lua`](./lmodrc.lua), [`refresh_module_cache.sh`](./refresh_module_cache.sh),
[`zz-lmod-cache.sh`](./zz-lmod-cache.sh) (Steps 2–3, as deployed).

## Deployment log (2026-07-05) — Steps 2 & 3 DONE

- **[FACT]** Step 2: `LMOD_IGNORE_CACHE=1` commented out in
  `/shared/apps/ubuntu/lmod/overridetcl2lmod.sh` (dated note left; timestamped `.bak` kept).
- **[FACT]** Step 3 (NFS): created `/nfsapps/ubuntu-24.04/moduleData/{lmodrc.lua,refresh_module_cache.sh}`
  and built the initial cache — `cacheDir/spiderT.lua` (432 KB) + `timestamp`. Verified end-to-end
  with 8.6.19: `lmod --config` → `number of cache dirs = 1`, `Ignore Cache = no`, `Cached loads = yes`;
  `avail rocm` lists all versions and `load rocm/7.2.3` resolves to `/nfsapps` with the hierarchical
  `rocmplus-7.2.3` scope (cupy, amdclang, …) served from cache.
- **[FACT]** Step 3 (`/etc/profile.d/zz-lmod-cache.sh`): baked into the `ubuntu-24.04` image
  (`wwctl image build` OK) and pushed live to 11/12 nodes — both front-ends (`aac6-fe1/2`) and 9
  compute nodes. `sh5-pl1-s12-36` was UNREACHABLE (powered off); it will pick up the file from the
  image on next boot. Verified on `aac6-fe1` and `sh5-pl1-s12-09`: `LMOD_RC`/`LMOD_CACHED_LOADS` set
  in a login shell and `number of cache dirs = 1`.
- **[FACT]** Step 4 (deploy-path hook, DONE): both install paths now refresh the cache at the end of
  a deploy — `bare_system/run_rocm_build.sh` (Phase 3.8, gated on `SKIP_EXTRACT`) and
  `bare_system/run_rocmplus_install.sbatch` (step 5, after `main_setup.sh`, on the compute node). The
  hook is self-adapting and non-fatal: it derives the cache home as `$(dirname TOP_MODULE_PATH)/moduleData`
  and only runs `refresh_module_cache.sh --force` when that script exists there (i.e. only for the
  `/nfsapps/ubuntu-24.04` tree today; legacy `/nfsapps`, `/opt`, shared-apps, and Cray `/shareddata`
  targets skip silently). A refresh failure logs a WARNING but never fails the install/job.
- **[FACT]** Step 4 (periodic backstop, DONE): `/etc/cron.d/lmod-cache-refresh` (repo copy:
  `infrastructure/lmod/lmod-cache-refresh.cron`) runs `refresh_module_cache.sh` every 30 min as root,
  conditional-on-change (no `--force`), logging to `/nfsapps/ubuntu-24.04/moduleData/refresh.log`.
  Deployed live on `aac6-fe1`; validated by running the cron command body manually (exit 0, log shows
  the dated header + "cache is up to date"). The job is hostname-gated to `aac6-fe1` so the same file
  is safe to bake into the shared Warewulf image (only one host does the work, no N-node NFS race).
- **[INFERENCE]** The live crontab on `aac6-fe1` is on a stateless node, so it is lost on reboot. For
  persistence, bake `lmod-cache-refresh.cron` into the `ubuntu-24.04` image (the hostname gate makes
  it a no-op on every node except `aac6-fe1`). Not yet done.
- **[OPINION]** Remaining: bake the cron drop-in into the image for reboot-persistence; re-run the live
  profile.d push for `sh5-pl1-s12-36` once it boots (or let the image cover it); consider a small
  logrotate entry for `refresh.log` (grows ~2 lines/run = ~100 lines/day).

## TL;DR

- **[FACT]** Every node — compute (`ppac-*`, `sh5-*`) and front-end (`aac6-fe1/2`) — is a **stateless Warewulf** node (`Root=initramfs`) that boots the `ubuntu-24.04` image, and all run the **local** engine **8.6.19** at `/usr/share/lmod` (verified live on `aac6-fe1`). A separate 8.7.65 exists at `/shared/apps/ubuntu/lmod`, but it is not the engine the nodes boot with.
- **[FACT]** There is no system spider cache; `lmod --config` reports `number of cache dirs = 0`. Lmod falls back to per-user `~/.cache/lmod` caches valid for 24h — the staleness that `LMOD_IGNORE_CACHE=1` (set in `overridetcl2lmod.sh`) was hiding.
- **[INFERENCE]** Because the fleet is **already uniform on 8.6.19**, **no Lmod install/upgrade is required** for the cache plan — a single spider cache built with 8.6.19 serves every node. The cross-version concern that originally motivated "standardizing" is moot (it assumed the front-end ran 8.7.65; it does not).
- **[OPINION]** Proceed directly to the cache work using the existing 8.6.19: add a registered system spider cache + timestamp on NFS (built with 8.6.19) and refresh it from a periodic job and the deploy path. Upgrading the image to 8.7.65 is an **optional, independent** maintenance item — the recipe is kept for when/if you choose to do it. Keep the module tree, software, and spider cache on NFS.

## Background (why)

**[FACT]** A `cupy` import failed under `rocm/7.2.3` on the front end because
`module load cupy` resolved to the retired `/shared/apps/ubuntu` (Ubuntu 22.04 /
Python 3.10) tree, whose bundled numpy has only `cpython-310` extensions, under a
Python 3.12 interpreter. The stale tree reached MODULEPATH via
`~/.bashrc` → `/shared/apps/ubuntu/lmod/overridetcl2lmod.sh`, which appended the
old base and set `LMOD_IGNORE_CACHE=1`.

**[INFERENCE]** The episode exposed two systemic issues this plan addresses:
per-node divergence in what Lmod resolves, and reliance on `LMOD_IGNORE_CACHE=1`
instead of a correct cache-refresh mechanism.

## Step 1 (revised) — none needed: the fleet is already uniform

**[FACT]** All nodes keep the engine local and identical: `MODULESHOME=/usr/share/lmod/lmod`,
`/etc/profile.d/lmod.sh` initializes from that local path, `/etc/profile.d/z00_lmod.*`
are symlinks into `/usr/share/lmod/lmod/init/`, the `ubuntu-24.04` image ships
`/usr/share/lmod/lmod -> 8.6.19`, and `aac6-fe1` was verified live running that same
`8.6.19`. Every node (compute + front-ends) is stateless (`Root=initramfs`) and boots
this one image.

**[INFERENCE]** Since the fleet is uniform on 8.6.19, **there is nothing to
standardize and no Lmod install is required** for the cache plan. Build the system
spider cache with 8.6.19 and it is valid for every node — the cross-version
cache-format problem cannot arise. Proceed to Step 2.

**[OPINION] (optional, independent) upgrading to 8.7.65 later.** If you decide to
adopt the newer engine for its own sake (bug fixes), do it via the image, never by
hand-installing on stateless nodes:

1. Throwaway-validate on one running compute node (zero-risk; a reboot reverts it):
   `sudo SRC_TARBALL=/tmp/Lmod-8.7.65.tar.gz bash install_lmod_8.7.65.sh` then
   `lmod --version`.
2. Bake into the image and rebuild:
   ```bash
   IMG=/var/local/warewulf/chroots/ubuntu-24.04/rootfs
   sudo cp Lmod-8.7.65.tar.gz            "$IMG/tmp/"
   sudo cp infrastructure/lmod/install_lmod_8.7.65.sh "$IMG/root/"
   sudo wwctl container exec ubuntu-24.04 -- bash /root/install_lmod_8.7.65.sh
   sudo wwctl container build ubuntu-24.04
   ```
   The recipe builds with `--prefix=/usr/share/lmod --with-lmodConfigDir=/etc/lmod`
   and repoints the `lmod` symlink; **no `/etc/profile.d` edits needed** (the
   version-agnostic `z00_lmod.*` symlinks follow it).
3. Reboot nodes into the rebuilt image (rolling/drained), then **rebuild the spider
   cache with 8.7.65** (cache format is engine-version-specific). Keep the prior
   image/container revision as rollback.

**[INFERENCE]** Resilience note (why the engine stays local, not on NFS):
`/etc/profile.d` runs on every shell; sourcing the engine from NFS would leave a
node with **no `module` command** if the mount were missing. Local (image-delivered)
engine degrades gracefully — `module` works, just finds no modulefiles until
`/nfsapps` mounts.

**[FACT]** Build prerequisites are already present in the image: `lua5.3`,
`lua-posix`, `lua-filesystem`, `tclsh`, `gcc`, `make`. Lmod is pure Lua/Tcl, so no
`-dev` headers are required. If the image build host is offline, stage the source
tarball (`SRC_TARBALL=`), since the front end has 8.7.65 *installed* but not its
source.

## Step 2 — remove the workaround

**[FACT]** `LMOD_IGNORE_CACHE=1` is set in exactly one place:
`/shared/apps/ubuntu/lmod/overridetcl2lmod.sh:38` (all other hits are Lmod's own
source). Remove that line. (Its value `1` may not even have taken effect, since
`Cache.lua` gates on `== "yes"`; remove it regardless.)

## Step 3 — registered system spider cache + timestamp (NFS)

**[FACT]** Verified on this cluster: seeding `update_lmod_system_cache_files` from
only the base captures the whole hierarchy (all `rocmplus-<ver>` trees) via the
`rocm/X.Y.Z` modules' `prepend_path("MODULEPATH", …)`; `cupy` appears once per
version, keyed by absolute path (no filename collision). With a registered system
cache, a module added out-of-band is **invisible** until the cache is rebuilt
(measured), and rebuilding fixes it; `module --ignore_cache` is the escape hatch.

Create (all on NFS, coupled to the module tree):

| Path | Purpose |
|---|---|
| `/nfsapps/ubuntu-24.04/moduleData/` | Cache home |
| `/nfsapps/ubuntu-24.04/moduleData/lmodrc.lua` | `scDescriptT` registering `cacheDir` + `timestamp` |
| `/nfsapps/ubuntu-24.04/moduleData/refresh_module_cache.sh` | Base-seeded `update_lmod_system_cache_files`; the single choke point |
| `/etc/profile.d/zz-lmod-cache.sh` (in the image) | `export LMOD_RC=…/moduleData/lmodrc.lua`, `LMOD_CACHED_LOADS=yes` |

**[INFERENCE]** Because every local engine is the same 8.6.19, one cache
format serves all clients (the cross-version fallback problem disappears).

## Step 4 — refresh on every change (not just via the build scripts)

**[INFERENCE]** Tying cache refresh only to the rocm/rocmplus scripts is fragile:
any manual `cp`, hand-edited modulefile, or other installer would leave the cache
stale. Make refresh a property of the tree.

**[OPINION]**
1. Periodic backstop: cron/systemd timer (one host with write access) runs
   `refresh_module_cache.sh` every 5–10 min; conditional-on-change (rebuild only
   if any modulefile is newer than `spiderT.lua`). Robust over NFS/multi-host,
   unlike inotify.
2. Immediate refresh: the rocm/rocmplus deploy path (`bare_system/run_rocm_build.sh`
   after Phase 3.5, and/or the `do_rocmplus*_install.sh` wrappers) calls the same
   script.
3. Document `module --ignore_cache avail/spider` as the escape hatch.

## Files to modify / create (summary)

Already done this session:

| File | Change |
|---|---|
| `rocm/scripts/rocm_setup.sh` | Self-locating `mbase` in both rocm `.lua` branches |
| `/shared/apps/ubuntu/lmod/overridetcl2lmod.sh` | Base repointed `/shared` → `/nfsapps` (backup kept) |
| `~bobrobey/.bashrc:127` | `source …/overridetcl2lmod.sh` commented out |

This plan:

| File | Change | Step |
|---|---|---|
| _(none — fleet already uniform on 8.6.19)_ | Cache plan proceeds with 8.6.19; no Lmod install | 1 |
| _(optional)_ Warewulf `ubuntu-24.04` image | Upgrade engine to 8.7.65 via recipe + `wwctl container build` + reboot; then rebuild cache | opt |
| `/shared/apps/ubuntu/lmod/overridetcl2lmod.sh` | Remove `LMOD_IGNORE_CACHE=1` | 2 |
| `/nfsapps/ubuntu-24.04/moduleData/{lmodrc.lua,refresh_module_cache.sh}` | Create | 3–4 |
| Image `/etc/profile.d/zz-lmod-cache.sh` | Create (`LMOD_RC`, `LMOD_CACHED_LOADS=yes`) | 3 |
| cron/systemd timer | Create (periodic refresh) | 4 |
| `bare_system/run_rocm_build.sh` / `do_rocmplus*_install.sh` | Call refresh at end of deploy | 4 |

## Open decisions

- **[OPINION]** Build the cache with the fleet's current engine (8.6.19). Step 1 is
  a no-op now; only if you later upgrade the image engine must you rebuild the cache
  with the new version.
- Which host owns the cron timer (needs write to `/nfsapps/…/moduleData` and read
  of the whole tree).
- `/etc/profile.d/zz-lmod-cache.sh` is node-local, so it belongs in the Warewulf
  image (same channel as `/etc/lmod/modulespath`).
- Mirror any extra `./configure` flags the current 8.6.19 used (check
  `lmod --config`) if behavior differs after upgrade.
