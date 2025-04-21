#/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.0
BUILD_CUPY=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/cupy
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
CUPY_PATH=/opt/rocmplus-${ROCM_VERSION}/cupy
CUPY_PATH_INPUT=""
GIT_COMMIT="9cdff1737eaa44aba657cb17f7e0cc421d7cca34"

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

# Autodetect defaults

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --build-cupy"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ CUPY_PATH ] default $CUPY_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --git-commit [ GIT_COMMIT ] specify what commit hash you want to build from, default is $GIT_COMMIT"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected"
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
      "--build-cupy")
          shift
          BUILD_CUPY=${1}
	  reset-last
          ;;
      "--git-commit")
          shift
          GIT_COMMIT=${1}
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
          CUPY_PATH_INPUT=${1}
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

if [ "${CUPY_PATH_INPUT}" != "" ]; then
   CUPY_PATH=${CUPY_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   CUPY_PATH=/opt/rocmplus-${ROCM_VERSION}/cupy
fi

# Load the ROCm version for this CuPy build
source /etc/profile.d/lmod.sh
source /etc/profile.d/z01_lmod.sh
module load rocm/${ROCM_VERSION}

echo ""
echo "==================================="
echo "Starting Cupy Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_CUPY: $BUILD_CUPY"
echo "CUPY_VERSION: $CUPY_VERSION"
echo "CUPY_PATH: $CUPY_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "Building from source off of this commit: $GIT_COMMIT"
echo "==================================="
echo ""

if [ "${BUILD_CUPY}" = "0" ]; then

   echo "CuPy will not be built, according to the specified value of BUILD_CUPY"
   echo "BUILD_CUPY: $BUILD_CUPY"
   exit

else
   cd /tmp

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/cupy.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached CuPy"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/cupy
      cd /opt/rocmplus-${ROCM_VERSION}
      #${SUDO} chmod a+w /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/cupy.tgz
      #chown -R root:root /opt/rocmplus-${ROCM_VERSION}/cupy
      #${SUDO} chmod og-w /opt/rocmplus-${ROCM_VERSION}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/cupy.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building CuPy"
      echo "============================"
      echo ""


      # Load the ROCm version for this CuPy build -- use hip compiler, path to ROCm and the GPU model
      export CUPY_INSTALL_USE_HIP=1
      export ROCM_HOME=${ROCM_PATH}
      export HIPCC=${ROCM_HOME}/bin/hipcc
      export CFLAGS+=-D__HIP__
      export HCC_AMDGPU_ARCH=${AMDGPU_GFXMODEL}

      if [ -d "$CUPY_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${CUPY_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      # Get source from the ROCm repository of CuPy.
      git clone -q --depth 1 --recursive https://github.com/ROCm/cupy.git
      cd cupy
      git reset --hard $GIT_COMMIT

      python3 -m pip install argcomplete==1.9.4
      # use version 1.25 of numpy – need to test with later numpy version
      sed -i -e '/numpy/s/1.27/1.25/' setup.py
      # set python path to installation directory
      PYTHONPATH=$CUPY_PATH
      # build basic cupy package
      python3 setup.py -q bdist_wheel

      # install necessary packages in installation directory
      ${SUDO} mkdir -p $CUPY_PATH
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w $CUPY_PATH
      fi
      pip3 install -v --target=$CUPY_PATH pytest mock xarray[complete] dask
      pip3 install -v --upgrade --target=$CUPY_PATH dist/*.whl
      pip3 install -v --target=$CUPY_PATH cupy-xarray --no-deps
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $CUPY_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $CUPY_PATH -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w $CUPY_PATH
      fi

      # cleanup
      cd ..
      rm -rf cupy
      module unload rocm/${ROCM_VERSION}
   fi

   # Create a module file for cupy
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

   CUPY_VERSION=`cat "$CUPY_PATH/cupy/_version.py"  | cut -f3 -d' ' |  tr -d "'"`
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${CUPY_VERSION}.lua
	whatis("CuPy with ROCm support")

	load("rocm/${ROCM_VERSION}")
	prepend_path("PYTHONPATH","$CUPY_PATH")
EOF

fi
