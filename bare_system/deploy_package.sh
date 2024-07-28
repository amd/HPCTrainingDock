#!/bin/bash
SELECTION_STRING=""

usage()
{
   echo "--help: this usage information"
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
      "--selection-string")
          shift
          SELECTION_STRING=${1}
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

# Load the ROCm version for this build
source /etc/profile.d/lmod.sh
module load rocm/${ROCM_VERSION}

cd /opt/rocmplus-${ROCM_VERSION}

for package in `find . -maxdepth 1 -type d `; do
   package=`basename $package`
   if [[ "${package}" =~ "$SELECTION_STRING" ]]; then
      tar -czvpf /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}/${package}.tgz ${package}
      #echo "cp -p /tmp/${package}.tgz /CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL}"
   fi
done
