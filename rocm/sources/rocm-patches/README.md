# rocm-patches: vendored cherry-picks for the bundled ROCm SDK

This directory holds **minimal**, self-contained patches that
`rocm/scripts/rocm_patches.sh` applies on top of the SDK installed
by `rocm/scripts/rocm_setup.sh`.

## Layout

```
sources/rocm-patches/
  README.md
  <component>-<bug-version>/       # patch-style bundle (cherry-picks)
    NNNN-<short-name>.patch        # one or more git-format patches
  <component>/                     # rebuild-style bundle (no patches;
    install.sh                     # the bundle ships shell scripts that
    build.sh                       # produce the artefact from upstream
    README.md.in                   # source plus a README template)
```

Subdirectory naming is keyed by the **upstream component + the version
of that component that contains the bug**, not by the ROCm release.
This is important because a single patch typically applies to every
ROCm release that ships the same buggy component (for instance,
`rocprof-sys-1.3.0` is the v1.3.0 source baseline that ships with
both ROCm 7.2.0 and 7.2.1).

Two bundle shapes are currently supported:

* **patch-style** (`<component>-<version>/`): a directory of
  `git format-patch` files cherry-picked from upstream.  The
  corresponding `build_<component>()` shell function in
  `rocm_patches.sh` clones upstream, applies the patches, and builds
  the artefact.  `rocprof-sys-1.3.0/` is the reference example.
* **rebuild-style** (`<component>/`): no patches; the bundle ships
  a self-contained `install.sh` + `build.sh` pair that the
  `build_<component>()` function copies into the overlay prefix and
  invokes.  Used when the work is *not* a code change but rather a
  packaging-level rebuild (e.g. the upstream component itself is
  fine, but the ROCm `.deb` ships a broken or missing artefact).
  `rocprof-compute/` is the reference example.

The mapping from ROCm release to which subdirectory of patches to
apply lives in `rocm/scripts/rocm_patches.sh` (see the
`rocm_version_to_patches()` function there). Adding a new vendored
fix is a two-line change: drop the patch (or rebuild-style scripts)
under the appropriate directory and extend that mapping.

## Currently vendored patches

### `rocprof-sys-1.6.0/` -- one cherry-pick onto v1.6.0's outer once-guard

Affected ROCm releases: **7.13.0, afar-23.2.1, therock-23.2.0**
(all three ship `librocprof-sys.so.1.6.0` from the same upstream
source baseline).

Without the cherry-pick, every MPI rank of an instrumented MPI +
OpenMP-target offload binary SIGSEGVs during static-init in
`rocprofiler_configure → sdk_tool_configure → rocprofsys_init_tooling_hidden`,
inside the `agent_type` map's `operator[]`. The crash chain enters
via the OMPT path (`__tgt_register_lib → ompt_libomp_connect →
ompt_start_tool → rocprofiler_set_api_table → rocprofiler_configure`)
and is reproduced cleanly by `MPI_Ghost_Exchange_Ver2_Rocprof-Sys`
in CTest.

Two of the three pieces of our v1.3.0 cherry-pick already landed
upstream in v1.6.0 via [PR #3412](https://github.com/ROCm/rocm-systems/pull/3412)
(merged 2026-04-08): `sdk_configured` is already a `std::atomic<bool>`
exchange in `sdk_tool_configure()`, and the
`settings_are_configured() || state < Active` guard already uses `||`
instead of `&&`. The third piece -- the **outer** once-guard in
`rocprofiler_configure()` itself -- was left non-atomic in PR #3412,
which permits a race that double-enters the body and lets the second
thread's caller use a half-populated `tool_data`. This bundle's
single 3-line patch promotes that outer guard to `std::atomic<bool>`,
closing the remaining hole.

Pin: upstream tag `therock-7.13` (sha `79e85e1`,
`projects/rocprofiler-systems/VERSION` = `1.6.0`). There is no
`rocm-7.13.0` tag upstream -- 7.13.0 was cut from the TheRock RC
line. `build_rocprof_sys_1_6_0()` hard-codes the pin accordingly.

References:
* upstream PR (parent of the same logical fix): https://github.com/ROCm/rocm-systems/pull/3412
* full bug write-up: `../../PROFILING_TEAM_REPORT_rocprof-sys_v1.6.0_2026_05_20.md`
* CTest reproducer: `/shareddata/cdash_testing/HPCTrainingExamples/tests/mpi_ghost_exchange_ver2.sh`

### `rocprof-sys-1.3.0/` -- one cherry-pick from upstream PR #3412

Affected ROCm releases: **7.2.0, 7.2.1**.

Without the cherry-pick, `rocprof-sys-run` SIGSEGVs in
`rocprofiler_configure +0x404` during static initialization when the
target binary is an MPI + OpenMP-target offload application. The
crash is timing-sensitive (a Heisenbug under `gdb`) and is triggered
during the early `.init_array` phase by a race in
`sdk_tool_configure()`:

* the function lacked an atomic once-guard, so it could be re-entered
  before the `rocprofsys::State` had reached `Active`; and
* the original `&&` in the init-tooling guard short-circuited the
  call to `rocprofsys_init_tooling_hidden()` whenever
  `settings_are_configured()` was already true (e.g. because
  `rocprof-sys-instrument`'s static constructor had set it), so
  `init_tooling()` was skipped, leaving the timemory settings
  registry (a `std::map<string, tim::tsettings*>` serialised through
  `cereal::PrettyJsonWriter`) half-initialised.

The cherry-pick adds the once-guard and flips `&&` to `||`; that is
the **entire** functional change. PR #3412 itself is much larger
(re-attach support, ~17 files); we deliberately take only the
bug-closing minimum, which is **6 source lines** in
`rocprofiler-sdk.cpp`.

References:
* upstream PR: https://github.com/ROCm/rocm-systems/pull/3412
* parent commit (= v1.3.0 baseline): `df199890^`
* full bug write-up + verification protocol: see
  `/shared/apps/ubuntu/opt/rocm-patches-7.2.1/doc/` on the cluster
  where the fix was first staged.

### How the patched .so wins runtime resolution (post-install steps)

Dropping the patched `librocprof-sys.so.X.Y.Z` next to the SDK and
adding the patches-overlay lib to `LD_LIBRARY_PATH` via the modulefile
is **not sufficient** on its own.  The SDK binary
`${ROCM_PATH}/bin/rocprof-sys-run` rewrites the child process's
`LD_LIBRARY_PATH` by prepending `${ROCPROFSYS_ROOT}/lib` (= the SDK's
own lib dir) ahead of whatever the parent shell inherited.  That
pushes the modulefile's overlay entry to a later position than the
SDK's lib dir, and the dynamic loader resolves `librocprof-sys.so.1`
to the SDK's unpatched copy in the profiled child -- so Bug A's
SIGSEGV in `rocprofiler_configure()` reappears even though the
patched .so is on disk and the modulefile is correct.

`rocm_patches.sh` therefore performs **two finishing steps** after
every successful build (and also during `--module-file-only`
backfill):

1. **`fix_overlay_runpath_and_libunwind`**: cmake bakes absolute
   paths into the patched .so's `DT_RUNPATH` that point inside the
   build tree (`<INSTALL_PREFIX>/build/rocprofiler-systems/external/timemory/...`).
   Those directories disappear once `build/` is cleaned up, and the
   .so silently picks up `libunwind.so.99: not found` / `libgotcha.so.2: not found`
   at load time.  The fix copies the timemory-bundled
   `libunwind.so.99.0.0` to `${INSTALL_PREFIX}/lib/` (borrowing from a
   sibling overlay if our own `build/` is gone -- DT_SONAME is the
   same across all our overlays so they are drop-in compatible),
   then rewrites `DT_RUNPATH` via `patchelf --set-rpath` to:

   ```
   $ORIGIN:$ORIGIN/../../rocm-X.Y.Z/lib/rocprofiler-systems:$ORIGIN/../../rocm-X.Y.Z/lib:/usr/lib/x86_64-linux-gnu/elfutils
   ```

   `$ORIGIN` resolves to `${INSTALL_PREFIX}/lib/` so the bundled
   libunwind is found, and the relative hops `$ORIGIN/../..` reach
   the SDK's lib + rocprofiler-systems subdir to resolve `libgotcha`
   etc.  Idempotent: a re-run detects the already-portable RUNPATH
   and skips.

2. **`swap_sdk_lib_symlink`**: turns the SDK's versioned
   `librocprof-sys.so.X.Y.Z` into a symlink that points at the
   overlay's patched copy.  The original SDK file is preserved as
   `librocprof-sys.so.X.Y.Z.orig` for clean rollback.  This is the
   step that actually wins the race against `rocprof-sys-run`'s
   `LD_LIBRARY_PATH` prepending: now wherever the dynamic loader
   resolves `librocprof-sys.so.1`, the patched bits run.  Only the
   one versioned file becomes a symlink; the `librocprof-sys.so.1`
   and `librocprof-sys.so` aliases (SDK-relative symlinks already)
   reach the patched lib transitively without modification.
   Idempotent: a re-run detects an existing symlink that already
   points at the overlay and exits without change.

Coverage matrix for these two finishing steps:

| ROCm release line | rocprof-sys overlay | runpath+libunwind fix | SDK symlink swap |
|-------------------|---------------------|-----------------------|------------------|
| `7.13.0`                    | yes (in-tree build, v1.6.0) | yes | yes |
| `afar-23.2.1`               | yes (in-tree build, v1.6.0) | yes | yes |
| `therock-23.2.0`            | yes (in-tree build, v1.6.0) | yes | yes |
| `7.2.0`, `7.2.1`            | yes (in-tree build, v1.3.0) | yes | yes |
| `7.2.2`, `7.2.3`, `7.2.4`   | yes (in-tree build, v1.3.0) | yes | yes |
| `7.1.0`, `7.1.1`            | yes (apply_and_build.sh)    | yes | yes |
| `7.0.0`, `7.0.1`, `7.0.2`   | yes (apply_and_build.sh)    | yes | yes |
| `6.4.0`, `6.4.1`, `6.4.2`, `6.4.3` | yes (apply_and_build.sh) | yes | yes |
| `afar-22.1.0`, `afar-22.2.0`       | yes (shortcut from rocm-patches-7.1.0/lib) | yes | yes |
| `6.3.0` -- `6.3.4`          | not engineered (different bug surface) | n/a | n/a |
| `therock-23.1.0`            | not engineered (v1.5.0 source; documented as passing MPI_Ghost_Exchange_Ver2) | n/a | n/a |

Rollback is one command per overlay: `mv ${ROCM_PATH}/lib/librocprof-sys.so.X.Y.Z.orig ${ROCM_PATH}/lib/librocprof-sys.so.X.Y.Z`.

### `rocprof-compute/` -- nuitka onefile rebuild of upstream rocprofiler-compute

Affected ROCm releases:

* **official releases (14):** 6.3.0, 6.3.1, 6.3.2, 6.3.3, 6.3.4,
  6.4.0, 6.4.1, 6.4.2, 6.4.3, 7.0.0, 7.0.1, 7.0.2, 7.1.0, 7.1.1
* **release-candidate flavours (3):** afar-22.1.0, afar-22.2.0,
  therock-23.2.0

Seventeen ROCm-installation flavours total.

This is a **rebuild-style** bundle: no `.patch` files, just three
shell artefacts (`install.sh`, `build.sh`, `README.md.in`) that the
`build_rocprof_compute()` function in `rocm_patches.sh` copies into
`/opt/rocm-patches-${ROCM_VERSION}/rocprof-compute/` and invokes.

Background.  On 6.3.x / 6.4.x / 7.0.x and on the afar/therock RC
flavours, the in-distribution `rocprof-compute` command is a symlink
to a Python wrapper whose pip dependencies were never installed by
HPCTrainingDock (`rocm_rocprof-compute_setup.sh` early-exits for
ROCM_VERSION > 6.1.2), so the wrapper aborts at startup with
`[ERROR] The 'astunparse==1.6.2' package was not found ...`.  Most
6.4.x / 7.0.x prefixes happen to have a working pre-built
`rocprof-compute.exe` next to the wrapper, but it is never wired into
`$PATH`.  6.3.x predates standalone-binary packaging entirely (the
v3.0.0 / Omniperf transition was Python-only) and ships no .exe at
all.  6.4.3's .exe is shipped with a broken pyinstaller bundle
(missing `VERSION.sha`) and is unusable.  The afar/therock RC trees
also ship no usable .exe.

The bundle's `build.sh` operates in **two source-pinning modes**:

* **official-release mode** (ROCM_VERSION is `X.Y.Z`): clone upstream
  at git tag `rocm-${ROCM_VERSION}`.  This is the path used by all 14
  official lines.
* **RC mode** (ROCM_VERSION matches `afar-*` / `therock-*`): clone
  upstream at the *commit SHA recorded in*
  `${ROCM_PATH}/libexec/rocprofiler-compute/VERSION.sha` (the .deb's
  own build provenance).  A full clone is done so the abbreviated
  SHA on disk (e.g. `bc96f0a`) can be resolved against the local
  object database via `git rev-parse`.  RC trees whose VERSION.sha
  is **missing or empty** are a *soft no-op*: `build.sh` exits 43
  (handled by `build_rocprof_compute()` in `rocm_patches.sh` as
  "no overlay produced, but not a failure"); we will not guess a
  commit, because the .deb may have been built from an unmerged
  branch we cannot identify.  This is what skips
  `therock-23.1.0` (empty `VERSION.sha`) and `afar-7.0.5` (no
  `rocprof-compute` install at all -- absent from the dispatch
  table so it never even reaches `build.sh`).

Three nuitka adjustments are shared across all modes:

* Auto-detected drop of `--include-package=rocprof_compute_tui` for
  v3.0.x / v3.1.x (the subpackage appeared in v3.2.x).
* Write `VERSION.sha` to both `src/` and the repo root so the
  `--include-data-files=${PROJECT_SOURCE_DIR}/VERSION*=./` glob
  actually captures it -- v3.0.x / v3.1.x crash hard at startup
  without it; v3.2.x falls back to "unknown" instead.
* Upstream-tag fallback for 6.3.4 (no `rocm-6.3.4` tag exists
  upstream so build.sh falls back to `rocm-6.3.3`).

`install.sh` does the wire-up: symlinks `bin/rocprof-compute ->
../lib/rocprof-compute.bin` and adds a single `prepend_path("PATH",
overlay/bin)` line to the modulefile.  The original ROCm distribution
bytes are *untouched* -- the overlay shadows the broken
in-distribution symlink via PATH ordering.

References:
* full design + per-version status table + build provenance:
  `/shared/apps/ubuntu/opt/rocm-patches-7.0.2/doc/ROCPROF_COMPUTE_OVERLAY.md`
  on the cluster.
* central bug report (Appendix D):
  `/shared/apps/ubuntu/opt/rocm-patches-7.2.1/doc/PROFILING_TEAM_REPORT.md`.

### Release-candidate flavour coverage matrix

RC trees on this cluster (`rocm-{therock,afar}-*` prefixes) are
pre-installed externally and the `SKIP_ROCM_INSTALL=1` branch of
`main_setup.sh` forces `rocm_setup.sh` to skip them.
`rocm_patches.sh` *does* still run on RC trees (see the same branch
of `main_setup.sh`), and its current per-tree coverage is:

| RC tree              | rocprof-compute overlay              | rocprof-sys overlay                 |
|----------------------|--------------------------------------|-------------------------------------|
| `afar-22.1.0`        | Track A attempted, **soft no-op**: VERSION.sha `167a9576` is not in any public ref of `github.com/ROCm/rocprofiler-compute` (verified via GitHub commits API HTTP 422). `build.sh` returns 43 and no overlay is produced. The .deb was likely built from an internal AMD branch. | Track B (out-of-tree `apply_and_build.sh` mapped to upstream tag `rocm-7.1.0` = v1.2.0 source; `librocprof-sys.so.1.2.0` drop-in copied from `rocm-patches-7.1.0/lib/`, identical SONAME=librocprof-sys.so.1 and matching rocprofiler-sdk SONAME).  Modulefile backfilled via `rocm_patches.sh --module-file-only`. |
| `afar-22.2.0`        | Track A attempted, **soft no-op**: VERSION.sha `bad92dc4` not in any public ref (HTTP 422 from commits API). Same root cause as 22.1.0. | Track B (same as 22.1.0) |
| `afar-7.0.5`         | not in dispatch (no `rocprof-compute` install on this tree) | n/a (no `rocprof-sys` install) |
| `therock-23.1.0`     | not in dispatch (empty `VERSION.sha`; cannot pin upstream commit) | not engineered (v1.5.0 source; documented as passing `MPI_Ghost_Exchange_Ver2`) |
| `therock-23.2.0`     | Track A attempted, **soft no-op**: VERSION.sha `bc96f0a` not in any public ref (HTTP 422 from commits API). Same root cause as the afar trees: built from internal AMD branch. | yes (in-tree build via `rocprof-sys-1.6.0` bundle, pinned to upstream tag `therock-7.13` = VERSION 1.6.0) |

Net Track A outcome for RC trees: on this cluster all three RC trees
that had a populated `VERSION.sha` produced *unresolvable* commits, so
no rocprof-compute overlay was produced for any of them.  The
machinery is in place and will start producing overlays automatically
the moment a future RC `.deb` ships a `VERSION.sha` that has been
pushed to the public repo.  The "do not guess a commit" policy
trades coverage breadth for build-provenance fidelity: a guessed
overlay would not necessarily reproduce the in-distribution binary's
behaviour.

## Adding a new patch

1. Drop the `git format-patch`-style file under
   `<component>-<version>/`.
2. Extend `rocm_version_to_patches()` in
   `rocm/scripts/rocm_patches.sh` so the affected ROCm releases map
   to the new directory.
3. Add a `build_<component>()` shell function in the same script if
   the component is not already handled (the rocprof-sys path is a
   reasonable template).
