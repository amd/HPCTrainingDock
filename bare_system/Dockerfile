ARG DISTRO
ARG DISTRO_VERSION
FROM ${DISTRO}:${DISTRO_VERSION}

ARG DISTRO
ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG ROCM_INSTALLPATH
ARG AMDGPU_GFXMODEL
ARG USE_MAKEFILE

LABEL maintainer="bob.robey@amd.com"

ENV HOME /root
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US
ENV LC_ALL C
ENV SHELL /bin/bash
ENV BASH_ENV /etc/bash.bashrc
ENV DEBIAN_FRONTEND noninteractive

# Adding render group early to avoid something else grabbing it and causing problems for slurm
RUN groupadd render -g 109
RUN groupadd renderalt -g 110

WORKDIR /tmp

RUN apt-get -q -y update
RUN apt-get install -q -y vim sudo apt-utils make


SHELL ["/bin/bash", "-c"]

RUN adduser --home /home/sysadmin --uid 20000 --shell /bin/bash --disabled-password --gecos '' sysadmin
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
#RUN usermod -a -G video,render,renderalt,sudo --password $(echo amdtest | openssl passwd -1 -stdin) sysadmin
RUN usermod -a -G video,render,renderalt,sudo sysadmin

RUN chown -R sysadmin:sysadmin /home/sysadmin
USER sysadmin
ENV HOME=/home/sysadmin
WORKDIR /home/sysadmin

#COPY rocm/sources/scripts/lmod_setup.sh /tmp/lmod_setup.sh
#RUN /tmp/lmod_setup.sh
#&& rm /tmp/lmod_setup.sh

ADD bare_system bare_system
ADD bare_system/Makefile Makefile
ADD rocm rocm
ADD omnitrace omnitrace
ADD omniperf omniperf
ADD training training
COPY cache.list CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/*.tgz /opt/rocmplus-${ROCM_VERSION}/

ENV ROCM_VERSION=$ROCM_VERSION
ENV AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL
ENV BUILD_CUPY=$BUILD_CUPY
ENV OMNITRACE_BUILD_FROM_SOURCE=1
ENV DISTRO=${DISTRO}
ENV DISTRO_VERSION=${DISTRO_VERSION}

RUN bare_system/main_setup.sh --rocm-version ${ROCM_VERSION} --rocm-install-path ${ROCM_INSTALLPATH} \
    --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --use-makefile ${USE_MAKEFILE}

# install module files
#COPY  training/sources/lua/gcc/*          /etc/lmod/modules/Linux/gcc/
#COPY  training/sources/lua/clang/*        /etc/lmod/modules/Linux/clang/
#RUN rocm/sources/scripts/lmod_setup.sh


ENTRYPOINT ["bash"]
