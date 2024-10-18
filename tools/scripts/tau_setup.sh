#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/tau
BUILD_TAU=0
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
   echo "  --build-tau: default is 0"
   echo "  --module-path [ MODULE_PATH ] default /etc/lmod/modules/misc/tau"
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
      "--build-tau")
          shift
          BUILD_TAU=${1}
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
echo "Starting TAU Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_TAU: $BUILD_TAU"
echo "==================================="
echo ""

CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}

if [ "${BUILD_TAU}" = "0" ]; then

   echo "TAU will not be build, according to the specified value of BUILD_TAU"
   echo "BUILD_TAU: $BUILD_TAU"
   exit 

else
   if [ -f ${CACHE_FILES}/tau.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached TAU"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/tau.tgz
      if [ "${USER}" != "root" ]; then
         chown -R root:root /opt/rocmplus-${ROCM_VERSION}/tau
      fi
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm /CacheFiles/tau.tgz
      fi

   else

      echo ""
      echo "============================"
      echo " Building TAU"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}

      TAU_PATH=/opt/rocmplus-${ROCM_VERSION}/tau
      PDT_PATH=/opt/rocmplus-${ROCM_VERSION}/pdt
      export TAU_LIB_DIR=${TAU_PATH}/x86_64/lib
      echo 'Defaults:%sudo env_keep += "TAU_LIB_DIR"' | ${SUDO} EDITOR='tee -a' visudo
      ${SUDO} mkdir -p ${TAU_PATH}
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
	 ${SUDO} chmod -R a+rwX /opt/rocmplus-${ROCM_VERSION}/pdt
      fi

      # install PDT with spack
      spack install pdt

      # get PDT install dir created by spack
      PDT_PATH=`spack find -p pdt | awk '{print $2}' | grep opt`

      # cloning the latest version of TAU
      git clone https://github.com/UO-OACISS/tau2.git
      cd tau2

      # install third pary dependencies
      wget http://tau.uoregon.edu/ext.tgz

      ${SUDO} tar zxf ext.tgz

      # install OpenMPI if not in the system already
      if [[ `which mpicc | wc -l` -eq 0 ]]; then
         ${SUDO} apt-get update
         ${SUDO} apt-get install -q -y libopenmpi-dev
      fi

      # install java to use paraprof
      ${SUDO} apt-get update
      ${SUDO} apt install -q -y default-jre

      # configure with: MPI OMPT OPENMP PDT ROCM
      ${SUDO} ./configure -c++=g++ -fortran=gfortran -cc=gcc -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  -rocm=${ROCM_PATH} -rocprofiler=${ROCM_PATH} -hip=${ROCM_PATH} -mpi -ompt -openmp -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -pdt=${PDT_PATH} -iowrapper

      ${SUDO} make install

      # configure with: MPI PDT ROCM
      ${SUDO} ./configure -c++=g++ -fortran=gfortran -cc=gcc -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  -rocm=${ROCM_PATH} -rocprofiler=${ROCM_PATH} -hip=${ROCM_PATH} -mpi -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -pdt=${PDT_PATH} -iowrapper

      ${SUDO} make install

      # configure with: OMPT OPENMP PDT ROCM
      ${SUDO} ./configure -c++=g++ -fortran=gfortran -cc=gcc -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  -rocm=${ROCM_PATH} -rocprofiler=${ROCM_PATH} -hip=${ROCM_PATH} -ompt -openmp -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -pdt=${PDT_PATH} -iowrapper

      ${SUDO} make install

      # configure with: PDT ROCM
      ${SUDO} ./configure -c++=g++ -fortran=gfortran -cc=gcc -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  -rocm=${ROCM_PATH} -rocprofiler=${ROCM_PATH} -hip=${ROCM_PATH} -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -pdt=${PDT_PATH} -iowrapper

      ${SUDO} make install

      # configure with: ROCM
      ${SUDO} ./configure -c++=g++ -fortran=gfortran -cc=gcc -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  -rocm=${ROCM_PATH} -rocprofiler=${ROCM_PATH} -hip=${ROCM_PATH} -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -iowrapper

      ${SUDO} make install

      # configure with: OMPT OPENMP ROCM
      ${SUDO} ./configure -c++=g++ -fortran=gfortran -cc=gcc -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  -rocm=${ROCM_PATH} -rocprofiler=${ROCM_PATH} -hip=${ROCM_PATH} -ompt -openmp -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -iowrapper

      ${SUDO} make install

      # configure with: MPI ROCM
      ${SUDO} ./configure -c++=g++ -fortran=gfortran -cc=gcc -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  -rocm=${ROCM_PATH} -rocprofiler=${ROCM_PATH} -hip=${ROCM_PATH} -mpi -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH} -iowrapper

      ${SUDO} make install

      # configure with: MPI OMPT OPENMP ROCM
      ${SUDO} ./configure -c++=g++ -fortran=gfortran -cc=gcc -prefix=${TAU_PATH} -zlib=download -otf=download -unwind=download -bfd=download  -rocm=${ROCM_PATH} -rocprofiler=${ROCM_PATH} -hip=${ROCM_PATH} -mpi -ompt -openmp -rocmsmi=${ROCM_PATH} -roctracer=${ROCM_PATH}  -iowrapper

      ${SUDO} make install

      # the configure flag -no_pthread_create
      # still creates linking options for the pthread wrapper
      # that are breaking the instrumentation tests in C and C++
      ${SUDO} rm ${TAU_PATH}/x86_64/lib/wrappers/pthread_wrapper/link_options.tau

      cd ..
      ${SUDO} rm -rf tau2
      ${SUDO} rm -rf spack

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find /opt/rocmplus-${ROCM_VERSION}/pdt -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w /opt/rocmplus-${ROCM_VERSION}/pdt
      fi

      module unload rocm/${ROCM_VERSION}

   fi   

   # Create a module file for TAU
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/dev.lua
	whatis(" TAU - portable profiling and tracing toolkit ") 

        load("rocm/${ROCM_VERSION}")
	prepend_path("PATH","${TAU_PATH}/x86_64/bin")
	setenv("TAU_LIB_DIR","${TAU_LIB_DIR}")
EOF

fi

