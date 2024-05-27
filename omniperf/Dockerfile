# -----------------------------------------------------------------------
# NOTE:
# Dependencies are not included as part of Omniperf.
# It's the user's responsibility to accept any licensing implications 
# before building the project
# -----------------------------------------------------------------------

ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG DOCKER_USER

FROM ${DOCKER_USER}/omnitrace:release-base-ubuntu-${DISTRO_VERSION}-rocm-${ROCM_VERSION}
ARG ROCM_VERSION

LABEL maintainer="david.doscher@amd.com"

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

RUN  /tmp/grafana_setup.sh && \
     rm /tmp/grafana_setup.sh

ENV PATH=$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH

#
# Install Omniperf
#

COPY omniperf/sources/scripts/omniperf_setup.sh /tmp/omniperf_setup.sh

RUN  /tmp/omniperf_setup.sh --rocm_version ${ROCM_VERSION} && \
     rm /tmp/omniperf_setup.sh

# Overwrite grafana ini file
COPY omniperf/docker/grafana.ini /etc/grafana

# switch Grafana port to 4000
RUN sed -i "s/^;http_port = 3000/http_port = 4000/" /etc/grafana/grafana.ini && \
    sed -i "s/^http_port = 3000/http_port = 4000/" /usr/share/grafana/conf/defaults.ini

# clean up /tmp
RUN rm -rf /tmp/*

# starts mongo and grafana-server at startup
COPY omniperf/docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod a+x /docker-entrypoint.sh

ENTRYPOINT [ "/docker-entrypoint.sh" ]
