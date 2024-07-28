SHELL:=/bin/bash
all: rocm openmpi omnitrace kokkos cupy
.PHONY: baseospackages lmod rocm openmpi omnitrace kokkos cupy pytorch

baseospackages: baseospackages.timestamp
lmod: lmod.timestamp
rocm: rocm.timestamp
openmpi: openmpi.timestamp
omnitrace: omnitrace.timestamp
kokkos: kokkos.timestamp
cupy: cupy.timestamp
pytorch: pytorch.timestamp
HPCTrainingExamples: HPCTrainingExamples.timestamp
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

lmod.timestamp: baseospackages.timestamp
	rocm/sources/scripts/lmod_setup.sh
	touch lmod.timestamp

rocm.timestamp: baseospackages.timestamp lmod.timestamp
	rocm/sources/scripts/rocm_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocm.timestamp

openmpi.timestamp: rocm.timestamp
	rocm/sources/scripts/openmpi_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}
	touch openmpi.timestamp


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

apps_setup_basic.timestamp:
	training/sources/scripts/apps_setup_basic.sh

kokkos.timestamp: rocm.timestamp
	training/sources/scripts/kokkos_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-kokkos ${BUILD_KOKKOS}

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

#training/sources/scripts/apps_setup.sh


# Testing support for builds
HPCTrainingExamples.timestamp:
	git clone https://github.com/AMD/HPCTrainingExamples 
	cd HPCTrainingExamples/tests && mkdir build && cd build && cmake ..
	touch HPCTrainingExamples.timestamp

openmpi_tests.timestamp: openmpi.timestamp HPCTrainingExamples.timestamp
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R OpenMPI
	touch openmpi_tests.timestamp

kokkos_tests.timestamp: kokkos.timestamp HPCTrainingExamples.timestamp
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Kokkos
	touch kokkos_tests.timestamp

cupy_tests.timestamp: cupy.timestamp HPCTrainingExamples.timestamp
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Cupy
	touch cupy_tests.timestamp

pytorch_tests.timestamp: pytorch.timestamp HPCTrainingExamples.timestamp
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Pytorch
	touch pytorch_tests.timestamp


# Deploy targets create a compressed tar image of the directory for the package
rocm_package.timestamp: rocm.timestamp
	cd /opt && \
	   tar -czpf /tmp/rocm-${ROCM_VERSION}.tgz \
	      /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/rocm-${ROCM_VERSION} && \
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
