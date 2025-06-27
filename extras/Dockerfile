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
ARG BUILD_TENSORFLOW
ARG BUILD_FTORCH
ARG BUILD_JULIA
ARG BUILD_PETSC
ARG BUILD_HYPRE
ARG BUILD_KOKKOS
ARG BUILD_MINIFORGE3
ARG BUILD_MINICONDA3
ARG BUILD_HDF5
ARG BUILD_NETCDF
ARG BUILD_ADIOS2
ARG BUILD_JAX
ARG BUILD_X11VNC
ARG BUILD_HIPFORT
ARG BUILD_FFTW
ARG HIPIFLY_MODULE
ARG BUILD_OLLAMA=1
ARG USE_CACHED_APPS
ARG AMDGPU_GFXMODEL=gfx90a
ARG PYTHON_VERSION

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
# some  networking tools, including the OpenSSH server
#
COPY extras/scripts/sshd_setup.sh /tmp/sshd_setup.sh
RUN  /tmp/sshd_setup.sh && rm /tmp/sshd_setup.sh

EXPOSE 22

COPY extras/scripts /tmp/extras

WORKDIR /tmp

RUN /tmp/extras/miniconda3_setup.sh \
        --rocm-version ${ROCM_VERSION} \
        --python-version ${PYTHON_VERSION} \
        --build-miniconda3 ${BUILD_MINICONDA3} && \
   /tmp/extras/miniforge3_setup.sh \
        --rocm-version ${ROCM_VERSION} \
        --build-miniforge3 ${BUILD_MINICONDA3} && \
   /tmp/extras/compiler_setup.sh && \
   /tmp/extras/amd_gcc_setup.sh --build-gcc-latest ${BUILD_GCC_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/aomp_setup.sh --build-aomp-latest ${BUILD_AOMP_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}  |& tee /app/aomp_build.out && \
   /tmp/extras/hipfort_setup.sh --build-hipfort ${BUILD_HIPFORT} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/hipifly_setup.sh --hipifly-module ${HIPIFLY_MODULE} --rocm-version ${ROCM_VERSION} && \
   /tmp/extras/fftw_setup.sh --build-fftw ${BUILD_FFTW} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/llvm-build.sh --build-llvm-latest ${BUILD_LLVM_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/clacc_setup.sh --build-clacc-latest ${BUILD_CLACC_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/kokkos_setup.sh --rocm-version ${ROCM_VERSION} --build-kokkos ${BUILD_KOKKOS} \\
   /tmp/extras/hdf5_setup.sh --rocm-version ${ROCM_VERSION} --build-hdf5 ${BUILD_HDF5} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/netcdf_setup.sh --rocm-version ${ROCM_VERSION} --build-netcdf ${BUILD_NETCDF} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/adios2_setup.sh --rocm-version ${ROCM_VERSION} --build-adios2 ${BUILD_ADIOS2} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/cupy_setup.sh --build-cupy ${BUILD_CUPY} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/tensorflow_setup.sh --build-tensorflow ${BUILD_TENSORFLOW} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/ftorch_setup.sh --build-ftorch ${BUILD_FTORCH} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/julia_setup.sh --build-julia ${BUILD_JULIA}  && \
   /tmp/extras/jax_setup.sh --build-jax ${BUILD_JAX} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/petsc_setup.sh --build-petsc ${BUILD_PETSC} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/hypre_setup.sh --build-hypre ${BUILD_HYPRE} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
   /tmp/extras/pytorch_setup.sh --build-pytorch ${BUILD_PYTORCH} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --python-version ${PYTHON_VERSION} |& tee /app/pytorch_build.out && \
   /tmp/extras/ollama_setup.sh --build-ollama ${BUILD_OLLAMA} && \
   chmod u+x /tmp/extras/apps_setup.sh && \
   /tmp/extras/apps_setup.sh && \
   rm -rf /tmp/extras


RUN echo "At end of packages install, now doing VNC" && cd /app && ls -l && cd /tmp && ls -l && cd && ls -l

WORKDIR /app

#
# Install VNC
#
ADD extras/image/etc  /etc
ADD extras/image/usr  /usr
ADD extras/image/home /users/default
EXPOSE 5900-5920
EXPOSE 6080
COPY extras/scripts/x11vnc_setup.sh /tmp/x11vnc_setup.sh

RUN  chmod u+x /tmp/x11vnc_setup.sh && \
     /tmp/x11vnc_setup.sh --build-x11vnc ${BUILD_X11VNC} ; rm /tmp/x11vnc_setup.sh

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
#COPY ./scripts/add_users.sh /tmp/add_users.sh
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
