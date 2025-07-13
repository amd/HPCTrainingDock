
ARG DISTRO
ARG DISTRO_VERSION
# This image will be built on top of the image below
# which is the OS image desired and defined by DISTRO
# and DISTRO_VERSION
FROM ${DISTRO}:${DISTRO_VERSION}

LABEL maintainer="bob.robey@amd.com"

ENV HOME /root
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US
ENV LC_ALL C
ENV SHELL /bin/bash
ENV BASH_ENV /etc/bash.bashrc
ENV DEBIAN_FRONTEND noninteractive

WORKDIR /tmp
SHELL [ "/bin/bash", "-c" ]

ARG DISTRO
ARG DISTRO_VERSION
ARG ROCM_VERSION="0.0"
ARG PYTHON_VERSION
ARG AMDGPU_GFXMODEL=gfx90a
ARG AMDGPU_GFXMODEL_FIRST=gfx90a
ARG AMDGPU_GFXMODEL_STRING=gfx90a
ARG BUILD_FLANGNEW=1
ENV PATH ${HOME}/.local/bin:${PATH}

COPY rocm/scripts/baseospackages_setup.sh /tmp/rocm/baseospackages_setup.sh
RUN  /tmp/rocm/baseospackages_setup.sh && \
     rm /tmp/rocm/baseospackages_setup.sh

COPY rocm/scripts/lmod_setup.sh /tmp/rocm/lmod_setup.sh
RUN  /tmp/rocm/lmod_setup.sh && \
     rm /tmp/rocm/lmod_setup.sh

COPY rocm/sources/lua/bash.bashrc /tmp/bash.bashrc
RUN cat /tmp/bash.bashrc >> /etc/bash.bashrc && rm -f /tmp/bash.bashrc

# Grab any cached files of MPI builds and place them in /opt/rocmplus-VERSION
ADD CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING} \
   /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

ADD CacheFiles/${DISTRO}-${DISTRO_VERSION} \
   /CacheFiles/${DISTRO}-${DISTRO_VERSION}


COPY rocm/scripts/rocm_setup.sh /tmp/rocm/rocm_setup.sh
RUN  /tmp/rocm/rocm_setup.sh \
        --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} \
        --rocm-version ${ROCM_VERSION} \
        --python-version ${PYTHON_VERSION} && \
     rm -f /tmp/rocm/rocm_setup.sh

COPY rocm/scripts/flang-new_setup.sh /tmp/rocm/flang-new_setup.sh
RUN  /tmp/rocm/flang-new_setup.sh \
        --build-flang-new ${BUILD_FLANGNEW} \
        --rocm-version ${ROCM_VERSION} \
        --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm -f /tmp/rocm/flang-new_setup.sh

USER root

# using /app rather than /tmp because prte encodes the HLD and removing /tmp files may cause problems
WORKDIR /app

#
# add slurm
#
# Adding render group early to avoid something else grabbing it and causing problems for slurm
RUN groupadd render -g 109 && groupadd renderalt -g 110

#
# Install Slurm
#

COPY rocm/scripts/slurm_setup.sh /tmp/rocm/slurm_setup.sh

COPY rocm/sources/slurm/slurm_${AMDGPU_GFXMODEL_FIRST}.conf /tmp/slurm.conf
COPY rocm/sources/slurm/gres_${AMDGPU_GFXMODEL_FIRST}.conf /tmp/gres.conf

RUN  /tmp/rocm/slurm_setup.sh && rm /tmp/rocm/slurm_setup.sh

ENV LC_ALL C.UTF-8

WORKDIR /home

SHELL [ "/bin/bash", "--login", "-c" ]
