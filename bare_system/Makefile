SHELL:=/bin/bash
all: rocm openmpi omnitrace cupy
cupy: /opt/rocmplus-${ROCM_VERSION}/cupy
rocm: /opt/rocm-${ROCM_VERSION}

baseospackages:
	rocm/sources/scripts/baseospackages_setup.sh

lmod: baseospackages
	rocm/sources/scripts/lmod_setup.sh

/opt/rocm-${ROCM_VERSION}: baseospackages lmod
	rocm/sources/scripts/rocm_setup.sh --rocm-version ${ROCM_VERSION}

openmpi: /opt/rocm-${ROCM_VERSION}
	rocm/sources/scripts/openmpi_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}

#rocm/sources/scripts/mvapich2_setup.sh --rocm-version ${ROCM_VERSION}

miniconda3:
	omnitrace/sources/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --python-versions ${PYTHON_VERSIONS}

omnitrace:
	omnitrace/sources/scripts/omnitrace_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}
#
#omniperf/sources/scripts/grafana_setup.sh
#
#omniperf/sources/scripts/omniperf_setup.sh --rocm-version ${ROCM_VERSION}
#
#training/sources/scripts/compiler_setup.sh
#
#training/sources/scripts/apps_setup_basic.sh
#


/opt/rocmplus-${ROCM_VERSION}/cupy: /opt/rocm-${ROCM_VERSION}
	training/sources/scripts/cupy_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-cupy ${BUILD_CUPY}

pytorch:
	training/sources/scripts/pytorch_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-pytorch ${BUILD_PYTORCH}

#training/sources/scripts/apps_setup.sh

kokkos:
	training/sources/scripts/kokkos_setup.sh --rocm-version ${ROCM_VERSION} --build-kokkos ${BUILD_KOKKOS}

HPCTrainingExamples:
	git clone https://github.com/AMD/HPCTrainingExamples 
	cd HPCTrainingExamples/tests && mkdir build && cd build && cmake ..

openmpi_tests: openmpi HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R OpenMPI

cupy_tests: /opt/rocmplus-${ROCM_VERSION}/cupy HPCTrainingExamples
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Cupy
