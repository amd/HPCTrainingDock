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

# fix the nodejs install if broken
RUN cd /etc/apt/sources.list.d  \
    && ls -lsa  \
    && rm -f  nodesource.list \
    && apt-get --fix-broken install \
    && apt-get update  \
    && apt-get remove nodejs \
    && apt-get remove nodejs-doc 

RUN apt-get update && \
    apt-get install -y apt-transport-https software-properties-common  adduser libfontconfig1 wget curl && \
    wget -q https://dl.grafana.com/enterprise/release/grafana-enterprise_8.3.4_amd64.deb &&\
    dpkg -i grafana-enterprise_8.3.4_amd64.deb &&\
    echo "deb https://packages.grafana.com/enterprise/deb stable main" | tee -a /etc/apt/sources.list.d/grafana.list && \
    echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" | tee /etc/apt/sources.list.d/yarn.list && \
    apt-get install gnupg && \
    wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc -O server-6.0.asc &&\
    apt-key add server-6.0.asc && \
    echo "deb [trusted=yes arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org.list && \
    wget -q -O - https://packages.grafana.com/gpg.key | apt-key add - && \
    curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarnkey.gpg > /dev/null  && \
    apt-get update && \
    apt-get install -y mongodb-org                                      && \
    apt-get install -y tzdata systemd apt-utils npm vim net-tools  	&& \
    mkdir -p /nonexistent                                               && \
    /usr/sbin/grafana-cli plugins install michaeldmoore-multistat-panel && \
    /usr/sbin/grafana-cli plugins install ae3e-plotly-panel             && \
    /usr/sbin/grafana-cli plugins install natel-plotly-panel            && \
    /usr/sbin/grafana-cli plugins install grafana-image-renderer        && \
    apt-get autoremove -y                                               && \
    chown root:grafana /etc/grafana                                     && \
    cd /var/lib/grafana/plugins/omniperfData_plugin                     && \
    npm install                                                         && \
    npm run build                                                       && \
    curl --compressed -o- -L https://yarnpkg.com/install.sh | bash      && \
    apt-get autoremove -y                                               && \
    apt-get autoclean -y                                                && \
    cd /var/lib/grafana/plugins/custom-svg                              && \
    sed -i "s/  bindIp.*/  bindIp: 0.0.0.0/" /etc/mongod.conf           && \
    mkdir -p /var/lib/grafana					        && \
    touch /var/lib/grafana/grafana.lib					&& \
    chown grafana:grafana /var/lib/grafana/grafana.lib			&& \
    rm /app/grafana-enterprise_8.3.4_amd64.deb /app/server-6.0.asc

ENV PATH=$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH

#COPY omniperf/requirements.txt  .
#ENV INSTALL_DIR=/opt/rocmplus-${ROCM_VERSION}/omniperf-1.0.10
#RUN  wget -q https://github.com/AMDResearch/omniperf/releases/download/v1.0.10/omniperf-v1.0.10.tar.gz && \
#     tar xfz omniperf-v1.0.10.tar.gz && \
#     cd ./omniperf-1.0.10\
#     && python3 -m pip install -t ${INSTALL_DIR}/python-libs -r requirements.txt \
#     && python3 -m pip install -t ${INSTALL_DIR}/python-libs pytest \
#     && mkdir build \
#     && cd build  \
#     &&  cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/ \
#        -DCMAKE_BUILD_TYPE=Release \
#        -DPYTHON_DEPS=${INSTALL_DIR}/python-libs \
#        -DMOD_INSTALL_PATH=${INSTALL_DIR}/modulefiles .. \
#     && make install \
#     && cd /app && rm -rf omniperf-1.0.10 omniperf-v1.0.10.tar.gz
#
#ENV INSTALL_DIR=/opt/rocmplus-${ROCM_VERSION}/omniperf-1.1.0-PR1
#RUN  wget -q https://github.com/AMDResearch/omniperf/releases/download/v1.1.0-PR1/omniperf-v1.1.0-PR1.tar.gz && \
#     tar xfz omniperf-v1.1.0-PR1.tar.gz && \
#     cd ./omniperf-1.1.0-PR1\
#     && python3 -m pip install -t ${INSTALL_DIR}/python-libs -r requirements.txt \
#     && python3 -m pip install -t ${INSTALL_DIR}/python-libs pytest \
#     && mkdir build \
#     && cd build  \
#     &&  cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/ \
#        -DCMAKE_BUILD_TYPE=Release \
#        -DPYTHON_DEPS=${INSTALL_DIR}/python-libs \
#        -DMOD_INSTALL_PATH=${INSTALL_DIR}/modulefiles .. \
#     && make install \
#     && cd /app && rm -rf omniperf-1.1.0-PR1 omniperf-v1.1.0-PR1.tar.gz

ENV INSTALL_DIR=/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.0
RUN  wget -q https://github.com/AMDResearch/omniperf/releases/download/v2.0.0-RC1/omniperf-2.0.0-RC1.tar.gz && \
     tar xfz omniperf-2.0.0-RC1.tar.gz && \
     cd ./omniperf-2.0.0-RC1\
     && python3 -m pip install -t ${INSTALL_DIR}/python-libs -r requirements.txt \
     && python3 -m pip install -t ${INSTALL_DIR}/python-libs pytest \
     && mkdir build \
     && cd build  \
     &&  cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/ \
        -DCMAKE_BUILD_TYPE=Release \
        -DPYTHON_DEPS=${INSTALL_DIR}/python-libs \
        -DMOD_INSTALL_PATH=${INSTALL_DIR}/modulefiles .. \
     && make install \
     && cd /app && rm -rf omniperf-2.0.0-RC1 omniperf-2.0.0-RC1.tar.gz

RUN sed -i -e 's/ascii/utf-8/' /opt/rocmplus-*/omniperf-*/bin/utils/specs.py

#ENV PATH=$INSTALL_DIR/bin:$PATH \
#    PYTHONPATH=$INSTALL_DIR/python-libs
#ENV PYTHONPATH=$INSTALL_DIR/python-libs

#RUN echo 'export PYTHONPATH=/opt/omniperf/python-libs' >> /etc/profile.d/omniperf.sh


# Overwrite grafana ini file
COPY omniperf/docker/grafana.ini /etc/grafana

# switch Grafana port to 4000
RUN sed -i "s/^;http_port = 3000/http_port = 4000/" /etc/grafana/grafana.ini && \
    sed -i "s/^http_port = 3000/http_port = 4000/" /usr/share/grafana/conf/defaults.ini

# clean up /tmp
RUN rm -rf /tmp/*

RUN mkdir /etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf
COPY  omniperf/sources/lua/omniperf/2.0.0.lua   /etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf/
#RUN sed -i "s|ROCM_VERSION|${ROCM_VERSION}|g" /etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf/1.0.10.lua 
#RUN sed -i "s|ROCM_VERSION|${ROCM_VERSION}|g" /etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf/1.1.0-PR1.lua 
RUN sed -i "s|ROCM_VERSION|${ROCM_VERSION}|g" /etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf/2.0.0.lua 

# starts mongo and grafana-server at startup
COPY omniperf/docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod a+x /docker-entrypoint.sh

ENTRYPOINT [ "/docker-entrypoint.sh" ]
