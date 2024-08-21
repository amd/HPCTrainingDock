
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
ARG AMDGPU_GFXMODEL=gfx90a
ENV PATH ${HOME}/.local/bin:${PATH}

COPY rocm/sources/scripts/baseospackages_setup.sh /tmp/baseospackages_setup.sh

RUN  /tmp/baseospackages_setup.sh && \
     rm /tmp/baseospackages_setup.sh

COPY rocm/sources/scripts/lmod_setup.sh /tmp/lmod_setup.sh

RUN  /tmp/lmod_setup.sh && \
     rm /tmp/lmod_setup.sh

# Grab any cached files of MPI builds and place them in /opt/rocmplus-VERSION
ADD CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL} \
   /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}

COPY rocm/sources/scripts/rocm_setup.sh /tmp/rocm_setup.sh

RUN  /tmp/rocm_setup.sh --rocm-version ${ROCM_VERSION} && \
     rm /tmp/rocm_setup.sh

COPY rocm/sources/lua/bash.bashrc /tmp/bash.bashrc
RUN cat /tmp/bash.bashrc >> /etc/bash.bashrc && rm -f /tmp/bash.bashrc

COPY rocm/sources/scripts/rocm_omnitrace_setup.sh /tmp/rocm_omnitrace_setup.sh

RUN  /tmp/rocm_omnitrace_setup.sh --rocm-version ${ROCM_VERSION} && \
     rm /tmp/rocm_omnitrace_setup.sh

COPY rocm/sources/scripts/rocm_omniperf_setup.sh /tmp/rocm_omniperf_setup.sh

RUN  /tmp/rocm_omniperf_setup.sh --rocm-version ${ROCM_VERSION} && \
     rm /tmp/rocm_omniperf_setup.sh

USER root

# using /app rather than /tmp because prte encodes the HLD and removing /tmp files may cause problems
WORKDIR /app 

#
# install OpenMPI and UCX 
#

COPY rocm/sources/scripts/openmpi_setup.sh /tmp/openmpi_setup.sh

RUN  /tmp/openmpi_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm /tmp/openmpi_setup.sh

#
# Install mvapich
#

COPY rocm/sources/scripts/mvapich_setup.sh /tmp/mvapich_setup.sh

RUN  /tmp/mvapich_setup.sh --rocm-version ${ROCM_VERSION} && \
     rm /tmp/mvapich_setup.sh

# 
# add slurm 
#
# Adding render group early to avoid something else grabbing it and causing problems for slurm
RUN groupadd render -g 109
RUN groupadd renderalt -g 110

#
# Install Slurm
#

COPY rocm/sources/scripts/slurm_setup.sh /tmp/slurm_setup.sh

COPY rocm/sources/slurm/slurm_${AMDGPU_GFXMODEL}.conf /tmp/slurm.conf
COPY rocm/sources/slurm/gres_${AMDGPU_GFXMODEL}.conf /tmp/gres.conf

RUN  /tmp/slurm_setup.sh --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
     rm /tmp/slurm_setup.sh

ENV LC_ALL C.UTF-8

WORKDIR /home

SHELL [ "/bin/bash", "--login", "-c" ]
