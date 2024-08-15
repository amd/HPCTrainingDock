#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/hpctoolkit
BUILD_HPCTOOLKIT=0
ROCM_VERSION=6.0

usage()
{
   echo "--help: this usage information"
   echo "--module-path [ MODULE_PATH ] default /etc/lmod/modules/misc/hpctoolkit" 
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
      "--build-hpctoolkit")
          shift
          BUILD_HPCTOOLKIT=${1}
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
echo "Starting HPCToolkit Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HPCTOOLKIT: $BUILD_HPCTOOLKIT"
echo "==================================="
echo ""

if [ "${BUILD_HPCTOOLKIT}" = "0" ]; then

   echo "HPCToolkit will not be build, according to the specified value of BUILD_HPCTOOLKIT"
   echo "BUILD_HPCTOOLKIT: $BUILD_HPCTOOLKIT"
   exit 

else
   if [ -f /opt/rocmplus-${ROCM_VERSION}/CacheFiles/hpctoolkit.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HPCToolkit"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xzf CacheFiles/hpctoolkit.tgz
      chown -R root:root /opt/rocmplus-${ROCM_VERSION}/hpctoolkit
      sudo rm /opt/rocmplus-${ROCM_VERSION}/CacheFiles/hpctoolkit.tgz

   else
      echo ""
      echo "============================"
      echo " Building HPCToolkit"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      module load rocm/${ROCM_VERSION}

      cd /tmp

      export HPCTOOLKIT_PATH=/opt/rocmplus-${ROCM_VERSION}/hpctoolkit
      sudo mkdir -p ${HPCTOOLKIT_PATH}

      if [[ "${USER}" != "root" ]]; then
         sudo chmod a+w ${HPCTOOLKIT_PATH} 
      fi

      pipx install 'meson>=1.3.2'
      export PATH=$HOME/.local/bin:$PATH
      git clone https://gitlab.com/hpctoolkit/hpctoolkit.git
      cd hpctoolkit
      export CMAKE_PREFIX_PATH=$ROCM_PATH:$CMAKE_PREFIX_PATH
      meson setup -Drocm=enabled -Dextended_tests=enabled  --prefix=${HPCTOOLKIT_PATH} --libdir=${HPCTOOLKIT_PATH}/lib build
      cd  build
      meson compile
      meson install

      if [[ "${USER}" != "root" ]]; then
         sudo find ${HPCTOOLKIT_PATH} -type f -execdir chown root:root "{}" +
         sudo find ${HPCTOOLKIT_PATH} -type d -execdir chown root:root "{}" +
      fi

      if [[ "${USER}" != "root" ]]; then
         sudo chmod go-w ${HPCTOOLKIT_PATH}
      fi

      cd ../..
      rm -rf hpctoolkit
      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for hpctoolkit
   sudo mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | sudo tee ${MODULE_PATH}/dev.lua
	whatis("HPCToolkit - integrated suite of tools for measurement and analysis of program performance")

        local base = "/opt/rocmplus-${ROCM_VERSION}/hpctoolkit"

	load("rocm/${ROCM_VERSION}")
        setenv("HPCTOOLKIT_PATH", base)
        prepend_path("PATH",pathJoin(base, "bin"))
        prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
        prepend_path("LD_LIBRARY_PATH","/usr/lib")
EOF

fi

