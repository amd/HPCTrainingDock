#!/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus/tau
BUILD_TAU=0
ROCM_VERSION=6.2.0
TAU_PATH=/opt/rocmplus-${ROCM_VERSION}/tau
PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
TAU_PATH_INPUT=""
C_COMPILER=amdclang
CXX_COMPILER=amdclang++
F_COMPILER=gfortran
PDT_PATH_INPUT=""
GIT_COMMIT="23a56e2a1a728e99ff03341c30f9d24892c5952b"
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
 echo "  WARNING: when specifying --tau-install-path, --pdt-install-path  and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-tau: default $BUILD_TAU"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --tau-install-path [ TAU_PATH_INPUT ] default $TAU_PATH"
   echo "  --c-compiler [ C_COMPILER ] default $C_COMPILER"
   echo "  --f-compiler [ F_COMPILER ] default $F_COMPILER"
   echo "  --cxx-compiler [ CXX_COMPILER ] default $CXX_COMPILER"
   echo "  --pdt-install-path [ PDT_PATH_INPUT ] default $PDT_PATH"
   echo "  --git-commit [ GIT_COMMIT ] specify what commit hash you want to build from, default is $GIT_COMMIT"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL_INPUT ] default autodetected"
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
          AMDGPU_GFXMODEL_INPUT=${1}
          reset-last
          ;;
      "--build-tau")
          shift
          BUILD_TAU=${1}
          reset-last
          ;;
      "--git-commit")
          shift
          GIT_COMMIT=${1}
          reset-last
          ;;
      "--c-compiler")
          shift
          C_COMPILER=${1}
          reset-last
          ;;
      "--f-compiler")
          shift
          F_COMPILER=${1}
          reset-last
          ;;
      "--cxx-compiler")
          shift
          CXX_COMPILER=${1}
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
      "--tau-install-path")
          shift
          TAU_PATH_INPUT=${1}
          reset-last
          ;;
      "--pdt-install-path")
          shift
          PDT_PATH_INPUT=${1}
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

if [ "${TAU_PATH_INPUT}" != "" ]; then
   TAU_PATH=${TAU_PATH_INPUT}
else
   # override tau path in case ROCM_VERSION has been supplied as input
   TAU_PATH=/opt/rocmplus-${ROCM_VERSION}/tau
fi

if [ "${PDT_PATH_INPUT}" != "" ]; then
   PDT_PATH=${PDT_PATH_INPUT}
else
   # override pdt path in case ROCM_VERSION has been supplied as input
   PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
fi

if [[ "$AMDGPU_GFXMODEL_INPUT" != "" ]]; then
   AMDGPU_GFXMODEL=$AMDGPU_GFXMODEL_INPUT
else
   AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
fi

echo ""
echo "==================================="
echo "Starting TAU Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_TAU: $BUILD_TAU"
echo "TAU_PATH: $TAU_PATH"
echo "PDT_PATH: $PDT_PATH"
echo "Building TAU off of this commit: $GIT_COMMIT"
echo "==================================="
echo ""


if [ "${BUILD_TAU}" = "0" ]; then

   echo "TAU will not be build, according to the specified value of BUILD_TAU"
   echo "BUILD_TAU: $BUILD_TAU"
   exit

else
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/pdt.tgz ] && [ -f ${CACHE_FILES}/tau.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached TAU"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/pdt.tgz
      tar -xpzf ${CACHE_FILES}/tau.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/pdt.tgz ${CACHE_FILES}/tau.tgz
      fi

   else

      echo ""
      echo "============================"
      echo " Building TAU"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}
      module load amdclang

     # don't use sudo if user has write access to both install paths
      if [ -d "$TAU_PATH" ]; then
         if [ -d "$PDT_PATH" ]; then
            # don't use sudo if user has write access to both install paths
            if [ -w ${TAU_PATH} ]; then
               if [ -w ${PDT_PATH} ]; then
                  SUDO=""
                  echo "WARNING: not using sudo since user has write access to install path, some dependencies may fail to get installed without sudo"
               else
                  echo "WARNING: using install paths that require sudo"
               fi
            fi
         fi
      else
         # if install paths do not both exist yet
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      export TAU_LIB_DIR=${TAU_PATH}/x86_64/lib
      ${SUDO} mkdir -p ${TAU_PATH}
      ${SUDO} mkdir -p ${PDT_PATH}

      git clone https://github.com/spack/spack.git

      # load spack environment
      source spack/share/spack/setup-env.sh

      # find already installed libs for spack
      spack external find --all

      # change spack install dir for PDT
      sed -i 's|$spack/opt/spack|'"${PDT_PATH}"'|g' spack/etc/spack/defaults/base/config.yaml 

      # open permissions to use spack to install PDT
      if [[ "${USER}" != "root" ]]; then
	 ${SUDO} chmod -R a+rwX $PDT_PATH
	 ${SUDO} chmod -R a+rwX $TAU_PATH
      fi

      # install PDT with spack
      spack install pdt

      # get PDT install dir created by spack
      PDT_PATH_ORIGINAL=$PDT_PATH
      PDT_PATH=$(spack location -i pdt)
      export PDTDIR=$PDT_PATH

      # cloning the latest version of TAU
      git clone https://github.com/UO-OACISS/tau2.git
      cd tau2
      git checkout $GIT_COMMIT

      # install third party dependencies
      wget http://tau.uoregon.edu/ext.tgz

      tar zxf ext.tgz

      # install OpenMPI if not in the system already
      module load openmpi
      if [[ `which mpicc | wc -l` -eq 0 ]]; then
         ${SUDO} apt-get update
         ${SUDO} apt-get install -q -y libopenmpi-dev
      fi

      # install java to use paraprof
      ${SUDO} apt-get update
      ${SUDO} apt install -q -y default-jre

      ROCM_FLAGS="-rocm=${ROCM_PATH} -hip=${ROCM_PATH} -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -rocprofiler=${ROCM_PATH}"
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" ]]; then # ROCM_VERSION >= 6.2
         ROCM_FLAGS="-rocm=${ROCM_PATH} -hip=${ROCM_PATH} -rocmsmi=${ROCM_PATH} -rocprofsdk=${ROCM_PATH} -llvm_src=${ROCM_PATH}/llvm/lib/cmake/llvm"
      fi

      # configure with: MPI OMPT OPENMP PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -ompt -openmp -pdt=${PDT_PATH} -iowrapper

      ${SUDO} make install

      # configure with: MPI PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -pdt=${PDT_PATH} -iowrapper

      ${SUDO} make install

      # configure with: OMPT OPENMP PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -ompt -openmp -pdt=${PDT_PATH} -iowrapper

      ${SUDO} make install

      # configure with: PDT ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -pdt=${PDT_PATH} -iowrapper

      ${SUDO} make install

      # configure with: ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -iowrapper

      ${SUDO} make install

      # configure with: OMPT OPENMP ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -ompt -openmp -iowrapper

      ${SUDO} make install

      # configure with: MPI ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  ${ROCM_FLAGS} -mpi -iowrapper

      ${SUDO} make install

      # configure with: MPI OMPT OPENMP ROCM
      ./configure -c++=$CXX_COMPILER -fortran=$F_COMPILER -cc=$C_COMPILER -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download ${ROCM_FLAGS} -mpi -ompt -openmp -iowrapper

      ${SUDO} make install

      # the configure flag -no_pthread_create
      # still creates linking options for the pthread wrapper
      # that are breaking the instrumentation tests in C and C++
      ${SUDO} rm ${TAU_PATH}/x86_64/lib/wrappers/pthread_wrapper/link_options.tau

      cd ..
      rm -rf tau2
      rm -rf spack

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $PDT_PATH_ORIGINAL -type f -execdir chown root:root "{}" +
         ${SUDO} find $PDT_PATH_ORIGINAL -type d -execdir chown root:root "{}" +
         ${SUDO} find $TAU_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $TAU_PATH -type d -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w $PDT_PATH_ORIGINAL
         ${SUDO} chmod go-w $TAU_PATH
      fi

      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for TAU
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/dev.lua
	whatis(" TAU - portable profiling and tracing toolkit ")

	load("rocm/${ROCM_VERSION}")
	prepend_path("PATH","${TAU_PATH}/x86_64/bin")
	prepend_path("PATH","${PDT_PATH}/bin")
	setenv("TAU_LIB_DIR","${TAU_LIB_DIR}")
EOF

fi
