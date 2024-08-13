#!/bin/bash

usage()
{
    echo "--help: this usage information"
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
      "--help")
          usage
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION_INPUT=${1}
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

#module load rocm/6.0.0 cray-python/3.11.5 craype-accel-amd-gfx90a
module load rocm
cd /tmp
git clone https://github.com/ROCm/rccl.git
cd rccl
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/opt/rocmplus-${ROCM_VERSION}/rccl
make -j 16 
make install
cd ../..
rm -rf rccl
