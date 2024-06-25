#!/bin/bash

: ${ROCM_VERSIONS:="6.0"}
: ${BUILD_PYTORCH:="1"}
: ${BUILD_CUPY:="1"}
: ${BUILD_PYTORCH:="1"}

OMNITRACE_BUILD_FROM_SOURCE=0
PYTHON_VERSIONS="9 10"

reset-last()
{
   last() { echo "Unsupported argument :: ${1}"; }
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
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

ls -l CacheFiles

rocm/sources/scripts/baseospackages_setup.sh

rocm/sources/scripts/lmod_setup.sh

source ~/.bashrc

rocm/sources/scripts/rocm_setup.sh --rocm-version ${ROCM_VERSION}

if [ -z "${AMDGPU_GFXMODEL}" ]; then
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

rocm/sources/scripts/openmpi_setup.sh --rocm-version ${ROCM_VERSION}

rocm/sources/scripts/mvapich2_setup.sh --rocm-version ${ROCM_VERSION}

omnitrace/sources/scripts/miniconda3_setup.sh --rocm-version ${ROCM_VERSION} --python-versions ${PYTHON_VERSIONS}

omnitrace/sources/scripts/omnitrace_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --omnitrace-build-from-source ${OMNITRACE_BUILD_FROM_SOURCE}

omniperf/sources/scripts/grafana_setup.sh

omniperf/sources/scripts/omniperf_setup.sh --rocm-version ${ROCM_VERSION}

training/sources/scripts/compiler_setup.sh

training/sources/scripts/apps_setup_basic.sh

training/sources/scripts/cupy_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-cupy ${BUILD_CUPY} 

training/sources/scripts/pytorch_setup.sh --rocm-version ${ROCM_VERSION} --amdgpu-gfxmodel ${AMDGPU_GFXMODEL} --build-pytorch ${BUILD_PYTORCH}

training/sources/scripts/apps_setup.sh
