#/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/Linux/scotch
BUILD_SCOTCH=1
INSTALL_PATH=/opt/scotch
SUDO="sudo"
SUDO=""
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
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  WARNING: when selecting the module to supply to --mpi-module, make sure it sets the MPI_PATH environment variable"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [ INSTALL_PATH ] default $INSTALL_PATH"
   echo "  --build-scotch [ BUILD_SCOTCH ] default is 0"
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
      "--build-scotch")
          shift
          BUILD_SCOTCH=${1}
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
          INSTALL_PATH=${1}
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
echo "Starting SCOTCH Install with"
echo "BUILD_SCOTCH: $BUILD_SCOTCH"
echo "Installing SCOTCH in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}

if [ "${BUILD_SCOTCH}" = "0" ]; then

   echo "SCOTCH will not be built, according to the specified value of BUILD_SCOTCH"
   echo "BUILD_SCOTCH: $BUILD_SCOTCH"
   exit

else
   if [ -f ${CACHE_FILES}/scotch.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached SCOTCH"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xpzf ${CACHE_FILES}/scotch.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/scotch.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building SCOTCH"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      rm -rf scotch_source
      mkdir scotch_source && cd scotch_source
      rm -rf scotch
      git clone git@gitlab.inria.fr:scotch/scotch.git
      cd scotch
      mkdir build && cd build
      cmake --prefix=${INSTALL_PATH} ..

      make -j 8

      echo "Installing SCOTCH in: $INSTALL_PATH"

      make install

      cd ..

      rm -rf scotch

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   SCOTCH_PATH=${INSTALL_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/dev.lua
        whatis("SCOTCH package")

        local base = "${SCOTCH_PATH}"

        setenv("SCOTCH_ROOT", base)
        setenv("SCOTCH_LIBDIR", pathJoin(base, "lib"))
        setenv("SCOTCH_INCLUDE", pathJoin(base, "include"))
EOF

fi
