#!/bin/bash

sudo apt-get install unzip liblzma-dev

ROCM_VERSION=6.4.2
AMDGPU_GFXMODEL=gfx90a,gfx942
INSTALL_PATH=/opt/rocm-$ROCM_VERSION
MODULE_PATH=/etc/lmod/modules/ROCm

# Spack user-scope isolation: per-job throwaway dirs for
# SPACK_USER_CONFIG_PATH and SPACK_USER_CACHE_PATH so that
# `spack compiler find`, `spack external find --all`, and the
# `spack config add` calls below write to throwaway dirs instead
# of polluting ~/.spack/{packages,compilers,config}.yaml across
# rocm-version sweeps. Without this, a user-scope install_tree.root
# from a prior build silently redirects spack's install dir away
# from ${INSTALL_PATH} (observed cross-contamination in
# rocmplus-7.0.1 scorep modulefile pointing at rocmplus-7.0.2 pdt).
SPACK_USER_CONFIG_PATH=$(mktemp -d -t spack-user-config.XXXXXX)
SPACK_USER_CACHE_PATH=$(mktemp -d -t spack-user-cache.XXXXXX)
export SPACK_USER_CONFIG_PATH SPACK_USER_CACHE_PATH

# Per-job throwaway build dir (mktemp under /tmp, or under
# $TMPDIR if Slurm set one). The spack clone, the rocm-spack
# environment dir, and all build scratch live here. Without this,
# concurrent rocm-spack jobs on the same compute node would race
# on fixed paths /tmp/spack and /tmp/rocm-spack and clobber each
# other (matches the pattern in the 6 rocmplus setup scripts:
# scorep, tau, hpctoolkit, hypre, petsc, lammps).
ROCM_SPACK_BUILD_DIR=$(mktemp -d -t rocm-spack-build.XXXXXX)
trap '${SUDO:-sudo} rm -rf "${ROCM_SPACK_BUILD_DIR:-/nonexistent}" "${SPACK_USER_CONFIG_PATH:-/nonexistent}" "${SPACK_USER_CACHE_PATH:-/nonexistent}"' EXIT
cd "${ROCM_SPACK_BUILD_DIR}"

git clone https://github.com/spack/spack.git
source spack/share/spack/setup-env.sh

mkdir rocm-spack && cd rocm-spack

sudo rm -rf /opt/rocm-6.4.2 

spack env create -d rocm-spack-environment
spack env activate rocm-spack-environment

export ROCM_SPACK_LIST_642="hipcc"
spack add hipcc

# Configure the environment
# Enable Lmod module generation, Lmod module root, and simple names
spack config add "modules:default:enable::[lmod]"
spack config add "modules:default:roots:lmod:${MODULE_PATH}"
spack config add "modules:default:lmod:hash_length:0"

# Enable a flat view so you get ${INSTALL_PATH}/bin/hipcc, ${INSTALL_PATH}/lib, etc.
spack config add "view:${INSTALL_PATH}"

# Concretizer settings
spack config add "concretizer:unify:when_possible"

spack compiler find
spack external find --all

sudo mkdir -p "${INSTALL_PATH}" "${MODULE_PATH}"
sudo chmod a+w "${INSTALL_PATH}" "${MODULE_PATH}" /opt
spack concretize -f
spack install -j 16
spack module lmod refresh -y
spack gc -y
spack find -c
module use "${MODULE_PATH}"
module avail
# Lock down
sudo chmod go-w "${INSTALL_PATH}" "${MODULE_PATH}" /opt
spack env deactivate
# ROCM_SPACK_BUILD_DIR (under /tmp, contains the spack clone and
# the rocm-spack environment) is removed by the EXIT trap above.

#export ROCM_SPACK_LIST_642="amdsmi aqlprofile comgr composable-kernel hip \
#   hipblas hipblaslt hipcc hipcub hipfft hipfort hipify-clang hiprand \
#   hipsolver hipsparse hipsparselt hip-tensor hip-tests hsakmt-roct \
#   hsa-rocr-dev llvm-amdgpu miopen-hip mivisionx omniperf omnitrace \
#   rccl rdc rocal rocalution rocblas rocdecode rocfft rocm-bandwidth-test \
#   rocm-cmake rocm-core rocm-debug-agent rocm-device-libs rocm-examples \
#   rocm-gdb rocminfo rocmlir rocm-opencl rocm-openmp-extras rocm-smi-lib \
#   rocm-tensile rocm-validation-suite rocprim rocprofiler-compute \
#   rocprofiler-dev rocprofiler-register rocprofiler-sdk \
#   rocprofiler-systems rocpydecode rocrand rocsolver rocsparse \
#   rocthrust roctracer-dev roctracer-dev-api rocwmma rpp"
