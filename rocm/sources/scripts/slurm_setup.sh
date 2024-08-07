#!/bin/bash

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

usage()
{
   echo "--amdgpu-gfxmodel [ AMDGPU-GFXMODEL ] default autodetected"
   echo "--help: this usage information"
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--amdgpu-gfxmodel")
         shift
         AMDGPU_GFXMODEL=${1}
         reset-last
         ;;
      "--help")
         usage
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

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

echo ""
echo "====================================="
echo "Installing Slurm with:"
echo "AMDGPU_GFXMODEL is $AMDGPU_GFXMODEL"
echo "====================================="
echo ""

if [ "${DISTRO}" = "ubuntu" ]; then
   # these are for slurm   :  libpmi2-0-dev 
   sudo apt-get update -y
   sudo apt-cache search libpmi*
   sudo apt-get install -y libpmi2-0-dev \
                           slurmd slurmctld

   apt-get -q clean && sudo rm -rf /var/lib/apt/lists/*

   sudo cp /tmp/slurm.conf /etc/slurm/slurm.conf
   sudo cp /tmp/gres.conf /etc/slurm/gres.conf

   sudo chown slurm /etc/slurm/slurm.conf
   sudo chgrp slurm /etc/slurm/slurm.conf
   sudo chmod 777 /etc/slurm

   sudo echo "OPTIONS=\"--force --key-file /etc/munge/munge.key --num-threads 10\"" > /etc/default/munge
fi

