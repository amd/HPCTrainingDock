SHELL:=/bin/bash
all: rocm openmpi omnitrace cupy
.PHONY: baseospackages lmod cupy rocm

baseospackages: baseospackages.timestamp
lmod: lmod.timestamp
rocm: rocm.timestamp
openmpi: openmpi.timestamp
omnitrace: omnitrace.timestamp
cupy: cupy.timestamp
pytorch: pytorch.timestamp

baseospackages.timestamp:
	rocm/sources/scripts/baseospackages_setup.sh
	touch baseospackages.timestamp

lmod.timestamp: baseospackages.timestamp
	rocm/sources/scripts/lmod_setup.sh
	touch lmod.timestamp

rocm.timestamp: baseospackages.timestamp lmod.timestamp
	rocm/sources/scripts/rocm_setup.sh --rocm-version ${ROCM_VERSION}
	touch rocm.timestamp

openmpi.timestamp: rocm.timestamp
	rocm/sources/scripts/openmpi_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}
	touch openmpi.timestamp

#rocm/sources/scripts/mvapich2_setup.sh --rocm-version ${ROCM_VERSION}

miniconda3:
	omnitrace/sources/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --python-versions ${PYTHON_VERSIONS}

omnitrace.timestamp: openmpi.timestamp
	omnitrace/sources/scripts/omnitrace_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}
	touch omnitrace.timestamp
#
#omniperf/sources/scripts/grafana_setup.sh
#
#omniperf/sources/scripts/omniperf_setup.sh --rocm-version ${ROCM_VERSION}
#
#training/sources/scripts/compiler_setup.sh
#
#training/sources/scripts/apps_setup_basic.sh
#


cupy.timestamp: rocm.timestamp
	training/sources/scripts/cupy_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-cupy ${BUILD_CUPY}
	touch cupy.timestamp

pytorch.timestamp: rocm.timestamp
	training/sources/scripts/pytorch_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-pytorch ${BUILD_PYTORCH}
	touch pytorch.timestamp

#training/sources/scripts/apps_setup.sh

kokkos: rocm.timestamp
	training/sources/scripts/kokkos_setup.sh --rocm-version ${ROCM_VERSION} --build-kokkos ${BUILD_KOKKOS}

HPCTrainingExamples:
	git clone https://github.com/AMD/HPCTrainingExamples 
	cd HPCTrainingExamples/tests && mkdir build && cd build && cmake ..

openmpi_tests: openmpi.timestamp HPCTrainingExamples
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R OpenMPI

cupy_tests: cupy.timestamp HPCTrainingExamples
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Cupy

pytorch_tests: pytorch.timestamp HPCTrainingExamples
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Pytorch

openmpi_deploy: openmpi.timestamp
	cd /opt/rocmplus-${ROCM_VERSION} && OPENMPI_NAME=`ls openmpi*` && mkdir -p ${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/${OPENMPI_NAME}.tgz && tar -czv ${OPENMPI_NAME}
	touch openmpi_deploy.timestamp
