#!/bin/bash
rm -rf  /home/sysadmin/.spack/*

cd /tmp
rm -rf spack rocm-spack
git clone https://github.com/spack/spack.git
source spack/share/spack/setup-env.sh

mkdir rocm-spack && cd rocm-spack

spack env create -d rocm-spack-environment
spack env activate rocm-spack-environment

export ROCM_SPACK_LIST_642="amdsmi aqlprofile comgr composable-kernel hip \
        hipblas hipblaslt hipcc hipcub hipfft hipfort hipify-clang hiprand \
        hipsolver hipsparse hipsparselt hip-tensor hip-tests hsakmt-roct \
        hsa-rocr-dev llvm-amdgpu migraphx miopen-hip mivisionx omniperf \
        omnitrace rccl rdc rocal rocalution rocblas rocdecode rocfft \
        rocjpeg rocm-bandwidth-test rocm-clang-ocl rocm-cmake rocm-core \
        rocm-debug-agent rocm-device-libs rocm-examples rocm-gdb rocminfo \
        rocmlir rocm-opencl rocm-openmp-extras rocm-smi-lib \
        rocm-tensile rocm-validation-suite rocprim rocprofiler-compute \
        rocprofiler-dev rocprofiler-register rocprofiler-sdk \
        rocprofiler-systems rocpydecode rocrand rocshmem rocsolver rocsparse \
        rocthrust roctracer-dev roctracer-dev-api rocwmma rpp transferbench"

spack add $ROCM_SPACK_LIST_642

spack compiler find
spack external find --all
# this command lists all components requested and 0 installed
spack find
spack spec
spack install -j 16
# this command lists all installed components in the environment
spack find
