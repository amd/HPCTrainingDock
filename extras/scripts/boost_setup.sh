#/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/misc/boost
BUILD_BOOST=1
ROCM_VERSION=6.4.0
BOOST_VERSION=1_82_0
INSTALL_PATH=/opt/boost-${BOOST_VERSION}
INSTALL_PATH_INPUT=""
SUDO="sudo"
SUDO=""
MPI_MODULE="openmpi"
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
   echo "  --install-path [ INSTALL_PATH_INPUT ] default $INSTALL_PATH"
   echo "  --boost-version [ BOOST_VERSION ] default $BOOST_VERSION"
   echo "  --build-boost [ BUILD_BOOST ] default is 0"
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
      "--build-boost")
          shift
          BUILD_BOOST=${1}
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
          INSTALL_PATH_INPUT=${1}
          reset-last
          ;;
      "--boost-version")
          shift
          BOOST_VERSION=${1}
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
   # override path in case BOOST_VERSION has been supplied as input
   INSTALL_PATH=/opt/boost-${BOOST_VERSION}
fi

echo ""
echo "==================================="
echo "Starting BOOST Install with"
echo "BUILD_BOOST: $BUILD_BOOST"
echo "Installing BOOST in: $INSTALL_PATH"
echo "MODULE_PATH: $MODULE_PATH"
echo "==================================="
echo ""

CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}

if [ "${BUILD_BOOST}" = "0" ]; then

   echo "BOOST will not be built, according to the specified value of BUILD_BOOST"
   echo "BUILD_BOOST: $BUILD_BOOST"
   exit

else
   if [ -f ${CACHE_FILES}/boost-${BOOST_VERSION}.tgz ]; then
      echo ""
      echo "============================"
      echo " Installing Cached BOOST"
      echo "============================"
      echo ""

      #install the cached version
      cd /opt
      tar -xpzf ${CACHE_FILES}/boost--${BOOST_VERSION}.tgz
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/boost-${BOOST_VERSION}.tgz
      fi

   else
      echo ""
      echo "============================"
      echo " Building BOOST"
      echo "============================"
      echo ""

      ${SUDO} mkdir -p ${INSTALL_PATH}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod -R a+w ${INSTALL_PATH}
      fi

      rm -rf boost_source
      mkdir boost_source && cd boost_source
      rm -rf boost_${BOOST_VERSION}.tar.gz boost_${BOOST_VERSION}
      wget -q https://archives.boost.io/release/1.82.0/source/boost_${BOOST_VERSION}.tar.gz
      tar -xzf boost_${BOOST_VERSION}.tar.gz
      cd boost_${BOOST_VERSION}
      ./bootstrap.sh --prefix=$INSTALL_PATH --with-libraries=all

      echo "Installing BOOST ${BOOST_VERSION} in: $INSTALL_PATH"
      ./b2 install --prefix=$INSTALL_PATH
      cd ..

      cd ..
      rm -rf boost_${BOOST_VERSION}.tar.gz boost_${BOOST_VERSION}

      if [[ "${USER}" != "root" ]]; then
         ${SUDO} find ${INSTALL_PATH} -type f -execdir chown root:root "{}" +
      fi
      if [[ "${USER}" != "root" ]]; then
         ${SUDO} chmod go-w ${INSTALL_PATH}
      fi
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   BOOST_PATH=${INSTALL_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/$BOOST_VERSION.lua
        whatis("BOOST ${BOOST_VERSION} package")

        local base = "${BOOST_PATH}"

        setenv("BOOST_ROOT", base)
        setenv("BOOST_LIBDIR", pathJoin(base, "lib"))
        setenv("BOOST_INCLUDE", pathJoin(base, "include"))
EOF

fi
