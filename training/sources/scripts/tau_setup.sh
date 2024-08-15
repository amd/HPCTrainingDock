#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/tau
BUILD_TAU=0
MPI_INCLUDE=""
MPI_LIB=""
ROCM_VERSION=6.0

usage()
{
   echo "--help: this usage information"
   echo "--build-tau: default is 0"
   echo "--mpi-include: default is an empty string"
   echo "--mpi-lib: default is an empty string"
   echo "--module-path [ MODULE_PATH ] default /etc/lmod/modules/misc/tau"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
      "--build-tau")
          shift
          BUILD_TAU=${1}
          reset-last
          ;;
      "--mpi-include")
          shift
          MPI_INCLUDE=${1}
          reset-last
          ;;
      "--mpi-lib")
          shift
          MPI_LIB=${1}
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
echo "Starting TAU Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_TAU: $BUILD_TAU"
echo "==================================="
echo ""

if [ "${BUILD_TAU}" = "0" ]; then

   echo "TAU will not be build, according to the specified value of BUILD_TAU"
   echo "BUILD_TAU: $BUILD_TAU"
   exit 

else
   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/tau.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached TAU"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/tau.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/tau
      sudo rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/tau.tgz

   else

      echo ""
      echo "============================"
      echo " Building TAU"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}

      TAU_PATH=/opt/rocmplus-${ROCM_VERSION}/tau
      sudo mkdir -p ${TAU_PATH}

      git clone https://github.com/UO-OACISS/tau2.git
      cd tau2
      sudo ./configure -c++=amdclang++ \
	               -cc=amdclang -prefix=${TAU_PATH} \
	               -openmp -ompt -rocm=${ROCM_PATH} \
		       -mpi -rocmsmi=${ROCM_PATH}/bin \
		       -rocprofiler=${ROCM_PATH} -rocprofv2 -rocprofv3

      sudo make install

      cd ..
      sudo rm -rf tau2
      module unload rocm/${ROCM_VERSION}

   fi   

   # Create a module file for mpi4py
   sudo mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | sudo tee ${MODULE_PATH}/dev.lua
	whatis(" TAU - portable profiling and tracing toolkit ") 

	prepend_path("PATH","/opt/rocmplus-${ROCM_VERSION}/tau")
EOF

fi

