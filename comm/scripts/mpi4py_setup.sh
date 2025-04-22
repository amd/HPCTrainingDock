#/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.0
AMDGPU_GFXMODEL_INPUT=""
MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mpi4py
BUILD_MPI4PY=0
MPI4PY_VERSION=4.0.3
MPI4PY_PATH=/opt/rocmplus-${ROCM_VERSION}/mpi4py
MPI4PY_PATH_INPUT=""
MPI_PATH="/usr"
MPI_MODULE="openmpi"
SUDO="sudo"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-mpi4py [ BUILD_MPI4PY ] default is $BUILD_MPI4PY"
   echo "  --mpi-module [ MPI_MODULE ] default is $MPI_MODULE "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
   echo "  --install-path [ MPI4PY_PATH_INPUT ] default $MPI4PY_PATH "
   echo "  --mpi4py-version [ MPI4PY_VERSION ] default is $MPI4PY_VERSION "
   echo "  --mpi-path [MPI_PATH] default is from MPI module"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
          ;;
      "--build-mpi4py")
          shift
          BUILD_MPI4PY=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--mpi-module")
          shift
          MPI_MODULE=${1}
          reset-last
          ;;
      "--mpi4py-version")
          shift
          MPI4PY_VERSION=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--install-path")
          shift
          MPI4PY_PATH_INPUT=${1}
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

if [ "${MPI4PY_PATH_INPUT}" != "" ]; then
   MPI4PY_PATH=${MPI4PY_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   MPI4PY_PATH=/opt/rocmplus-${ROCM_VERSION}/mpi4py
fi

echo ""
echo "==================================="
echo "Starting MPI4PY Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_MPI4PY: $BUILD_MPI4PY"
echo "MPI4PY_VERSION: $MPI4PY_VERSION"
echo "MPI4PY_PATH: $MPI4PY_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Loading MPI module: $MPI_MODULE"
echo "==================================="
echo ""

if [ "${BUILD_MPI4PY}" = "0" ]; then

   echo "MPI4PY will not be built, according to the specified value of BUILD_MPI4PY"
   echo "BUILD_MPI4PY: $BUILD_MPI4PY"
   exit

else
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
      module load ${MPI_MODULE}
      module load rocm/${ROCM_VERSION}

      if [ -d "$MPI4PY_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${MPI4PY_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p ${MPI4PY_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${MPI4PY_PATH}
      fi

      git clone --branch $MPI4PY_VERSION https://github.com/mpi4py/mpi4py.git
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
      module unload ${MPI_MODULE}

   fi


   # Create a module file for mpi4py
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${MPI4PY_VERSION}.lua
	whatis(" MPI4PY - provides Python bindings for MPI")

        prepend_path("PYTHONPATH", "${MPI4PY_PATH}")
	load("${MPI_MODULE}")
EOF

fi

