SHELL:=/bin/bash
all: rocm openmpi omnitrace omniperf kokkos cupy
.PHONY: baseospackages rocm openmpi mvapich slurm omnitrace amd_gcc aomp kokkos apps_setup_basic cupy pytorch apps_setup

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
apps_setup_basic: apps_setup_basic.timestamp
cupy: cupy.timestamp
pytorch: pytorch.timestamp
apps_setup: apps_setup.timestamp

hip_tests: hip_tests.timestamp
rocprof_tests: rocprof_tests.timestamp
openmp_tests: openmp_tests.timestamp
hipstdpar_tests: hipstdpar_tests.timestamp
rocm_tests: rocm_tests.timestamp
openmpi_tests: openmpi_tests.timestamp
kokkos_tests: kokkos_tests.timestamp
cupy_tests: cupy_tests.timestamp
pytorch_tests: pytorch_tests.timestamp

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

openmpi.timestamp: rocm.timestamp
	rocm/sources/scripts/openmpi_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}
	touch openmpi.timestamp

mvapich.timestamp: rocm.timestamp
	rocm/sources/scripts/mvapich_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch mvapich.timestamp

slurm.timestamp:
	rocm/sources/scripts/slurm_setup.sh
	touch slurm.timestamp

# From Omnitrace layer
miniconda3.timestamp:
	omnitrace/sources/scripts/miniconda3_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --python-versions ${PYTHON_VERSIONS}
	touch miniconda3.timestamp

omnitrace.timestamp: miniconda3.timestamp openmpi.timestamp
	omnitrace/sources/scripts/omnitrace_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
	   --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}
	touch omnitrace.timestamp

# From Omniperf layer

grafana.timestamp:
	omniperf/sources/scripts/grafana_setup.sh

omniperf.timestamp: rocm.timestamp
	omniperf/sources/scripts/omniperf_setup.sh \
	   --rocm-version ${ROCM_VERSION}

# From Training layer

compiler_setup.sh:
	training/sources/scripts/compiler_setup.sh
	touch compiler_setup.timestamp

amd_gcc.timestamp: amd_gcc.timestamp
	training/sources/scripts/amd_gcc_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-gcc-latest ${BUILD_GCC_LATEST}
	touch amd_gcc.timestamp

aomp.timestamp: aomp.timestamp
	training/sources/scripts/aomp_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-aomp-latest ${BUILD_AOMP_LATEST}
	touch aomp.timestamp

kokkos.timestamp: rocm.timestamp
	training/sources/scripts/kokkos_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-kokkos ${BUILD_KOKKOS}
	touch kokkos.timestamp

apps_setup_basic.timestamp:
	training/sources/scripts/apps_setup_basic.sh
	touch apps_setup_basic.timestamp

cupy.timestamp: rocm.timestamp
	training/sources/scripts/cupy_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
	   --build-cupy ${BUILD_CUPY}
	touch cupy.timestamp

pytorch.timestamp: rocm.timestamp apps_setup_basic.timestamp
	training/sources/scripts/pytorch_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
	   --build-pytorch ${BUILD_PYTORCH}
	touch pytorch.timestamp

apps_setup.timestamp:
	training/sources/scripts/apps_setup.sh
	touch apps_basic.timestamp


# Testing support for builds
HPCTrainingExamples:
	git clone https://github.com/AMD/HPCTrainingExamples
	cd HPCTrainingExamples/tests && mkdir build && cd build && cmake ..

hip_tests.timestep: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R HIP_Vector -R HIP_Jacobi -R HIP_Stream -R HIP_Saxpy
	touch rocprof_tests.timestamp

rocprof_tests.timestep: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Rocprof
	touch rocprof_tests.timestamp

openmp_tests.timestep: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R "^OpenMP_"
	touch openmp_tests.timestamp

hipstdpar_tests.timestep: rocm.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R HIPStdPar
	touch hipstdpar_tests.timestamp

rocm_tests.timestamp: hip_tests.timestep rocprof_tests.timestep openmp_tests.timestep hipstdpar_tests.timestep
	touch rocm_tests.timestamp

openmpi_tests.timestamp: openmpi.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R OpenMPI
	touch openmpi_tests.timestamp

kokkos_tests.timestamp: kokkos.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Kokkos
	touch kokkos_tests.timestamp

cupy_tests.timestamp: cupy.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Cupy
	touch cupy_tests.timestamp

pytorch_tests.timestamp: pytorch.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Pytorch
	touch pytorch_tests.timestamp


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
