#/bin/bash

# Variables controlling setup process
ROCM_VERSION=6.0
BUILD_SMARTSIM=0
MODULE_PATH=/etc/lmod/modules/ROCmPlus-AI/smartsim
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
CRAYLABS_PATH=/opt/rocmplus-${ROCM_VERSION}/cray-labs
CRAYLABS_PATH_INPUT=""

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
   echo "  --build-smartsim [ BUILD_SMARTSIM ] default $BUILD_SMARTSIM "
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ CRAYLABS_PATH ] default $CRAYLABS_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
      "--build-smartsim")
          shift
          BUILD_SMARTSIM=${1}
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
          CRAYLABS_PATH_INPUT=${1}
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

if [ "${CRAYLABS_PATH_INPUT}" != "" ]; then
   CRAYLABS_PATH=${CRAYLABS_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   CRAYLABS_PATH=/opt/rocmplus-${ROCM_VERSION}/cray-labs
fi

# Load the ROCm version for this SmartSim build
source /etc/profile.d/lmod.sh
source /etc/profile.d/z01_lmod.sh
module load rocm/${ROCM_VERSION}
module load amdflang-new
module load pytorch

echo ""
echo "==================================="
echo "Starting SmartSim Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_GFXMODEL: $AMDGPU_GFXMODEL"
echo "BUILD_SMARTSIM: $BUILD_SMARTSIM"
echo "INSTALL_PATH: $CRAYLABS_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_SMARTSIM}" = "0" ]; then

   echo "SmartSim will not be built, according to the specified value of BUILD_SMARTSIM"
   echo "BUILD_SMARTSIM: $BUILD_SMARTSIM"
   exit

else
   cd /tmp

   AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
   CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}
   if [ -f ${CACHE_FILES}/smartsim.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached SmartSim"
      echo "============================"
      echo ""

      #install the cached version
      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/smartsim
      cd /opt/rocmplus-${ROCM_VERSION}
      ${SUDO} tar -xzpf ${CACHE_FILES}/smartsim.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/smartsim.tgz
      fi
   else
      echo ""
      echo "============================"
      echo " Building SmartSim"
      echo "============================"
      echo ""

      if [ -d "$CRAYLABS_PATH" ]; then
         # don't use sudo if user has write access to install path
         if [ -w ${CRAYLABS_PATH} ]; then
            SUDO=""
         else
            echo "WARNING: using an install path that requires sudo"
         fi
      else
         # if install path does not exist yet, the check on write access will fail
         echo "WARNING: using sudo, make sure you have sudo privileges"
      fi

      ${SUDO} mkdir -p $CRAYLABS_PATH
      export SMART_SIM_PATH=${CRAYLABS_PATH}/smartsim
      export SMART_REDIS_PATH=${CRAYLABS_PATH}/smartredis
      ${SUDO} mkdir -p ${CRAYLABS_PATH}
      ${SUDO} mkdir -p ${SMART_SIM_PATH}
      ${SUDO} mkdir -p ${SMART_REDIS_PATH}
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w $CRAYLABS_PATH
      fi

      git clone https://github.com/CrayLabs/SmartRedis.git
      cd SmartRedis
      mkdir build && cd build
      cmake -DBUILD_FORTRAN=ON .. -DCMAKE_INSTALL_PREFIX=$SMART_REDIS_PATH
      make -j
      ${SUDO} make install
      cd ..

      export PATH=$PATH:"$SMART_REDIS_PATH/bin"
      export PYTHONPATH=$PYTHONPATH:$SMART_REDIS_PATH

      pip3 install --target=$SMART_REDIS_PATH .

      cd ..

      git clone https://github.com/CrayLabs/SmartSim.git
      cd SmartSim
      pip3 install --target=$SMART_SIM_PATH .
      export PATH=$PATH:"$SMART_SIM_PATH/bin"
      export PYTHONPATH=$PYTHONPATH:$SMART_SIM_PATH
      wget https://raw.githubusercontent.com/amd/HPCTrainingDock/main/extras/sources/smartsim/LinuxX64ROCM6.json 
      sed -i 's/${PYTORCH_VERSION}/'${PYTORCH_VERSION}'/g' LinuxX64ROCM6.json
      sed -i 's|${Torch_DIR}|'${Torch_DIR}'|g' LinuxX64ROCM6.json
      PWD=`pwd`

      smart build --device rocm-6 --config-dir $PWD

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find $CRAYLABS_PATH -type f -execdir chown root:root "{}" +
         ${SUDO} find $CRAYLABS_PATH -type d -execdir chown root:root "{}" +

         ${SUDO} chmod go-w $CRAYLABS_PATH
      fi

      # cleanup
      cd ..
      rm -rf smartsim
      module unload rocm/${ROCM_VERSION}
      module unload amdflang-new
      module unload pytorch
   fi

   # Create a module file for smartsim
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
	whatis("SmartSim from CrayLabs")

	load("rocm/${ROCM_VERSION}")
	load("amdflang-new")
	load("pytorch")
	prepend_path("PYTHONPATH","$SMART_REDIS_PATH")
	prepend_path("PYTHONPATH","$SMART_SIM_PATH")
	prepend_path("PATH","${SMART_SIM_PATH}/bin")
	prepend_path("PATH","${SMART_REDIS_PATH}/bin")
EOF

fi
