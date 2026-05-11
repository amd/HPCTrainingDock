# HPCTrainingDock — Operator Examples

Sample commands captured while developing and exercising the Slurm-driven
ROCm SDK build and ROCm-plus software install pipelines for `/nfsapps` on the
sh5 admin nodes. All commands assume:

- Logged in as a member of the `adm` group on the AAC6 login node.
- Running from `~/repos/HPCTrainingDock` (the path mirroring is at
  `/shared/apps/ubuntu/sbin/` for the operational copies).
- Slurm partition `sh5_cpx_admin_long` (sh5 nodes, 48h MaxTime, AllowGroups=adm).
- `/nfsapps/opt` is the canonical install root and `/nfsapps/modules` is the
  Lmod root (`base/rocm/<v>.lua` for the SDK meta-modules; `rocm-<v>/<pkg>`
  for tools shipped with the SDK; `rocmplus-<v>/<pkg>` for the on-top-of-ROCm
  software stack).

The companion reports are
`/shared/apps/ubuntu/docs/System_Management_Reports/24_rocm_batch_install.md`
(SDK builds) and
`/shared/apps/ubuntu/docs/System_Management_Reports/25_rocmplus_batch_install.md`
(software-stack installs).

---

## 1. ROCm SDK build sweep — `bare_system/run_rocm_build_sweep.sh`

Builds `/nfsapps/opt/rocm-<v>/` from the `HPCTrainingDock` Dockerfile, deploys
the resulting `.tgz` and module tarballs, prunes old `CacheFiles/*.tgz`.

### 1.1 Full default sweep (8 versions)

```bash
cd ~/repos/HPCTrainingDock
bare_system/run_rocm_build_sweep.sh
# default --rocm-versions "7.1.0 7.0.2 7.0.1 7.0.0 6.4.3 6.4.2 6.4.1 6.4.0"
# default --min-per-version 60   --margin-min 60   -> --time computed
# default --keep-tarballs 3      --replace-existing 0
# default partition sh5_cpx_admin_long
```

### 1.2 Single-version test build

```bash
bare_system/run_rocm_build_sweep.sh --rocm-versions "7.1.0"
# Submitted batch job NNNN, --time=02:00:00 (1 * 60 + 60 margin)
```

### 1.3 Explicit version list with custom per-version budget

```bash
bare_system/run_rocm_build_sweep.sh \
   --rocm-versions    "7.0.2 7.0.1 7.0.0" \
   --min-per-version  44 \
   --margin-min       60
```

### 1.4 Force overwrite an existing install

```bash
bare_system/run_rocm_build_sweep.sh \
   --rocm-versions "7.1.0" \
   --replace-existing 1
# /nfsapps/opt/rocm-7.1.0 (and its module files) are removed and replaced.
# Mirrors --replace-existing in run_rocmplus_install_sweep.sh; the older
# spelling --force-extract / FORCE_EXTRACT is still accepted as a
# deprecated alias.
```

### 1.5 Dry-run (print sbatch command without submitting)

```bash
bare_system/run_rocm_build_sweep.sh \
   --rocm-versions "7.1.0 7.0.2" \
   --dry-run
```

### 1.6 What gets produced per version

```bash
ls /nfsapps/opt/rocm-7.1.0/                  # SDK install
ls /nfsapps/modules/base/rocm/7.1.0.lua      # SDK meta-module
ls /nfsapps/modules/rocm-7.1.0/              # category for SDK tools (hipfort, rocprof-*, ...)
ls $HOME/repos/HPCTrainingDock/CacheFiles/   # tarballs (kept: 3 most recent rocm-*.tgz)
```

### 1.7 Operate on a single version directly (no sweep submitter)

```bash
# Submit a single-version job using the same sbatch the sweep submitter uses,
# bypassing the submitter logic. Useful when iterating on one stuck version.
sbatch \
   --job-name=rocm_build_7.0.1 \
   --partition=sh5_cpx_admin_long \
   --time=02:00:00 \
   --export=ALL,ROCM_VERSIONS=7.0.1,REPLACE_EXISTING=1,KEEP_TARBALLS=3 \
   bare_system/run_rocm_build_sweep.sbatch
```

### 1.8 In-container manual rebuild (last-resort, no Slurm)

The sweep ultimately drives `bare_system/run_rocm_build.sh`, which in turn
calls `bare_system/test_install.sh` for the docker build and runs the
container non-interactively. To reproduce just one phase by hand on the
sh5 node:

```bash
ssh sh5-pl1-s12-12
cd ~/repos/HPCTrainingDock
bare_system/run_rocm_build.sh \
   --rocm-version    7.0.1 \
   --distro          ubuntu \
   --distro-version  24.04 \
   --amdgpu-gfxmodel "gfx942;gfx90a" \
   --use-makefile    1 \
   --replace-existing 0 \
   --keep-tarballs    3
```

---

## 2. ROCm-plus software install sweep — `bare_system/run_rocmplus_install_sweep.sh`

Builds the on-top-of-ROCm software stack via `bare_system/main_setup.sh`,
loaded with `rocm/<v>` for each version. Per-version dependency chain
(`afterany`), 24h walltime per job by default.

### 2.1 Two-version dependency-chain smoke test (fast)

```bash
cd ~/repos/HPCTrainingDock
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions  "7.0.1 7.0.2" \
   --quick-installs 1
# Submitted batch job NNNN     (rocm-7.0.1, no dependency)
# Submitted batch job NNNN+1   (rocm-7.0.2, --dependency=afterany:NNNN)
```

### 2.2 Full single-version install (everything on, ~16-24h)

```bash
bare_system/run_rocmplus_install_sweep.sh --rocm-versions "7.0.2"
```

### 2.3 Multi-version full sweep — chain depth bounded only by patience

```bash
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions "7.1.0 7.0.2 7.0.1 6.4.3 6.4.2 6.4.1 6.4.0"
# 7 jobs, each 24h, chained afterany. Stays inside the 48h
# per-JOB partition cap because each job is independent.
```

### 2.4 Reinstall an already-deployed version cleanly

```bash
# Nukes /nfsapps/opt/rocmplus-7.0.1 and /nfsapps/modules/rocmplus-7.0.1
# before installing. Does NOT touch /nfsapps/opt/rocm-7.0.1 (the SDK).
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions    "7.0.1" \
   --replace-existing 1
```

### 2.5 Append to an existing rocm SDK build sweep

```bash
# Wait for SDK build job 7900 to finish, then start the rocmplus chain.
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions "7.0.1 7.0.2" \
   --start-after   7900 \
   --quick-installs 1
```

### 2.6 Custom paths (e.g. building a 22.04 staging tree)

The submitter (and the sbatch) auto-detect the python minor version from
`/etc/os-release` on the compute node — Ubuntu 22.04 → `3.10`, 24.04 → `3.12` —
so `--python-version` is normally **not** needed. Override only if you really
want to deviate from the distro default.

```bash
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions     "7.0.2" \
   --top-install-path  /shared/apps/ubuntu/opt \
   --top-module-path   /shared/apps/modules/ubuntu/lmodfiles \
   --rocm-install-path /shared/apps/ubuntu/opt
```

### 2.7 Dry-run (preview the chained sbatch commands)

```bash
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions  "7.0.1 7.0.2" \
   --quick-installs 1 \
   --dry-run
```

### 2.7a Build only specific packages (`--packages` whitelist)

`--packages "name1 name2 ..."` disables every package not on the list. It
**overrides** `--quick-installs` for the listed packages, so you can
explicitly request a long-pole package even when the default is to skip
them. With `--replace-existing 1`, only the *whitelisted* package's
install + module dirs are removed and rebuilt; everything else stays put.

Recognized names: `flang-new`, `openmpi`, `mpi4py`, `mvapich`,
`rocprof-sys`, `rocprof-compute`, `hpctoolkit`, `likwid`, `scorep`, `tau`,
`cupy`, `hip-python`, `tensorflow`, `jax`, `ftorch`, `pytorch`, `magma`,
`elpa`, `kokkos`, `miniconda3`, `miniforge3`, `hipfort`, `hipifly`, `hdf5`,
`netcdf`, `fftw`, `petsc`, `hypre`.

```bash
# Re-build only the openmpi bundle (xpmem/ucx/ucc/openmpi) for rocm-7.0.2,
# wiping any prior versions on /nfsapps:
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions    "7.0.2" \
   --replace-existing 1 \
   --packages         "openmpi"

# Quick-install run, but force pytorch to actually build:
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions  "7.0.2" \
   --quick-installs 1 \
   --packages       "pytorch"

# Rebuild fftw + netcdf for several ROCm versions in one chain:
bare_system/run_rocmplus_install_sweep.sh \
   --rocm-versions    "7.0.1 7.0.2 7.1.0" \
   --replace-existing 1 \
   --packages         "fftw netcdf"
```

`--packages` is also available directly on `bare_system/main_setup.sh` if
you bypass Slurm.

### 2.8 Run `main_setup.sh` directly (no Slurm) on a node with GPUs

```bash
# From an interactive Slurm session OR ssh'd into the sh5 node:
module use /nfsapps/modules/base
module load rocm/7.0.1

cd ~/repos/HPCTrainingDock
bare_system/main_setup.sh \
   --amdgpu-gfxmodel    'gfx942;gfx90a' \
   --rocm-install-path  /nfsapps/opt \
   --top-install-path   /nfsapps/opt \
   --top-module-path    /nfsapps/modules \
   --python-version     10 \
   --quick-installs     1 \
   --replace-existing   0
```

> Use `--python-version 10` on Ubuntu 22.04 (the distro default) and `12` on
> 24.04. The Slurm sweep auto-detects this; `main_setup.sh` invoked directly
> still requires the flag.

---

## 3. Slurm queue management

```bash
# What's in the admin queue
squeue -p sh5_cpx_admin_long -o "%.8i %.18j %.10P %.8u %.8T %.10M %.20R %.10l"

# What's running for me, sorted by submit order
squeue -u $USER --sort=i -o "%.8i %.18j %.8T %.10M %.20R %.10l %.16E"

# Inspect dependency wiring on a pending job
scontrol show job <jobid> | grep -E 'JobState|Dependency|Reason|TimeLimit|NodeList'

# Per-version exit summary for a chain
sacct -j 7843,7844,7845 -o JobID,JobName,State,ExitCode,Elapsed,NodeList

# Cancel one job in a chain (the rest still chain off afterany,
# so dependents will release and start anyway).
scancel <jobid>
```

---

## 4. Live log inspection

```bash
# rocm SDK sweep (single sbatch with internal loop)
tail -f slurm-<jobid>-rocm-sweep.out
tail -f sweep_summary_*.out          # per-version SKIP/OK/FAIL ledger

# rocmplus install (one sbatch per version)
tail -f slurm-<jobid>-rocmplus-<v>.out
tail -f slurm-<jobid>-rocmplus-<v>.err
```

---

## 5. Verifying a deployed ROCm + rocmplus pair

```bash
# SDK
ls /nfsapps/opt/rocm-7.0.1/                   # bin/ lib/ include/ ...
ls /nfsapps/modules/base/rocm/7.0.1.lua

# rocmplus packages
ls /nfsapps/opt/rocmplus-7.0.1/               # openmpi/ kokkos/ hdf5/ ...
ls /nfsapps/modules/rocmplus-7.0.1/           # openmpi/ kokkos/ hdf5/ ...

# Lmod end-to-end
module use /nfsapps/modules/base
module load rocm/7.0.1                        # adds /nfsapps/modules/rocm-7.0.1
                                              # and  /nfsapps/modules/rocmplus-7.0.1
                                              # to MODULEPATH automatically
module avail                                   # everything for this rocm version
module load openmpi
mpicc --version
```

---

## 6. NFS / mount sanity on sh5 compute nodes

```bash
# What the controller exports for /nfsapps
cat /etc/exports                | grep nfsapps
cat /etc/exports.d/nfsapps_sh5_rw.exports

# What the sh5 node has mounted
ssh sh5-pl1-s12-12 'mount | grep nfsapps'

# What the warewulf-managed fstab says (rendered from the fstab overlay
# resource list)
ssh sh5-pl1-s12-12 'cat /etc/fstab | grep nfsapps'

# Apply the per-host server-side rw export after editing
sudo exportfs -ra
sudo exportfs -v | grep nfsapps

# Defensive on-node remount (what run_rocmplus_install.sbatch does on entry)
ssh sh5-pl1-s12-12 'sudo mount -o remount,rw /nfsapps && touch /nfsapps/.write_test && rm /nfsapps/.write_test'
```

---

## 7. Common one-off operations

### 7.1 Just rebuild the docker image without doing the install

```bash
bare_system/test_install.sh \
   --rocm-version 7.0.1 \
   --distro ubuntu --distro-version 24.04 \
   --amdgpu-gfxmodel "gfx90a;gfx942" \
   --use-makefile 1
# Stops after `docker build` -- no make rocm, no extract.
```

### 7.2 Clean the `CacheFiles` tarball cache by hand

```bash
ls -lt $HOME/repos/HPCTrainingDock/CacheFiles/*/rocm-*.tgz
# Keep the 3 most recent; the sweep does this automatically via trap EXIT,
# but if a process was killed mid-stream:
find $HOME/repos/HPCTrainingDock/CacheFiles -name 'rocm-*.tgz' \
   ! -name 'rocm-modules-*.tgz' -printf '%T@ %p\n' \
   | sort -rn | tail -n +4 | awk '{print $2}' | xargs -r rm -v
```

### 7.3 Check group + partition entitlement

```bash
groups | tr ' ' '\n' | grep '^adm$'   # must print "adm"
sinfo -p sh5_cpx_admin_long           # 2 nodes, 48h MaxTime
```

### 7.4 Keep state across login bounces

The whole pipeline is sbatch-based, so jobs survive ssh / tmux / VPN drops.
For interactive babysitting that survives a disconnect, run the submitter
in tmux on the login node:

```bash
tmux new -s rocmsweep
# inside tmux:
bare_system/run_rocmplus_install_sweep.sh --rocm-versions "..." --quick-installs 1
# Ctrl-b d  to detach.  Reattach later with:
tmux attach -t rocmsweep
```
