ARG DISTRO
ARG DISTRO_VERSION
FROM ${DISTRO}:${DISTRO_VERSION}

ARG DISTRO
ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG ROCM_INSTALLPATH
ARG AMDGPU_GFXMODEL
ARG PYTHON_VERSION
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
#RUN groupadd render -g 109
#RUN groupadd renderalt -g 110

WORKDIR /tmp

COPY bare_system/bootstrap_os.sh /tmp/bootstrap_os.sh
RUN /tmp/bootstrap_os.sh && rm /tmp/bootstrap_os.sh

COPY rocm/scripts/lmod_setup.sh /tmp/lmod_setup.sh

RUN  /tmp/lmod_setup.sh && \
     rm /tmp/lmod_setup.sh

COPY rocm/sources/lua/bash.bashrc /tmp/bash.bashrc
RUN cat /tmp/bash.bashrc >> /etc/bash.bashrc && rm -f /tmp/bash.bashrc

SHELL ["/bin/bash", "-c"]

RUN apt-get update && \
    apt-get install -y  net-tools iproute2 openssh-server iputils-ping && \
    systemctl enable ssh

EXPOSE 22

COPY bare_system/adduser_os.sh /tmp/adduser_os.sh
RUN /tmp/adduser_os.sh && rm /tmp/adduser_os.sh

USER sysadmin
ENV HOME=/home/sysadmin
ENV USER=sysadmin
WORKDIR /home/sysadmin

ENV ROCM_VERSION=$ROCM_VERSION
ENV AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL
ENV PYTHON_VERSION=$PYTHON_VERSION
ENV OMNITRACE_BUILD_FROM_SOURCE=1
ENV DISTRO=${DISTRO}
ENV DISTRO_VERSION=${DISTRO_VERSION}

ADD bare_system bare_system
ADD bare_system/Makefile Makefile
ADD rocm rocm
ADD comm comm
ADD tools tools
ADD extras extras

# for VNC
ADD extras/image/etc  /etc
ADD extras/image/usr  /usr
ADD extras/image/home /home/sysadmin

RUN sudo chown -R sysadmin:sysadmin /home/sysadmin

RUN bare_system/main_setup.sh --rocm-version ${ROCM_VERSION} --rocm-install-path ${ROCM_INSTALLPATH} \
    --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --use-makefile ${USE_MAKEFILE} --python-version ${PYTHON_VERSION} \
    --distro ${DISTRO} --distro-version ${DISTRO_VERSION}

ENTRYPOINT ["bash"]
