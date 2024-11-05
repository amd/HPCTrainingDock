#!/bin/bash

: ${ROCM_VERSION:="6.0"}
: ${ROCM_INSTALLPATH:="/opt/"}
: ${BUILD_PYTORCH:="1"}
: ${BUILD_CUPY:="1"}
: ${BUILD_JAX:="1"}
: ${BUILD_SCOREP:="1"}
: ${BUILD_KOKKOS:="1"}
: ${BUILD_HIPFORT:="1"}
: ${BUILD_HDF5:="1"}
: ${BUILD_MINICONDA3:="1"}
: ${BUILD_MINIFORGE3:="1"}
: ${BUILD_HPCTOOLKIT:="1"}
: ${BUILD_MPI4PY:="1"}
: ${BUILD_TAU:="1"}
: ${BUILD_X11VNC:="1"}
: ${PYTHON_VERSION:="10"} # python3 minor release
: ${USE_MAKEFILE:="0"}

OMNITRACE_BUILD_FROM_SOURCE=0
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [[ "${DISTRO}" == "ubuntu" ]]; then
   if [[ "${DISTRO_VERSION}" == "24.04" ]]; then
      PYTHON_VERSION="12"
   fi
fi

reset-last()
{
   last() { echo "Unsupported argument :: ${1}"; }
}

usage()
{
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ]:  default is $ROCM_VERSION"
   echo "  --rocm-install-path [ ROCM_INSTALL_PATH ]:  default is $ROCM_INSTALLPATH"
   echo "  --python-version [ PYTHON_VERSION ]: python3 minor release, default is $PYTHON_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ]: if not provided, rocminfo is used to assign a value" 
   echo "  --omnitrace-build-from-source [0 or 1]:  default is 0 (false)"
   echo "  --distro [DISTRO: ubuntu|rockylinux|opensuse/leap]: autodetected by looking into /etc/os-release"
   echo "  --distro-versions [DISTRO_VERSION]: autodetected by looking into /etc/os-release"
   echo "  --use-makefile [0 or 1]:  default is 0 (false)"
   echo "  --help: prints this message"
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
      "--python-version")
          shift
          PYTHON_VERSION=${1}
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


rocm/scripts/baseospackages_setup.sh

rocm/scripts/lmod_setup.sh

source ~/.bashrc

rocm/scripts/rocm_setup.sh --rocm-version ${ROCM_VERSION}

rocm/scripts/rocm_omnitrace_setup.sh --rocm-version ${ROCM_VERSION}

rocm/scripts/rocm_omniperf_setup.sh --rocm-version ${ROCM_VERSION}

comm/scripts/openmpi_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL}

comm/scripts/mpi4py_setup.sh --rocm-version ${ROCM_VERSION} --build-mpi4py ${BUILD_MPI4PY}

comm/scripts/mvapich_setup.sh --rocm-version ${ROCM_VERSION}

tools/scripts/omnitrace_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}

tools/scripts/grafana_setup.sh

tools/scripts/omniperf_setup.sh --rocm-version ${ROCM_VERSION}

tools/scripts/hpctoolkit_setup.sh --rocm-version ${ROCM_VERSION} --build-hpctoolkit ${BUILD_HPCTOOLKIT}

tools/scripts/scorep_setup.sh --rocm-version ${ROCM_VERSION} --build-scorep ${BUILD_SCOREP}

tools/scripts/tau_setup.sh --rocm-version ${ROCM_VERSION} --build-tau ${BUILD_TAU}

extras/scripts/compiler_setup.sh

extras/scripts/apps_setup_basic.sh

extras/scripts/cupy_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-cupy ${BUILD_CUPY} 

extras/scripts/jax_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-jax ${BUILD_JAX} 

extras/scripts/pytorch_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-pytorch ${BUILD_PYTORCH}

extras/scripts/apps_setup.sh

extras/scripts/kokkos_setup.sh --rocm-version ${ROCM_VERSION} --build-kokkos ${BUILD_KOKKOS}

extras/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniconda3 ${BUILD_MINICONDA3} --python-version ${PYTHON_VERSION}

extras/scripts/miniforge3_setup.sh --rocm-version ${ROCM_VERSION} --build-miniforge3 ${BUILD_MINIFORGE3}

extras/scripts/x11vnc_setup.sh --build-x11vnc ${BUILD_X11VNC}

extras/scripts/hipfort_setup.sh --build-x11vnc ${BUILD_HIPFORT}

extras/scripts/hdf5_setup.sh --build-x11vnc ${BUILD_HDF5}

#If ROCm should be installed in a different location
if [ "${ROCM_INSTALLPATH}" != "/opt/" ]; then
   ${SUDO} mv /opt/rocm-${ROCM_VERSION} ${ROCM_INSTALLPATH}
   ${SUDO} mv /opt/rocmplus-${ROCM_VERSION} ${ROCM_INSTALLPATH}
   ${SUDO} ln -sfn ${ROCM_INSTALLPATH}/rocm-${ROCM_VERSION} /etc/alternatives/rocm
   ${SUDO} sed -i "s|\/opt\/|${ROCM_INSTALLPATH}|" /etc/lmod/modules/ROCm/*/*.lua
fi

git clone https://github.com/AMD/HPCTrainingExamples.git
