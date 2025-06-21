#/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/LinuxPlus/julia
BUILD_JULIA=0
JULIA_VERSION="1.12"
JULIA_PATH=/opt/julia-v${JULIA_VERSION}
JULIA_PATH_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --install-path [ JULIA_PATH ] default $JULIA_PATH"
   echo "  --build-julia [ BUILD_JULIA ], set to 1 to build Julia, default is 0"
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
      "--build-julia")
          shift
          BUILD_JULIA=${1}
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
          JULIA_PATH_INPUT=${1}
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

if [ "${JULIA_PATH_INPUT}" != "" ]; then
   JULIA_PATH=${JULIA_PATH_INPUT}
else
   # override path in case JULIA_VERSION has been supplied as input
   JULIA_PATH=/opt/julia-v${JULIA_VERSION}
fi

echo ""
echo "==================================="
echo "Starting Julia Install with"
echo "JULIA_VERSION: $JULIA_VERSION"
echo "BUILD_JULIA: $BUILD_JULIA"
echo "JULIA_PATH:  $JULIA_PATH"
echo "MODULE_PATH:  $MODULE_PATH"
echo "==================================="
echo ""

if [ "${BUILD_JULIA}" = "0" ]; then

   echo "Julia will not be built, according to the specified value of BUILD_JULIA"
   echo "BUILD_JULIA: $BUILD_JULIA"
   exit

else
   echo ""
   echo "============================"
   echo " Building Julia"
   echo "============================"
   echo ""

   # don't use sudo if user has write access to install path
   if [ -d "$JULIA_PATH" ]; then
      # don't use sudo if user has write access to install path
      if [ -w ${JULIA_PATH} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      # if install path does not exist yet, the check on write access will fail
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p ${JULIA_PATH}

   # Create a module file for kokkos
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

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod a+w $JULIA_PATH
   fi

   curl -fsSL https://install.julialang.org curl | sh -s -- --yes --add-to-path=no -p=${JULIA_PATH}
   export PATH=$PATH:${JULIA_PATH}/bin
   juliaup add ${JULIA_VERSION}

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} find $JULIA_PATH -type f -execdir chown root:root "{}" +
      ${SUDO} find $JULIA_PATH -type d -execdir chown root:root "{}" +
      ${SUDO} chmod go-w $JULIA_PATH
   fi

   # Create a module file for julia
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${JULIA_VERSION}.lua
	whatis("Julia programming language, version ${JULIA_VERSION}")

	prepend_path("PATH","${JULIA_PATH}/bin")
	setenv("JULIA_PATH","${JULIA_PATH}")
EOF

fi

