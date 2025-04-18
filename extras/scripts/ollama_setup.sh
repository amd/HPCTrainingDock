#!/bin/bash

BUILD_OLLAMA=0

usage()
{
   echo "  --build-ollama [ BUILD_OLLAMA ], set to 1 to build ollama, default is $BUILD_OLLAMA "
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
else
   echo " OLLAMA will not be built, according to the value of BUILD_OLLAMA: $BUILD_OLLAMA "
   echo " Use --build-ollama 1 to build Ollama "
   exit 1
fi

