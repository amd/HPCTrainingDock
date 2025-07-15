#/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/hipfort_from_source
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_HIPFORT=0
ROCM_VERSION=6.0.0
HIPFORT_PATH="/opt/rocmplus-${ROCM_VERSION}/hipfort"
HIPFORT_PATH_INPUT=""
FC_COMPILER=gfortran

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
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default is $AMDGPU_GFXMODEL"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --build-hipfort [ BUILD_HIPFORT ], set to 1 to build hipfort, default is $BUILD_HIPFORT"
   echo "  --fc-compiler [FC_COMPILER: gfortran|amdflang-new|cray-ftn], default is $FC_COMPILER"
   echo "  --install-path [ HIPFORT_PATH ], default is $HIPFORT_PATH"
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
      "--build-hipfort")
          shift
          BUILD_HIPFORT=${1}
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
          HIPFORT_PATH_INPUT=${1}
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

if [ "${HIPFORT_PATH_INPUT}" != "" ]; then
   HIPFORT_PATH=${HIPFORT_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   HIPFORT_PATH=/opt/rocmplus-${ROCM_VERSION}/hipfort
fi

echo ""
echo "==================================="
echo "Starting Hipfort Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HIPFORT: $BUILD_HIPFORT"
echo "MODULE_PATH: $MODULE_PATH"
echo "HIPFORT_PATH: $HIPFORT_PATH"
echo "FC_COMPILER: $FC_COMPILER"
echo "==================================="
echo ""

if [ "${BUILD_HIPFORT}" = "0" ]; then

   echo "Hipfort will not be built, according to the specified value of BUILD_HIPFORT"
   echo "BUILD_HIPFORT: $BUILD_HIPFORT"
   exit

else
   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

   if [ -f ${CACHE_FILES}/hipfort.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Hipfort"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf ${CACHE_FILES}/hipfort.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hipfort
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm -f ${CACHE_FILES}/hipfort.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building Hipfort"
      echo "============================"
      echo ""

      # don't use sudo if user has write access to install path
      if [ -w ${HIPFORT_PATH} ]; then
         SUDO=""
      fi

      if  [ "${BUILD_HIPFORT}" = "1" ]; then

         source /etc/profile.d/lmod.sh
         source /etc/profile.d/z01_lmod.sh
         module load rocm/${ROCM_VERSION}

         if [ -d "$HIPFORT_PATH" ]; then
            # don't use sudo if user has write access to install path
            if [ -w ${HIPFORT_PATH} ]; then
               SUDO=""
            else
               echo "WARNING: using an install path that requires sudo"
            fi
         else
            # if install path does not exist yet, the check on write access will fail
            echo "WARNING: using sudo, make sure you have sudo privileges"
         fi

         ${SUDO} mkdir -p ${HIPFORT_PATH}

         git clone --branch rocm-${ROCM_VERSION} https://github.com/ROCm/hipfort.git
         cd hipfort

         mkdir build && cd build

         if [ "${FC_COMPILER}" = "gfortran" ]; then
            cmake -DHIPFORT_INSTALL_DIR=${HIPFORT_PATH} ..
         elif [ "${FC_COMPILER}" = "amdflang-new" ]; then
            module load amdflang-new
            cmake -DHIPFORT_INSTALL_DIR=${HIPFORT_PATH} -DHIPFORT_COMPILER=$FC -DHIPFORT_COMPILER_FLAGS="-ffree-form -cpp" ..
         elif [ "${FC_COMPILER}" = "cray-ftn" ]; then
            cmake -DHIPFORT_INSTALL_DIR=$HIPFORT_PATH -DHIPFORT_BUILD_TYPE=RELEASE -DHIPFORT_COMPILER=$(which ftn) -DHIPFORT_COMPILER_FLAGS="-ffree -eT" -DHIPFORT_AR=$(which ar) -DHIPFORT_RANLIB=$(which ranlib) ..
         else
            echo " ERROR: requested compiler is not currently among the available options "
            echo " Please choose one among: gfortran (default), amdflang-new, cray-ftn "
            exit 1
         fi

         ${SUDO} make install

         cd ../..
         ${SUDO} rm -rf hipfort

      fi

   fi

   # Create a module file for hipfort
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis(" hipfort module ")
	whatis(" this hipfort build has been compiled with: $FC_COMPILER. ")
	load("rocm/${ROCM_VERSION}")
	local fc_compiler = "${FC_COMPILER}"
	if fc_compiler == "amdflang-new" then
		load("amdflang-new")
	end
	append_path("LD_LIBRARY_PATH","${HIPFORT_PATH}/lib")
	setenv("LIBS","-L${HIPFORT_PATH}/lib -lhipfort-amdgcn.a")
	setenv("HIPFORT_PATH","${HIPFORT_PATH}")
	prepend_path("PATH","${HIPFORT_PATH}/bin")
EOF

fi

