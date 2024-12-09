#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
NETCDF_C_MODULE_PATH=/etc/lmod/modules/misc/netcdf-c
NETCDF_FC_MODULE_PATH=/etc/lmod/modules/misc/netcdf-fortran
BUILD_NETCDF=0
ROCM_VERSION=6.0
C_COMPILER=gcc
C_COMPILER_INPUT=""
CXX_COMPILER=g++
CXX_COMPILER_INPUT=""
FC_COMPILER=gfortran
FC_COMPILER_INPUT=""
NETCDF_C_VERSION="4.9.3-rc1"
NETCDF_FC_VERSION="4.6.2-rc1"
HDF5_MODULE="hdf5"
NETCDF_PATH=/opt/rocmplus-${ROCM_VERSION}/netcdf
NETCDF_PATH_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --netcdf-c-version [ NETCDF_C_VERSION ] default $NETCDF_C_VERSION"
   echo "  --netcdf-fc-version [ NETCDF_FC_VERSION ] default $NETCDF_FC_VERSION"
   echo "  --netcdf-c-module-path [ NETCDF_C_MODULE_PATH ] default $NETCDF_C_MODULE_PATH"
   echo "  --netcdf-fc-module-path [ NETCDF_FC_MODULE_PATH ] default $NETCDF_FC_MODULE_PATH"
   echo "  --hdf5-module [ HDF5_MODULE ] default $HDF5_MODULE"
   echo "  --install-path [ NETCDF_PATH ] default $NETCDF_PATH"
   echo "  --c-compiler [ C_COMPILER ] default ${C_COMPILER}"
   echo "  --cxx-compiler [ CXX_COMPILER ] default ${CXX_COMPILER}"
   echo "  --fc-compiler [ FC_COMPILER ] default ${FC_COMPILER}"
   echo "  --build-netcdf [ BUILD_NETCDF ], set to 1 to build netcdf-c and netcdf-fortran, default is 0"
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
      "--build-netcdf")
          shift
          BUILD_NETCDF=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--netcdf-c-module-path")
          shift
          NETCDF_C_MODULE_PATH=${1}
          reset-last
          ;;
      "--netcdf-fc-module-path")
          shift
          NETCDF_FC_MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          NETCDF_PATH_INPUT=${1}
          reset-last
          ;;
      "--hdf5-module")
          shift
          HDF5_MODULE=${1}
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
      "--netcdf-c-version")
          shift
          NETCDF_C_VERSION=${1}
          reset-last
          ;;
      "--netcdf-fc-version")
          shift
          NETCDF_FC_VERSION=${1}
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

if [ "${NETCDF_PATH_INPUT}" != "" ]; then
   NETCDF_PATH=${NETCDF_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   NETCDF_PATH=/opt/rocmplus-${ROCM_VERSION}/netcdf
fi

if [ "${BUILD_NETCDF}" = "0" ]; then

   echo "NETCDF will not be built, according to the specified value of BUILD_NETCDF"
   echo "BUILD_NETCDF: $BUILD_NETCDF"
   echo "Make sure to set '--build-netcdf 1' when running this install script"
   exit 

else

   echo ""
   echo "==============================================="
   echo " Installing NETCDF"
   echo " Install directory: $NETCDF_PATH"
   echo " Netcdf-c Version: $NETCDF_C_VERSION"
   echo " Netcdf-c Module Directory: $NETCDF_C_MODULE_PATH"
   echo " Netcdf-fortran Version: $NETCDF_FC_VERSION"
   echo " Netcdf-fortran Module Directory: $NETCDF_FC_MODULE_PATH"
   echo " ROCm Version: $ROCM_VERSION"
   echo "==============================================="
   echo ""

   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/netcdf.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached NETCDF"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/netcdf.tgz
      chown -R root:root ${NETCDF_PATH}
      ${SUDO} rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/netcdf.tgz

   else
      echo ""
      echo "================================"
      echo " Installing NETCDF from source"
      echo "================================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh

      # don't use sudo if user has write access to install path
      if [ -w ${NETCDF_PATH} ]; then
         SUDO=""
      fi
      ${SUDO} mkdir -p ${NETCDF_PATH}
      ${SUDO} mkdir -p ${NETCDF_PATH}/netcdf-c
      ${SUDO} mkdir -p ${NETCDF_PATH}/netcdf-fortran
      ${SUDO} mkdir -p ${NETCDF_PATH}/pnetcdf

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${NETCDF_PATH}
      fi

      module load ${HDF5_MODULE}
      if [[ `which h5dump | wc -l` -eq 0 ]]; then
         echo "h5dump was not found in PATH after loading the hdf5 module"
         echo "hdf5 is a requirement for netcdf, please make sure hdf5"
         echo "is installed and present in PATH, then retry"
         exit
      else 
         C_COMPILER=$HDF5_C_COMPILER
         CXX_COMPILER=$HDF5_CXX_COMPILER
         FC_COMPILER=$HDF5_FC_COMPILER
      fi

      # override flags with user defined values if present
      if [ "${C_COMPILER_INPUT}" != "" ]; then
         C_COMPILER=${C_COMPILER_INPUT}
      fi
      if [ "${CXX_COMPILER_INPUT}" != "" ]; then
         CXX_COMPILER=${CXX_COMPILER_INPUT}
      fi
      if [ "${FC_COMPILER_INPUT}" != "" ]; then
         FC_COMPILER=${FC_COMPILER_INPUT}
      fi

      # install libcurl 
      ${SUDO} apt-get update
      ${SUDO} apt-get install libcurl4-gnutls-dev 

      # install pnetcdf
      git clone --branch checkpoint.1.14.0 https://github.com/Parallel-NetCDF/PnetCDF.git
      cd PnetCDF
      autoreconf -i
      ./configure --prefix=${NETCDF_PATH}/pnetcdf MPICC=`which mpicc` MPIF90=`which mpifort`
      ${SUDO} make install
      cd ..

      echo ""
      echo "================================="
      echo " Installing NETCDF-C"
      echo "================================="
      echo ""

      git clone --branch v${NETCDF_C_VERSION} https://github.com/Unidata/netcdf-c.git
      cd netcdf-c 
      mkdir build && cd build

      cmake -DCMAKE_INSTALL_PREFIX=${NETCDF_PATH}/netcdf-c \
	    -DNETCDF_ENABLE_HDF5=ON -DNETCDF_ENABLE_DAP=ON \
	    -DNETCDF_BUILD_UTILITIES=ON -DNETCDF_ENABLE_CDF5=ON \
	    -DNETCDF_ENABLE_TESTS=OFF -DNETCDF_ENABLE_PARALLEL_TESTS=OFF \
	    -DZLIB_INCLUDE_DIR=${HDF5_ROOT}/zlib/include \
	    -DCMAKE_C_FLAGS="-I ${HDF5_ROOT}/include/" \
	    -DCMAKE_C_COMPILER=${C_COMPILER} \
	    -DNETCDF_ENABLE_PNETCDF=ON \
	    -DPNETCDF_LIBRARY=${NETCDF_PATH}/pnetcdf/lib/libpnetcdf.so \
	    -DPNETCDF_INCLUDE_DIR=${NETCDF_PATH}/pnetcdf/include \
	    -DNETCDF_ENABLE_FILTER_SZIP=OFF -DNETCDF_ENABLE_NCZARR=OFF ..

      make install

      cd ../..

      # put netcdf-c install path in PATH for netcdf-fortran install
      export PATH=${NETCDF_PATH}/netcdf-c:$PATH
      export HDF5_PLUGIN_PATH=${NETCDF_PATH}/netcdf-c/hdf5/lib/plugin/

      git clone --branch v${NETCDF_FC_VERSION} https://github.com/Unidata/netcdf-fortran.git
      cd netcdf-fortran

      # netcdf-fortran is looking for nc_def_var_szip even if SZIP is OFF
      LINE=`sed -n '/if (NOT HAVE_DEF_VAR_SZIP)/=' CMakeLists.txt | grep -n ""`
      LINE=`echo ${LINE} | cut -c 3-`
      sed -i ''"${LINE}"'i set(HAVE_DEF_VAR_SZIP TRUE)' CMakeLists.txt

      mkdir build && cd build
      cmake -DCMAKE_INSTALL_PREFIX=${NETCDF_PATH}/netcdf-fortran \
	    -DENABLE_TESTS=OFF -DBUILD_EXAMPLES=OFF \
	    -DCMAKE_Fortran_COMPILER=$FC_COMPILER ..

      make install

      cd ../..
      rm -rf netcdf-c 
      rm -rf netcdf-fortran
      ${SUDO} rm -rf PnetCDF

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${NETCDF_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${NETCDF_PATH} -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w ${NETCDF_PATH}
      fi

   fi

   # Create a module file for netcdf-c
   if [ ! -w ${NETCDF_C_MODULE_PATH} ]; then
      SUDO="sudo"
   else
     SUDO=""
   fi
   ${SUDO} mkdir -p ${NETCDF_C_MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${NETCDF_C_MODULE_PATH}/${NETCDF_C_VERSION}.lua
	whatis("Netcdf-c Library")

        load("hdf5")
        local base = "${NETCDF_PATH}/netcdf-c"
        local base_pnetcdf = "${NETCDF_PATH}/pnetcdf"
        prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
        prepend_path("LD_LIBRARY_PATH", pathJoin(base_pnetcdf, "lib"))
        prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("PATH", pathJoin(base, "bin"))
        prepend_path("PATH", base)
        prepend_path("PATH", pathJoin(base_pnetcdf, "bin"))
	setenv("NETCDF_C_ROOT", base)
	setenv("PNETCDF_ROOT", base_pnetcdf)
EOF

   # Create a module file for netcdf-fortran
   if [ ! -w ${NETCDF_FC_MODULE_PATH} ]; then
      SUDO="sudo"
   else
     SUDO=""
   fi
   ${SUDO} mkdir -p ${NETCDF_FC_MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${NETCDF_FC_MODULE_PATH}/${NETCDF_FC_VERSION}.lua
	whatis("Netcdf-fortan Library")

        load("hdf5")
        local base = "${NETCDF_PATH}/netcdf-fortran"
        local base_pnetcdf = "${NETCDF_PATH}/pnetcdf"
        prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
        prepend_path("LD_LIBRARY_PATH", pathJoin(base_pnetcdf, "lib"))
        prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
        prepend_path("PATH", pathJoin(base, "bin"))
        prepend_path("PATH", base)
        prepend_path("PATH", pathJoin(base_pnetcdf, "bin"))
	setenv("NETCDF_FC_ROOT", base)
	setenv("PNETCDF_ROOT", base_pnetcdf)
EOF

fi

