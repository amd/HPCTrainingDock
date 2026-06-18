# AAC6 System Status — 2026-06-18

## Sys Admins Comments

No comments

## Overview

- Date: 2026-06-18 04:30:02 CDT
- OS: Ubuntu 22.04.5 LTS
- Kernel: 6.5.0-45-generic (x86_64)
- Login host: pl1vm1mi300ctln01
- ROCm default: 7.2.3

## Login & Access

- Authentication: SSH key + TOTP via PrivacyIDEA (required)
- Enroll 2FA: `enroll-2fa` on the login node (see `man aac6_2fa_apps`)

## Compute

- Default partition: 1CN192C24G1H_MI300A_Ubuntu22

| Partition | Nodes | CPUs/node | GRES | Max walltime | Default |
|---|---|---|---|---|---|
| 1CN192C24G1H_MI300A_Ubuntu22 | 1 | 192 | gpu:24(S:0-3) | 8:00:00 | yes |
| 1CN192C4G1H_MI300A_Ubuntu22 | 4 | 192 | gpu:4 | 8:00:00 | no |
| 1CN48C6G1H_MI300A_Ubuntu22 | 4 | 48 | gpu:6 | 8:00:00 | no |
| sh5_cpx_admin_long | 4 | 48 | gpu:6 | 2-00:00:00 | no |

Note: `--gpus=<n>` is required to be allocated GPUs in any partition.

## Compute Health

All compute nodes are in a healthy state (alloc/idle/mix/...).

## Software Stack

- ROCm versions available: 6.3.0, 6.3.1, 6.3.2, 6.3.3, 6.3.4, 6.4.0, 6.4.1, 6.4.2, 6.4.3, 7.0.0, 7.0.1, 7.0.2, 7.1.0, 7.1.1, 7.2.0, 7.2.1, 7.2.2, 7.2.3, 7.2.4, 7.12.0, 7.13.0, afar-22.1.0-7.1.0, afar-22.2.0-7.2.0, afar-23.1.0-7.12.0, afar-23.2.1-7.13.0, afar-23.3.0-7.14.0
- gcc: 11.4.0
- Other user-facing module families: apptainer, fp64monitor, gcc, hmmer, miniconda3, miniforge3, nextflow, paraview, rocbudai, roofline-extractor, tracelens, turbovnc, uprof, visit
- Browse all modules with `module avail`. See `man aac6_modules`.

## Containers

- podman: 4.6.2
- apptainer: 1.4.5 (`module load apptainer`)
- singularity: via apptainer compatibility shim
- ROCm device binding is automatic on compute nodes. See `man aac6_podman` and `man aac6_apptainer`.

## Filesystems

| Mount | Size | Used |
|---|---|---|
| /home | 207G | 61% |
| /shared | 67T | 60% |

## Help & Documentation

- `man aac6` for the system overview.
- AAC6 man pages installed: aac6, aac6_2fa_apps, aac6_apptainer, aac6_data_policies, aac6_flux, aac6_modules, aac6_novnc, aac6_paraview, aac6_podman, aac6_slurm, aac6_visit, aac6_vnc, aac6_x11
- Examples: https://github.com/amd/HPCTrainingExamples
- Login info: https://github.com/amd/HPCTrainingExamples/tree/main/login_info/AAC
- This page: https://github.com/amd/HPCTrainingDock/tree/main/managed_systems_status/aac6

## Changes Since Previous Snapshot

- Down/drained nodes:
    - ppac-pl1-s24-35:drain

---

*Generated on 2026-06-18 04:30:02 CDT.*

<!-- AAC6_STATUS_METADATA — machine-readable facts for the next-run diff. Do not edit by hand.
os=Ubuntu 22.04.5 LTS
kernel=6.5.0-45-generic
rocm_default=7.2.3
rocm_versions=6.3.0,6.3.1,6.3.2,6.3.3,6.3.4,6.4.0,6.4.1,6.4.2,6.4.3,7.0.0,7.0.1,7.0.2,7.1.0,7.1.1,7.2.0,7.2.1,7.2.2,7.2.3,7.2.4,7.12.0,7.13.0,afar-22.1.0-7.1.0,afar-22.2.0-7.2.0,afar-23.1.0-7.12.0,afar-23.2.1-7.13.0,afar-23.3.0-7.14.0
module_top=apptainer,fp64monitor,gcc,hmmer,miniconda3,miniforge3,nextflow,paraview,rocbudai,roofline-extractor,tracelens,turbovnc,uprof,visit
default_partition=1CN192C24G1H_MI300A_Ubuntu22
partitions=1CN192C24G1H_MI300A_Ubuntu22:1,1CN192C4G1H_MI300A_Ubuntu22:4,1CN48C6G1H_MI300A_Ubuntu22:4,sh5_cpx_admin_long:4
podman=4.6.2
apptainer=1.4.5
singularity=via apptainer compatibility shim
gcc=11.4.0
tfa=SSH key + TOTP via PrivacyIDEA (required)
man_pages=aac6,aac6_2fa_apps,aac6_apptainer,aac6_data_policies,aac6_flux,aac6_modules,aac6_novnc,aac6_paraview,aac6_podman,aac6_slurm,aac6_visit,aac6_vnc,aac6_x11
modules_all=apptainer/1.4.5,fp64monitor/dev,gcc/base,hmmer/3.4,miniconda3/25.3.1,miniforge3/24.9.0,nextflow/26.02.0,paraview/5.13.3,rocbudai/dev,rocm/6.3.0,rocm/6.3.1,rocm/6.3.2,rocm/6.3.3,rocm/6.3.4,rocm/6.4.0,rocm/6.4.1,rocm/6.4.2,rocm/6.4.3,rocm/7.0.0,rocm/7.0.1,rocm/7.0.2,rocm/7.1.0,rocm/7.1.1,rocm/7.12.0,rocm/7.13.0,rocm/7.2.0,rocm/7.2.1,rocm/7.2.2,rocm/7.2.3,rocm/7.2.4,rocm/afar-22.1.0-7.1.0,rocm/afar-22.2.0-7.2.0,rocm/afar-23.1.0-7.12.0,rocm/afar-23.2.1-7.13.0,rocm/afar-23.3.0-7.14.0,roofline-extractor/dev,tracelens/dev,turbovnc/3.0.3,uprof/5.3-518,visit/3.4.2
down_nodes=
opt_dirs=amdgpu,AMDuProf_5.3-518,flux-accounting,flux-env.sh,flux-pilot-configs,flux.sh.fixed,fp64monitor,miniconda3,miniconda3-v25.3.1,miniforge3,miniforge3-v24.9.0,opencode,rocbudai,rocm-6.3.0,rocm-6.3.1,rocm-6.3.2,rocm-6.3.3,rocm-6.3.4,rocm-6.4.0,rocm-6.4.1,rocm-6.4.2,rocm-6.4.3,rocm-7.0.0,rocm-7.0.1,rocm-7.0.2,rocm-7.1.0,rocm-7.1.1,rocm-7.12.0,rocm-7.13.0,rocm-7.2.0,rocm-7.2.2,rocm-7.2.3,rocm-7.2.4,rocm-afar-22.1.0,rocm-afar-22.2.0,rocm-afar-23.1.0,rocm-afar-23.2.1,rocm-afar-23.3.0,rocm-patches-6.3.0,rocm-patches-6.3.1,rocm-patches-6.3.2,rocm-patches-6.3.3,rocm-patches-6.3.4,rocm-patches-6.4.0,rocm-patches-6.4.1,rocm-patches-6.4.2,rocm-patches-6.4.3,rocm-patches-7.0.0,rocm-patches-7.0.1,rocm-patches-7.0.2,rocm-patches-7.1.0,rocm-patches-7.1.1,rocm-patches-7.13.0,rocm-patches-7.2.0,rocm-patches-7.2.2,rocm-patches-7.2.3,rocm-patches-7.2.4,rocm-patches-afar-22.1.0,rocm-patches-afar-22.2.0,rocm-patches-afar-23.1.0,rocm-patches-afar-23.2.1,rocmplus-6.3.0,rocmplus-6.3.1,rocmplus-6.3.2,rocmplus-6.3.3,rocmplus-6.3.4,rocmplus-6.4.0,rocmplus-6.4.1,rocmplus-6.4.2,rocmplus-6.4.3,rocmplus-7.0.0,rocmplus-7.0.1,rocmplus-7.0.2,rocmplus-7.1.0,rocmplus-7.1.1,rocmplus-7.12.0,rocmplus-7.13.0,rocmplus-7.2.0,rocmplus-7.2.2,rocmplus-7.2.3,rocmplus-7.2.4,rocmplus-afar-22.1.0-7.1.0,rocmplus-afar-22.2.0-7.2.0,rocmplus-afar-23.1.0-7.12.0,rocmplus-afar-23.2.1-7.13.0,rocmplus-afar-23.3.0-7.14.0,rooflineExtractor,spack,spack-envs,tracelens
-->
