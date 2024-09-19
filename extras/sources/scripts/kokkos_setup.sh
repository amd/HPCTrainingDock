#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/kokkos
BUILD_KOKKOS=0
ROCM_VERSION=6.0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  --module-path [ MODULE_PATH ] default /etc/lmod/modules/misc/kokkos"
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
      "--build-kokkos")
          shift
          BUILD_KOKKOS=${1}
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
echo "Starting Kokkos Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_KOKKOS: $BUILD_KOKKOS"
echo "==================================="
echo ""

if [ "${BUILD_KOKKOS}" = "0" ]; then

   echo "Kokkos will not be build, according to the specified value of BUILD_KOKKOS"
   echo "BUILD_KOKKOS: $BUILD_KOKKOS"
   exit 

else
   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached Kokkos"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/kokkos.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/kokkos
      ${SUDO} rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos.tgz

   else
      echo ""
      echo "============================"
      echo " Building Kokkos"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm/${ROCM_VERSION}

      ${SUDO} mkdir -p /opt/rocmplus-${ROCM_VERSION}/kokkos

      git clone --branch 4.4.00 https://github.com/kokkos/kokkos
      cd kokkos

      ${SUDO} mkdir build
      cd build

      ${SUDO} cmake -DCMAKE_INSTALL_PREFIX=/opt/rocmplus-${ROCM_VERSION}/kokkos \
                 -DCMAKE_PREFIX_PATH=/opt/rocm-${ROCM_VERSION} \
                 -DKokkos_ENABLE_SERIAL=ON \
                 -DKokkos_ENABLE_HIP=ON \
                 -DKokkos_ARCH_ZEN=ON \
                 -DKokkos_ARCH_VEGA90A=ON \
                 -DCMAKE_CXX_COMPILER=hipcc ..

      ${SUDO} make -j
      ${SUDO} make install

      cd ../..
      ${SUDO} rm -rf kokkos

      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for kokkos
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/4.4.0.lua
	whatis("Kokkos - Performance Portability Language")

	load("rocm/${ROCM_VERSION}")
	load("amdclang")
	prepend_path("PATH","/opt/rocmplus-${ROCM_VERSION}/kokkos")
EOF

fi

