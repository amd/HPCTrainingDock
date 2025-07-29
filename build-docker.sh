#!/usr/bin/env bash

: ${DOCKER_USER:=$(whoami)}
: ${ROCM_VERSIONS:="6.0"}
: ${PYTHON_VERSION:="10"}
: ${BUILD_CI:=""}
: ${PUSH:=0}
: ${PULL:=--pull}
: ${OUTPUT_VERBOSITY:=""}
: ${BUILD_OPTIONS:=""}
: ${BUILD_AOMP_LATEST:="0"}
: ${BUILD_LLVM_LATEST:="0"}
: ${BUILD_GCC_LATEST:="0"}
: ${BUILD_OG_LATEST:="0"}
: ${BUILD_CLACC_LATEST:="0"}
: ${BUILD_PYTORCH:="0"}
: ${BUILD_CUPY:="0"}
: ${BUILD_TENSORFLOW:="0"}
: ${BUILD_JAX:="0"}
: ${BUILD_KOKKOS:="0"}
: ${BUILD_TAU:="0"}
: ${BUILD_SCOREP:="0"}
: ${BUILD_MPI4PY:="0"}
: ${BUILD_FFTW:="0"}
: ${BUILD_MINICONDA3:="0"}
: ${BUILD_MINIFORGE3:="0"}
: ${BUILD_HPCTOOLKIT:="0"}
: ${BUILD_HDF5:="0"}
: ${BUILD_PETSC:="0"}
: ${BUILD_HYPRE:="0"}
: ${BUILD_NETCDF:="0"}
: ${BUILD_ADIOS2:="0"}
: ${BUILD_FTORCH:="0"}
: ${BUILD_JULIA:="0"}
: ${BUILD_X11VNC:="0"}
: ${BUILD_FLANGNEW:="0"}
: ${BUILD_OLLAMA:="1"}
: ${BUILD_HIPFORT:="0"}
: ${BUILD_ALL_LATEST:="0"}
: ${HIPIFLY_MODULE:="1"}
: ${RETRY:=3}
: ${NO_CACHE:=""}
: ${ADMIN_USERNAME:="admin"}
: ${ADMIN_PASSWORD:=""}
: ${USE_CACHED_APPS:=0}
: ${AMDGPU_GFXMODEL:=""}
: ${INSTALL_GRAFANA:=0}
: ${INSTALL_ROCPROF_SYS_FROM_SOURCE:=0}
: ${INSTALL_ROCPROF_COMPUTE_FROM_SOURCE:=0}
: ${BUILD_ROCPROFILER_SDK:=0}
: ${BUILD_AQLPROFILE:=0}

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`

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

usage()
{
    print_option() { printf "    --%-20s %-24s     %s\n" "${1}" "${2}" "${3}"; }
    echo "Options:"
    print_option "help -h" "" "prints this message to terminal"
    echo ""
    print_default_option() { printf "    --%-20s %-24s     %s (default: %s)\n" "${1}" "${2}" "${3}" "$(tolower ${4})"; }
    print_default_option "no-pull" "[PULL: --no-pull or --pull]" "instructs to not pull down the most recent base container" "$PULL"
    print_default_option "admin-username" "[ADMIN_USERNAME]" "container admin username" "${ADMIN_USERNAME}"
    print_default_option admin-password "[ADMIN_PASSWORD]" "MANDATORY: container admin password" "not set, needs to be provided as input"
    print_default_option build-options "[BUILD_OPTIONS: default is not set]" "use this to specify a semi-colon separate list of packages to install" "not set"
    print_default_option build-aomp-latest "[BUILD_AOMP_LATEST: 0 or 1]" "include this flag build the latest version of AOMP for offloading" "${BUILD_AOMP_LATEST} (don't build)"
    print_default_option build-llvm-latest "[BUILD_LLVM_LATEST: 0 or 1]"  "include this flag to build the latest version of LLVM for offloading" "${BUILD_LLVM_LATEST} (don't build)"
    print_default_option build-gcc-latest "[BUILD_GCC_LATEST: 0 or 1]"  "include this flag to build the latest version of gcc with offloading" "${BUILD_GCC_LATEST} (don't build)"
    print_default_option build-clacc-latest "[BUILD_CLACC_LATEST: 0 or 1]"  "include this flag to build the latest version of clacc with offloading" "${BUILD_CLACC_LATEST} (don't build)"
    print_default_option build-pytorch "[BUILD_PYTORCH: 0 or 1]"  "include this flag to build version 2.7.1" "${BUILD_PYTORCH} (don't build)"
    print_default_option build-miniconda3 "[BUILD_MINICONDA3: 0 or 1]" "include this flag to build version 25.3.1" "${BUILD_MINICONDA3} (don't build)"
    print_default_option build-miniforge3 "[BUILD_MINIFORGE3: 0 or 1]" "include this flag to build version 24.9.0" "${BUILD_MINIFORGE3} (don't build)"
    print_default_option build-hdf5 "[BUILD_HDF5: 0 or 1]" "include this flag to build version 1.14.6" "${BUILD_HDF5} (don't build)"
    print_default_option build-netcdf "[BUILD_NETCDF: 0 or 1]" "include this flag to build version 4.9.3 of netcdf-c and 4.6.2 of netcdf-fortran" "${BUILD_NETCDF} (don't build)"
    print_default_option build-adios2 "[BUILD_ADIOS2: 0 or 1]" "include this flag to build version 2.10.1" "${BUILD_ADIOS2} (don't build)"
    print_default_option build-ftorch "[BUILD_FTORCH: 0 or 1]" "include this flag to build version dev" "${BUILD_FTORCH} (don't build)"
    print_default_option build-julia "[BUILD_JULIA: 0 or 1]" "include this flag to build version 1.12" "${BUILD_JULIA} (don't build)"
    print_default_option build-hipfort "[BUILD_HIPFORT: 0 or 1]" "include this flag to build the same version as ROCm" "${BUILD_HIPFORT} (don't build)"
    print_default_option build-cupy "[BUILD_CUPY: 0 or 1]" "include this flag to build version 14.0.0a1" "${BUILD_CUPY} (don't build)"
    print_default_option build-tensorflow "[BUILD_TENSORFLOW: 0 or 1]" "include this flag to build branch merge-250318" "${BUILD_TENSORFLOW} (don't build)"
    print_default_option build-jax "[BUILD_JAX: 0 or 1]" "include this flag to build version 0.6.0" "${BUILD_JAX} (don't build)"
    print_default_option build-kokkos "[BUILD_KOKKOS: 0 or 1]"  "include this flag to build version 4.5.01" "${BUILD_KOKKOS} (don't build)"
    print_default_option build-hpctoolkit "[BUILD_HPCTOOLKIT: 0 or 1]"  "include this flag to build verison 2024.11.27dev" "${BUILD_HPCTOOLKIT} (don't build)"
    print_default_option build-tau "[BUILD_TAU: 0 or 1]"  "include this flag to build version dev" "${BUILD_TAU} (don't build)"
    print_default_option build-scorep "[BUILD_SCOREP: 0 or 1]" "include this flag to build version 9.0" "${BUILD_SCOREP} (don't build)"
    print_default_option build-x11vnc "[BUILD_X11VNC: 0 or 1]" "include this flag to enable x11 screen forwarding in the container" "${BUILD_X11VNC} (don't build)"
    print_default_option build-petsc "[BUILD_PETSC: 0 or 1]" "include this flag to build version 3.23.1" "${BUILD_PETSC} (don't build)"
    print_default_option build-hypre "[BUILD_HYPRE: 0 or 1]" "include this flag to build version 2.33" "${BUILD_HYPRE} (don't build)"
    print_default_option build-mpi4py "[BUILD_MPI4PY: 0 or 1]" "include this flag to build version 4.0.1" "${BUILD_MPI4PY} (don't build)"
    print_default_option build-fftw "[BUILD_FFTW: 0 or 1]" "include this flag to build version 3.3.10" "${BUILD_FFTW} (don't build)"
    print_default_option build-flang-new "[BUILD_FLANGNEW: 0 or 1]" "include this flag to unpack the latest ROCm AFAR drop" "${BUILD_FLANGNEW} (don't build)"
    print_default_option install-grafana "[INSTALL_GRAFANA: 0 or 1]" "include this flag to install Grafana" "${INSTALL_GRAFANA} (don't build)"
    print_default_option build-all-latest "[BUILD_ALL_LATEST: 0 or 1]" "include this flag to build all the additional libraries that need a flag to be built except LLVM latest, GCC latest and CLACC latest" "${BUILD_ALL_LATEST} (don't build)"
    print_default_option use_cached-apps "[USE_CACHED_APPS: 0 or 1]" "use pre-built gcc and aomp located in CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} directory" "${USE_CACHED_APPS} (don't use)"
    print_default_option install-rocprof-sys-from-source "[INSTALL_ROCPROF_SYS_FROM_SOURCE: 0 or 1]" "include this flag to build rocprof-sys from source, the default branch is amd-staging" "${INSTALL_ROCPROF_SYS_FROM_SOURCE} (don't install)"
    print_default_option install-rocprof-compute-from-source "[INSTALL_ROCPROF_COMPUTE_FROM_SOURCE: 0 or 1]" "include this flag to build rocprof-compute from source, the default branch is amd-staging" "${INSTALL_ROCPROF_COMPUTE_FROM_SOURCE} (don't install)"
    print_default_option build-rocprofiler-sdk "[BUILD_ROCPROFILER_SDK: 0 or 1]" "include this flag to build rocprofiler-sdk from source, the default branch is amd-staging" "${BUILD_ROCPROFILER_SDK} (don't install)"
    print_default_option build-aqlprofile "[BUILD_AQLPROFILE: 0 or 1]" "include this flag to build aqlprofile from source, the default branch is amd-staging" "${BUILD_AQLPROFILE} (don't install)"
    print_default_option output-verbosity "[OUTPUT_VERBOSITY: not set or set to '--progress-plain']" "include this flag to show more docker build output" "not set"
    print_default_option distro "[DISTRO: ubuntu|rockylinux|opensuse/leap]" "OS distribution" "autodetected -> ${DISTRO}"
    print_default_option distro-versions "[DISTRO_VERSION] [VERSION...]" "Ubuntu, OpenSUSE, or RHEL release" "autodetected -> ${DISTRO_VERSION}"
    print_default_option amdgpu-gfxmodel "[AMDGPU_GFXMODEL]" "Specify the AMD GPU target architecture" "autodetected -> ${AMDGPU_GFXMODEL}"
    print_default_option rocm-versions "[ROCM_VERSIONS] [VERSION...]" "ROCm versions" "${ROCM_VERSIONS}"
    print_default_option python-version "[PYTHON_VERSION]" "python3 minor release" "${PYTHON_VERSION}"
    print_default_option "docker-user" "[DOCKER_USERNAME]" "DockerHub username" "${DOCKER_USER}"
    print_default_option "retry" "[RETRY: number of retries]" "Number of attempts to build (to account for network errors)" "${RETRY}"
    print_default_option no-cache "[NO_CACHE: not set or set to '-no-cache'" "Supplies the --no-cache option to Docker" "not set"
    print_default_option push "[PUSH: 0 or 1]" "Push the image to Dockerhub" "${PUSH} (don't push)"
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
        "--python-version")
            shift
            PYTHON_VERSION_INPUT=${1}
            reset-last
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
            AMDGPU_GFXMODEL="${1}"
            reset-last
            ;;
        "--install-rocprof-sys-from-source")
            INSTALL_ROCPROF_SYS_FROM_SOURCE=1
            reset-last
            ;;
        "--install-rocprof-compute-from-source")
            INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=1
            reset-last
            ;;
        "--build-rocprofiler-sdk")
            BUILD_ROCPROFILER_SDK=1
            reset-last
            ;;
        "--build-aqlprofile")
            BUILD_AQLPROFILE=1
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
	"--build-options")
            shift
	    BUILD_OPTIONS=${1}
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
        "--build-clacc-latest")
            BUILD_CLACC_LATEST="1"
            reset-last
            ;;
        "--build-pytorch")
            BUILD_PYTORCH="1"
            reset-last
            ;;
        "--build-petsc")
            BUILD_PETSC="1"
            reset-last
            ;;
        "--build-hypre")
            BUILD_HYPRE="1"
            reset-last
            ;;
        "--build-cupy")
            BUILD_CUPY="1"
            reset-last
            ;;
        "--build-tensorflow")
            BUILD_TENSORFLOW="1"
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
        "--build-miniconda3")
            BUILD_MINICONDA3="1"
            reset-last
            ;;
        "--build-miniforge3")
            BUILD_MINIFORGE3="1"
            reset-last
            ;;
        "--build-hdf5")
            BUILD_HDF5="1"
            reset-last
            ;;
        "--build-netcdf")
            BUILD_NETCDF="1"
            reset-last
            ;;
        "--build-adios2")
            BUILD_ADIOS2="1"
            reset-last
            ;;
        "--build-tau")
            BUILD_TAU="1"
            reset-last
            ;;
        "--build-scorep")
            BUILD_SCOREP="1"
            reset-last
            ;;
        "--build-mpi4py")
            BUILD_MPI4PY="1"
            reset-last
            ;;
        "--build-fftw")
            BUILD_FFTW="1"
            reset-last
            ;;
        "--build-hpctoolkit")
            BUILD_HPCTOOLKIT="1"
            reset-last
            ;;
        "--build-x11vnc")
            BUILD_X11VNC="1"
            reset-last
            ;;
        "--build-flang-new")
            BUILD_FLANGNEW="1"
            reset-last
            ;;
        "--build-hipfort")
            BUILD_HIPFORT="1"
            reset-last
            ;;
        "--build-ftorch")
            BUILD_FTORCH="1"
            reset-last
            ;;
        "--build-julia")
            BUILD_JULIA="1"
            reset-last
            ;;
        "--install-grafana")
            INSTALL_GRAFANA="1"
            reset-last
            ;;
        "--build-all-latest")
            #BUILD_AOMP_LATEST="1"
            #BUILD_LLVM_LATEST="1"
            #BUILD_GCC_LATEST="1"
            #BUILD_OG_LATEST="1"
            #BUILD_CLACC_LATEST="1"
            BUILD_PYTORCH="1"
            BUILD_CUPY="1"
            BUILD_TENSORFLOW="1"
            BUILD_PETSC="1"
            BUILD_HYPRE="1"
            BUILD_JAX="1"
            BUILD_HDF5="1"
            BUILD_NETCDF="1"
            BUILD_ADIOS2="1"
	    BUILD_KOKKOS="1"
	    BUILD_MINICONDA3="1"
	    BUILD_MINIFORGE3="1"
	    BUILD_TAU="1"
	    BUILD_SCOREP="1"
	    BUILD_MPI4PY="1"
	    BUILD_FFTW="1"
	    BUILD_HPCTOOLKIT="1"
	    BUILD_X11VNC="1"
	    BUILD_FLANGNEW="1"
	    BUILD_HIPFORT="1"
	    BUILD_FTORCH="1"
	    #BUILD_JULIA="1"
	    INSTALL_ROCPROF_SYS_FROM_SOURCE="1"
            INSTALL_ROCPROF_COMPUTE_FROM_SOURCE="1"
	    BUILD_ROCPROFILER_SDK="1"
	    BUILD_AQLPROFILE="1"
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

if [[ "${PYTHON_VERSION_INPUT}" == "" ]]; then
   if [[ "${DISTRO}" == "ubuntu" &&  "${DISTRO_VERSION}" == "24.04" ]]; then
      PYTHON_VERSION="12"
   fi
else
   PYTHON_VERSION=${PYTHON_VERSION_INPUT}
fi

if [ "${BUILD_OPTIONS}" != "" ]; then
   echo "Requesting additional \"${BUILD_OPTIONS}\" build options"
   for i in ${BUILD_OPTIONS//;/ }
   do
      case "$i" in
	 # optional communication packages
         "mpi4py")
	    echo "Setting MPI4PY build"
            BUILD_MPI4PY=1
	    ;;
	 # optional tool packages
         "grafana")
	    echo "Setting grafana build"
            BUILD_GRAFANA=1
	    ;;
         "hpctoolkit")
	    echo "Setting hpctoolkit build"
            BUILD_HPCTOOLKIT=1
	    ;;
         "rocprof-sys")
	    echo "Setting rocprof-sys install from source"
            INSTALL_ROCPROF_SYS_FROM_SOURCE=1
	    ;;
         "rocprof-compute")
	    echo "Setting rocprof-compute install from source"
            INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=1
	    ;;
         "hdf5")
	    echo "Setting hdf5 build"
            BUILD_HDF5=1
	    ;;
         "netcdf")
	    echo "Setting netcdf build"
            BUILD_NETCDF=1
	    ;;
         "adios2")
	    echo "Setting adios2 build"
            BUILD_ADIOS2=1
	    ;;
         "petsc")
	    echo "Setting petsc build"
            BUILD_PETSC=1
	    ;;
         "hypre")
	    echo "Setting hypre build"
            BUILD_HYPRE=1
	    ;;
         "scorep")
	    echo "Setting scorep build"
            BUILD_SCOREP=1
	    ;;
         "tau")
	    echo "Setting TAU build"
            BUILD_TAU=1
	    ;;
	 # optional compiler packages
         "aomp_latest")
	    echo "Setting AOMP_LATEST build"
            BUILD_AOMP_LATEST=1
	    ;;
         "clacc_latest")
	    echo "Setting CLACC_LATEST build"
            BUILD_CLACC_LATEST=1
	    ;;
         "flang-new")
	    echo "Setting FLANGNEW build"
            BUILD_FLANGNEW=1
	    ;;
         "hipfort")
	    echo "Setting HIPFORT build"
            BUILD_HIPFORT=1
	    ;;
         "ftorch")
	    echo "Setting FTORCH build"
            BUILD_FTORCH=1
	    ;;
         "julia")
	    echo "Setting JULIA build"
            BUILD_JULIA=1
	    ;;
         "gcc_latest")
	    echo "Setting GCC_LATEST build"
            BUILD_GCC_LATEST=1
	    ;;
         "llvm_latest")
	    echo "Setting LLVM_LATEST build"
            BUILD_LLVM_LATEST=1
	    ;;
	 # optional AI packages
         "cupy")
	    echo "Setting CUPY build"
            BUILD_CUPY=1
	    ;;
         "tensorflow")
	    echo "Setting TENSORFLOW build"
            BUILD_TENSORFLOW=1
	    ;;
         "jax")
	    echo "Setting JAX build"
            BUILD_JAX=1
	    ;;
         "pytorch")
	    echo "Setting PYTORCH build"
            BUILD_PYTORCH=1
	    ;;
	 # optional languages/frameworks
         "kokkos")
	    echo "Setting KOKKOS build"
            BUILD_KOKKOS=1
	    ;;
	 # optional external libraries
         "fftw")
	    echo "Setting FFTW build"
            BUILD_FFTW=1
	    ;;
	 # optional python virtual environments
         "miniconda3")
	    echo "Setting MINICONDA3 build"
            BUILD_MINICONDA3=1
	    ;;
         "miniforge3")
	    echo "Setting MINIFORGE3 build"
            BUILD_MINIFORGE3=1
	    ;;
	 # optional graphics interfaces
         "x11vnc")
	    echo "Setting X11VNC build"
            BUILD_X11VNC=1
	    ;;
	 # All latest recommended
         "all-latest")
	    echo "Setting all latest build"
            #BUILD_AOMP_LATEST="1"
            #BUILD_LLVM_LATEST="1"
            #BUILD_GCC_LATEST="1"
            #BUILD_OG_LATEST="1"
            #BUILD_CLACC_LATEST="1"
            BUILD_PYTORCH="1"
            BUILD_CUPY="1"
            BUILD_TENSORFLOW="1"
            BUILD_PETSC="1"
            BUILD_HYPRE="1"
            BUILD_JAX="1"
            BUILD_KOKKOS="1"
            BUILD_MINICONDA3="1"
            BUILD_MINIFORGE3="1"
            BUILD_TAU="1"
	    BUILD_FFTW="1"
            BUILD_SCOREP="1"
            BUILD_MPI4PY="1"
            BUILD_HDF5="1"
            BUILD_NETCDF="1"
            BUILD_ADIOS2="1"
            BUILD_HPCTOOLKIT="1"
            BUILD_X11VNC="1"
            BUILD_FLANGNEW="1"
            BUILD_HIPFORT="1"
            BUILD_FTORCH="1"
            #BUILD_JULIA="1"
	    INSTALL_ROCPROF_SYS_FROM_SOURCE="1"
            INSTALL_ROCPROF_COMPUTE_FROM_SOURCE="1"
	    BUILD_ROCPROFILER_SDK="1"
	    BUILD_AQLPROFILE="1"
	    ;;
         *)
            echo "Unsupported build option request \"$i\""
	    echo "Valid options are:"
	    echo " # optional communication packages"
            echo "   mpi4py"
	    echo " # optional tool packages"
            echo "   grafana"
            echo "   hpctoolkit"
            echo "   rocprof-sys"
            echo "   rocprof-compute"
            echo "   scorep"
            echo "   petsc"
            echo "   hypre"
            echo "   tau"
	    echo " # optional compiler packages"
            echo "   aomp_latest"
            echo "   clacc_latest"
            echo "   flang-new"
            echo "   gcc_latest"
            echo "   llvm_latest"
	    echo " # optional AI packages"
            echo "   cupy"
            echo "   jax"
            echo "   pytorch"
	    echo " # optional languages/frameworks"
            echo "   kokkos"
	    echo " # optional python virtual environments"
	    echo "   miniconda3"
	    echo "   miniforge3"
	    echo " # optional data model"
	    echo "   hdf5"
	    echo " # optional graphics interfaces"
            echo "   x11vnc"
	    echo " # All latest recommended"
            echo "   all-latest"
            ;;
      esac
   done
fi

if [ "x${ADMIN_PASSWORD}" == "x" ] ; then
	echo "A password for the admin user is required"
	echo " --admin-password <xxxx>"
	echo " --admin-username <admin>"
	exit;
fi

AMDGPU_GFXMODEL_FIRST=`echo ${AMDGPU_GFXMODEL} | cut -f1 -d';'`
AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`

ADD_OPTIONS=""
PODMAN_DETECT=`docker |& grep "Emulate Docker CLI using podman" | wc -l`
if [[ "${PODMAN_DETECT}" -ge "1" ]]; then
   ADD_OPTIONS="${ADD_OPTIONS} --format docker"
fi

for ROCM_VERSION in ${ROCM_VERSIONS}
do
    mkdir -p CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

    if [ -d CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}/ ]; then
       USE_CACHED_APPS=1
    fi

    GENERAL_DOCKER_OPTS="${ADD_OPTIONS} ${OUTPUT_VERBOSITY} ${NO_CACHE}"
    GENERAL_DOCKER_OPTS="${GENERAL_DOCKER_OPTS} --build-arg DISTRO=${DISTRO}"
    GENERAL_DOCKER_OPTS="${GENERAL_DOCKER_OPTS} --build-arg DISTRO_VERSION=${DISTRO_VERSION}"
    GENERAL_DOCKER_OPTS="${GENERAL_DOCKER_OPTS} --build-arg ROCM_VERSION=${ROCM_VERSION}"
    GENERAL_DOCKER_OPTS="${GENERAL_DOCKER_OPTS} --build-arg USE_CACHED_APPS=${USE_CACHED_APPS}"
    GENERAL_DOCKER_OPTS="${GENERAL_DOCKER_OPTS} --build-arg DOCKER_USER=${DOCKER_USER}"

# Building rocm docker
    verbose-build docker build ${GENERAL_DOCKER_OPTS} ${PULL} \
       --build-arg AMDGPU_GFXMODEL=\"${AMDGPU_GFXMODEL}\" \
       --build-arg AMDGPU_GFXMODEL_STRING=\"${AMDGPU_GFXMODEL_STRING}\" \
       --build-arg BUILD_FLANGNEW=${BUILD_FLANGNEW} \
       --build-arg PYTHON_VERSION=\"${PYTHON_VERSION}\" \
       --tag ${DOCKER_USER}/rocm:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       -f rocm/Dockerfile .

# Building comm docker
    verbose-build docker build ${GENERAL_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=\"${AMDGPU_GFXMODEL}\" \
       --build-arg AMDGPU_GFXMODEL_STRING=\"${AMDGPU_GFXMODEL_STRING}\" \
       --build-arg BUILD_MPI4PY=${BUILD_MPI4PY} \
       -t ${DOCKER_USER}/comm:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       -f comm/Dockerfile .

# Building tools docker
    verbose-build docker build ${GENERAL_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=\"${AMDGPU_GFXMODEL}\" \
       --build-arg INSTALL_GRAFANA="${INSTALL_GRAFANA}" \
       --build-arg BUILD_HPCTOOLKIT=${BUILD_HPCTOOLKIT}  \
       --build-arg BUILD_TAU=${BUILD_TAU}  \
       --build-arg BUILD_SCOREP=${BUILD_SCOREP} \
       --build-arg PYTHON_VERSION=${PYTHON_VERSION}  \
       --build-arg INSTALL_ROCPROF_SYS_FROM_SOURCE=${INSTALL_ROCPROF_SYS_FROM_SOURCE} \
       --build-arg INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=${INSTALL_ROCPROF_COMPUTE_FROM_SOURCE} \
       --build-arg BUILD_ROCPROFILER_SDK=${BUILD_ROCPROFILER_SDK} \
       --build-arg BUILD_AQLPROFILE=${BUILD_AQLPROFILE} \
       -t ${DOCKER_USER}/tools:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       -f tools/Dockerfile .

# Building extras docker
    verbose-build docker build ${GENERAL_DOCKER_OPTS} \
       --build-arg AMDGPU_GFXMODEL=\"${AMDGPU_GFXMODEL}\" \
       --build-arg BUILD_GCC_LATEST=${BUILD_GCC_LATEST} \
       --build-arg BUILD_AOMP_LATEST=${BUILD_AOMP_LATEST} \
       --build-arg BUILD_LLVM_LATEST=${BUILD_LLVM_LATEST} \
       --build-arg BUILD_OG_LATEST=${BUILD_OG_LATEST} \
       --build-arg BUILD_CLACC_LATEST=${BUILD_CLACC_LATEST} \
       --build-arg BUILD_PYTORCH=${BUILD_PYTORCH} \
       --build-arg BUILD_CUPY=${BUILD_CUPY} \
       --build-arg BUILD_TENSORFLOW=${BUILD_TENSORFLOW} \
       --build-arg BUILD_JAX=${BUILD_JAX} \
       --build-arg BUILD_PETSC=${BUILD_PETSC} \
       --build-arg BUILD_HYPRE=${BUILD_HYPRE} \
       --build-arg BUILD_KOKKOS=${BUILD_KOKKOS} \
       --build-arg BUILD_MINICONDA3=${BUILD_MINICONDA3} \
       --build-arg BUILD_MINIFORGE3=${BUILD_MINIFORGE3} \
       --build-arg BUILD_HDF5=${BUILD_HDF5} \
       --build-arg BUILD_NETCDF=${BUILD_NETCDF} \
       --build-arg BUILD_ADIOS2=${BUILD_ADIOS2} \
       --build-arg BUILD_X11VNC=${BUILD_X11VNC} \
       --build-arg BUILD_FFTW=${BUILD_FFTW} \
       --build-arg BUILD_OLLAMA=${BUILD_OLLAMA} \
       --build-arg HIPIFLY_MODULE=${HIPIFLY_MODULE} \
       --build-arg BUILD_HIPFORT=${BUILD_HIPFORT} \
       --build-arg BUILD_FTORCH=${BUILD_FTORCH} \
       --build-arg BUILD_JULIA=${BUILD_JULIA} \
       --build-arg BUILD_DATE=$(date +'%Y-%m-%dT%H:%M:%SZ') \
       --build-arg OG_BUILD_DATE=$(date -u +'%y-%m-%d') \
       --build-arg BUILD_VERSION=1.1 \
       --build-arg DISTRO=${DISTRO} \
       --build-arg PYTHON_VERSION=${PYTHON_VERSION} \
       --build-arg ADMIN_USERNAME=${ADMIN_USERNAME} \
       --build-arg ADMIN_PASSWORD=${ADMIN_PASSWORD} \
       -t ${DOCKER_USER}/training:release-base-${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION} \
       -t training \
       -f extras/Dockerfile .

    if [ "${PUSH}" -ne 0 ]; then
        docker push ${CONTAINER}
    fi
done
