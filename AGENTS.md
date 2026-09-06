# AGENTS.md — HPCTrainingDock

## What this repo is

A collection of shell scripts and Dockerfiles to build training environments for AMD GPU software (ROCm, MPI, OpenMP, PyTorch, and more). It supports two installation modes:

1. **Container installation** via Docker/Podman (recommended) — builds four stacked images: `rocm`, `comm`, `tools`, `extras`.
2. **Bare metal installation** — scripts in `bare_system/` that can also be tested inside a throwaway container.

The upstream source lives at `amd/HPCTrainingDock`; this fork tracks it.

## Repository layout

```
.
├── build-docker.sh            # Main container build entry point
├── test-docker-release.sh     # Smoke tests for the four built images
├── runTraining.sh             # Run a training example after the build
├── getpackages4cache.sh       # Pre-download packages for offline/cache builds
├── bare_system/               # Bare-metal install scripts and Dockerfile for testing
├── rocm/                      # ROCm Dockerfiles (Ubuntu, RHEL, openSUSE, Jupyter)
├── comm/                      # Communication stack Dockerfile (MPI, UCX, etc.)
├── tools/                     # Extra HPC tools Dockerfile
├── extras/                    # Additional frameworks Dockerfile
├── infrastructure/            # Cluster/infrastructure notes
├── tutorials/                 # Training tutorial index
├── QA/                        # Validation scripts
└── Examples.md                # Worked examples
```

## Verified setup commands

### Inspect build options

```bash
./build-docker.sh --help
```

### Build the standard Ubuntu 24.04 ROCm training stack

```bash
./build-docker.sh \
  --rocm-versions 7.2.0 \
  --distro ubuntu \
  --distro-version 24.04 \
  --admin-username admin \
  --admin-password <set-a-password>
```

You **must** pass `--admin-password`; the script errors if it is omitted.

### Smoke test the four built images

```bash
./test-docker-release.sh
```

### Run a quick training example

```bash
./runTraining.sh
```

## Code / contribution style

- Shell scripts are POSIX-ish bash; they are executed directly, so keep them executable.
- Dockerfiles use multi-stage builds where possible; ROCm version selection is driven by `--build-arg`.
- Prefer explicit `--distro` / `--distro-version` flags in docs; defaults can drift.
- Scripts auto-detect Podman vs. Docker in `build-docker.sh` and `bare_system/test_install.sh`.

## Common gotchas

- **Podman builds need `--format docker`**: the build script handles this when Podman emulates Docker, but if Podman is your primary runtime, double-check `bare_system/test_install.sh` manually.
- **Password required**: `build-docker.sh` refuses to run without `--admin-password`.
- **GPU detection**: the build script auto-detects the local AMDGPU model; override with `--amdgpu-gfxmodel` if you are cross-building.
- **Large images**: each layer can be tens of gigabytes; ensure the Docker/Podman storage backend has plenty of free space.
- **Singularity**: supported by building a sandbox from a plain Ubuntu image and then running `bare_system/main_setup.sh` inside it (see README section 1.2).

## Key files to read when changing something

- Changing the build matrix: `build-docker.sh`
- Adding a new package to the ROCm layer: `rocm/Dockerfile`
- Adding communication libraries: `comm/Dockerfile`
- Adding HPC/dev tools: `tools/Dockerfile`
- Adding ML frameworks: `extras/Dockerfile`
- Bare-metal install logic: `bare_system/main_setup.sh`
- Examples/worked recipes: `Examples.md`
