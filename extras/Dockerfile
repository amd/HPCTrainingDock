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

#
# Install miniconda3
#
COPY extras/scripts/miniconda3_setup.sh /tmp/miniconda3_setup.sh

RUN /tmp/miniconda3_setup.sh \
        --rocm-version ${ROCM_VERSION} \
        --python-version ${PYTHON_VERSION} \
        --build-miniconda3 ${BUILD_MINICONDA3} && \
    rm -f /tmp/miniconda3_setup.sh

#
# Install miniforge3
#
COPY extras/scripts/miniforge3_setup.sh /tmp/miniforge3_setup.sh

RUN /tmp/miniforge3_setup.sh \
        --rocm-version ${ROCM_VERSION} \
        --build-miniforge3 ${BUILD_MINICONDA3} && \
    rm -f /tmp/miniforge3_setup.sh

#
# Install our desired compilers
#
COPY extras/scripts/compiler_setup.sh /tmp/compiler_setup.sh

RUN /tmp/compiler_setup.sh && \
    rm /tmp/compiler_setup.sh

# Build the latest AMD OpenMP compiler if requested -- moved to aomp_setup.sh
#RUN apt-get update && apt-get install -y gawk ninja-build generate-ninja ccache
#RUN pip3 install CppHeaderParser

# Build the latest GCC for AMD compiler if requested
COPY extras/scripts/amd_gcc_setup.sh /tmp/amd_gcc_setup.sh
RUN /tmp/amd_gcc_setup.sh --build-gcc-latest ${BUILD_GCC_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && \
    rm /tmp/amd_gcc_setup.sh

# install aomp
COPY extras/scripts/aomp_setup.sh /tmp/aomp_setup.sh
RUN /tmp/aomp_setup.sh --build-aomp-latest ${BUILD_AOMP_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}  |& tee /app/aomp_build.out && rm /tmp/aomp_setup.sh

# install hipfort
COPY extras/scripts/hipfort_setup.sh /tmp/hipfort_setup.sh
RUN /tmp/hipfort_setup.sh --build-hipfort ${BUILD_HIPFORT} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/hipfort_setup.sh

# create hipifly module
COPY extras/scripts/hipifly_setup.sh /tmp/hipifly_setup.sh
COPY extras/sources/hipifly/hipifly.h /tmp/hipifly.h
RUN /tmp/hipifly_setup.sh --hipifly-module ${HIPIFLY_MODULE} --rocm-version ${ROCM_VERSION} --hipifly-header-path /tmp/ && rm /tmp/hipifly*

# install fftw
COPY extras/scripts/fftw_setup.sh /tmp/fftw_setup.sh
RUN /tmp/fftw_setup.sh --build-fftw ${BUILD_FFTW} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/fftw_setup.sh

# install latest llvm
COPY extras/scripts/llvm-build.sh /tmp/llvm-build.sh
RUN /tmp/llvm-build.sh --build-llvm-latest ${BUILD_LLVM_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/llvm-build.sh

# Grab any cache files of compiler builds

# Build the clacc_clang compiler
COPY extras/scripts/clacc_setup.sh /tmp/clacc_setup.sh
RUN /tmp/clacc_setup.sh --build-clacc-latest ${BUILD_CLACC_LATEST} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/clacc_setup.sh

WORKDIR /tmp

#
# Install kokkos
#
COPY extras/scripts/kokkos_setup.sh /tmp/kokkos_setup.sh
RUN /tmp/kokkos_setup.sh --rocm-version ${ROCM_VERSION} --build-kokkos ${BUILD_KOKKOS} && rm /tmp/kokkos_setup.sh

#
# Install hdf5
#
COPY extras/scripts/hdf5_setup.sh /tmp/hdf5_setup.sh
RUN /tmp/hdf5_setup.sh --rocm-version ${ROCM_VERSION} --build-hdf5 ${BUILD_HDF5} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/hdf5_setup.sh

# Install netcdf
#
COPY extras/scripts/netcdf_setup.sh /tmp/netcdf_setup.sh
RUN /tmp/netcdf_setup.sh --rocm-version ${ROCM_VERSION} --build-netcdf ${BUILD_NETCDF} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/netcdf_setup.sh

# Install adios2
#
COPY extras/scripts/adios2_setup.sh /tmp/adios2_setup.sh
RUN /tmp/adios2_setup.sh --rocm-version ${ROCM_VERSION} --build-adios2 ${BUILD_ADIOS2} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/adios2_setup.sh

#
<<<<<<< HEAD
# Moved into scripts that need these
# Install any additional apps or libs that are needed
#
#COPY extras/scripts/apps_setup_basic.sh /tmp/apps_setup_basic.sh
#
#RUN  chmod u+x /tmp/apps_setup_basic.sh && \
#     /tmp/apps_setup_basic.sh; rm /tmp/apps_setup_basic.sh

#
# Install cupy
=======
# Install cupy 
>>>>>>> 416b20b (Partial changes for Ubuntu 24.04)
#
COPY extras/scripts/cupy_setup.sh /tmp/cupy_setup.sh

RUN /tmp/cupy_setup.sh --build-cupy ${BUILD_CUPY} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/cupy_setup.sh

WORKDIR /app

# Install tensorflow
#
COPY extras/scripts/tensorflow_setup.sh /tmp/tensorflow_setup.sh

RUN /tmp/tensorflow_setup.sh --build-tensorflow ${BUILD_TENSORFLOW} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/tensorflow_setup.sh

WORKDIR /app

#
# Install jax
#
COPY extras/scripts/jax_setup.sh /tmp/jax_setup.sh

RUN /tmp/jax_setup.sh --build-jax ${BUILD_JAX} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/jax_setup.sh

WORKDIR /app

#
# Install petsc
#
COPY extras/scripts/petsc_setup.sh /tmp/petsc_setup.sh

RUN /tmp/petsc_setup.sh --build-petsc ${BUILD_PETSC} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/petsc_setup.sh

WORKDIR /app

#
# Install hypre
#
COPY extras/scripts/hypre_setup.sh /tmp/hypre_setup.sh

RUN /tmp/hypre_setup.sh --build-hypre ${BUILD_HYPRE} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} && rm /tmp/hypre_setup.sh

WORKDIR /app

#
# Install pytorch
#

COPY extras/scripts/pytorch_setup.sh /tmp/pytorch_setup.sh
COPY extras/scripts/pytorch_build_triton_wheel_py.patch /tmp/pytorch_build_triton_wheel_py.patch

RUN /tmp/pytorch_setup.sh --build-pytorch ${BUILD_PYTORCH} --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --python-version ${PYTHON_VERSION} |& tee /app/pytorch_build.out && rm /tmp/pytorch_setup.sh

RUN echo "At end of pytorch install" && cd /app && ls -l && cd /tmp && ls -l && cd && ls -l
WORKDIR /app

#
# Install ollama
#
COPY extras/scripts/ollama_setup.sh /tmp/ollama_setup.sh

RUN /tmp/ollama_setup.sh --build-ollama ${BUILD_OLLAMA} && rm /tmp/ollama_setup.sh

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
# Install any additional apps or libs that are needed
#
COPY extras/scripts/apps_setup.sh /tmp/apps_setup.sh

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
