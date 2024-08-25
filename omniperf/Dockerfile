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
FROM ${DOCKER_USER}/omnitrace:release-base-ubuntu-${DISTRO_VERSION}-rocm-${ROCM_VERSION}
ARG ROCM_VERSION
ARG INSTALL_GRAFANA=0

LABEL maintainer="bob.robey@amd.com"

WORKDIR /tmp
WORKDIR /app

USER root

ENV DEBIAN_FRONTEND noninteractive
ENV TZ "US/Chicago"

ADD omniperf/grafana_plugins/svg_plugin /var/lib/grafana/plugins/custom-svg
ADD omniperf/grafana_plugins/omniperfData_plugin /var/lib/grafana/plugins/omniperfData_plugin

RUN chmod 1777 /tmp

#
# Install Grafana
#

COPY omniperf/sources/scripts/grafana_setup.sh /tmp/grafana_setup.sh

RUN  /tmp/grafana_setup.sh --install-grafana ${INSTALL_GRAFANA} && \
     rm /tmp/grafana_setup.sh

ENV PATH=$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH

#
# Install Omniperf
#

COPY omniperf/sources/scripts/omniperf_setup.sh /tmp/omniperf_setup.sh

RUN  /tmp/omniperf_setup.sh --rocm-version ${ROCM_VERSION} && \
     rm /tmp/omniperf_setup.sh

# Overwrite grafana ini file
COPY omniperf/docker/grafana.ini /etc/grafana

# clean up /tmp
RUN rm -rf /tmp/*

# starts mongo and grafana-server at startup
COPY omniperf/docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod a+x /docker-entrypoint.sh

ENTRYPOINT [ "/docker-entrypoint.sh" ]
