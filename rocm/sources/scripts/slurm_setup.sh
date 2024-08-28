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
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   unset DEB_FRONTEND
fi

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
   ${SUDO} apt-get update -y
   ${SUDO} apt-cache search libpmi*
   ${SUDO} ${DEB_FRONTEND} apt-get install -y libpmi2-0-dev \
                           slurmd slurmctld

   apt-get -q clean && ${SUDO} rm -rf /var/lib/apt/lists/*

   ${SUDO} cp /tmp/slurm.conf /etc/slurm/slurm.conf
   ${SUDO} cp /tmp/gres.conf /etc/slurm/gres.conf

   ${SUDO} chown slurm /etc/slurm/slurm.conf
   ${SUDO} chgrp slurm /etc/slurm/slurm.conf
   ${SUDO} chmod 777 /etc/slurm

   ${SUDO} echo "OPTIONS=\"--force --key-file /etc/munge/munge.key --num-threads 10\"" > /etc/default/munge
fi

