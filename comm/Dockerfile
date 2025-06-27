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
ARG BUILD_MPI4PY

LABEL maintainer="bob.robey@amd.com"

WORKDIR /app

USER root

ENV DEBIAN_FRONTEND noninteractive
ENV TZ "US/Chicago"

COPY comm/scripts/ /tmp/comm/

RUN  /tmp/comm/openmpi_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     /tmp/comm/mvapich_setup.sh --rocm-version ${ROCM_VERSION} && \
     /tmp/comm/mpi4py_setup.sh --rocm-version ${ROCM_VERSION}  --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-mpi4py ${BUILD_MPI4PY} && \
     rm -rf /tmp/comm

ENV LC_ALL C.UTF-8

WORKDIR /home

SHELL [ "/bin/bash", "--login", "-c" ]
