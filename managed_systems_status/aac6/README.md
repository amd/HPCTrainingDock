<!-- Original location: HPCTrainingDock/managed_systems_status/aac6/README.md -->

# AAC6 — User-Facing System Status

A brief, factual snapshot of the AAC6 cluster as users see it, plus a running change log of what has changed between snapshots.

The MOTD on AAC6 links to `AAC6_system_status_current.md`, so users always see the latest state when they log in.

## Files

| File | What it is |
|---|---|
| `AAC6_system_status_current.md` | Latest snapshot. Reflects the system as it is today. |
| `AAC6_system_status_CHANGELOG.md` | One section per snapshot, newest first. Lists user-visible changes since the previous snapshot. |
| `archive/AAC6_system_status_<YYYY-MM-DD>.md` | Dated copy of the snapshot taken on that day. |

## What is captured

User-facing facts only. Each snapshot has, in this order:

1. **Sys Admins Comments** — short note from the AAC6 administrators about the current snapshot, when relevant.
2. **Overview** — date, OS, kernel, login host, ROCm default.
3. **Login & Access** — authentication method, 2FA enrolment pointer.
4. **Compute** — Slurm partitions, node counts, GPUs, walltime, default partition.
5. **Software Stack** — ROCm versions available, gcc, other module families.
6. **Containers** — podman, apptainer, singularity versions.
7. **Filesystems** — mount points users see.
8. **Help & Documentation** — `man` pages and links to training repos.
9. **Changes Since Previous Snapshot** — the diff vs the previous snapshot.

The snapshot ends with a hidden HTML-comment metadata block. It exists for tooling and is not part of the user-facing content; please don't edit or rely on it.

## Update cadence

The snapshot is republished whenever the AAC6 administrators make a user-visible change to the cluster (ROCm version, partition layout, modules, etc.). Most of the time the snapshot is unchanged for several days at a stretch.
