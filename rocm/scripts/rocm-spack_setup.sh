#!/bin/bash
#rm -rf  /home/sysadmin/.spack/*

sudo apt-get install unzip liblzma-dev

cd /tmp
rm -rf spack
git clone https://github.com/spack/spack.git
source spack/share/spack/setup-env.sh

rm -rf rocm-spack
mkdir rocm-spack && cd rocm-spack

spack env create -d rocm-spack-environment
spack env activate rocm-spack-environment

export ROCM_SPACK_LIST_642="amdsmi aqlprofile comgr composable-kernel hip \
   hipblas hipblaslt hipcc hipcub hipfft hipfort hipify-clang hiprand \
   hipsolver hipsparse hipsparselt hip-tensor hip-tests hsakmt-roct \
   hsa-rocr-dev llvm-amdgpu miopen-hip mivisionx omniperf omnitrace \
   rccl rdc rocal rocalution rocblas rocdecode rocfft rocm-bandwidth-test \
   rocm-cmake rocm-core rocm-debug-agent rocm-device-libs rocm-examples \
   rocm-gdb rocminfo rocmlir rocm-opencl rocm-openmp-extras rocm-smi-lib \
   rocm-tensile rocm-validation-suite rocprim rocprofiler-compute \
   rocprofiler-dev rocprofiler-register rocprofiler-sdk \
   rocprofiler-systems rocpydecode rocrand rocsolver rocsparse \
   rocthrust roctracer-dev roctracer-dev-api rocwmma rpp"

spack add $ROCM_SPACK_LIST_642

# this command lists all components requested and 0 installed
spack find
sed -i -e '/view/s!true!/opt/rocm-6.4.2!' rocm-spack-environment/spack.yaml
sudo rm -rf /opt/rocm-6.4.2 /opt/._rocm-6.4.2
sudo chmod a+w /opt
spack compiler find
spack external find --all
spack concretize
spack spec
spack install -j 16
# this command lists all installed components in the environment
spack find
du -sk rocm-spack-environment
spack gc -y
du -sk rocm-spack-environment
sudo chmod go-w /opt/rocm-6.4.2 /opt
spack env deactivate
rm -rf /tmp/rocm-spack
