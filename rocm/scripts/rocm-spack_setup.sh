#!/bin/bash

sudo apt-get install unzip liblzma-dev

ROCM_VERSION=6.4.2
AMDGPU_GFXMODEL=gfx90a,gfx942
INSTALL_PATH=/opt/rocm-$ROCM_VERSION
MODULE_PATH=/etc/lmod/modules/ROCm

cd /tmp
rm -rf spack
git clone https://github.com/spack/spack.git
source spack/share/spack/setup-env.sh

rm -rf rocm-spack
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
rm -rf /tmp/rocm-spack
rm -rf /tmp/spack

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
