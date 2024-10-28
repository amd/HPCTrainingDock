#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/hdf5
BUILD_HDF5=0
ROCM_VERSION=6.0
C_COMPILER=gcc
CXX_COMPILER=g++
FC_COMPILER=gfortran
HDF5_VERSION=1.14.5

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  --module-path [ MODULE_PATH ] default /etc/lmod/modules/misc/kokkos"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hdf5-version [ HDF5_VERSION ] default $HDF5_VERSIONS"
   echo "  --c-compiler [ CC ] default ${C_COMPILER}"
   echo "  --cxx-compiler [ CXX ] default ${CXX_COMPILER}"
   echo "  --fc-compiler [ FC ] default ${FC_COMPILER}"
   echo "  --build-hdf5 [ BUILD_HDF5 ], set to 1 to build HDF5, default is 0"
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
      "--build-hdf5")
          shift
          BUILD_HDF5=${1}
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

echo ""
echo "==================================="
echo "Starting HDF5 Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HDF5: $BUILD_HDF5"
echo "==================================="
echo ""

if [ "${BUILD_HDF5}" = "0" ]; then

   echo "HDF5 will not be built, according to the specified value of BUILD_HDF5"
   echo "BUILD_HDF5: $BUILD_HDF5"
   exit 

else
   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/hdf5.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HDF5"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/hdf5.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hdf5
      ${SUDO} rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/hdf5.tgz

   else
      echo ""
      echo "============================"
      echo " Building HDF5"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh

      HDF5_PATH=/opt/rocmplus-${ROCM_VERSION}/hdf5
      ${SUDO} mkdir -p ${HDF5_PATH}

      git clone --branch hdf5_${HDF5_VERSION} https://github.com/HDFGroup/hdf5.git
      cd hdf5

      # install dependencies

      # get ZLIB
      wget https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
      tar zxf zlib-1.3.1.tar.gz
      ${SUDO} mkdir -p ${HDF5_PATH}/zlib
      cd zlib-1.3.1
      ${SUDO} ./configure --prefix=${HDF5_PATH}/zlib
      ${SUDO} make install

      # get LIBAEC -- support for szip library is currently broken: https://github.com/HDFGroup/hdf5/issues/4614
      #wget https://github.com/MathisRosenhauer/libaec/releases/download/v1.1.3/libaec-1.1.3.tar.gz
      #tar zxf libaec-1.1.3.tar.gz
      #${SUDO} mkdir -p ${HDF5_PATH}/libaec
      #cd libaec-1.1.3
      #${SUDO} ./configure --prefix=${HDF5_PATH}/libaec
      #${SUDO} make install

      # default build is parallel hdf5
      ENABLE_PARALLEL="OFF"
      module load openmpi
      if [[ `which mpicc | wc -l` -eq 1 ]]; then
	 # if no mpi is found in the path, fall back to serial hdf5
         ENABLE_PARALLEL="ON"
      fi

      cd ..
      mkdir build && cd build

      ${SUDO} cmake -G "Unix Makefiles" -DCMAKE_BUILD_TYPE:STRING=Release \
                                        -DBUILD_SHARED_LIBS:BOOL=OFF -DBUILD_TESTING:BOOL=ON \
  	 			        -DHDF5_BUILD_TOOLS:BOOL=ON -DCMAKE_INSTALL_PREFIX=${HDF5_PATH} \
                                        -DZLIB_ROOT=${HDF5_PATH}/zlib \
                                        -DCMAKE_CXX_COMPILER=${CXX_COMPILER} \
                                        -DCMAKE_C_COMPILER=${C_COMPILER} \
                                        -DCMAKE_FC_COMPILER=${FC_COMPILER} \
					-DHDF5_ENABLE_PARALLEL:BOOL=${ENABLE_PARALLEL} ..

      ${SUDO} cmake --build . --config Release

      ${SUDO} cpack -C Release CPackConfig.cmake

      ${SUDO} ./HDF5-${HDF5_VERSION}-Linux.sh --prefix=${HDF5_PATH} --skip-license

      cd ..
      ${SUDO} rm -rf hdf5

   fi

   # Create a module file for hdf5
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${HDF5_VERSION}.lua
	whatis("HDF5 Data Model")

        local base = "${HDF5_PATH}/HDF_Group/HDF5/${HDF5_VERSION}"
        prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
        prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("PATH", pathJoin(base, "bin"))
EOF

fi
