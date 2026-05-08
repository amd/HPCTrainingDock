
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
        --include-tools 1 \
        --python-version ${PYTHON_VERSION} && \
     rm -f /tmp/rocm/rocm_setup.sh

# Vendored cherry-picks on top of the SDK we just installed. Selective
# by ROCM_VERSION (only 7.2.0 / 7.2.1 currently need a fix; every other
# release is a no-op exit 43). The .patch files under
# rocm/sources/rocm-patches/ are read at build time; rocm_patches.sh
# probes both /tmp/rocm/sources/rocm-patches and the repo-relative
# layout, so this COPY pair is sufficient. Layout matters: the .sh and
# the sources/ dir must end up siblings under /tmp/rocm/ so the script
# can find the bundle without --patch-source-dir.
COPY rocm/scripts/rocm_patches.sh    /tmp/rocm/rocm_patches.sh
COPY rocm/sources/rocm-patches       /tmp/rocm/sources/rocm-patches
# rocm_patches.sh exit codes:
#   0  -- vendored fix applied (currently only ROCm 7.2.0 / 7.2.1)
#   43 -- NOOP_RC: this ROCm release has no vendored fix; treat as success
#         so the image build does not fail for unaffected releases.
#   *  -- real error
RUN  /tmp/rocm/rocm_patches.sh --rocm-version ${ROCM_VERSION} ; rc=$? ; \
     if [ "$rc" -ne 0 ] && [ "$rc" -ne 43 ]; then exit "$rc"; fi ; \
     rm -f /tmp/rocm/rocm_patches.sh ; \
     rm -rf /tmp/rocm/sources/rocm-patches

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
RUN if [[ -z "`getent group render`" ]]; then groupadd render -g 109 && groupadd renderalt -g 110; fi

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
