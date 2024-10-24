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
ARG DISTRO
ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG AMDGPU_GFXMODEL

LABEL maintainer="bob.robey@amd.com"

WORKDIR /app

USER root

ENV DEBIAN_FRONTEND noninteractive
ENV TZ "US/Chicago"

#
# install OpenMPI, UCC, and UCX
#

COPY comm/scripts/openmpi_setup.sh /tmp/openmpi_setup.sh

RUN  /tmp/openmpi_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm /tmp/openmpi_setup.sh

#
# Install mvapich
#

COPY comm/scripts/mvapich_setup.sh /tmp/mvapich_setup.sh

RUN  /tmp/mvapich_setup.sh --rocm-version ${ROCM_VERSION} && \
     rm /tmp/mvapich_setup.sh

#
# install MPI4PY
#

COPY comm/scripts/mpi4py_setup.sh /tmp/mpi4py_setup.sh

RUN  /tmp/mpi4py_setup.sh --rocm-version ${ROCM_VERSION}  --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-mpi4py 1 && \
     rm /tmp/mpi4py_setup.sh

ENV LC_ALL C.UTF-8

WORKDIR /home

SHELL [ "/bin/bash", "--login", "-c" ]
