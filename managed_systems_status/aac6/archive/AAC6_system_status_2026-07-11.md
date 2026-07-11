# AAC6 System Status — 2026-07-11

## Sys Admins Comments

No comments

## Overview

- Date: 2026-07-11 04:30:02 CDT
- OS: Ubuntu 24.04.4 LTS
- Kernel: 6.8.0-100-generic (x86_64)
- Login host: aac6-fe1
- ROCm default: 7.2.4

## Login & Access

- Authentication: SSH key + TOTP via PrivacyIDEA (required)
- Enroll 2FA: `enroll-2fa` on the login node (see `man aac6_2fa_apps`)

## Compute

- Default partition: PPAC_MI300A_CPX

| Partition | Nodes | CPUs/node | GRES | Max walltime | Default |
|---|---|---|---|---|---|
| PPAC_MI300A_CPX | 1 | 192 | gpu:24(S:0-3) | 8:00:00 | yes |
| PPAC_MI300A_SPX | 4 | 192 | gpu:4 | 8:00:00 | no |
| sh5_cpx_admin_long | 3 | 48 | gpu:6 | 2-00:00:00 | no |
| SH5_MI300A_CPX | 3 | 48 | gpu:6 | 8:00:00 | no |
| SH5_MI300A_SPX | 1 | 48 | gpu:1 | 8:00:00 | no |

Note: `--gpus=<n>` is required to be allocated GPUs in any partition.

## Compute Health

| Node | State |
|---|---|
| ppac-pl1-s24-30 | down |

## Software Stack

- ROCm versions available: 6.3.0, 6.3.1, 6.3.2, 6.3.3, 6.3.4, 6.4.0, 6.4.1, 6.4.2, 6.4.3, 7.0.0, 7.0.1, 7.0.2, 7.1.0, 7.1.1, 7.2.0, 7.2.1, 7.2.2, 7.2.3, 7.2.4, 7.12.0, 7.13.0, afar-22.1.0-7.1.0, afar-22.2.0-7.2.0, afar-23.1.0-7.12.0, afar-23.2.1-7.13.0
- gcc: 13.3.0
- Other user-facing module families: emacs, miniconda3, miniforge3, rocbudai, roofline-extractor, tracelens, turbovnc
- Browse all modules with `module avail`. See `man aac6_modules`.

## Containers

- podman: not installed
- apptainer: 1.5.2 (`module load apptainer`)
- singularity: via apptainer compatibility shim
- ROCm device binding is automatic on compute nodes. See `man aac6_podman` and `man aac6_apptainer`.

## Filesystems

| Mount | Size | Used |
|---|---|---|
| / | 800G | 56% |
| /shared | 67T | 61% |

## Help & Documentation

- `man aac6` for the system overview.
- AAC6 man pages installed: aac6, aac6_2fa_apps, aac6_apptainer, aac6_data_policies, aac6_flux, aac6_modules, aac6_novnc, aac6_paraview, aac6_podman, aac6_slurm, aac6_visit, aac6_vnc, aac6_x11
- Examples: https://github.com/amd/HPCTrainingExamples
- Login info: https://github.com/amd/HPCTrainingExamples/tree/main/login_info/AAC
- This page: https://github.com/amd/HPCTrainingDock/tree/main/managed_systems_status/aac6

## Changes Since Previous Snapshot

- Down/drained nodes:
    + ppac-pl1-s24-30:down
- /shared/apps/ubuntu/opt:
    - tracelens

---

*Generated on 2026-07-11 04:30:02 CDT.*

<!-- AAC6_STATUS_METADATA — machine-readable facts for the next-run diff. Do not edit by hand.
os=Ubuntu 24.04.4 LTS
kernel=6.8.0-100-generic
rocm_default=7.2.4
rocm_versions=6.3.0,6.3.1,6.3.2,6.3.3,6.3.4,6.4.0,6.4.1,6.4.2,6.4.3,7.0.0,7.0.1,7.0.2,7.1.0,7.1.1,7.2.0,7.2.1,7.2.2,7.2.3,7.2.4,7.12.0,7.13.0,afar-22.1.0-7.1.0,afar-22.2.0-7.2.0,afar-23.1.0-7.12.0,afar-23.2.1-7.13.0
module_top=emacs,miniconda3,miniforge3,rocbudai,roofline-extractor,tracelens,turbovnc
default_partition=PPAC_MI300A_CPX
partitions=PPAC_MI300A_CPX:1,PPAC_MI300A_SPX:4,sh5_cpx_admin_long:3,SH5_MI300A_CPX:3,SH5_MI300A_SPX:1
podman=not installed
apptainer=1.5.2
singularity=via apptainer compatibility shim
gcc=13.3.0
tfa=SSH key + TOTP via PrivacyIDEA (required)
man_pages=aac6,aac6_2fa_apps,aac6_apptainer,aac6_data_policies,aac6_flux,aac6_modules,aac6_novnc,aac6_paraview,aac6_podman,aac6_slurm,aac6_visit,aac6_vnc,aac6_x11
modules_all=emacs/30.1,miniconda3/25.3.1,miniforge3/24.9.0,rocbudai/dev,rocm/6.3.0,rocm/6.3.1,rocm/6.3.2,rocm/6.3.3,rocm/6.3.4,rocm/6.4.0,rocm/6.4.1,rocm/6.4.2,rocm/6.4.3,rocm/7.0.0,rocm/7.0.1,rocm/7.0.2,rocm/7.1.0,rocm/7.1.1,rocm/7.12.0,rocm/7.13.0,rocm/7.2.0,rocm/7.2.1,rocm/7.2.2,rocm/7.2.3,rocm/7.2.4,rocm/afar-22.1.0-7.1.0,rocm/afar-22.2.0-7.2.0,rocm/afar-23.1.0-7.12.0,rocm/afar-23.2.1-7.13.0,roofline-extractor/dev,tracelens/dev,turbovnc/3.0.3
down_nodes=ppac-pl1-s24-30:down
opt_dirs=amdgpu,AMDuProf_5.3-518,flux-accounting,flux-env.sh,flux-pilot-configs,flux.sh.fixed,fp64monitor,miniconda3,miniconda3-v25.3.1,miniforge3,miniforge3-v24.9.0,opencode,rocbudai,rocm-6.3.0,rocm-6.3.1,rocm-6.3.2,rocm-6.3.3,rocm-6.3.4,rocm-6.4.0,rocm-6.4.1,rocm-6.4.2,rocm-6.4.3,rocm-7.0.0,rocm-7.0.1,rocm-7.0.2,rocm-7.1.0,rocm-7.1.1,rocm-7.12.0,rocm-7.13.0,rocm-7.2.0,rocm-7.2.2,rocm-7.2.3,rocm-7.2.4,rocm-afar-22.1.0,rocm-afar-22.2.0,rocm-afar-23.1.0,rocm-afar-23.2.1,rocm-patches-6.3.0,rocm-patches-6.3.1,rocm-patches-6.3.2,rocm-patches-6.3.3,rocm-patches-6.3.4,rocm-patches-6.4.0,rocm-patches-6.4.1,rocm-patches-6.4.2,rocm-patches-6.4.3,rocm-patches-7.0.0,rocm-patches-7.0.1,rocm-patches-7.0.2,rocm-patches-7.1.0,rocm-patches-7.1.1,rocm-patches-7.13.0,rocm-patches-7.2.0,rocm-patches-7.2.2,rocm-patches-7.2.3,rocm-patches-7.2.4,rocm-patches-afar-22.1.0,rocm-patches-afar-22.2.0,rocm-patches-afar-23.1.0,rocm-patches-afar-23.2.1,rocmplus-6.3.0,rocmplus-6.3.1,rocmplus-6.3.2,rocmplus-6.3.3,rocmplus-6.3.4,rocmplus-6.4.0,rocmplus-6.4.1,rocmplus-6.4.2,rocmplus-6.4.3,rocmplus-7.0.0,rocmplus-7.0.1,rocmplus-7.0.2,rocmplus-7.1.0,rocmplus-7.1.1,rocmplus-7.12.0,rocmplus-7.13.0,rocmplus-7.2.0,rocmplus-7.2.2,rocmplus-7.2.3,rocmplus-7.2.4,rocmplus-afar-22.1.0-7.1.0,rocmplus-afar-22.2.0-7.2.0,rocmplus-afar-23.1.0-7.12.0,rocmplus-afar-23.2.1-7.13.0,spack,spack-envs
-->
