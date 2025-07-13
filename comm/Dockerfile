# -----------------------------------------------------------------------
# NOTE:
# Dependencies are not included as part of Omnitrace.
# It's the user's responsibility to accept any licensing implications
# before building the project
# -----------------------------------------------------------------------

ARG DISTRO
ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG DOCKER_USER

# This image will be built on top of the image below
# which is the rocm image built before this one
FROM ${DOCKER_USER}/rocm:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}

# List the variables needed below. ROCM_VERSION needs reloading because it is 
#  consumed with FROM command
ARG ROCM_VERSION
ARG AMDGPU_GFXMODEL
ARG BUILD_MPI4PY

LABEL maintainer="bob.robey@amd.com"

WORKDIR /app

USER root

ENV DEBIAN_FRONTEND noninteractive
ENV TZ "US/Chicago"

# Install GPU aware OpenMPI
COPY comm/scripts/openmpi_setup.sh /tmp/comm/openmpi_setup.sh
RUN  /tmp/comm/openmpi_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm -f /tmp/comm/openmpi_setup.sh

# Install GPU aware MVAPICH
COPY comm/scripts/mvapich_setup.sh /tmp/comm/mvapich_setup.sh
RUN  /tmp/comm/mvapich_setup.sh --rocm-version ${ROCM_VERSION} && \
     rm -f /tmp/comm/mvapich_setup.sh

COPY comm/scripts/mpi4py_setup.sh /tmp/comm/mpi4py_setup.sh
RUN  /tmp/comm/mpi4py_setup.sh --rocm-version ${ROCM_VERSION}  --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-mpi4py ${BUILD_MPI4PY} && \
     rm -f /tmp/comm/mpi4py_setup.sh

ENV LC_ALL C.UTF-8

WORKDIR /home

SHELL [ "/bin/bash", "--login", "-c" ]
