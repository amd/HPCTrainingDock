# AAC6 System Status — 2026-06-03

## Sys Admins Comments

No comments

## Overview

- Date: 2026-06-03 04:30:02 CDT
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
| 1CN192C4G1H_MI300A_Ubuntu22 | 3 | 192 | gpu:4 | 8:00:00 | no |
| 1CN48C6G1H_MI300A_Ubuntu22 | 5 | 48 | gpu:6 | 8:00:00 | no |
| sh5_cpx_admin_long | 5 | 48 | gpu:6 | 2-00:00:00 | no |

Note: `--gpus=<n>` is required to be allocated GPUs in any partition.

## Software Stack

- ROCm versions available: 6.3.0, 6.3.1, 6.3.2, 6.3.3, 6.3.4, 6.4.0, 6.4.1, 6.4.2, 6.4.3, 7.0.0, 7.0.1, 7.0.2, 7.1.0, 7.1.1, 7.2.0, 7.2.1, 7.2.2, 7.2.3, 7.13.0, afar-22.1.0-7.1.0, afar-22.2.0-7.2.0, afar-23.1.0-7.12.0, afar-23.2.1-7.13.0
- gcc: 11.4.0
- Other user-facing module families: apptainer, fp64monitor, gcc, hmmer, miniconda3, miniforge3, nextflow, paraview, rocbudai, roofline-extractor, tracelens, turbovnc, visit
- Browse all modules with `module avail`. See `man aac6_modules`.

## Containers

- podman: 4.6.2
- apptainer: 1.4.5 (`module load apptainer`)
- singularity: via apptainer compatibility shim
- ROCm device binding is automatic on compute nodes. See `man aac6_podman` and `man aac6_apptainer`.

## Filesystems

| Mount | Size | Used |
|---|---|---|
| /home | 207G | 87% |
| /shared | 67T | 59% |

## Help & Documentation

- `man aac6` for the system overview.
- AAC6 man pages installed: aac6, aac6_2fa_apps, aac6_apptainer, aac6_data_policies, aac6_flux, aac6_modules, aac6_novnc, aac6_paraview, aac6_podman, aac6_slurm, aac6_visit, aac6_vnc, aac6_x11
- Examples: https://github.com/amd/HPCTrainingExamples
- Login info: https://github.com/amd/HPCTrainingExamples/tree/main/login_info/AAC
- This page: https://github.com/amd/HPCTrainingDock/tree/main/managed_systems_status/aac6

## Changes Since Previous Snapshot

- Slurm partitions:
    + 1CN48C6G1H_MI300A_Ubuntu22:5
    + sh5_cpx_admin_long:5
    - 1CN48C6G1H_MI300A_Ubuntu22:4
    - sh5_cpx_admin_long:4

---

*Generated on 2026-06-03 04:30:02 CDT.*

<!-- AAC6_STATUS_METADATA — machine-readable facts for the next-run diff. Do not edit by hand.
os=Ubuntu 22.04.5 LTS
kernel=6.5.0-45-generic
rocm_default=7.2.3
rocm_versions=6.3.0,6.3.1,6.3.2,6.3.3,6.3.4,6.4.0,6.4.1,6.4.2,6.4.3,7.0.0,7.0.1,7.0.2,7.1.0,7.1.1,7.2.0,7.2.1,7.2.2,7.2.3,7.13.0,afar-22.1.0-7.1.0,afar-22.2.0-7.2.0,afar-23.1.0-7.12.0,afar-23.2.1-7.13.0
module_top=apptainer,fp64monitor,gcc,hmmer,miniconda3,miniforge3,nextflow,paraview,rocbudai,roofline-extractor,tracelens,turbovnc,visit
default_partition=1CN192C24G1H_MI300A_Ubuntu22
partitions=1CN192C24G1H_MI300A_Ubuntu22:1,1CN192C4G1H_MI300A_Ubuntu22:3,1CN48C6G1H_MI300A_Ubuntu22:5,sh5_cpx_admin_long:5
podman=4.6.2
apptainer=1.4.5
singularity=via apptainer compatibility shim
gcc=11.4.0
tfa=SSH key + TOTP via PrivacyIDEA (required)
man_pages=aac6,aac6_2fa_apps,aac6_apptainer,aac6_data_policies,aac6_flux,aac6_modules,aac6_novnc,aac6_paraview,aac6_podman,aac6_slurm,aac6_visit,aac6_vnc,aac6_x11
-->
