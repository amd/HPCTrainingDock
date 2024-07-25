#!/bin/bash

: ${ROCM_VERSION:="6.0"}
: ${ROCM_INSTALLPATH:="/opt/"}
: ${USE_MAKEFILE:="0"}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

usage()
{
   echo "--rocm-version [ ROCM_VERSIONS ]:  default is $ROCM_VERSION"
   echo "--rocm-install-path [ ROCM_INSTALL_PATH ]:  default is $ROCM_INSTALLPATH"
   echo "--python-versions [ PYTHON_VERSIONS ]: default is $PYTHON_VERSIONS"
   echo "--amdgpu-gfxmodel [ AMDGPU_GFXMODEL ]: auto detected using rocminfo"
   echo "--distro [DISTRO]: auto detected by looking into /etc/os-release "
   echo "--distro-versions [DISTRO_VERSIONS]: auto detected by looking into /etc/os-release "
   echo "--use-makefile [0 or 1]: default 0 "
   echo "--help: prints this message"
   exit 1
}

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

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
      "--amdgpu-gfxmodel")
            shift
            AMDGPU_GFXMODEL=${1}
            reset-last
            ;;
      "--distro")
          shift
          DISTRO=${1}
          last() { DISTRO="${DISTRO} ${1}"; }
          ;;
      "--distro-versions")
          shift
          DISTRO_VERSION=${1}
          last() { DISTRO_VERSION="${DISTRO_VERSION} ${1}"; }
          ;;
      "--use-makefile")
          shift
          USE_MAKEFILE=1
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


CACHE_FILES="CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}"
if [ ! -d ${CACHE_FILES} ]; then
   mkdir -p ${CACHE_FILES}
   touch ${CACHE_FILES}/test.tgz
fi

set -v

docker build --no-cache --build-arg DISTRO=${DISTRO}  \
             --build-arg DISTRO_VERSION=${DISTRO_VERSION} \
             --build-arg ROCM_VERSION=${ROCM_VERSION} \
             --build-arg ROCM_INSTALLPATH=${ROCM_INSTALLPATH} \
             --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
             --build-arg USE_MAKEFILE=${USE_MAKEFILE} \
             -t bare -f bare_system/Dockerfile .

docker run -it --device=/dev/kfd --device=/dev/dri \
           --group-add video --group-add render --group-add renderalt \
	   -p 2222:22 --name Bare  --security-opt seccomp=unconfined \
	   --rm -v $HOME/Class/training/hostdir:/hostdir bare
