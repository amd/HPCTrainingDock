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
# which is the omnitrace image built before this one
FROM ${DOCKER_USER}/comm:release-base-ubuntu-${DISTRO_VERSION}-rocm-${ROCM_VERSION}
ARG ROCM_VERSION
ARG OMNITRACE_BUILD_FROM_SOURCE
ARG AMDGPU_GFXMODEL
ARG INSTALL_GRAFANA=0
ARG BUILD_HPCTOOLKIT
ARG BUILD_TAU
ARG BUILD_SCOREP

LABEL maintainer="bob.robey@amd.com"

COPY tools/sources/scripts/omnitrace_setup.sh /tmp/omnitrace_setup.sh

RUN /tmp/omnitrace_setup.sh \
       --rocm-version ${ROCM_VERSION} \
       --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
       --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE} && \
    rm /tmp/omnitrace_setup.sh

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

COPY tools/sources/scripts/grafana_setup.sh /tmp/grafana_setup.sh

RUN  /tmp/grafana_setup.sh --install-grafana ${INSTALL_GRAFANA} && \
     rm /tmp/grafana_setup.sh

ENV PATH=$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH

#
# Install Omniperf
#

COPY tools/sources/scripts/omniperf_setup.sh /tmp/omniperf_setup.sh

RUN  /tmp/omniperf_setup.sh --rocm-version ${ROCM_VERSION} --amd-staging 1 --replace 1 && \
     rm /tmp/omniperf_setup.sh

# Overwrite grafana ini file
COPY tools/docker/grafana.ini /etc/grafana

# clean up /tmp
RUN rm -rf /tmp/*

# starts mongo and grafana-server at startup
COPY tools/docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod a+x /docker-entrypoint.sh

#
# Install HPCToolkit
#
COPY tools/sources/scripts/hpctoolkit_setup.sh /tmp/hpctoolkit_setup.sh

RUN  /tmp/hpctoolkit_setup.sh --rocm-version ${ROCM_VERSION} --build-hpctoolkit ${BUILD_HPCTOOLKIT} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm /tmp/hpctoolkit_setup.sh


#
# Install TAU
#
COPY tools/sources/scripts/tau_setup.sh /tmp/tau_setup.sh

RUN  /tmp/tau_setup.sh --rocm-version ${ROCM_VERSION} --build-tau ${BUILD_TAU} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm /tmp/tau_setup.sh


#
# Install Score-P
#
COPY tools/sources/scripts/scorep_setup.sh /tmp/scorep_setup.sh

RUN  /tmp/scorep_setup.sh --rocm-version ${ROCM_VERSION} --build-scorep ${BUILD_SCOREP} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm /tmp/scorep_setup.sh

ENTRYPOINT [ "/docker-entrypoint.sh" ]
