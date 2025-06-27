# -----------------------------------------------------------------------
# NOTE:
# Dependencies are not included as part of Omniperf.
# It's the user's responsibility to accept any licensing implications
# before building the project
# -----------------------------------------------------------------------

ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG DOCKER_USER

# This image will be built on top of the image below
# which is the communication packages image built before this one
FROM ${DOCKER_USER}/comm:release-base-ubuntu-${DISTRO_VERSION}-rocm-${ROCM_VERSION}
ARG ROCM_VERSION
ARG PYTHON_VERSION
ARG AMDGPU_GFXMODEL
ARG INSTALL_GRAFANA=0
ARG BUILD_HPCTOOLKIT
ARG BUILD_TAU
ARG BUILD_SCOREP
ARG INSTALL_ROCPROF_SYS_FROM_SOURCE
ARG INSTALL_ROCPROF_COMPUTE_FROM_SOURCE

LABEL maintainer="bob.robey@amd.com"

#
# Install rocprof-sys (or omnitrace depending on ROCm version)
#

COPY tools/scripts/rocprof-sys_setup.sh /tmp/rocprof-sys_setup.sh

RUN /tmp/rocprof-sys_setup.sh \
       --rocm-version ${ROCM_VERSION} \
       --python-version ${PYTHON_VERSION} \
       --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
       --install-rocprof-sys-from-source ${INSTALL_ROCPROF_SYS_FROM_SOURCE} && \
    rm /tmp/rocprof-sys_setup.sh

ENV LC_ALL C.UTF-8

WORKDIR /app

USER root

ENV DEBIAN_FRONTEND noninteractive
ENV TZ "US/Chicago"

ADD tools/grafana_plugins/svg_plugin /var/lib/grafana/plugins/custom-svg
ADD tools/grafana_plugins/omniperfData_plugin /var/lib/grafana/plugins/omniperfData_plugin

RUN chmod 1777 /tmp

#
# Install Grafana
#

COPY tools/scripts/ /tmp/tools

RUN  /tmp/tools/grafana_setup.sh --install-grafana ${INSTALL_GRAFANA} && \
     /tmp/tools/rocprof-compute_setup.sh \
        --rocm-version ${ROCM_VERSION} \
        --python-version ${PYTHON_VERSION} \
        --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
        --install-rocprof-compute-from-source ${INSTALL_ROCPROF_COMPUTE_FROM_SOURCE} && \
     /tmp/tools/hpctoolkit_setup.sh --rocm-version ${ROCM_VERSION} --build-hpctoolkit ${BUILD_HPCTOOLKIT} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     /tmp/tools/tau_setup.sh --rocm-version ${ROCM_VERSION} --build-tau ${BUILD_TAU} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     /tmp/tools/scorep_setup.sh --rocm-version ${ROCM_VERSION} --build-scorep ${BUILD_SCOREP} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm -rf /tmp/tools

ENV PATH=$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH

# Overwrite grafana ini file
COPY tools/docker/grafana.ini /etc/grafana

# clean up /tmp
RUN rm -rf /tmp/*

# starts mongo and grafana-server at startup
COPY tools/docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod a+x /docker-entrypoint.sh

ENTRYPOINT [ "/docker-entrypoint.sh" ]
