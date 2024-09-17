# -----------------------------------------------------------------------
# NOTE:
# Dependencies are not included as part of Omniperf.
# It's the user's responsibility to accept any licensing implications 
# before building the project
# -----------------------------------------------------------------------

ARG BUILD_DATE
ARG BUILD_VERSION
ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG DOCKER_USER

# This image will be built on top of the image below
# which is the omniperf image built before this one
FROM ${DOCKER_USER}/tools:release-base-ubuntu-${DISTRO_VERSION}-rocm-${ROCM_VERSION}
ARG DISTRO
ARG DISTRO_VERSION
ARG ROCM_VERSION
ARG ADMIN_USERNAME
ARG ADMIN_PASSWORD
ARG BUILD_GCC_LATEST
ARG BUILD_AOMP_LATEST
ARG BUILD_LLVM_LATEST
ARG BUILD_OG_LATEST
ARG BUILD_CLACC_LATEST
ARG BUILD_PYTORCH
ARG BUILD_CUPY
ARG BUILD_KOKKOS
ARG USE_CACHED_APPS
ARG AMDGPU_GFXMODEL=gfx90a
ARG PYTHON_VERSIONS

LABEL maintainer="bob.robey@amd.com"


LABEL org.label-schema.build-date=$BUILD_DATE
LABEL org.label-schema.description="AMD ROCm Training container"
LABEL org.label-schema.vendor="AMD"
LABEL org.label-schema.version=$BUILD_VERSION
# LABEL org.label-schema.docker.cmd="docker run -v ... "

ARG OG_BUILD_DATE
 
ENV DEBIAN_FRONTEND noninteractive
ENV TZ "US/Chicago"

#
# install a few extra things for the extras classes 
# for og13 -- libgmp-dev libmpfr-dev
#
RUN apt-get update && \
    apt-get install -y  hwloc numactl libnuma-dev  libpci-dev \
    lshw emacs htop pandoc ffmpeg cgdb && \
    apt-get install -y --no-install-recommends gedit dos2unix && \
    apt-get install -qy libgmp-dev libmpfr-dev liblzma-dev libbabeltrace-dev

#
# some  networking tools, including the OpenSSH server 
#
RUN apt-get install -y  net-tools iproute2 openssh-server iputils-ping && \
    systemctl enable ssh && service ssh start

EXPOSE 22

#
# Install miniconda
#
COPY extras/sources/scripts/miniconda3_setup.sh /tmp/miniconda3_setup.sh

RUN /tmp/miniconda3_setup.sh \
        --rocm-version ${ROCM_VERSION} \
        --python-versions "${PYTHON_VERSIONS}" && \
    rm -f /tmp/miniconda3_setup.sh

#
# Install our desired compilers
#
COPY extras/sources/scripts/compiler_setup.sh /tmp/compiler_setup.sh

RUN /tmp/compiler_setup.sh && \
    rm /tmp/compiler_setup.sh

# Build the latest AMD OpenMP compiler if requested -- moved to aomp_setup.sh
#RUN apt-get update && apt-get install -y gawk ninja-build generate-ninja ccache
#RUN pip3 install CppHeaderParser

# Build the latest GCC for AMD compiler if requested
COPY extras/sources/scripts/amd_gcc_setup.sh /tmp/amd_gcc_setup.sh
RUN /tmp/amd_gcc_setup.sh --build-gcc-latest ${BUILD_GCC_LATEST} --rocm-version ${ROCM_VERSION} && \
    rm /tmp/amd_gcc_setup.sh

# install aomp
COPY extras/sources/scripts/aomp_setup.sh /tmp/aomp_setup.sh
RUN /tmp/aomp_setup.sh --build-aomp-latest ${BUILD_AOMP_LATEST} --rocm-version ${ROCM_VERSION} && rm /tmp/aomp_setup.sh
 
RUN echo "At end of aomp install" && cd /app && ls -l && cd /tmp && ls -l && cd && ls -l

# install latest llvm
COPY extras/sources/scripts/llvm-build.sh /tmp/llvm-build.sh
RUN /tmp/llvm-build.sh --build-llvm-latest ${BUILD_LLVM_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/llvm-build.sh
 
# Grab any cache files of compiler builds

# Build the clacc_clang compiler
COPY extras/sources/scripts/clacc_setup.sh /tmp/clacc_setup.sh
RUN /tmp/clacc_setup.sh --build-clacc-latest ${BUILD_CLACC_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/clacc_setup.sh

# Install the OpenMP GCC compiler latest drop
COPY extras/sources/scripts/og_setup.sh /tmp/og_setup.sh
RUN /tmp/og_setup.sh --build-og-latest ${BUILD_OG_LATEST} --rocm-version ${ROCM_VERSION} && rm /tmp/og_setup.sh

WORKDIR /tmp 

#
# Install kokkos
#
COPY extras/sources/scripts/kokkos_setup.sh /tmp/kokkos_setup.sh

RUN /tmp/kokkos_setup.sh --rocm-version ${ROCM_VERSION} --build-kokkos ${BUILD_KOKKOS} && rm /tmp/kokkos_setup.sh

#
# Moved into scripts that need these
# Install any additional apps or libs that are needed 
#
#COPY extras/sources/scripts/apps_setup_basic.sh /tmp/apps_setup_basic.sh
#
#RUN  chmod u+x /tmp/apps_setup_basic.sh && \
#     /tmp/apps_setup_basic.sh; rm /tmp/apps_setup_basic.sh

#
# Install cupy 
#
COPY extras/sources/scripts/cupy_setup.sh /tmp/cupy_setup.sh

RUN /tmp/cupy_setup.sh --build-cupy ${BUILD_CUPY} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/cupy_setup.sh

WORKDIR /app 

#
# Install pytorch
#

COPY extras/sources/scripts/pytorch_setup.sh /tmp/pytorch_setup.sh
COPY extras/sources/scripts/pytorch_build_triton_wheel_py.patch /tmp/pytorch_build_triton_wheel_py.patch

RUN /tmp/pytorch_setup.sh --build-pytorch ${BUILD_PYTORCH} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} |& tee /app/pytorch_build.out && rm /tmp/pytorch_setup.sh

RUN echo "At end of pytorch install" && cd /app && ls -l && cd /tmp && ls -l && cd && ls -l
WORKDIR /app

#
# Install any additional apps or libs that are needed 
#
COPY extras/sources/scripts/apps_setup.sh /tmp/apps_setup.sh

RUN  chmod u+x /tmp/apps_setup.sh && \
     /tmp/apps_setup.sh; rm /tmp/apps_setup.sh

RUN echo "At end of apps setup install" && cd /app && ls -l && cd /tmp && ls -l && cd && ls -l

#
# create a default .bashrc  (based on Ubuntu 22 /etc/skel/.bashrc )
#
RUN mkdir -p /users/default
COPY extras/sources/skel/bashrc /users/default/.bashrc
COPY extras/sources/skel/setTmpDir.sh  /users/default/setTmpDir.sh
RUN  chmod a+x /users/default/.bashrc && chmod a+x /users/default/setTmpDir.sh

# TODO:
# For Plexus, we need to put a home directory for the user on 
# /datasets/teams/hackathon-testing
#
# and then fix up .bashrc to cd to the new home directory

#
# add some default userids 
#
# add a user with sudo auth
RUN useradd --create-home --skel /users/default --shell /bin/bash --home /users/${ADMIN_USERNAME} --password ${ADMIN_PASSWORD} --uid 11000 ${ADMIN_USERNAME}
RUN  echo "${ADMIN_USERNAME}:${ADMIN_PASSWORD}" | chpasswd
# add groups for access to the GPU (see /dev/dri /dev/kfd)
RUN usermod -a -G audio,video,render,renderalt ${ADMIN_USERNAME} \
    && usermod -a -G sudo  ${ADMIN_USERNAME}


# add some users 
#COPY ./sources/scripts/add_users.sh /tmp/add_users.sh
#RUN  chmod u+x /tmp/add_users.sh  \
#     && /tmp/add_users.sh  \
#     && rm -f /tmp/add_users.sh 

# add the management script (use by the ${ADMIN_USERNAME}) 
COPY extras/manage /users/${ADMIN_USERNAME}/
#RUN ls -lsa /users/${ADMIN_USERNAME}/
RUN chown -R ${ADMIN_USERNAME} /users/${ADMIN_USERNAME}/bin && chmod -R a-rwx /users/${ADMIN_USERNAME}/bin && \
    chmod -R u+rx /users/${ADMIN_USERNAME}/bin && chmod -R u-w /users/${ADMIN_USERNAME}/bin && \
    echo "PATH=/users/${ADMIN_USERNAME}/bin:${PATH}" >> /users/${ADMIN_USERNAME}/.bash_profile

RUN mkdir /Shared && chown ${ADMIN_USERNAME} /Shared && chmod 770 /Shared

RUN sed --in-place=.bak \
   '/#ADD_EXTRA_GROUPS=1/s/#ADD_EXTRA_GROUPS=1/EXTRA_GROUPS=audio video render renderalt\nADD_EXTRA_GROUPS=1\n/' \
   /etc/adduser.conf

#
# the external init.sh script can be used for run time initialization.
# we will start the openssh server via init.sh.
#

COPY extras/init.sh /root/init.sh

RUN  chmod a+rx /root/init.sh

# CMD ["/usr/sbin/sshd","-D"]

CMD ["/root/init.sh"]
