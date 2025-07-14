#/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/LinuxPlus/hdf5
BUILD_HDF5=0
ROCM_VERSION=6.0
C_COMPILER=`which gcc`
C_COMPILER_INPUT=""
CXX_COMPILER=`which g++`
CXX_COMPILER_INPUT=""
FC_COMPILER=`which gfortran`
FC_COMPILER_INPUT=""
ENABLE_PARALLEL_INPUT=""
HDF5_VERSION=1.14.6
MPI_MODULE="openmpi"
HDF5_PATH=/opt/hdf5-v${HDF5_VERSION}
HDF5_PATH_INPUT=""

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
   echo "  --hdf5-version [ HDF5_VERSION ] default $HDF5_VERSION"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --mpi-module [ MPI_MODULE ] default $MPI_MODULE"
   echo "  --enable-parallel [ ENABLE_PARALLEL ], set to ON or OFF, ON by default if MPI is installed"
   echo "  --install-path [ HDF5_PATH ] default $HDF5_PATH"
   echo "  --c-compiler [ C_COMPILER ] default ${C_COMPILER}"
   echo "  --cxx-compiler [ CXX_COMPILER ] default ${CXX_COMPILER}"
   echo "  --fc-compiler [ FC_COMPILER ] default ${FC_COMPILER}"
   echo "  --build-hdf5 [ BUILD_HDF5 ], set to 1 to build HDF5, default is 0"
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
      "--build-hdf5")
          shift
          BUILD_HDF5=${1}
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
          HDF5_PATH_INPUT=${1}
          reset-last
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--enable-parallel")
          shift
          ENABLE_PARALLEL_INPUT=${1}
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
      "--hdf5-version")
          shift
          HDF5_VERSION=${1}
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

if [ "${HDF5_PATH_INPUT}" != "" ]; then
   HDF5_PATH=${HDF5_PATH_INPUT}
else
   # override path in case HDF5_VERSION has been supplied as input
   HDF5_PATH=/opt/hdf5-v${HDF5_VERSION}
fi

if [ "${BUILD_HDF5}" = "0" ]; then

   echo "HDF5 will not be built, according to the specified value of BUILD_HDF5"
   echo "BUILD_HDF5: $BUILD_HDF5"
   echo "Make sure to set '--build-hdf5 1' when running this install script"
   exit

else

   echo ""
   echo "==============================="
   echo " Installing HDF5"
   echo " Install directory: $HDF5_PATH"
   echo " Module directory: $MODULE_PATH"
   echo " HDF5 Version: $HDF5_VERSION"
   echo " ROCm Version: $ROCM_VERSION"
   echo "==============================="
   echo ""

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/hdf5.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HDF5"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xzf  ${CACHE_FILES}/hdf5.tgz
      chown -R root:root /opt/hdf5
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/hdf5.tgz
      fi

   else
      echo ""
      echo "==============================="
      echo " Installing HDF5 from source"
      echo "==============================="
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh

      # don't use sudo if user has write access to install path
      if [ -d "$HDF5_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${HDF5_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${HDF5_PATH}
      ${SUDO} mkdir -p ${HDF5_PATH}/zlib
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${HDF5_PATH}
      fi

      git clone --branch hdf5_${HDF5_VERSION} https://github.com/HDFGroup/hdf5.git
      cd hdf5

      # install dependencies

      # get ZLIB
      wget https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
      tar zxf zlib-1.3.1.tar.gz
      cd zlib-1.3.1
      ./configure --prefix=${HDF5_PATH}/zlib
      make install

      # get LIBAEC -- support for szip library is currently broken: https://github.com/HDFGroup/hdf5/issues/4614
      #wget https://github.com/MathisRosenhauer/libaec/releases/download/v1.1.3/libaec-1.1.3.tar.gz
      #tar zxf libaec-1.1.3.tar.gz
      #${SUDO} mkdir -p ${HDF5_PATH}/libaec
      #cd libaec-1.1.3
      #${SUDO} ./configure --prefix=${HDF5_PATH}/libaec
      #${SUDO} make install

      # default build is serial hdf5
      ENABLE_PARALLEL="OFF"
      module load ${MPI_MODULE}
      if [[ `which mpicc | wc -l` -eq 1 ]]; then
	 # if mpicc is found in the path, build hdf5 parallel
         ENABLE_PARALLEL="ON"
	 C_COMPILER=`which mpicc`
	 CXX_COMPILER=`which mpicxx`
	 FC_COMPILER=`which mpifort`
      fi

      # override flags with user defined values if present
      if [ "${ENABLE_PARALLEL_INPUT}" != "" ]; then
         ENABLE_PARALLEL=${ENABLE_PARALLEL_INPUT}
      fi
      if [ "${C_COMPILER_INPUT}" != "" ]; then
         C_COMPILER=${C_COMPILER_INPUT}
      fi
      if [ "${CXX_COMPILER_INPUT}" != "" ]; then
         CXX_COMPILER=${CXX_COMPILER_INPUT}
      fi
      if [ "${FC_COMPILER_INPUT}" != "" ]; then
         FC_COMPILER=${FC_COMPILER_INPUT}
      fi

      cd ..
      mkdir build && cd build

      cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE:STRING=Release \
  			        -DHDF5_BUILD_TOOLS:BOOL=ON -DCMAKE_INSTALL_PREFIX=${HDF5_PATH} \
                                -DZLIB_ROOT=${HDF5_PATH}/zlib \
				-DHDF5_ENABLE_SZIP_SUPPORT:BOOL=OFF \
                                -DCMAKE_CXX_COMPILER=${CXX_COMPILER} \
                                -DCMAKE_C_COMPILER=${C_COMPILER} \
				-DCMAKE_Fortran_COMPILER=${FC_COMPILER} \
				-DBUILD_TESTING:BOOL=OFF \
				-DHDF5_ENABLE_PARALLEL:BOOL=${ENABLE_PARALLEL} \
				-DHDF5_BUILD_FORTRAN:BOOL=ON ..


      cmake --build . --config Release

      cpack -C Release CPackConfig.cmake

      ./HDF5-${HDF5_VERSION}-Linux.sh --prefix=${HDF5_PATH} --skip-license

      cd ../..
      rm -rf hdf5

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${HDF5_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${HDF5_PATH} -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w ${HDF5_PATH}
      fi

   fi

   # Create a module file for hdf5
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${HDF5_VERSION}.lua
	whatis("HDF5 Data Model")

	local base = "${HDF5_PATH}/HDF_Group/HDF5/${HDF5_VERSION}"
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	setenv("HDF5_PATH", base)
	setenv("HDF5_ROOT", base)
	setenv("HDF5_C_COMPILER", "${C_COMPILER}")
	setenv("HDF5_FC_COMPILER", "${FC_COMPILER}")
	setenv("HDF5_CXX_COMPILER", "${CXX_COMPILER}")
	setenv("HDF5_ENABLE_PARALLEL", "${ENABLE_PARALLEL}")
	setenv("HDF5_MPI_MODULE", "${MPI_MODULE}")
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("PATH", base)
EOF

fi

