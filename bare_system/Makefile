SHELL:=/bin/bash
all: rocm openmpi omnitrace omniperf kokkos aomp cupy pytorch hpctoolkit mpi4py tau jax scorep
.PHONY: baseospackages rocm openmpi mvapich slurm omnitrace amd_gcc aomp kokkos aomp cupy pytorch apps_setup hpctoolkit mpi4py tau jax scorep

baseospackages: baseospackages.timestamp
rocm: rocm.timestamp
openmpi: openmpi.timestamp
mvapich: mvapich.timestamp
slurm: slurm.timestip
omnitrace: omnitrace.timestamp
omniperf: omniperf.timestamp
amd_gcc: amd_gcc.timestamp
aomp: aomp.timestamp
kokkos: kokkos.timestamp
tau: tau.timestamp
scorep: scorep.timestamp
mpi4py: mpi4py.timestamp
hpctoolkit: hpctoolkit.timestamp
cupy: cupy.timestamp
pytorch: pytorch.timestamp
jax: jax.timestamp
apps_setup: apps_setup.timestamp

checkSystemConfig: checkSystemConfig.timestamp
env_check: env_check.timestamp
rocm_bandwidth_test: rocm_bandwidth_test.timestamp
hip_tests: hip_tests.timestamp
rocprof_tests: rocprof_tests.timestamp
openmp_tests: openmp_tests.timestamp
hipstdpar_tests: hipstdpar_tests.timestamp
rocm_tests: rocm_tests.timestamp
openmpi_tests: openmpi_tests.timestamp
tau_tests: tau_tests.timestamp
scorep_tests: scorep_tests.timestamp
aomp_tests: aomp_tests.timestamp
kokkos_tests: kokkos_tests.timestamp
mpi4py_tests: mpi4py_tests.timestamp
hpctoolkit_tests: hpctoolkit_tests.timestamp
cupy_tests: cupy_tests.timestamp
pytorch_tests: pytorch_tests.timestamp
jax_tests: jax_tests.timestamp

rocm_package: rocm_package.timestamp
openmpi_package: openmpi_package.timestamp
omnitrace_package: omnitrace_package.timestamp
cupy_package: cupy_package.timestamp
all_packages: all_packages.timestamp

# From base rocm layer
baseospackages.timestamp:
	rocm/sources/scripts/baseospackages_setup.sh
	touch baseospackages.timestamp

rocm.timestamp: baseospackages.timestamp # lmod.timestamp
	rocm/sources/scripts/rocm_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocm.timestamp

rocm_omnitrace.timestamp: baseospackages.timestamp rocm.timestamp
	rocm/sources/scripts/rocm_omnitrace_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocm_omnitrace.timestamp

rocm_omniperf.timestamp: baseospackages.timestamp rocm.timestamp
	rocm/sources/scripts/rocm_omniperf_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocm_omniperf.timestamp

slurm.timestamp:
	rocm/sources/scripts/slurm_setup.sh
	touch slurm.timestamp

# From Comm layer
openmpi.timestamp: rocm.timestamp
	comm/sources/scripts/openmpi_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}
	touch openmpi.timestamp

mvapich.timestamp: rocm.timestamp
	comm/sources/scripts/mvapich_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch mvapich.timestamp

mpi4py.timestamp: rocm.timestamp
	comm/sources/scripts/mpi4py_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-mpi4py ${BUILD_MPI4PY}
	touch mpi4py.timestamp

# From Tools layer

miniconda3.timestamp:
	tools/sources/scripts/miniconda3_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --python-versions ${PYTHON_VERSIONS}
	touch miniconda3.timestamp

omnitrace.timestamp: miniconda3.timestamp openmpi.timestamp
	tools/sources/scripts/omnitrace_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
	   --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}
	touch omnitrace.timestamp

grafana.timestamp:
	tools/sources/scripts/grafana_setup.sh

omniperf.timestamp: rocm.timestamp
	tools/sources/scripts/omniperf_setup.sh \
	   --rocm-version ${ROCM_VERSION}

tau.timestamp: rocm.timestamp
	tools/sources/scripts/tau_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-tau ${BUILD_TAU}
	touch tau.timestamp

scorep.timestamp: rocm.timestamp
	tools/sources/scripts/scorep_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-scorep ${BUILD_SCOREP}
	touch scorep.timestamp

hpctoolkit.timestamp: rocm.timestamp
	tools/sources/scripts/hpctoolkit_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-hpctoolkit ${BUILD_HPCTOOLKIT}
	touch hpctoolkit.timestamp

# From Training layer

compiler_setup.sh:
	extras/sources/scripts/compiler_setup.sh
	touch compiler_setup.timestamp

amd_gcc.timestamp: rocm.timestamp
	extras/sources/scripts/amd_gcc_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-gcc-latest ${BUILD_GCC_LATEST}
	touch amd_gcc.timestamp

aomp.timestamp: rocm.timestamp
	extras/sources/scripts/aomp_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-aomp-latest ${BUILD_AOMP_LATEST}
	touch aomp.timestamp

kokkos.timestamp:
	extras/sources/scripts/kokoks_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-kokkos ${BUILD_KOKKOS}
	touch kokkos.timestamp

cupy.timestamp: rocm.timestamp
	extras/sources/scripts/cupy_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
	   --build-cupy ${BUILD_CUPY}
	touch cupy.timestamp

pytorch.timestamp: rocm.timestamp
	extras/sources/scripts/pytorch_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
	   --build-pytorch ${BUILD_PYTORCH}
	touch pytorch.timestamp

jax.timestamp: rocm.timestamp
	extras/sources/scripts/jax_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
	   --build-jax ${BUILD_JAX}
	touch jax.timestamp

apps_setup.timestamp:
	extras/sources/scripts/apps_setup.sh
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

rocprof_tests.timestamp: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Rocprof
	touch rocprof_tests.timestamp

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

pytorch_tests.timestamp: pytorch.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Pytorch
	touch pytorch_tests.timestamp

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

omnitrace_package.timestamp: omnitrace.timestamp
	bare_system/deploy_package.sh --selection-string omnitrace
	touch omnitrace_package.timestamp

cupy_package.timestamp: cupy.timestamp
	bare_system/deploy_package.sh --selection-string cupy
	touch cupy_package.timestamp

all_packages.timestamp: rocm_package.timestamp openmpi_package.timestamp omnitrace_package.timestamp cupy_package.timestamp
	touch all_packages.timestamp
