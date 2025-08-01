#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus/scorep
BUILD_SCOREP=0
ROCM_VERSION=6.0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"
MPI_MODULE="openmpi"
MPI_CONFIG=""
SCOREP_VERSION=9.0
SCOREP_PATH=/opt/rocmplus-${ROCM_VERSION}/scorep
PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
SCOREP_PATH_INPUT=""
PDT_PATH_INPUT=""

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
   echo "  WARNING: when specifying --scorep-install-path, --pdt-install-path  and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-scorep: set to 1 to build Score-P, default is 0"
   echo "  --scorep-version [SCOREP_VERSION] default is $SCOREP_VERSION "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --scorep-install-path [ SCOREP_PATH_INPUT ] default $SCOREP_PATH "
   echo "  --pdt-install-path [ PDT_PATH_INPUT ] default $PDT_PATH "
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE "
   echo "  --mpi-config [ MPI_CONFIG ] what to pass to --with-mpi= when configuring score-p, default is $MPI_MODULE "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected "
   echo "  --help: print this usage information"
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
      "--scorep-version")
          shift
          SCOREP_VERSION=${1}
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
      "--scorep-install-path")
          shift
          SCOREP_PATH_INPUT=${1}
          reset-last
          ;;
      "--pdt-install-path")
          shift
          PDT_PATH_INPUT=${1}
          reset-last
          ;;
     "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
     "--mpi-config")
          shift
          MPI_CONFIG=${1}
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

if [ "${SCOREP_PATH_INPUT}" != "" ]; then
   SCOREP_PATH=${SCOREP_PATH_INPUT}
else
   # override score-p path in case ROCM_VERSION has been supplied as input
   SCOREP_PATH=/opt/rocmplus-${ROCM_VERSION}/scorep
fi

if [ "${PDT_PATH_INPUT}" != "" ]; then
   PDT_PATH=${PDT_PATH_INPUT}
else
   # override pdt path in case ROCM_VERSION has been supplied as input
   PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
fi

echo ""
echo "==================================="
echo "Starting SCORE-P Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_SCOREP: $BUILD_SCOREP"
echo "SCOREP_PATH: $SCOREP_PATH"
echo "PDT_PATH: $PDT_PATH"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_SCOREP}" = "0" ]; then

   echo "SCORE-P will not be built, according to the specified value of BUILD_SCOREP"
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
      tar -xpzf ${CACHE_FILES}/scorep.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CacheFiles}/scorep.tgz
      fi

   else

      echo ""
      echo "==============================="
      echo "        Building SCORE-P       "
      echo "==============================="
      echo ""

      CUR_DIR=`pwd`

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}
      module load amdflang-new
      if [[ `which amdflang-new | wc -l` -eq 0 ]]; then
         # if amdflang-new is not found in the path
         # build with compilers from ROCm
         module load amdclang
      fi


     # don't use sudo if user has write access to both install paths
      if [ -d "$SCOREP_PATH" ]; then
         if [ -d "$PDT_PATH" ]; then
            # don't use sudo if user has write access to both install paths
            if [ -w ${SCOREP_PATH} ]; then
               if [ -w ${PDT_PATH} ]; then
                  SUDO=""
                  echo "WARNING: not using sudo since user has write access to install path, if no $MPI_MODULE module is found MPI will not be installed"
               else
                  echo "WARNING: using install paths that require sudo"
               fi
            fi
         fi
      else
         # if install paths do not both exist yet
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${SCOREP_PATH}
      ${SUDO} mkdir -p ${PDT_PATH}

      git clone https://github.com/spack/spack.git

      # load spack environment
      source spack/share/spack/setup-env.sh

      # find already installed libs for spack
      spack external find

      # change spack install dir for PDT
      sed -i 's|$spack/opt/spack|'"${PDT_PATH}"'|g' spack/etc/spack/defaults/config.yaml

      # open permissions to use spack to install PDT
      if [[ "${USER}" != "root" ]]; then
	 ${SUDO} chmod -R a+rwX ${PDT_PATH}
	 ${SUDO} chmod -R a+rwX ${SCOREP_PATH}
      fi

      # install PDT with spack
      spack install pdt

      # get PDT install dir created by spack
      PDT_PATH_ORIGINAL=$PDT_PATH
      PDT_PATH=`spack find -p pdt | awk '{print $2}' | grep opt`
      export PATH=$PDT_PATH/bin:$PATH

      # install OpenMPI if not in the system already
      module load ${MPI_MODULE}
      if [[ `which mpicc | wc -l` -eq 0 ]]; then
         if [[ ${SUDO} != "" ]]; then
            ${SUDO} apt-get update
            ${SUDO} ${DEB_FRONTEND} apt-get install -q -y libopenmpi-dev
         else
            echo "WARNING: module for ${MPI_MODULE} not found, and did not install libopenmpi-dev due to not having sudo"
         fi
      fi

      if [[ $MPI_CONFIG == "" ]]; then
         if [[ $MPI_MODULE == "openmpi" ]]; then
            MPI_CONFIG="openmpi"
         elif [[ $MPI_MODULE == "cray-mpich" ]]; then
            MPI_CONFIG="cray"
         elif [[ $MPI_MODULE == "mpich" ]]; then
            MPI_CONFIG="mpich"
         else
            echo " ERROR: --mpi-config not specified at input and not detected through $MPI_MODULE module"
            exit 1
         fi
      fi

      wget https://perftools.pages.jsc.fz-juelich.de/cicd/scorep/tags/scorep-${SCOREP_VERSION}/scorep-${SCOREP_VERSION}.tar.gz
      tar -xvf scorep-${SCOREP_VERSION}.tar.gz
      cd scorep-${SCOREP_VERSION}
      mkdir build
      cd build
      ../configure --with-rocm=$ROCM_PATH  --with-mpi=$MPI_CONFIG  --prefix=$SCOREP_PATH  --with-librocm_smi64-include=$ROCM_PATH/include/rocm_smi \
                   --with-librocm_smi64-lib=$ROCM_PATH/lib --with-libunwind=download --enable-shared --with-libbfd=download --without-shmem  \
		   --with-libgotcha=download CC=$CC CXX=$CXX FC=$FC CFLAGS=-fPIE

      make
      ${SUDO} make install

      cd ${CUR_DIR}
      rm -rf scorep-${SCOREP_VERSION}*
      rm -rf spack

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $PDT_PATH_ORIGINAL -type f -execdir chown root:root "{}" +
         ${SUDO} find $SCOREP_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} chmod go-w $PDT_PATH_ORIGINAL
         ${SUDO} chmod go-w $SCOREP_PATH
      fi

      module unload rocm/${ROCM_VERSION}
      module unload amdclang
      module unload amdflang-new
      module unload ${MPI_MODULE}

   fi

   # Create a module file for SCORE-P
   if [ -d "$MODULE_PATH" ]; then
      # use sudo if user does not have write access to module path
      if [ ! -w ${MODULE_PATH} ]; then
         SUDO="sudo"
      else
         echo "WARNING: not using sudo since user has write access to module path"
      fi
   else
      # if module path dir does not exist yet, the check on write access will fail
      SUDO="sudo"
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${SCOREP_VERSION}.lua
	whatis(" Score-P Performance Analysis Tool ")

	load("rocm/${ROCM_VERSION}")
	prepend_path("PATH","${SCOREP_PATH}/bin")
	prepend_path("PATH","${PDT_PATH}/bin")
EOF

fi

