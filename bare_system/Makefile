SHELL:=/bin/bash
all: rocm openmpi rocprof-sys_rocm rocprof-sys_source rocprof-compute_rocm rocprof-compute_source kokkos aomp cupy pytorch hpctoolkit mpi4py tau jax scorep x11vnc miniconda3 miniforge3 hdf5 hipfort netcdf flang-new fftw hipifly rocprofiler-sdk compiler petsc hypre
.PHONY: baseospackages rocm openmpi mvapich slurm rocprof-sys_rocm rocprof-sys_source amd_gcc aomp kokkos aomp cupy pytorch apps_setup hpctoolkit mpi4py tau jax scorep miniconda3 miniforge3 hdf5 hipfort netcdf flang-new fftw hipifly rocprofiler-sdk rocprof-compute_rocm rocprof-compute_source compiler petsc hypre

baseospackages: baseospackages.timestamp
rocm: rocm.timestamp
rocprof-compute_rocm: rocprof-compute_rocm.timestamp
rocprof-sys_rocm: rocprof-sys_rocm.timestamp
rocprofiler-sdk: rocprofiler-sdk.timestamp
openmpi: openmpi.timestamp
mvapich: mvapich.timestamp
slurm: slurm.timestamp
rocprof-sys_source: rocprof-sys_source.timestamp
rocprof-compute_source: rocprof-compute_source.timestamp
amd_gcc: amd_gcc.timestamp
aomp: aomp.timestamp
fftw: fftw.timestamp
flang-new: flang-new.timestamp
kokkos: kokkos.timestamp
compiler: compiler_setup.timestamp
miniconda3: miniconda3.timestamp
miniforge3: miniforge3.timestamp
hdf5: hdf5.timestamp
netcdf: netcdf.timestamp
hipfort: hipfort.timestamp
hipifly: hipifly.timestamp
tau: tau.timestamp
scorep: scorep.timestamp
mpi4py: mpi4py.timestamp
hpctoolkit: hpctoolkit.timestamp
cupy: cupy.timestamp
pytorch: pytorch.timestamp
petsc: petsc.timestamp
hypre: hypre.timestamp
x11vnc: x11vnc.timestamp
jax: jax.timestamp
apps_setup: apps_setup.timestamp

checkSystemConfig: checkSystemConfig.timestamp
env_check: env_check.timestamp
rocm_bandwidth_test: rocm_bandwidth_test.timestamp
hip_tests: hip_tests.timestamp
rocprof_tests: rocprof_tests.timestamp
rocprof-compute_rocm_tests: rocprof-compute_rocm_tests.timestamp
rocprof-compute_source_tests: rocprof-compute_source_tests.timestamp
rocprof-sys_rocm_tests: rocprof-sys_rocm_tests.timestamp
rocprof-sys_source_tests: rocprof-sys_source_tests.timestamp
openmp_tests: openmp_tests.timestamp
hipstdpar_tests: hipstdpar_tests.timestamp
rocm_tests: rocm_tests.timestamp
openmpi_tests: openmpi_tests.timestamp
tau_tests: tau_tests.timestamp
scorep_tests: scorep_tests.timestamp
aomp_tests: aomp_tests.timestamp
kokkos_tests: kokkos_tests.timestamp
miniconda3_tests: miniconda3_tests.timestamp
miniforge3_tests: miniforge3_tests.timestamp
hdf5_tests: hdf5_tests.timestamp
netcdf_tests: netcdf_tests.timestamp
hipfort_tests: hipfort_tests.timestamp
hipifly_tests: hipifly_tests.timestamp
mpi4py_tests: mpi4py_tests.timestamp
hpctoolkit_tests: hpctoolkit_tests.timestamp
cupy_tests: cupy_tests.timestamp
pytorch_tests: pytorch_tests.timestamp
petsc_tests: petsc_tests.timestamp
hypre_tests: hypre_tests.timestamp
jax_tests: jax_tests.timestamp

rocm_package: rocm_package.timestamp
openmpi_package: openmpi_package.timestamp
rocprof-sys_source_package: rocprof-sys_source_package.timestamp
cupy_package: cupy_package.timestamp
all_packages: all_packages.timestamp

# From base rocm layer
baseospackages.timestamp:
	rocm/scripts/baseospackages_setup.sh
	touch baseospackages.timestamp

rocm.timestamp: baseospackages.timestamp # lmod.timestamp
	rocm/scripts/rocm_setup.sh \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' --rocm-version ${ROCM_VERSION}
	touch rocm.timestamp

rocprof-sys_rocm.timestamp: rocm.timestamp
	rocm/scripts/rocm_rocprof-sys_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocprof-sys_rocm.timestamp

rocprof-compute_rocm.timestamp: rocm.timestamp
	rocm/scripts/rocm_rocprof-compute_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocprof-compute_rocm.timestamp

rocprofiler-sdk.timestamp: rocm.timestamp
	tools/scripts/rocprofiler-sdk_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocprofiler-sdk.timestamp

slurm.timestamp:
	rocm/scripts/slurm_setup.sh
	touch slurm.timestamp

# From Comm layer
openmpi.timestamp: rocm.timestamp
	comm/scripts/openmpi_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}'
	touch openmpi.timestamp

mvapich.timestamp: rocm.timestamp
	comm/scripts/mvapich_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch mvapich.timestamp

mpi4py.timestamp: openmpi.timestamp rocm.timestamp
	comm/scripts/mpi4py_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-mpi4py 1
	touch mpi4py.timestamp

# From Tools layer

rocprof-sys_source.timestamp: openmpi.timestamp
	tools/scripts/rocprof-sys_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --install-rocprof-sys-from-source 1
	touch rocprof-sys_source.timestamp

grafana.timestamp:
	tools/scripts/grafana_setup.sh

rocprof-compute_source.timestamp: rocm.timestamp
	tools/scripts/rocprof-compute_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --install-rocprof-compute-from-source 1
	touch rocprof-compute_source.timestamp

tau.timestamp: rocm.timestamp
	tools/scripts/tau_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-tau 1
	touch tau.timestamp

scorep.timestamp: rocm.timestamp flang-new.timestamp
	tools/scripts/scorep_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-scorep 1
	touch scorep.timestamp

hpctoolkit.timestamp: rocm.timestamp
	tools/scripts/hpctoolkit_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-hpctoolkit 1
	touch hpctoolkit.timestamp

# From Training layer

compiler_setup.timestamp:
	extras/scripts/compiler_setup.sh
	touch compiler_setup.timestamp

amd_gcc.timestamp: rocm.timestamp
	extras/scripts/amd_gcc_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-gcc-latest 1
	touch amd_gcc.timestamp

aomp.timestamp: rocm.timestamp
	extras/scripts/aomp_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-aomp-latest 1
	touch aomp.timestamp

flang-new.timestamp: rocm.timestamp
	extras/scripts/flang-new_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-flang-new 1
	touch flang-new.timestamp

miniconda3.timestamp:
	extras/scripts/miniconda3_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --python-version ${PYTHON_VERSION} \
	   --build-miniconda3 1
	touch miniconda3.timestamp

miniforge3.timestamp:
	extras/scripts/miniforge3_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --python-version ${PYTHON_VERSION} \
	   --build-miniforge3 1
	touch miniforge3.timestamp

hdf5.timestamp:
	extras/scripts/hdf5_setup.sh \
           --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
           --build-hdf5 1
	touch hdf5.timestamp

netcdf.timestamp: hdf5.timestamp
	extras/scripts/netcdf_setup.sh \
           --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
           --build-netcdf 1
	touch netcdf.timestamp

hipfort.timestamp: rocm.timestamp
	extras/scripts/hipfort_setup.sh \
           --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
           --build-hipfort 1
	touch hipfort.timestamp

hipifly.timestamp: rocm.timestamp
	extras/scripts/hipifly_setup.sh \
           --rocm-version ${ROCM_VERSION} \
	   --hipifly-header-path extras/sources/hipifly \
           --hipifly-module 1
	touch hipifly.timestamp

kokkos.timestamp: rocm.timestamp
	extras/scripts/kokkos_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-kokkos 1
	touch kokkos.timestamp

cupy.timestamp: rocm.timestamp
	extras/scripts/cupy_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-cupy 1
	touch cupy.timestamp

pytorch.timestamp: rocm.timestamp
	extras/scripts/pytorch_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-pytorch 1
	touch pytorch.timestamp

petsc.timestamp: rocm.timestamp openmpi.timestamp
	extras/scripts/petsc_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
           --use-spack 0 \
	   --build-petsc 1
	touch petsc.timestamp

hypre.timestamp: rocm.timestamp openmpi.timestamp
	extras/scripts/hypre_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
           --use-spack 0 \
	   --build-hypre 1
	touch hypre.timestamp

jax.timestamp: rocm.timestamp
	extras/scripts/jax_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-jax 1
	touch jax.timestamp

fftw.timestamp:
	extras/scripts/fftw_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
           --build-fftw 1
	touch fftw.timestamp

x11vnc.timestamp:
	extras/scripts/x11vnc_setup.sh \
           --build-x11vnc 1
	touch x11vnc.timestamp

apps_setup.timestamp:
	extras/scripts/apps_setup.sh
	touch apps_basic.timestamp


# Testing support for builds
HPCTrainingExamples:
	git clone https://github.com/AMD/HPCTrainingExamples
	cd HPCTrainingExamples/tests && mkdir build && cd build && cmake ..

checkSystemConfig.timestamp: rocm.timestamp
	extras/manage/bin/checkSystemConfig.sh
	touch checkSystemConfig.timestamp

env_check.timestamp: rocm.timestamp
	extras/manage/bin/env_check.sh check
	touch env_check.timestamp

rocm_bandwidth_test.timestamp: rocm.timestamp
	rocm_bandwidth_test
	touch rocm_bandwidth_test.timestamp

hip_tests.timestamp: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R "HIP_Vector|HIP_Jacobi|^HIP_Stream|HIP_Saxpy"
	touch hip_tests.timestamp

rocprofv3_tests.timestamp: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Rocprofv3
	touch rocprofv3_tests.timestamp

rocprofiler-sdk_tests.timestamp: rocprofiler-sdk.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Rocprofv3
	touch rocprofv3_tests.timestamp

openmp_tests.timestamp: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R "^OpenMP_"
	touch openmp_tests.timestamp

hipstdpar_tests.timestamp: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R HIPStdPar
	touch hipstdpar_tests.timestamp

rocm_tests.timestamp: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R "HIP_Vector|HIP_Jacobi|^HIP_Stream|HIP_Saxpy|Rocprof|^OpenMP_|HIPStdPar"
	touch rocm_tests.timestamp

openmpi_tests.timestamp: openmpi.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R OpenMPI
	touch openmpi_tests.timestamp

tau_tests.timestamp: tau.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R TAU
	touch tau_tests.timestamp

rocprof-compute_rocm_tests.timestamp: rocprof-compute_rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Rocprof-compute_ROCm
	touch rocprof-compute_rocm_tests.timestamp

rocprof-compute_source_tests.timestamp: rocprof-compute_source.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Rocprof-compute_Source
	touch rocprof-compute_source_tests.timestamp

rocprof-sys_rocm_tests.timestamp: rocprof-sys_rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Rocprof-sys_ROCm
	touch rocprof-sys_rocm_tests.timestamp

rocprof-sys_source_tests.timestamp: rocprof-sys_source.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Rocprof-sys_Source
	touch rocprof-sys_source_tests.timestamp

scorep_tests.timestamp: scorep.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Score-P
	touch scorep_tests.timestamp

mpi4py_tests.timestamp: mpi4py.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R MPI4PY
	touch mpi4py_tests.timestamp

hpctoolkit_tests.timestamp: hpctoolkit.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R HPCToolkit
	touch hpctoolkit_tests.timestamp

aomp_tests.timestamp: aomp.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R AOMP
	touch aomp_tests.timestamp

cupy_tests.timestamp: cupy.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Cupy
	touch cupy_tests.timestamp

kokkos_tests.timestamp: kokkos.timestamp compiler_setup.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Kokkos
	touch kokkos_tests.timestamp

miniconda3_tests.timestamp: miniconda3.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Miniconda3
	touch miniconda3_tests.timestamp

miniforge3_tests.timestamp: miniforge3.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Miniforge3
	touch miniforge3_tests.timestamp

hdf5_tests.timestamp: hdf5.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R HDF5
	touch hdf5_tests.timestamp

netcdf_tests.timestamp: netcdf.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Netcdf
	touch netcdf_tests.timestamp

fftw_tests.timestamp: fftw.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R FFTW
	touch fftw_tests.timestamp

hipfort_tests.timestamp: hipfort.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R HIPFort
	touch hipfort_tests.timestamp

hipifly_tests.timestamp: hipifly.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Hipifly
	touch hipifly_tests.timestamp

pytorch_tests.timestamp: pytorch.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Pytorch
	touch pytorch_tests.timestamp

petsc_tests.timestamp: petsc.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R PETSc
	touch petsc_tests.timestamp

hypre_tests.timestamp: hypre.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R HYPRE
	touch hypre_tests.timestamp

jax_tests.timestamp: jax.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R JAX
	touch jax_tests.timestamp

# Deploy targets create a compressed tar image of the directory for the package
rocm_package.timestamp: rocm.timestamp
	bare_system/deploy_package.sh --package-basedir /opt --selection-string rocm-${ROCM_VERSION}
	touch rocm_package.timestamp

openmpi_package.timestamp: openmpi.timestamp
	bare_system/deploy_package.sh --selection-string ucx
	bare_system/deploy_package.sh --selection-string ucc
	bare_system/deploy_package.sh --selection-string openmpi
	touch openmpi_package.timestamp

rocprof-sys_source_package.timestamp: rocprof-sys_source.timestamp
	bare_system/deploy_package.sh --selection-string rocprof-sys
	touch rocprof-sys_source_package.timestamp

cupy_package.timestamp: cupy.timestamp
	bare_system/deploy_package.sh --selection-string cupy
	touch cupy_package.timestamp

all_packages.timestamp: rocm_package.timestamp openmpi_package.timestamp rocprof-sys_source_package.timestamp cupy_package.timestamp
	touch all_packages.timestamp
