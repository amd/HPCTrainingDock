#/bin/bash

ROCM_VERSION=6.0
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
BUILD_KOKKOS=0

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          ;;
      "--build-kokkos")
          shift
          BUILD_KOKKOS=${1}
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
   exit 1

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
      sudo rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/kokkos.tgz

   else
      echo ""
      echo "============================"
      echo " Building Kokkos"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}

      git clone https://github.com/kokkos/kokkos 
      cd kokkos

      sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/kokkos

      sudo mkdir build
      cd build
      sudo cmake -DCMAKE_INSTALL_PREFIX=/opt/rocmplus-${ROCM_VERSION}/kokkos \
                 -DKokkos_ENABLE_SERIAL=ON \
                 -DKokkos_ENABLE_HIP=ON \ 
		 -DKokkos_ARCH_ZEN=ON \
		 -DKokkos_ARCH_VEGA90A=ON \
                 -DCMAKE_CXX_COMPILER=hipcc ..

      make -j
      sudo make install

      cd ../..
      sudo irm -rf kokkos

      module unload rocm/${ROCM_VERSION}

   fi
   # Create a module file for kokoks
   export MODULE_PATH=/etc/lmod/modules/kokkos

   sudo mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | sudo tee ${MODULE_PATH}/4.3.1.lua
        whatis("Kokkos - Performance Portability Language")

        load("rocm/${ROCM_VERSION}")
        load("amdclang")
        prepend_path("PATH","/opt/rocmplus-${ROCM_VERSION}/kokkos")
EOF

fi

