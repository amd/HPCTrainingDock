#!/bin/bash

: ${ROCM_VERSION:="6.0"}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
            shift
            AMDGPU_GFXMODEL=${1}
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

set -v

docker build --no-cache --build-arg DISTRO=${DISTRO}  \
             --build-arg DISTRO_VERSION=${DISTRO_VERSION} \
             --build-arg ROCM_VERSION=${ROCM_VERSION} \
             --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
             -t bare -f bare_system/Dockerfile .

docker run -it --device=/dev/kfd --device=/dev/dri \
           --group-add video --group-add render --group-add renderalt \
	   -p 2222:22 --name BareGiacomo  --security-opt seccomp=unconfined \
	   --rm -v /home/bobrobey/Class/training/hostdir:/hostdir bare
