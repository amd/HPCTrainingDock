#/bin/bash

# Variables controlling setup process
AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
MODULE_PATH=/etc/lmod/modules/misc/hypre
BUILD_HYPRE=0
ROCM_VERSION=6.0
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "Usage:"
   echo "  --module-path [ MODULE_PATH ] default /etc/lmod/modules/misc/hypre"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "  --build-hypre [ BUILD_HYPRE ] default is 0"
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
          reset-last
          ;;
      "--build-hypre")
          shift
          BUILD_HYPRE=${1}
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
echo "Starting HYPRE Install with"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "BUILD_HYPRE: $BUILD_HYPRE"
echo "==================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [ "${BUILD_HYPRE}" = "0" ]; then

   echo "HYPRE will not be built, according to the specified value of BUILD_HYPRE"
   echo "BUILD_HYPRE: $BUILD_HYPRE"
   exit

else
   if [ -f ${CACHE_FILES}/hypre.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached HYPRE"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt/rocmplus-${ROCM_VERSION}
      tar -xpzf ${CACHE_FILES}/hypre.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/hypre.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building HYPRE"
      echo "============================"
      echo ""

      source /etc/profile.d/lmod.sh
      source /etc/profile.d/z01_lmod.sh
      module load rocm/${ROCM_VERSION}
      module load openmpi

      cd /tmp

      export HYPRE_PATH=/opt/rocmplus-${ROCM_VERSION}/hypre
      ${SUDO} mkdir -p ${HYPRE_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod a+w ${HYPRE_PATH}
      fi

      # ------------ Installing HYPRE

      git clone https://github.com/spack/spack.git

      # load spack environment
      source spack/share/spack/setup-env.sh

      # find already installed libs for spack
      spack external find

      # change spack install dir for Hypre
      ${SUDO} sed -i 's|$spack/opt/spack|'"${HYPRE_PATH}"'|g' spack/etc/spack/defaults/config.yaml

      # open permissions to use spack to install hypre
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+rwX ${HYPRE_PATH}
      fi

      # install hypre with spack
      #spack install hypre+rocm+rocblas+unified-memory
      spack install hypre+rocm+rocblas+unified-memory+gpu-aware-mpi amdgpu_target=gfx942


      # get hypre install dir created by spack
      HYPRE_PATH=`spack find -p hypre | awk '{print $2}' | grep opt`

      ${SUDO} rm -rf spack

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${HYPRE_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${HYPRE_PATH}
      fi

      module unload rocm/${ROCM_VERSION}

   fi

   # Create a module file for hypre
   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/2.32.0.lua
	whatis("HYPRE - solver package")

	local base = "${HYPRE_PATH}"

	load("rocm/${ROCM_VERSION}")
	load("openmpi")
	setenv("HYPRE_PATH", base)
	prepend_path("PATH",pathJoin(base, "bin"))
	prepend_path("PATH","${HYPRE_PATH}/bin")
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH","/usr/lib")
EOF

fi
