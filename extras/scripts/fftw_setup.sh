#/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/ROCmPlus/fftw
BUILD_FFTW=0
ROCM_VERSION=6.0
C_COMPILER=`which gcc`
C_COMPILER_INPUT=""
CXX_COMPILER=`which g++`
CXX_COMPILER_INPUT=""
FC_COMPILER=`which gfortran`
FC_COMPILER_INPUT=""
ENABLE_MPI_INPUT=""
FFTW_VERSION=3.3.10
MPI_MODULE="openmpi"
FFTW_PATH=/opt/rocmplus-${ROCM_VERSION}/fftw-v$FFTW_VERSION
FFTW_PATH_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --fftw-version [ FFTW_VERSION ] default $FFTW_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --enable-mpi [ ENABLE_MPI ], set to 1 to enable, enabled by default if MPI is installed"
   echo "  --install-path [ FFTW_PATH ] default $FFTW_PATH"
   echo "  --c-compiler [ C_COMPILER ] default ${C_COMPILER}"
   echo "  --cxx-compiler [ CXX_COMPILER ] default ${CXX_COMPILER}"
   echo "  --fc-compiler [ FC_COMPILER ] default ${FC_COMPILER}"
   echo "  --build-fftw [ BUILD_FFTW ], set to 1 to build FFTW, default is 0"
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
      "--build-fftw")
          shift
          BUILD_FFTW=${1}
          reset-last
          ;;
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
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
          FFTW_PATH_INPUT=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--enable-mpi")
          shift
          ENABLE_MPI_INPUT=${1}
          reset-last
          ;;
      "--c-compiler")
          shift
          C_COMPILER=${1}
          reset-last
          ;;
      "--cxx-compiler")
          shift
          CXX_COMPILER=${1}
          reset-last
          ;;
      "--fc-compiler")
          shift
          FC_COMPILER=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--fftw-version")
          shift
          FFTW_VERSION=${1}
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

if [ "${FFTW_PATH_INPUT}" != "" ]; then
   FFTW_PATH=${FFTW_PATH_INPUT}
else
   # override path in case FFTW_VERSION has been supplied as input
   INSTALL_PATH=/opt/rocmplus-${ROCM_VERSION}/fftw-v${FFTW_VERSION}
fi


if [ "${BUILD_FFTW}" = "0" ]; then

   echo "FFTW will not be built, according to the specified value of BUILD_FFTW"
   echo "BUILD_FFTW: $BUILD_FFTW"
   echo "Make sure to set '--build-fftw 1' when running this install script"
   exit

else

   echo ""
   echo "==============================="
   echo " Installing FFTW"
   echo " Install directory: $FFTW_PATH"
   echo " Module directory: $MODULE_PATH"
   echo " FFTW Version: $FFTW_VERSION"
   echo " ROCm Version: $ROCM_VERSION"
   echo "==============================="
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   # Should remove ROCM_VERSION from script
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

   if [ -f ${CACHE_FILES}/fftw-v${FFTW_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached FFTW"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xzf  ${CACHE_FILES}/fftw-v${FFTW_VERSION}.tgz
      chown -R root:root /opt/fftw-v${FFTW_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm  ${CACHE_FILES}/fftw-v${FFTW_VERSION}.tgz
      fi

   else
      echo ""
      echo "==============================="
      echo " Installing FFTW from source"
      echo "==============================="
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh

      if [ -d "$FFTW_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${FFTW_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${FFTW_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${FFTW_PATH}
      fi

      # default build is without mpi
      ENABLE_MPI=""
      module load ${MPI_MODULE}
      if [[ `which mpicc | wc -l` -eq 1 ]]; then
	 # if mpi is found in the path, build fftw parallel
         ENABLE_MPI="--enable-mpi"
      fi

      # override flags with user defined values if present
      if [ "${ENABLE_MPI_INPUT}" == "1" ]; then
         ENABLE_MPI="--enable-mpi"
      fi

      wget -q https://www.fftw.org/fftw-${FFTW_VERSION}.tar.gz
      tar zxf fftw-${FFTW_VERSION}.tar.gz
      cd fftw-${FFTW_VERSION}

      # configure for double precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-sse2 --enable-avx --enable-avx2
      make install

      # configure for single precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-sse2 --enable-avx --enable-avx2 --enable-float
      make install

      # configure for long double precision
      ./configure --prefix=${FFTW_PATH} \
	          --enable-shared --enable-static --enable-threads --enable-openmp \
		  ${ENABLE_MPI} --enable-threads --enable-long-double
      make install

      cd ..
      rm -rf fftw-${FFTW_VERSION} fftw-${FFTW_VERSION}.tar.gz

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${FFTW_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${FFTW_PATH} -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w ${FFTW_PATH}
      fi

   fi

   # Create a module file for fftw
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${FFTW_VERSION}.lua
	whatis("FFTW: Fastest Fourier Transform in the West")

	local base = "${FFTW_PATH}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	setenv("FFTW_PATH", base)
	prepend_path("PATH", pathJoin(base, "bin"))
EOF

fi

