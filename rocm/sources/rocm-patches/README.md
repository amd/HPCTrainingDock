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

### `rocprof-compute/` -- nuitka onefile rebuild of upstream rocprofiler-compute

Affected ROCm releases: **6.3.0, 6.3.1, 6.3.2, 6.3.3, 6.3.4, 6.4.0,
6.4.1, 6.4.2, 6.4.3, 7.0.0, 7.0.1, 7.0.2, 7.1.0, 7.1.1** (fourteen
release lines).

This is a **rebuild-style** bundle: no `.patch` files, just three
shell artefacts (`install.sh`, `build.sh`, `README.md.in`) that the
`build_rocprof_compute()` function in `rocm_patches.sh` copies into
`/opt/rocm-patches-${ROCM_VERSION}/rocprof-compute/` and invokes.

Background.  On 6.3.x / 6.4.x / 7.0.x the in-distribution
`rocprof-compute` command is a symlink to a Python wrapper whose pip
dependencies were never installed by HPCTrainingDock
(`rocm_rocprof-compute_setup.sh` early-exits for ROCM_VERSION > 6.1.2),
so the wrapper aborts at startup with
`[ERROR] The 'astunparse==1.6.2' package was not found ...`.  Most
6.4.x / 7.0.x prefixes happen to have a working pre-built
`rocprof-compute.exe` next to the wrapper, but it is never wired into
`$PATH`.  6.3.x predates standalone-binary packaging entirely (the
v3.0.0 / Omniperf transition was Python-only) and ships no .exe at
all.  6.4.3's .exe is shipped with a broken pyinstaller bundle
(missing `VERSION.sha`) and is unusable.

The bundle's `build.sh` produces a fresh nuitka onefile from
`https://github.com/ROCm/rocprofiler-compute.git` @ tag
`rocm-${ROCM_VERSION}` using the same recipe that
`rocm_setup.sh` uses for `>= 7.1.0`, with one auto-detected
adjustment (drop `--include-package=rocprof_compute_tui` for v3.0.x /
v3.1.x, which lacks that subpackage), one bug-fix relative to the
in-tree build path (write `VERSION.sha` to both `src/` and the repo
root so the `--include-data-files=${PROJECT_SOURCE_DIR}/VERSION*=./`
glob actually captures it -- v3.0.x / v3.1.x crash hard at startup
without it; v3.2.x falls back to "unknown" instead), and one
upstream-tag fallback for 6.3.4 (no `rocm-6.3.4` tag exists upstream
so build.sh falls back to `rocm-6.3.3`).

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

## Adding a new patch

1. Drop the `git format-patch`-style file under
   `<component>-<version>/`.
2. Extend `rocm_version_to_patches()` in
   `rocm/scripts/rocm_patches.sh` so the affected ROCm releases map
   to the new directory.
3. Add a `build_<component>()` shell function in the same script if
   the component is not already handled (the rocprof-sys path is a
   reasonable template).
