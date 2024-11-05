#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/ROCmPlus-LatestCompilers/hipfort
BUILD_HIPFORT=0
ROCM_VERSION=6.0
USE_FLANGNEW=0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --build-hipfort [ BUILD_HIPFORT ], set to 1 to build hipfort, default is 0"
   echo "  --use-flang-new [ USE_FLANGNEW ], , default is $USE_FLANGNEW"
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
      "--help")
          usage
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--use-flang-new")
          shift
          USE_FLANGNEW=${1}
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
echo "Starting Kokkos Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_KOKKOS: $BUILD_KOKKOS"
echo "USE_FLANGNEW: $USE_FLANGNEW"
echo "==================================="
echo ""

if [ "${BUILD_HIPFORT}" = "0" ]; then

   echo "Hipfort will not be built, according to the specified value of BUILD_HIPFORT"
   echo "BUILD_HIPFORT: $BUILD_HIPFORT"
   exit 

else
   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/hipfort.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Hipfort"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/hipfort.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hipfort
      ${SUDO} rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/hipfort.tgz

   else
      echo ""
      echo "============================"
      echo " Building Hipfort"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm/${ROCM_VERSION}

      HIPFORT_COMPILER_FLAGS=""
      if [ "${USE_FLANGNEW}" = "1" ]; then
         module load amdflang-new-beta-drop
	 HIPFORT_COMPILER_FLAGS="-DHIPFORT_COMPILER_FLAGS='-ffree-form -cpp'"
      fi

      HIPFORT_PATH=/opt/rocmplus-${ROCM_VERSION}/hipfort
      ${SUDO} mkdir -p ${HIPFORT_PATH}

      # clone from main as soon as this PR is merged: https://github.com/ROCm/hipfort/pull/198
      git clone --branch enable-flang-new https://github.com/bcornille/hipfort.git
      cd hipfort

      ${SUDO} mkdir build
      cd build

      ${SUDO} cmake -DHIPFORT_INSTALL_DIR=${HIPFORT_PATH} ${HIPFORT_COMPILER_FLAGS} ..

      ${SUDO} make install

      cd ../..
      ${SUDO} rm -rf hipfort

      module unload rocm/${ROCM_VERSION}
      if [ "${USE_FLANGNEW}" = "1" ]; then
         module unload amdflang-new-beta-drop
      fi

   fi

   # Create a module file for hipfort
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/0.4-0.lua
	whatis(" hipfc: Wrapper to call Fortran compiler with hipfort. Also calls hipcc for non Fortran files. ")
	load("rocm/${ROCM_VERSION}")
	prepend_path("PATH","${HIPFORT_PATH}/bin")
EOF

fi

