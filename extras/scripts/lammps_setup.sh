#!/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/lammps
BUILD_LAMMPS=1
ROCM_VERSION=6.4.0
INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/lammps
INSTALL_PATH_INPUT=""
USE_SPACK=0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [ INSTALL_PATH_INPUT ] default $INSTALL_PATH"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --use-spack [ USE_SPACK ] default is $USE_SPACK "
   echo "  --build-lammps [ BUILD_LAMMPS ] default is 0"
   echo "  --help: this usage information"
   exit 1
}

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

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--build-lammps")
          shift
          BUILD_LAMMPS=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--use-spack")
          shift
          USE_SPACK=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/lammps
fi

echo ""
echo "==================================="
echo "Starting LAMMPS Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_LAMMPS: $BUILD_LAMMPS"
echo "Installing LAMMPS in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_LAMMPS}" = "0" ]; then

   echo "LAMMPS will not be built, according to the specified value of BUILD_LAMMPS"
   echo "BUILD_LAMMPS: $BUILD_LAMMPS"
   exit

else
   if [ -f ${CACHE_FILES}/lammps.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached LAMMPS"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xpzf ${CACHE_FILES}/lammps.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/lammps.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building LAMMPS"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}
      ${SUDO} chmod -R a+w ${INSTALL_PATH}

      #source /etc/profile.d/lmod.sh
      #source /etc/profile.d/z00_lmod.sh
      module load rocm/${ROCM_VERSION}
      module load amdclang
      module load openmpi

      sudo apt-get -y install libssl-dev unzip

      # spack install
      if [[ ${USE_SPACK} == "1" ]]; then
         git clone --branch=v0.23.1 https://github.com/spack/spack
         # change spack install dir for Hypre
         source spack/share/spack/setup-env.sh
         spack compiler find
         spack external find --all
         sed -i 's|$spack/opt/spack|'"${INSTALL_PATH}"'|g' spack/etc/spack/defaults/base/config.yaml
         spack install lammps +rocm amdgpu_target=${AMDGPU_GFXMODEL}

         rm -rf spack .spack
      else
	 git clone -b patch_27Jun2024 https://github.com/lammps/lammps.git
         #wget https://github.com/lammps/lammps/releases/download/stable_22Jul2025/lammps-linux-x86_64-22Jul2025.tar.gz
	 #tar -xzvf lammps-linux-x86_64-22Jul2025.tar.gz
# cmake install
#kokkos_arch_flag, which needs to be -DKokkos_ARCH_VEGA942=ON (for MI300)
#
         #cd lammps-linux-x86_64-22Jul2025
         cd lammps
	 mkdir build && cd build
	 cmake   -DPKG_KOKKOS=on \
                 -DPKG_REAXFF=on \
                 -DPKG_MANYBODY=on \
                 -DPKG_ML-SNAP=on \
                 -DPKG_MOLECULE=on \
                 -DPKG_KSPACE=on \
                 -DPKG_RIGID=on \
                 -DBUILD_MPI=on \
                 -DMPI_CXX_SKIP_MPICXX=on \
                 -DFFT_KOKKOS=HIPFFT \
                 -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH} \
                 -DMPI_CXX_COMPILER=$(which mpicxx) \
                 -DCMAKE_BUILD_TYPE=Release \
                 -DKokkos_ENABLE_HIP=on \
                 -DKokkos_ENABLE_SERIAL=on \
                 -DCMAKE_CXX_STANDARD=17 \
                 -DCMAKE_CXX_COMPILER=$(which hipcc) \
                 -DKokkos_ARCH_VEGA90A=ON \
                 -DKokkos_ENABLE_HWLOC=on \
                 -DLAMMPS_SIZES=smallbig \
                 -DKokkos_ENABLE_HIP_MULTIPLE_KERNEL_INSTANTIATIONS=ON \
                 -DCMAKE_CXX_FLAGS="-munsafe-fp-atomics" \
           ../cmake
         make -j 8
         make install
	 cd ../..
	 #rm -rf lammps
	 #rm -rf lammps-linux-x86_64-22Jul2025
      fi

      ${SUDO} chmod -R go-w ${INSTALL_PATH}

   fi
fi

