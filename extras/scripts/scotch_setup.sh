#/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/LinuxPlus/scotch
BUILD_SCOTCH=1
SCOTCH_VERSION=7.0.7
INSTALL_PATH=/opt/scotch-v${SCOTCH_VERSION}
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
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --install-path [ INSTALL_PATH ] default $INSTALL_PATH"
   echo "  --build-scotch [ BUILD_SCOTCH ] default is 0"
   echo "  --scotch-version [ SCOTCH_VERSION ] default is $SCOTCH_VERSION"
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
      "--scotch-version")
          shift
          SCOTCH_VERSION=${1}
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case SCOTCH_VERSION has been supplied as input
   INSTALL_PATH=/opt/scotch-v${SCOTCH_VERSION}
fi

echo ""
echo "==================================="
echo "Starting SCOTCH Install with"
echo "BUILD_SCOTCH: $BUILD_SCOTCH"
echo "SCOTCH_VERSION: $SCOTCH_VERSION"
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
      git clone -b v${SCOTCH_VERSION} https://gitlab.inria.fr/scotch/scotch.git 
      cd scotch
      mkdir build && cd build
      cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH} -DCMAKE_BUILD_TYPE=Release ..

      make -j 8

      echo "Installing SCOTCH in: $INSTALL_PATH"

      make install

      cd ../../..

      rm -rf scotch_source

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi
   fi

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
        whatis("SCOTCH package")

        local base = "${INSTALL_PATH}"

        setenv("SCOTCH_ROOT", base)
        setenv("SCOTCH_LIBDIR", pathJoin(base, "lib"))
        setenv("SCOTCH_INCLUDE", pathJoin(base, "include"))
EOF

fi
