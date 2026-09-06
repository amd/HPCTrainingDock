# HPC Training Dock Agent Guide

**Project:** AMD HPC Training Dock — container + bare-metal ROCm training environment setup
**Shell / Docker**

## Overview

This repo builds and provisions ROCm-aware training environments. It supports
Docker/Podman image builds, bare-metal installs via `bare_system/`, and
Singularity workflows.

## Repository Layout

| Path | Purpose |
|------|---------|
| `build-docker.sh` | Main Docker image builder |
| `runTraining.sh` | Launch a training container |
| `test-docker-release.sh` | Validate a built training image |
| `bare_system/` | Bare-metal setup scripts and Makefile |
| `rocm/` | ROCm-specific Dockerfiles |
| `infrastructure/` | Lmod module and AMI notes |
| `tutorials/` | Training tutorial material |
| `tools/` | Helper utilities |
| `Examples.md` | Usage examples |

## Build Commands

```bash
# Build the default training Docker image
./build-docker.sh

# Run it
./runTraining.sh

# Bare-metal setup (read README options first)
cd bare_system
make help
./main_setup.sh +options
```

## Test Commands

```bash
# Validate a built release image
./test-docker-release.sh <image_tag>
```

## Lint / Format

- Shell scripts: run `shellcheck` on modified `.sh` files.
- No formal lint target; follow existing style.

## Key Conventions

- Scripts auto-detect Podman vs Docker (`docker info` / `podman -v`).
- Bare-metal flow uses `bare_system/main_setup.sh` with `+options` flags.
- Singularity builds start from a writable sandbox.

## Gotchas

- Requires root / fakeroot for container builds.
- ROCm packages are large; ensure adequate disk space.
- Bare-metal installs must match the host ROCm and distro version.
