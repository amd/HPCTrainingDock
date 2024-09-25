#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/scorep
BUILD_SCOREP=0
ROCM_VERSION=6.0
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  --build-scorep: default is 0"
   echo "  --module-path [ MODULE_PATH ] default /etc/lmod/modules/misc/scorep"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
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
      "--build-scorep")
          shift
          BUILD_SCOREP=${1}
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

echo ""
echo "==================================="
echo "Starting SCORE-P Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_SCOREP: $BUILD_SCOREP"
echo "==================================="
echo ""

CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}

if [ "${BUILD_SCOREP}" = "0" ]; then

   echo "SCORE-P will not be build, according to the specified value of BUILD_SCOREP"
   echo "BUILD_SCOREP: $BUILD_SCOREP"
   exit 

else
   if [ -f ${CACHE_FILES}/scorep.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached SCORE-P "
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/scorep.tgz
      if [ "${USER}" != "root" ]; then
         chown -R root:root /opt/rocmplus-${ROCM_VERSION}/scorep
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm /CacheFiles/scorep.tgz
      fi

   else

      echo ""
      echo "==============================="
      echo "        Building SCORE-P       "
      echo "==============================="
      echo ""

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}

      SCOREP_PATH=/opt/rocmplus-${ROCM_VERSION}/scorep
      PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
      ${SUDO} mkdir -p ${SCOREP_PATH}
      ${SUDO} mkdir -p ${PDT_PATH}

      git clone https://github.com/spack/spack.git

      # load spack environment
      source spack/share/spack/setup-env.sh

      # find already installed libs for spack
      spack external find

      # change spack install dir for PDT
      ${SUDO} sed -i 's|$spack/opt/spack|/opt/rocmplus-'"${ROCM_VERSION}"'/pdt|g' spack/etc/spack/defaults/config.yaml

      # open permissions to use spack to install PDT
      if [[ "${USER}" != "root" ]]; then
	 ${SUDO} chmod -R a+rwX ${PDT_PATH} 
	 ${SUDO} chmod -R a+rwX ${SCOREP_PATH}
      fi

      # install PDT with spack
      spack install pdt

      # get PDT install dir created by spack
      PDT_PATH=`spack find -p pdt | awk '{print $2}' | grep opt`
      export PATH=$PDT_PATH/bin:$PATH

      # install OpenMPI if not in the system already
      if [[ `which mpicc | wc -l` -eq 0 ]]; then
         ${SUDO} apt-get update
         ${SUDO} apt-get install -q -y libopenmpi-dev  
      fi

      wget http://go.fzj.de/scorep-ompt-device-tracing
      mv scorep-ompt-device-tracing scorep-ompt-device-tracing.tar.gz
      tar -xvf scorep-ompt-device-tracing.tar.gz
      cd sources.37b6f127
      mkdir build
      cd build
      export OMPI_CC=$ROCM_PATH/llvm/bin/clang
      export OMPI_CXX=$ROCM_PATH/llvm/bin/clang++
      export OMPI_FC=$ROCM_PATH/llvm/bin/flang
      ../configure --with-rocm=$ROCM_PATH  --with-mpi=openmpi  --prefix=$SCOREP_PATH  --with-librocm_smi64-include=$ROCM_PATH/include/rocm_smi \
                   --with-librocm_smi64-lib=$ROCM_PATH/lib --with-libunwind=download --enable-shared --with-libbfd=download --without-shmem  \
		     CC=$ROCM_PATH/llvm/bin/clang CXX=$ROCM_PATH/llvm/bin/clang++ FC=$ROCM_PATH/llvm/bin/flang CFLAGS=-fPIE

      ${SUDO} make
      ${SUDO} make install

      cd ../..
      ${SUDO} rm -rf scorep-ompt* sources.37b6f127
      ${SUDO} rm -rf spack

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/pdt -type f -execdir chown root:root "{}" +
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/scorep -type f -execdir chown root:root "{}" +
         ${SUDO} chmod go-w /opt/rocmplus-${ROCM_VERSION}/pdt
         ${SUDO} chmod go-w /opt/rocmplus-${ROCM_VERSION}/scorep
      fi

      module unload rocm/${ROCM_VERSION}

   fi   

   # Create a module file for SCORE-P
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/9.0-dev.lua
	whatis(" Score-P Performance Analysis Tool ")

        load("rocm/${ROCM_VERSION}")
	prepend_path("PATH","${SCOREP_PATH}/bin")
EOF

fi

