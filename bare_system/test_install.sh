#!/bin/bash

: ${ROCM_VERSION:="6.4.1"}
: ${ROCM_INSTALLPATH:="/opt/"}
: ${USE_MAKEFILE:="0"}
: ${PYTHON_VERSION:="12"}
: ${IMAGE_NAME:="bare"}
: ${DISTRO:="ubuntu"}
: ${DISTRO_VERSION:="24.04"}

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

usage()
{
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ]:  default is $ROCM_VERSION"
   echo "  --rocm-install-path [ ROCM_INSTALL_PATH ]:  default is $ROCM_INSTALLPATH"
   echo "  --python-version [ PYTHON_VERSION ]: python3 minor release, default is $PYTHON_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ]: autodetected using rocminfo"
   echo "  --distro [DISTRO: ubuntu|rockylinux|opensuse/leap]: autodetected by looking into /etc/os-release"
   echo "  --distro-versions [DISTRO_VERSION]: autodetected by looking into /etc/os-release"
   echo "  Including alternate version --distro-version to avoid errors"
   echo "  --distro-version [DISTRO_VERSION]: autodetected by looking into /etc/os-release"
   echo "  --image-name [IMAGE_NAME]: Docker image name, default is $IMAGE_NAME"
   echo "  --use-makefile [0 or 1]: default 0 "
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--python-version")
          shift
          PYTHON_VERSION_INPUT=${1}
          reset-last
          ;;
      "--distro")
          shift
          DISTRO=${1}
          reset-last
          ;;
      "--distro-versions")
          shift
          DISTRO_VERSION=${1}
          reset-last
          ;;
      # alternate version
      "--distro-version")
          shift
          DISTRO_VERSION=${1}
          reset-last
          ;;
      "--image-name")
          shift
          IMAGE_NAME=${1}
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

if [[ "${PYTHON_VERSION_INPUT}" == "" ]]; then
   if [[ "${DISTRO}" == "ubuntu" ]]; then
      if [[ "${DISTRO_VERSION}" == "24.04" ]]; then
         PYTHON_VERSION="12"
      fi
      if [[ "${DISTRO_VERSION}" == "22.04" ]]; then
         PYTHON_VERSION="10"
      fi
   fi
else
   PYTHON_VERSION=${PYTHON_VERSION_INPUT}
fi


CACHE_FILES="CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}"
if [[ ! -d ${CACHE_FILES} ]]; then
   mkdir -p ${CACHE_FILES}
fi

set -v

ADD_OPTIONS=""
echo "Using Docker as default, falling back to Podman if Docker is not installed"
if command -v docker >/dev/null 2>&1; then
    BUILDER=docker
elif command -v podman >/dev/null 2>&1; then
    BUILDER=podman
else
    echo "ERROR: neither Podman nor Docker found"
    exit 1
fi

if [[ "$BUILDER" == "podman" ]]; then
    ADD_OPTIONS="${ADD_OPTIONS} --format docker"
fi

if [[ "${DISTRO}" == *"rocky"* ]]; then
   DISTRO="rockylinux/rockylinux"
fi

docker build --no-cache ${ADD_OPTIONS} \
             --build-arg DISTRO=${DISTRO}  \
             --build-arg DISTRO_VERSION=${DISTRO_VERSION} \
             --build-arg ROCM_VERSION=${ROCM_VERSION} \
             --build-arg ROCM_INSTALLPATH=${ROCM_INSTALLPATH} \
             --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
             --build-arg USE_MAKEFILE=${USE_MAKEFILE} \
	     --build-arg PYTHON_VERSION=${PYTHON_VERSION} \
             -t ${IMAGE_NAME} \
	     -f bare_system/Dockerfile .

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to build Docker image, you might need to manually specify the '--distro' and '--distro-versions'."
    exit 1
fi

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" == *"rocky"* || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

ADD_OPTIONS=""

if [[ "${DISTRO}" == "ubuntu" ]]; then
   ADD_OPTIONS="${ADD_OPTIONS} --group-add renderalt"
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
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
    --rm -v $PWD/CacheFiles:/CacheFiles ${IMAGE_NAME}
