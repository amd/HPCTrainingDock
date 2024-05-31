
ARG DISTRO
ARG DISTRO_VERSION
FROM ${DISTRO}:${DISTRO_VERSION}

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

RUN apt-get update
RUN apt-get install -q -y git vim sudo

SHELL ["/bin/bash", "-c"]

RUN groupadd student && useradd -m -s /bin/bash -g student student
RUN usermod -a -G video,render,renderalt,sudo --password $(echo amdtest | openssl passwd -1 -stdin) student

RUN chown -R student:student /home/student
USER student
ENV HOME=/home/student
WORKDIR /home/student
RUN git clone https://github.com/AMD/HPCTrainingDock


ENTRYPOINT ["bash"]
