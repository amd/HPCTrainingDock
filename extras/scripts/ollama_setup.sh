#!/bin/bash

BUILD_OLLAMA=0

usage()
{
   echo "  --build-netcdf [ BUILD_NETCDF ], set to 1 to build netcdf-c and netcdf-fortran, default is 0"
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
      "--build-ollama")
         shift
         BUILD_OLLAMA=${1}
         reset-last
         ;;
      "--help")
          usage
          ;;
   esac
   n=$((${n} + 1))
   shift
done

if [ ${BUILD_OLLAMA} = "1" ]; then
   wget https://ollama.com/install.sh
   chmod +x install.sh
   ./install.sh
fi

