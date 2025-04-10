#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mpi4py
BUILD_MPI4PY=0
ROCM_VERSION=6.0
MPI_PATH="/usr"
SUDO="sudo"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

LOAD_MODULE="openmpi"

usage()
{
   echo "Usage:"
   echo "  --build-mpi4py: default is 0"
   echo "  --load-module [ LOAD_MODULE ] default is ""openmpi"" module"
   echo "  --module-path [ MODULE_PATH ] default /etc/lmod/modules/ROCmPlus-MPI/mpi4py"
   echo "  --mpi-path [MPI_PATH] default is from MPI module"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
          ;;
      "--build-mpi4py")
          shift
          BUILD_MPI4PY=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--load-module")
          shift
          LOAD_MODULE=${1}
          reset-last
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
      "--mpi-path")
          shift
          MPI_PATH=${1}
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
echo "Starting MPI4PY Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_MPI4PY: $BUILD_MPI4PY"
echo "==================================="
echo ""

if [ "${BUILD_MPI4PY}" = "0" ]; then

   echo "MPI4PY will not be built, according to the specified value of BUILD_MPI4PY"
   echo "BUILD_MPI4PY: $BUILD_MPI4PY"
   exit 

else
   MPI4PY_PATH=/opt/rocmplus-${ROCM_VERSION}/mpi4py
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/mpi4py.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached MPI4PY"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/mpi4py.tgz
      chown -R root:root ${MPI4PY_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/mpi4py.tgz
      fi

   else

      echo ""
      echo "============================"
      echo " Building MPI4PY"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load ${LOAD_MODULE}
      module load rocm/${ROCM_VERSION}

      ${SUDO} mkdir -p ${MPI4PY_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${MPI4PY_PATH}
      fi

      git clone --branch 4.0.3 https://github.com/mpi4py/mpi4py.git
      cd mpi4py

      echo "[model]              = ${MPI_PATH}" >> mpi.cfg
      echo "mpi_dir              = ${MPI_PATH}" >> mpi.cfg
      echo "mpicc                = ${MPI_PATH}"/bin/mpicc >> mpi.cfg
      echo "mpic++               = ${MPI_PATH}"/bin/mpic++ >> mpi.cfg
      echo "library_dirs         = %(mpi_dir)s/lib" >> mpi.cfg
      echo "include_dirs         = %(mpi_dir)s/include" >> mpi.cfg

      CC=${ROCM_PATH}/bin/amdclang CXX=${ROCM_PATH}/bin/amdclang++ python3 setup.py build --mpi=model
      CC=${ROCM_PATH}/bin/amdclang CXX=${ROCM_PATH}/bin/amdclang++ python3 setup.py bdist_wheel

      pip3 install -v --target=${MPI4PY_PATH} dist/mpi4py-*.whl

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${MPI4PY_PATH} -type f -execdir chown root:root "{}" +
         ${SUDO} find ${MPI4PY_PATH} -type d -execdir chown root:root "{}" +

	 ${SUDO} chmod go-w ${MPI4PY_PATH}
      fi

      # cleanup
      cd ..
      ${SUDO} rm -rf mpi4py
      module unload rocm/${ROCM_VERSION}

   fi   


   # Create a module file for mpi4py
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/4.0.3.lua
	whatis(" MPI4PY - provides Python bindings for MPI")

        prepend_path("PYTHONPATH", "${MPI4PY_PATH}")
	load("${LOAD_MODULE}")
EOF

fi

