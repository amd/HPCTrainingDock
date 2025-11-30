#!/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/LinuxPlus/julia
BUILD_JULIA=0
JULIA_VERSION="1.12"
JULIA_PARENT_DIR=/opt
JULIA_PARENT_DIR_INPUT=""

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --parent-dir [ JULIA_PARENT_DIR ] Julia will be installed in ${JULIA_PARENT_DIR}/julia-v${JULIA_VERSION}"
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
      "--parent-dir")
          shift
          JULIA_PARENT_DIR=${1}
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

if [ "${JULIA_PARENT_DIR_INPUT}" != "" ]; then
   JULIA_PARENT_DIR=${JULIA_PARENT_DIR_INPUT}
fi

echo ""
echo "==================================="
echo "Starting Julia Install with"
echo "JULIA_VERSION: $JULIA_VERSION"
echo "BUILD_JULIA: $BUILD_JULIA"
echo "JULIA_PARENT_DIR:  $JULIA_PARENT_DIR"
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

   # don't use sudo if user has write access to the julia parent dir
   if [ -d "${JULIA_PARENT_DIR}" ]; then
      # don't use sudo if user has write access to the julia parent dir
      if [ -w ${JULIA_PARENT_DIR} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      # if install path does not exist yet, the check on write access will fail
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} chmod -R a+w $JULIA_PARENT_DIR
   fi

   # the julia install wants to create the directory to install so it has not exist already
   JULIA_PATH=${JULIA_PARENT_DIR}/julia-v${JULIA_VERSION}
   export JULIA_DEPOT_PATH=$JULIA_PATH
   curl -fsSL https://install.julialang.org | sh -s -- --yes --add-to-path=no -p=${JULIA_PATH}
   export PATH=$PATH:"$JULIA_PATH/bin"
   juliaup add 1.12
   juliaup default 1.12
   julia -e 'using Pkg; Pkg.add("AMDGPU")'
   ${SUDO} mv ~/.julia $JULIA_PATH
   cd ${JULIA_PATH}/.julia
   ${SUDO} mv ../* .
   cd ..
   ${SUDO} mv .julia/bin .
   ${SUDO} mv .julia/juliaupself.json .
   ${SUDO} chmod -R 755 .julia/*

   if [[ "${USER}" != "root" ]]; then
      ${SUDO} find $JULIA_PARENT_DIR -type f -execdir chown root:root "{}" +
      ${SUDO} find $JULIA_PARENT_DIR -type d -execdir chown root:root "{}" +
      ${SUDO} chmod -R go-w $JULIA_PARENT_DIR
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

	#setenv("JULIA_DEPOT_PATH","${JULIA_PATH}")
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${JULIA_VERSION}.lua
	whatis("Julia programming language, version ${JULIA_VERSION}")

	prepend_path("PATH","${JULIA_PATH}/bin")
	setenv("JULIA_PATH","${JULIA_PATH}")
	setenv("JULIA_VERSION","${JULIA_VERSION}")
	cmd1="cp -r ${JULIA_PATH}/.julia $HOME"
	execute{cmd=cmd1, modeA={"load"}}


EOF

fi

