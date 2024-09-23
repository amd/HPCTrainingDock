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

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}

      SCOREP_PATH=/opt/rocmplus-${ROCM_VERSION}/scorep
      PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
      ${SUDO} mkdir -p ${SCOREP_PATH}
      ${SUDO} mkdir -p ${PDT_PATH}

      export PATH=${SCOREP_PATH}/bin:$PATH

      echo ""
      echo "==============================="
      echo " Building SCORE-P Dependencies"
      echo "==============================="
      echo ""

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

      # install afs-dev
      wget https://perftools.pages.jsc.fz-juelich.de/utils/afs-dev/afs-dev-latest.tar.gz
      tar -xvf afs-dev-latest.tar.gz
      cd afs-dev-latest
      ./install-afs-dev.sh --continue-after-download --prefix=$SCOREP_PATH
      cd ..
      rm -rf afs-dev-latest*

      # install perftools-dev
      wget https://perftools.pages.jsc.fz-juelich.de/utils/perftools-dev/perftools-dev-latest.tar.gz
      tar -xvf perftools-dev-latest.tar.gz
      cd perftools-dev-latest
      ./install-perftools-dev.sh --continue-after-download --prefix=$SCOREP_PATH
      cd ..
      rm -rf perftools-dev-latest*

      # install cubew
      wget https://apps.fz-juelich.de/scalasca/releases/cube/4.8/dist/cubew-4.8.2.tar.gz
      tar -xvf cubew-4.8.2.tar.gz
      cd cubew-4.8.2
      ./configure --prefix=$SCOREP_PATH
      make
      make install
      cd ..
      rm -rf cubew-4.8.2*

      # install cubelib
      wget https://apps.fz-juelich.de/scalasca/releases/cube/4.8/dist/cubelib-4.8.2.tar.gz
      tar -xvf cubelib-4.8.2.tar.gz
      cd cubelib-4.8.2
      ./configure --prefix=$SCOREP_PATH
      make
      make install
      cd ..
      rm -rf cubelib*

      # install opari2
      wget https://perftools.pages.jsc.fz-juelich.de/cicd/opari2/tags/opari2-2.0.8/opari2-2.0.8.tar.gz
      tar -xvf opari2-2.0.8.tar.gz
      cd opari2-2.0.8
      ./configure --prefix=$SCOREP_PATH
      make
      make install
      cd ..
      rm -rf opari2-2.0.8*

      # install otf2
      wget https://perftools.pages.jsc.fz-juelich.de/cicd/otf2/tags/otf2-3.0.3/otf2-3.0.3.tar.gz
      tar -xvf otf2-3.0.3.tar.gz
      cd otf2-3.0.3
      ./configure --prefix=$SCOREP_PATH
      make
      make install
      cd ..
      rm -rf otf2*

      echo ""
      echo "==============================="
      echo "        Building SCORE-P       "
      echo "==============================="
      echo ""

      wget https://gitlab.com/score-p/scorep/-/archive/v8.4/scorep-v8.4.tar.gz
      tar -xvf  scorep-v8.4.tar.gz
      cd scorep-v8.4
      ./bootstrap
      mkdir build
      cd build
      touch ../build-config/REVISION
      export OMPI_CC=$ROCM_PATH/llvm/bin/clang
      export OMPI_CXX=$ROCM_PATH/llvm/bin/clang++
      export OMPI_FC=$ROCM_PATH/llvm/bin/flang
      ../configure --with-rocm=$ROCM_PATH --with-pdt=$PDT_PATH --with-mpi=openmpi \
	           --without-shmem --prefix=$SCOREP_PATH  --with-librocm_smi64-include=$ROCM_PATH/include/rocm_smi \
		   --with-librocm_smi64-lib=$ROCM_PATH/lib --with-libunwind=download CC=$ROCM_PATH/llvm/bin/clang \
		     CXX=$ROCM_PATH/llvm/bin/clang++ FC=$ROCM_PATH/llvm/bin/flang --enable-shared --with-libbfd=download
      ${SUDO} make
      ${SUDO} make install

      cd ../..
#      ${SUDO} rm -rf scorep-v8.4*
      ${SUDO} rm -rf spack

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/pdt -type f -execdir chown root:root "{}" +
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/scorep -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w /opt/rocmplus-${ROCM_VERSION}/pdt
         ${SUDO} chmod go-w /opt/rocmplus-${ROCM_VERSION}/scorep
      fi

      module unload rocm/${ROCM_VERSION}

   fi   

   # Create a module file for SCORE-P
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/8.4.lua
	whatis(" Score-P Performance Analysis Tool ")

        load("rocm/${ROCM_VERSION}")
	prepend_path("PATH","${SCOREP_PATH}/bin")
EOF

fi

