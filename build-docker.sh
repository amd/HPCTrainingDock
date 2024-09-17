#!/usr/bin/env bash

: ${DOCKER_USER:=$(whoami)}
: ${ROCM_VERSIONS:="5.0"}
: ${PYTHON_VERSIONS:="10"}
: ${BUILD_CI:=""}
: ${PUSH:=0}
: ${PULL:=--pull}
: ${OUTPUT_VERBOSITY:=""}
: ${BUILD_AOMP_LATEST:="0"}
: ${BUILD_LLVM_LATEST:="0"}
: ${BUILD_GCC_LATEST:="0"}
: ${BUILD_OG_LATEST:="0"}
: ${BUILD_CLACC_LATEST:="0"}
: ${BUILD_PYTORCH:="0"}
: ${BUILD_CUPY:="0"}
: ${BUILD_JAX:="0"}
: ${BUILD_KOKKOS:="0"}
: ${BUILD_TAU:="0"}
: ${BUILD_MPI4PY:="0"}
: ${BUILD_HPCTOOLKIT:="0"}
: ${BUILD_ALL_LATEST:="0"}
: ${RETRY:=3}
: ${NO_CACHE:=""}
: ${OMNITRACE_BUILD_FROM_SOURCE:=0}
: ${ADMIN_USERNAME:="admin"}
: ${ADMIN_PASSWORD:=""}
: ${USE_CACHED_APPS:=0}
: ${AMDGPU_GFXMODEL:=""}
: ${INSTALL_GRAFANA:=0}

tolower()
{
    echo "$@" | awk -F '\\|~\\|' '{print tolower($1)}';
}

toupper()
{
    echo "$@" | awk -F '\\|~\\|' '{print toupper($1)}';
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

verbose-run()
{
    echo -e "\n### Executing \"${@}\"... ###\n"
    eval "${@}"
}

verbose-build()
{
    echo -e "\n### Executing \"${@}\" a maximum of ${RETRY} times... ###\n"
    for i in $(seq 1 1 ${RETRY})
    do
        set +e
        eval "${@}"
        local RETC=$?
        set -e
        if [ "${RETC}" -eq 0 ]; then
            break
        else
            echo -en "\n### Command failed with error code ${RETC}... "
            if [ "${i}" -ne "${RETRY}" ]; then
                echo -e "Retrying... ###\n"
                sleep 3
            else
                echo -e "Exiting... ###\n"
                exit ${RETC}
            fi
        fi
    done
}

reset-last()
{
    last() { send-error "Unsupported argument :: ${1}"; }
}

set -e

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`

usage()
{
    print_option() { printf "    --%-20s %-24s     %s\n" "${1}" "${2}" "${3}"; }
    echo "Options:"
    print_option "help -h" "" "prints this message to terminal"
    echo ""
    print_default_option() { printf "    --%-20s %-24s     %s (default: %s)\n" "${1}" "${2}" "${3}" "$(tolower ${4})"; }
    print_default_option "pull" -- "instructs to not pull down the most recent base container" "--pull"
    print_default_option "admin-username" "[ADMIN_USERNAME]" "container admin username" "${ADMIN_USERNAME}"
    print_default_option admin-password "[ADMIN_PASSWORD]" "container admin password" "not set, needs to be provided as input"
    print_default_option build-openmpi -- "flag to build OpenMPI" "not included"
    print_default_option build-aomp-latest -- "flag to build the latest version of AOMP for offloading" "not included"
    print_default_option build-llvm-latest -- "flag to build the latest version of LLVM for offloading" "not included"
    print_default_option build-gcc-latest -- "flag to build the latest version of gcc with offloading" "not included"
    print_default_option build-og-latest -- "flag to build the latest version of gcc develop with offloading" "not included"
    print_default_option build-clacc-latest -- "flag to build the latest version of clacc with offloading" "not included"
    print_default_option build-pytorch -- "flag to build the latest version of pytorch" "not included"
    print_default_option build-cupy -- "flag to build the latest version of cupy" "not included"
    print_default_option build-kokkos -- "flag to build the latest version of kokkos" "not included"
    print_default_option build-hpctoolkit -- "flag to build the latest version of hpctoolkit" "not included"
    print_default_option install-grafana -- "flag to install grafana" "not included"
    print_default_option build-all-latest -- "flag to build all the additional libraries that need a flag to be built" "not included"
    print_default_option use_cached-apps -- "flag to use pre-built gcc and aomp located in CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} directory" "not included"
    print_default_option omnitrace-build-from-source -- "flag to build omnitrace from source instead of using pre-built versions" "not included"
    print_default_option output-verbosity -- "flag to show more docker build output" "not included"
    print_default_option distro "[ubuntu|opensuse|rhel]" "OS distribution" "${DISTRO}"
    print_default_option distro-versions "[VERSION] [VERSION...]" "Ubuntu, OpenSUSE, or RHEL release" "${DISTRO_VERSIONS}"
    print_default_option amdgpu-gfxmodel [AMDGPU_GFXMODEL] "Specify the AMD GPU target architecture" "${AMDGPU_GFXMODEL}"
    print_default_option rocm-versions "[VERSION] [VERSION...]" "ROCm versions" "${ROCM_VERSIONS}"
    print_default_option python-versions "[VERSION] [VERSION...]" "Python 3 minor releases" "${PYTHON_VERSIONS}"
    print_default_option "docker-user" "[DOCKER_USERNAME]" "DockerHub username" "${DOCKER_USER}"
    print_default_option "retry" "[NUMBER OF ATTEMPTS]" "Number of attempts to build (to account for network errors)" "${RETRY}"
    print_default_option push -- "Push the image to Dockerhub" "do not push"
}


n=0
while [[ $# -gt 0 ]]
do
    case "${1}" in
        "--help")
            usage
            exit 0
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
        "--rocm-versions")
            shift
            ROCM_VERSIONS=${1}
            last() { ROCM_VERSIONS="${ROCM_VERSIONS} ${1}"; }
            ;;
        "--python-versions")
            shift
            PYTHON_VERSIONS=${1}
            last() { PYTHON_VERSIONS="${PYTHON_VERSIONS} ${1}"; }
            ;;
        "--docker-user")
            shift
            DOCKER_USER=${1}
            reset-last
            ;;
        "--admin-username")
            shift
            ADMIN_USERNAME=${1}
            reset-last
            ;;
        "--admin-password")
            shift
            ADMIN_PASSWORD=${1}
            reset-last
            ;;
        "--amdgpu-gfxmodel")
            shift
            AMDGPU_GFXMODEL=${1}
            reset-last
            ;;
        "--omnitrace-build-from-source")
            OMNITRACE_BUILD_FROM_SOURCE=1
            reset-last
            ;;
        "--push")
            PUSH=1
            reset-last
            ;;
        "--output-verbosity")
            OUTPUT_VERBOSITY="--progress=plain"
            reset-last
            ;;
        "--no-cache")
            NO_CACHE=--no-cache
            reset-last
            ;;
        "--no-pull")
            PULL=""
            reset-last
            ;;
        "--retry")
            shift
            RETRY=${1}
            reset-last
            ;;
        "--build-aomp-latest")
            BUILD_AOMP_LATEST="1"
            reset-last
            ;;
        "--build-llvm-latest")
            BUILD_LLVM_LATEST="1"
            reset-last
            ;;
        "--build-gcc-latest")
            BUILD_GCC_LATEST="1"
            reset-last
            ;;
        "--build-og-latest")
            BUILD_OG_LATEST="1"
            reset-last
            ;;
        "--build-clacc-latest")
            BUILD_CLACC_LATEST="1"
            reset-last
            ;;
        "--build-pytorch")
            BUILD_PYTORCH="1"
            reset-last
            ;;
        "--build-cupy")
            BUILD_CUPY="1"
            reset-last
            ;;
        "--build-jax")
            BUILD_JAX="1"
            reset-last
            ;;
        "--build-kokkos")
            BUILD_KOKKOS="1"
            reset-last
            ;;
        "--build-tau")
            BUILD_TAU="1"
            reset-last
            ;;
        "--build-mpi4py")
            BUILD_MPI4PY="1"
            reset-last
            ;;
        "--build-hpctoolkit")
            BUILD_HPCTOOLKIT="1"
            reset-last
            ;;
        "--install-grafana")
            INSTALL_GRAFANA="1"
            reset-last
            ;;
        "--build-all-latest")
            BUILD_AOMP_LATEST="1"
            #BUILD_LLVM_LATEST="1"
            BUILD_GCC_LATEST="1"
            #BUILD_OG_LATEST="1"
            #BUILD_CLACC_LATEST="1"
            BUILD_PYTORCH="1"
            BUILD_CUPY="1"
            BUILD_JAX="1"
	    BUILD_KOKKOS="1"
	    BUILD_TAU="1"
	    BUILD_MPI4PY="1"
	    BUILD_HPCTOOLKIT="1"
            reset-last
            ;;
        "--use-cached-apps")
            USE_CACHED_APPS="1"
            reset-last
            ;;
        "--*")
            send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
            ;;
        *)
            last ${1}
            ;;
    esac
    n=$((${n} + 1))
    shift
done

if [ "x${ADMIN_PASSWORD}" == "x" ] ; then
	echo "A password for the admin user is required"
	echo " --admin-password <xxxx>"
	echo " --admin-username <admin>"
	exit;
fi

ROCM_DOCKER_OPTS="${PULL} -f rocm/Dockerfile ${NO_CACHE}"

COMM_DOCKER_OPTS="-f comm/Dockerfile ${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER} --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL}"

TOOLS_DOCKER_OPTS="-f tools/Dockerfile ${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER} --build-arg OMNITRACE_BUILD_FROM_SOURCE=\"${OMNITRACE_BUILD_FROM_SOURCE}\" --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} --build-arg BUILD_HPCTOOLKIT=${BUILD_HPCTOOLKIT} --build-arg BUILD_TAU=${BUILD_TAU} "

EXTRAS_DOCKER_OPTS="${NO_CACHE} --build-arg DOCKER_USER=${DOCKER_USER} --build-arg BUILD_DATE=$(date +'%Y-%m-%dT%H:%M:%SZ') --build-arg OG_BUILD_DATE=$(date -u +'%y-%m-%d') --build-arg BUILD_VERSION=1.1 --build-arg DISTRO=${DISTRO} --build-arg PYTHON_VERSIONS=\"${PYTHON_VERSIONS}\" --build-arg ADMIN_USERNAME=${ADMIN_USERNAME} --build-arg ADMIN_PASSWORD=${ADMIN_PASSWORD}"

EXTRAS_DOCKER_OPTS="${EXTRAS_DOCKER_OPTS} -f extras/Dockerfile"

ADD_OPTIONS=""
PODMAN_DETECT=`docker |& grep "Emulate Docker CLI using podman" | wc -l`
if [[ "${PODMAN_DETECT}" -ge "1" ]]; then
   ADD_OPTIONS="${ADD_OPTIONS} --format docker"
fi

for ROCM_VERSION in ${ROCM_VERSIONS}
do
    mkdir -p CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}

    if [ -d CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/ ]; then
       USE_CACHED_APPS=1
    fi

    GENERAL_DOCKER_OPTS="${ADD_OPTIONS} --build-arg DISTRO=${DISTRO} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION}"

# Building rocm docker
    verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${ROCM_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
       --build-arg USE_CACHED_APPS=${USE_CACHED_APPS} \
       --tag ${DOCKER_USER}/rocm:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       .

# Building comm docker
    verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${COMM_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
       --build-arg USE_CACHED_APPS=${USE_CACHED_APPS} \
       -t ${DOCKER_USER}/comm:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       .

# Building tools docker
    verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${TOOLS_DOCKER_OPTS} \
       --build-arg INSTALL_GRAFANA="${INSTALL_GRAFANA}" \
       -t ${DOCKER_USER}/tools:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       .

# Building extrasdocker
    verbose-build docker build ${OUTPUT_VERBOSITY} ${GENERAL_DOCKER_OPTS} ${EXTRAS_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=${AMDGPU_GFXMODEL} \
       --build-arg BUILD_GCC_LATEST=${BUILD_GCC_LATEST} \
       --build-arg BUILD_AOMP_LATEST=${BUILD_AOMP_LATEST} \
       --build-arg BUILD_LLVM_LATEST=${BUILD_LLVM_LATEST} \
       --build-arg BUILD_OG_LATEST=${BUILD_OG_LATEST} \
       --build-arg BUILD_CLACC_LATEST=${BUILD_CLACC_LATEST} \
       --build-arg BUILD_PYTORCH=${BUILD_PYTORCH} \
       --build-arg BUILD_CUPY=${BUILD_CUPY} \
       --build-arg BUILD_JAX=${BUILD_JAX} \
       --build-arg BUILD_KOKKOS=${BUILD_KOKKOS} \
       --build-arg BUILD_TAU=${BUILD_TAU} \
       --build-arg BUILD_MPI4PY=${BUILD_MPI4PY} \
       --build-arg BUILD_HPCTOOLKIT=${BUILD_HPCTOOLKIT} \
       --build-arg USE_CACHED_APPS=${USE_CACHED_APPS} \
       -t ${DOCKER_USER}/training:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       -t training \
       .

    if [ "${PUSH}" -ne 0 ]; then
        docker push ${CONTAINER}
    fi
done
