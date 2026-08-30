# Layer 2 — rocprofiler-sdk profiling guard (`librocprof_guard.so`)

The single durable guard against MI300A profiling node-resets. Replaces the Layer-1
`rocprofv3` PATH-shim. Companion: `../rocprof-watch/GUARD-EXPANSION-PLAN.md` (design,
evidence, rollout) and `../rocprof-watch/crash-evidence.jsonl` (the KPI).

## Why a rocprofiler-sdk tool (not CLI shims)
Every modern profiler front-end — `rocprofv3`, `rocprof-sys` (the released name for
omnitrace), `rocprof-compute`, and the PyTorch/roctracer path — initializes through
**rocprofiler-sdk**. There is no `rocprofv2`/`rocprof` to wrap. So one rocprofiler-sdk
*tool* at that layer covers them all.

## What it does (MI300A only)
rocprofiler-sdk `dlopen`s every lib in `ROCP_TOOL_LIBRARIES` and calls its
`rocprofiler_configure` when profiling initializes. Ours (returns `NULL` — creates no
context, never touches the real tool's data):
1. **Stands down** for non-profiling GPU apps. On ROCm 10.x the sdk *core* initializes for
   every HIP app, so `configure` is called even without profiling; we act only when a real
   collector is present (`librocprofiler-sdk-tool`/`libroctracer`/att/spm/pc, or
   `HSA_TOOLS_LIB`).
2. **Strips beta env** — `ROCPROFILER_PC_SAMPLING_BETA_ENABLED`, `..._SPM_BETA_ENABLED`,
   `ROCPROF_ATT_LIBRARY_PATH` (Vector B). Best-effort; the modulefile `unsetenv` is primary.
3. **Serializes** concurrent profiling *sessions* via `flock(/tmp/rocprofv3-pmc/pmc.node.lock)`,
   with **per-`SLURM_JOB_ID` leader election** (same-job ranks are followers → MPI never
   deadlocks) and an **ancestor-guard inherit** (never re-locks under a parent guard).
4. **Marks guarded** — holds the node-lock fd (what `rocprof-watch` keys on) and exports
   `ROCPROFV3_GUARDED=1`.

Pure libc (no ROCm link) → one `.so` for all ROCm lines. Fail-open: any error → proceed +
syslog (`-t rocprof-guard`).

## Escape hatches
- `ROCPROFV3_NOLOCK=1` — don't serialize (still scrubs beta). `ROCPROFV3_LOCK_WAIT=N` — max wait.
- Test hooks (off in prod): `ROCPROF_GUARD_FORCE_MI300A=1`, `ROCPROF_GUARD_FORCE_ACTIVE=1`,
  `ROCPROF_GUARD_DEBUG=1`.

## Files
- `rocprof_guard.c` — the interposer.  `build.sh` — build `.so` + `selftest`.
- `selftest.c` / `run_selftest.sh` — no-GPU logic tests (scrub / leader / follower / ancestor).
- `trivial_hip.cpp` — host-only HIP probe for the safe (`--hip-trace`) node smoke test.
- `apply_layer2.sh` — migrate live modulefiles (`--all` / `--revert-all` / `--list`).
- Canonical build installer: `HPCTrainingDock/bare_system/rocm10_rocprofv3_guard.sh`
  (builds + wires L2, strips legacy L1). **Commit/push that repo change** so nightly
  builds keep installing L2.

## Build / test / deploy
```bash
./build.sh          # -> librocprof_guard.so + selftest
./run_selftest.sh   # T1-T4, no GPU
./apply_layer2.sh --all        # migrate every 10.x modulefile (backs up each)
./apply_layer2.sh --revert-all # restore newest backups
```
No image rebuild: modulefiles + `.so` live on NFS (`/nfsapps`), read live by the nodes.
