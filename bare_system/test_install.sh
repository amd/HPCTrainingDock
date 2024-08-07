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
   echo "--rocm-version [ ROCM_VERSION ]:  default is $ROCM_VERSION"
   echo "--rocm-install-path [ ROCM_INSTALL_PATH ]:  default is $ROCM_INSTALLPATH"
   echo "--python-versions [ PYTHON_VERSIONS ]: default is $PYTHON_VERSIONS"
   echo "--amdgpu-gfxmodel [ AMDGPU_GFXMODEL ]: auto detected using rocminfo"
   echo "--distro [DISTRO]: auto detected by looking into /etc/os-release "
   echo "--distro-version [DISTRO_VERSION]: auto detected by looking into /etc/os-release "
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
      "--distro-version")
          shift
          DISTRO_VERSION=${1}
          last() { DISTRO_VERSION="${DISTRO_VERSION} ${1}"; }
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


CACHE_FILES="CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}"
if [ ! -d ${CACHE_FILES} ]; then
   mkdir -p ${CACHE_FILES}
fi

set -v

ADD_OPTIONS=""
PODMAN_DETECT=`docker |& grep "Emulate Docker CLI using podman" | wc -l`
if [[ "${PODMAN_DETECT}" -ge "1" ]]; then
   ADD_OPTIONS="${ADD_OPTIONS} --format docker"
fi

docker build --no-cache ${ADD_OPTIONS} \
             --build-arg DISTRO=${DISTRO}  \
             --build-arg DISTRO_VERSION=${DISTRO_VERSION} \
             --build-arg ROCM_VERSION=${ROCM_VERSION} \
             --build-arg ROCM_INSTALLPATH=${ROCM_INSTALLPATH} \
             --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
             --build-arg USE_MAKEFILE=${USE_MAKEFILE} \
             -t bare -f bare_system/Dockerfile .

ADD_OPTIONS=""

if [[ "${DISTRO}" == "ubuntu" ]]; then
   ADD_OPTIONS="${ADD_OPTIONS} --group-add renderalt"
fi
if [[ "${DISTRO}" == "rocky linux" ]]; then
   ADD_OPTIONS="${ADD_OPTIONS} --group-add renderalt"
fi


NAMEBASE=Bare
NAME=$NAMEBASE
NUMBER=0
while [ `docker inspect --format='{{.Name}}' $NAME |& grep /$NAME | wc -l` != "0" ]; do
   NUMBER=$((NUMBER+1))
   NAME=$NAMEBASE$NUMBER
done
PORT_NUMBER=2222
while [ `docker ps | grep -w "${PORT_NUMBER}" | wc -l` != "0" ]; do
   PORT_NUMBER=$((PORT_NUMBER+1))
done

echo "NAME is ${NAME}"
echo "PORT_NUMBER is ${PORT_NUMBER}"

docker run -it --device=/dev/kfd --device=/dev/dri \
    --group-add video --group-add render ${ADD_OPTIONS} \
    -p ${PORT_NUMBER}:22 --name ${NAME}  --security-opt seccomp=unconfined \
    --rm -v $PWD/CacheFiles:/CacheFiles bare
