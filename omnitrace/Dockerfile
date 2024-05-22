# -----------------------------------------------------------------------
# NOTE:
# Dependencies are not included as part of Omnitrace.
# It's the user's responsibility to accept any licensing implications 
# before building the project
# -----------------------------------------------------------------------

ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG DOCKER_USER

FROM ${DOCKER_USER}/rocm:release-base-ubuntu-${DISTRO_VERSION}-rocm-${ROCM_VERSION}
ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG OMNITRACE_BUILD_FROM_SOURCE
ARG AMDGPU_GFXMODEL=gfx90a

LABEL maintainer="david.doscher@amd.com"

RUN ls -lsa /home

WORKDIR /tmp
WORKDIR /app

USER root

ENV DEBIAN_FRONTEND noninteractive
ENV TZ "US/Chicago"

RUN wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /opt/miniconda-installer.sh && \
    bash /opt/miniconda-installer.sh -b -p /opt/miniconda3 && \
    export PATH="/opt/miniconda3/bin:${PATH}" && \
    conda config --set always_yes yes --set changeps1 no && \
    conda update -c defaults -n base conda && \
    for i in ${PYTHON_VERSIONS}; do conda create -n py3.${i} -c defaults -c conda-forge python=3.${i} pip; done && \
    for i in ${PYTHON_VERSIONS}; do /opt/conda/envs/py3.${i}/bin/python -m pip install numpy perfetto dataclasses; done && \
    conda clean -a -y && \
    rm -rf /opt/miniconda-installer.sh

#   conda init && \

COPY  omnitrace/sources/lua/miniconda3/23.11.0.lua  /etc/lmod/modules/Linux/miniconda3/23.11.0.lua
RUN sed -i -e "s/SCRIPT_ROCM_VERSION/${ROCM_VERSION}/g"  /etc/lmod/modules/Linux/miniconda3/23.11.0.lua

COPY omnitrace/sources/scripts/omnitrace_setup.sh /tmp/omnitrace_setup.sh

RUN chmod u+x /tmp/omnitrace_setup.sh && \
          /tmp/omnitrace_setup.sh \
            --rocm-version ${ROCM_VERSION} \
            --distro-version ${DISTRO_VERSION} \
            --amdgpu_gfxmode ${AMDGPU_GFXMODEL} \
            --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE} && \
          rm /tmp/omnitrace_setup.sh

# omnitrace (omnitrace-avail) will throw this message using default values, so change default to 2
# [omnitrace][116] /proc/sys/kernel/perf_event_paranoid has a value of 3. Disabling PAPI (requires a value <= 2)...
# [omnitrace][116] In order to enable PAPI support, run 'echo N | sudo tee /proc/sys/kernel/perf_event_paranoid' where                   N is <= 2
RUN if (( `cat /proc/sys/kernel/perf_event_paranoid` > 0 )); then echo "Please do:  echo 0  | sudo tee /proc/sys/kernel/perf_event_paranoid"; fi

ENV LC_ALL C.UTF-8

WORKDIR /home

SHELL [ "/bin/bash", "--login", "-c" ]
