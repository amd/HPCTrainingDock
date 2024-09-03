#!/bin/bash

: ${ROCM_VERSIONS:="6.0"}
: ${ROCM_INSTALLPATH:="/opt/"}
: ${BUILD_PYTORCH:="1"}
: ${BUILD_CUPY:="1"}
: ${BUILD_JAX:="1"}
: ${BUILD_KOKKOS:="1"}
: ${BUILD_HPCTOOLKIT:="1"}
: ${BUILD_MPI4PY:="1"}
: ${BUILD_TAU:="1"}
: ${USE_MAKEFILE:="0"}

OMNITRACE_BUILD_FROM_SOURCE=0
PYTHON_VERSIONS="9 10"
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

reset-last()
{
   last() { echo "Unsupported argument :: ${1}"; }
}

usage()
{
   echo "--rocm-version [ ROCM_VERSIONS ]:  default is $ROCM_VERSIONS"
   echo "--rocm-install-path [ ROCM_INSTALL_PATH ]:  default is $ROCM_INSTALLPATH"
   echo "--python-versions [ PYTHON_VERSIONS ]: default is $PYTHON_VERSIONS"
   echo "--amdgpu-gfxmodel [ AMDGPU_GFXMODEL ]: no default but rocminfo is used to assign a value to it, if a value is not provided" 
   echo "--omnitrace-build-from-source [0 or 1]:  default is 0 (false)"
   echo "--use-makefile [0 or 1]:  default is 0 (false)"
   echo "--help: prints this message"
   exit 1
}

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--rocm-install-path")
          shift
          ROCM_INSTALLPATH=${1}
          reset-last
          ;;
      "--python-versions")
          shift
          PYTHON_VERSIONS=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--omnitrace-build-from-source")
          shift
          OMNITRACE_BUILD_FROM_SOURCE=${1}
          reset-last
          ;;
      "--use-makefile")
          shift
          USE_MAKEFILE=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

if [ -z "${AMDGPU_GFXMODEL}" ]; then
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

# Not available until docker run command
#ls -l /CacheFiles
#${SUDO} chmod a+w /CacheFiles/
#${SUDO} mkdir /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/
#${SUDO} chmod a+w /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/

if [ "${USE_MAKEFILE}" == 1 ]; then
   exit
fi


rocm/sources/scripts/baseospackages_setup.sh

rocm/sources/scripts/lmod_setup.sh

source ~/.bashrc

rocm/sources/scripts/rocm_setup.sh --rocm-version ${ROCM_VERSION}

rocm/sources/scripts/rocm_omnitrace_setup.sh --rocm-version ${ROCM_VERSION}

rocm/sources/scripts/rocm_omniperf_setup.sh --rocm-version ${ROCM_VERSION}

comm/sources/scripts/openmpi_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}

comm/sources/scripts/mpi4py_setup.sh --rocm-version ${ROCM_VERSION} --build-mpi4py ${BUILD_MPI4PY}

comm/sources/scripts/mvapich_setup.sh --rocm-version ${ROCM_VERSION}

tools/sources/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --python-versions ${PYTHON_VERSIONS}

tools/sources/scripts/omnitrace_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}

tools/sources/scripts/grafana_setup.sh

tools/sources/scripts/omniperf_setup.sh --rocm-version ${ROCM_VERSION}

tools/sources/scripts/hpctoolkit_setup.sh --rocm-version ${ROCM_VERSION} --build-hpctoolkit ${BUILD_HPCTOOLKIT}

tools/sources/scripts/tau_setup.sh --rocm-version ${ROCM_VERSION} --build-hpctoolkit ${BUILD_TAU}

extras/sources/scripts/compiler_setup.sh

extras/sources/scripts/apps_setup_basic.sh

extras/sources/scripts/cupy_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-cupy ${BUILD_CUPY} 

extras/sources/scripts/jax_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-jax ${BUILD_JAX} 

extras/sources/scripts/pytorch_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-pytorch ${BUILD_PYTORCH}

extras/sources/scripts/apps_setup.sh

extras/sources/scripts/kokkos_setup.sh --rocm-version ${ROCM_VERSION} --build-kokkos ${BUILD_KOKKOS}

#If ROCm should be installed in a different location
if [ "${ROCM_INSTALLPATH}" != "/opt/" ]; then
   ${SUDO} mv /opt/rocm-${ROCM_VERSION}/ ${ROCM_INSTALLPATH}
   ${SUDO} ln -sfn ${ROCM_INSTALLPATH}/rocm-${ROCM_VERSION} /etc/alternatives/rocm
   ${SUDO} sed -i "s|\/opt\/|${ROCM_INSTALLPATH}|" /etc/lmod/modules/ROCm/*/*.lua
fi

git clone https://github.com/AMD/HPCTrainingExamples.git
