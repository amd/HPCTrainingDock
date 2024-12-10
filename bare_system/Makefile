SHELL:=/bin/bash
all: rocm openmpi omnitrace omniperf kokkos aomp cupy pytorch hpctoolkit mpi4py tau jax scorep x11vnc miniconda3 miniforge3 hdf5 hipfort netcdf flang-new fftw hipifly
.PHONY: baseospackages rocm openmpi mvapich slurm omnitrace amd_gcc aomp kokkos aomp cupy pytorch apps_setup hpctoolkit mpi4py tau jax scorep miniconda3 miniforge3 hdf5 hipfort netcdf flang-new fftw hipifly

baseospackages: baseospackages.timestamp
rocm: rocm.timestamp
rocm_omniperf: rocm_omniperf.timestamp
rocm_omnitrace: rocm_omnitrace.timestamp
openmpi: openmpi.timestamp
mvapich: mvapich.timestamp
slurm: slurm.timestamp
omnitrace: omnitrace.timestamp
omniperf: omniperf.timestamp
amd_gcc: amd_gcc.timestamp
aomp: aomp.timestamp
fftw: fftw.timestamp
flang-new: flang-new.timestamp
kokkos: kokkos.timestamp
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
x11vnc: x11vnc.timestamp
jax: jax.timestamp
apps_setup: apps_setup.timestamp

checkSystemConfig: checkSystemConfig.timestamp
env_check: env_check.timestamp
rocm_bandwidth_test: rocm_bandwidth_test.timestamp
hip_tests: hip_tests.timestamp
rocprof_tests: rocprof_tests.timestamp
omniperf_tests: omniperf_tests.timestamp
omnitrace_tests: omnitrace_tests.timestamp
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
jax_tests: jax_tests.timestamp

rocm_package: rocm_package.timestamp
openmpi_package: openmpi_package.timestamp
omnitrace_package: omnitrace_package.timestamp
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

rocm_omnitrace.timestamp: baseospackages.timestamp rocm.timestamp
	rocm/scripts/rocm_omnitrace_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocm_omnitrace.timestamp

rocm_omniperf.timestamp: baseospackages.timestamp rocm.timestamp
	rocm/scripts/rocm_omniperf_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch rocm_omniperf.timestamp

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
	   --build-mpi4py ${BUILD_MPI4PY}
	touch mpi4py.timestamp

# From Tools layer

omnitrace.timestamp: openmpi.timestamp
	tools/scripts/omnitrace_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}
	touch omnitrace.timestamp

grafana.timestamp:
	tools/scripts/grafana_setup.sh

omniperf.timestamp: rocm.timestamp
	tools/scripts/omniperf_setup.sh \
	   --rocm-version ${ROCM_VERSION}
	touch omniperf.timestamp

tau.timestamp: rocm.timestamp
	tools/scripts/tau_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-tau ${BUILD_TAU}
	touch tau.timestamp

scorep.timestamp: rocm.timestamp
	tools/scripts/scorep_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-scorep ${BUILD_SCOREP}
	touch scorep.timestamp

hpctoolkit.timestamp: rocm.timestamp
	tools/scripts/hpctoolkit_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-hpctoolkit ${BUILD_HPCTOOLKIT}
	touch hpctoolkit.timestamp

# From Training layer

compiler_setup.sh:
	extras/scripts/compiler_setup.sh
	touch compiler_setup.timestamp

amd_gcc.timestamp: rocm.timestamp
	extras/scripts/amd_gcc_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-gcc-latest ${BUILD_GCC_LATEST}
	touch amd_gcc.timestamp

aomp.timestamp: rocm.timestamp
	extras/scripts/aomp_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-aomp-latest ${BUILD_AOMP_LATEST}
	touch aomp.timestamp

flang-new.timestamp: rocm.timestamp
	extras/scripts/flang-new_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-flang-new ${BUILD_FLANGNEW}
	touch flang-new.timestamp

miniconda3.timestamp:
	extras/scripts/miniconda3_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --python-version ${PYTHON_VERSION} \
	   --build-miniconda3 ${BUILD_MINICONDA3}
	touch miniconda3.timestamp

miniforge3.timestamp:
	extras/scripts/miniforge3_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --python-version ${PYTHON_VERSION} \
	   --build-miniforge3 ${BUILD_MINIFORGE3}
	touch miniforge3.timestamp

hdf5.timestamp:
	extras/scripts/hdf5_setup.sh \
           --rocm-version ${ROCM_VERSION} \
           --build-hdf5 ${BUILD_HDF5}
	touch hdf5.timestamp

netcdf.timestamp: hdf5.timestamp
	extras/scripts/netcdf_setup.sh \
           --rocm-version ${ROCM_VERSION} \
           --build-netcdf ${BUILD_NETCDF}
	touch netcdf.timestamp

hipfort.timestamp: rocm.timestamp
	extras/scripts/hipfort_setup.sh \
           --rocm-version ${ROCM_VERSION} \
           --build-hipfort ${BUILD_HIPFORT}
	touch hipfort.timestamp

hipifly.timestamp: rocm.timestamp
	extras/scripts/hipifly_setup.sh \
           --rocm-version ${ROCM_VERSION} \
           --hipifly-module ${HIPIFLY_MODULE} \
	   --hipifly-header-path extras/sources/hipifly
	touch hipifly.timestamp

kokkos.timestamp: rocm.timestamp
	extras/scripts/kokkos_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --build-kokkos ${BUILD_KOKKOS}
	touch kokkos.timestamp

cupy.timestamp: rocm.timestamp
	extras/scripts/cupy_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-cupy ${BUILD_CUPY}
	touch cupy.timestamp

pytorch.timestamp: rocm.timestamp
	extras/scripts/pytorch_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-pytorch ${BUILD_PYTORCH}
	touch pytorch.timestamp

jax.timestamp: rocm.timestamp
	extras/scripts/jax_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
	   --amdgpu-gfxmodel '${AMDGPU_GFXMODEL}' \
	   --build-jax ${BUILD_JAX}
	touch jax.timestamp

fftw.timestamp:
	extras/scripts/fftw_setup.sh \
	   --rocm-version ${ROCM_VERSION} \
           --build-fftw ${BUILD_FFTW}
	touch fftw.timestamp

x11vnc.timestamp:
	extras/scripts/x11vnc_setup.sh \
           --build-x11vnc ${BUILD_X11VNC}
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

omniperf_tests.timestamp: omniperf.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Omniperf_AMD_Research
	touch omniperf_tests.timestamp

omnitrace_tests.timestamp: omnitrace.timestamp HPCTrainingExamples
	cd HPCTrainingExamples/tests/build && ctest -R Omnitrace
	touch omnitrace_tests.timestamp

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

kokkos_tests.timestamp: kokkos.timestamp HPCTrainingExamples
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
