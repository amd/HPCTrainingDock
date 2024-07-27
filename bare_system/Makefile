SHELL:=/bin/bash
all: rocm openmpi omnitrace kokkos cupy
.PHONY: baseospackages lmod rocm openmpi omnitrace cupy pytorch

baseospackages: baseospackages.timestamp
lmod: lmod.timestamp
rocm: rocm.timestamp
openmpi: openmpi.timestamp
omnitrace: omnitrace.timestamp
kokkos: kokkos.timestamp
cupy: cupy.timestamp
pytorch: pytorch.timestamp

# From base rocm layer
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


# From Omnitrace layer
miniconda3.timestamp:
	omnitrace/sources/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --python-versions ${PYTHON_VERSIONS}
	touch miniconda3.timestamp

omnitrace.timestamp: miniconda3.timestamp openmpi.timestamp
	omnitrace/sources/scripts/omnitrace_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}
	touch omnitrace.timestamp

# From Omniperf layer

grafana.timestamp:
	omniperf/sources/scripts/grafana_setup.sh

omniperf.timestamp: rocm.timestamp
	omniperf/sources/scripts/omniperf_setup.sh --rocm-version ${ROCM_VERSION}

# From Training layer

compiler_setup.sh:
	training/sources/scripts/compiler_setup.sh

apps_setup_basic.timestamp:
	training/sources/scripts/apps_setup_basic.sh

kokkos.timestamp: rocm.timestamp
	training/sources/scripts/kokkos_setup.sh --rocm-version ${ROCM_VERSION} --build-kokkos ${BUILD_KOKKOS}

cupy.timestamp: rocm.timestamp
	training/sources/scripts/cupy_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-cupy ${BUILD_CUPY}
	touch cupy.timestamp

pytorch.timestamp: rocm.timestamp apps_setup_basic.timestamp
	training/sources/scripts/pytorch_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-pytorch ${BUILD_PYTORCH}
	touch pytorch.timestamp

#training/sources/scripts/apps_setup.sh


# Testing support for builds
HPCTrainingExamples:
	git clone https://github.com/AMD/HPCTrainingExamples 
	cd HPCTrainingExamples/tests && mkdir build && cd build && cmake ..

openmpi_tests: openmpi.timestamp HPCTrainingExamples
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R OpenMPI

kokkos_tests: kokkos.timestamp HPCTrainingExamples
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Kokkos

cupy_tests: cupy.timestamp HPCTrainingExamples
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Cupy

pytorch_tests: pytorch.timestamp HPCTrainingExamples
	source /etc/profile.d/lmod.sh && cd HPCTrainingExamples/tests/build && ctest -R Pytorch


# Deploy targets create a compressed tar image of the directory for the package
rocm_package: rocm.timestamp
	cd /opt && \
	   tar -czpf /tmp/rocm-${ROCM_VERSION}.tgz rocm-${ROCM_VERSION} && \
	   cp -p /tmp/rocm-${ROCM_VERSION}.tgz /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}
	touch rocm_package.timestamp

openmpi_package: openmpi.timestamp
	cd /opt/rocmplus-${ROCM_VERSION} && OPENMPI_NAME=`ls openmpi*` && \
	   tar -czvpf ${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/${OPENMPI_NAME}.tgz ${OPENMPI_NAME}
	cd /opt/rocmplus-${ROCM_VERSION} && UCC_NAME=`ls ucc*` && \
	   tar -czvpf ${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/${UCC_NAME}.tgz ${UCC_NAME}
	cd /opt/rocmplus-${ROCM_VERSION} && UCX_NAME=`ls ucx*` && \
	   tar -czvpf ${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/${UCX_NAME}.tgz ${UCX_NAME}
	touch openmpi_package.timestamp

omnitrace_package: omnitrace.timestamp
	cd /opt/rocmplus-${ROCM_VERSION} && OMNITRACE_NAME=`ls omnitrace*` && \
	   tar -czvpf ${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/${OMNITRACE_NAME}.tgz ${OMNITRACE_NAME}
	touch omnitrace_package.timestamp

cupy_package: cupy.timestamp
	cd /opt/rocmplus-${ROCM_VERSION} && \
	   tar -czvpf /tmp/cupy.tgz cupy
	   sudo cp /tmp/cupy.tgz /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}
	touch cupy_package.timestamp

pytorch_package: pytorch.timestamp
	cd /opt/rocmplus-${ROCM_VERSION} && PYTORCH_NAME=`ls cupy*` && \
	   tar -czvpf ${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/${PYTORCH_NAME}.tgz ${PYTORCH_NAME}
	touch pytorch_package.timestamp

package_all:
	cd /opt/rocmplus-${ROCM_VERSION} && \
	   for package in `ls *`; do \
	      if [ "${package}" =~ "cupy" ]; then \
	         tar -czvpf ${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/${package}.tgz ${package} \
	      fi \
	   done
		   

#all_package: rocm_package.timestamp openmpi_package.timestamp omnitrace_package.timestamp cupy_package.timestamp pytorch_package.timestamp
