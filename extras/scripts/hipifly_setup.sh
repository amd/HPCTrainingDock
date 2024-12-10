#/bin/bash

# Variables controlling setup process
MODULE_PATH=/etc/lmod/modules/misc/hipifly
HIPIFLY_MODULE=0
ROCM_VERSION=6.0

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --hipifly-module [ HIPIFLY_MODULE ], set to 1 to create hipifly, default is $HIPIFLY_MODULE"
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
      "--hipifly-module")
          shift
          HIPIFLY_MODULE=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;	  
      "--module-path")
          shift
          MODULE_PATH=${1}
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
echo "Setting Up the HIPIFLY Module"
echo "HIPIFLY_MODULE: $HIPIFLY_MODULE"
echo "==================================="
echo ""

if [ "${HIPIFLY_MODULE}" = "0" ]; then

   echo "Hipifly module  will not be created, according to the specified value of HIPIFLY_MODULE"
   echo "HIPIFLY_MODULE: $HIPIFLY_MODULE"
   exit 

else
      HIPIFLY_PATH=/opt/rocmplus-${ROCM_VERSION}/hipifly
      ${SUDO} mkdir -p ${HIPIFLY_PATH}
      ${SUDO} cp extras/sources/hipifly/hipifly.h ${HIPIFLY_PATH}

      ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/dev.lua
	whatis(" Hipifly header file ") 
	load("rocm/${ROCM_VERSION}")
        setenv("HIPIFLY_PATH","${HIPIFLY_PATH}")
EOF

fi

