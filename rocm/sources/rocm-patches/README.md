# rocm-patches: vendored cherry-picks for the bundled ROCm SDK

This directory holds **minimal**, self-contained patches that
`rocm/scripts/rocm_patches.sh` applies on top of the SDK installed
by `rocm/scripts/rocm_setup.sh`.

## Layout

```
sources/rocm-patches/
  README.md
  <component>-<bug-version>/
    NNNN-<short-name>.patch       # one or more git-format patches
```

Subdirectory naming is keyed by the **upstream component + the version
of that component that contains the bug**, not by the ROCm release.
This is important because a single patch typically applies to every
ROCm release that ships the same buggy component (for instance,
`rocprof-sys-1.3.0` is the v1.3.0 source baseline that ships with
both ROCm 7.2.0 and 7.2.1).

The mapping from ROCm release to which subdirectory of patches to
apply lives in `rocm/scripts/rocm_patches.sh` (see the
`rocm_version_to_patches()` function there). Adding a new vendored
fix is a two-line change: drop the patch under
`<component>-<version>/` and extend that mapping.

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

## Adding a new patch

1. Drop the `git format-patch`-style file under
   `<component>-<version>/`.
2. Extend `rocm_version_to_patches()` in
   `rocm/scripts/rocm_patches.sh` so the affected ROCm releases map
   to the new directory.
3. Add a `build_<component>()` shell function in the same script if
   the component is not already handled (the rocprof-sys path is a
   reasonable template).
