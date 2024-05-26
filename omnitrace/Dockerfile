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

FROM ${DOCKER_USER}/rocm:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}
ARG ROCM_VERSION
ARG OMNITRACE_BUILD_FROM_SOURCE
ARG PYTHON_VERSIONS

LABEL maintainer="david.doscher@amd.com"

RUN ls -lsa /home

WORKDIR /tmp
WORKDIR /app

USER root

ENV DEBIAN_FRONTEND noninteractive
ENV TZ "US/Chicago"

COPY omnitrace/sources/scripts/miniconda3_setup.sh /tmp/miniconda3_setup.sh

RUN /tmp/miniconda3_setup.sh \
        --rocm-version ${ROCM_VERSION} \
        --python_versions "${PYTHON_VERSIONS}" \
    rm /tmp/miniconda3_setup.sh

#   conda init && \

COPY omnitrace/sources/scripts/omnitrace_setup.sh /tmp/omnitrace_setup.sh

RUN /tmp/omnitrace_setup.sh \
       --rocm-version ${ROCM_VERSION} \
       --amdgpu_gfxmode ${AMDGPU_GFXMODEL} \
       --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE} && \
    rm /tmp/omnitrace_setup.sh

ENV LC_ALL C.UTF-8

WORKDIR /home

SHELL [ "/bin/bash", "--login", "-c" ]
