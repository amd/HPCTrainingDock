#!/bin/bash

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

AMDGPU_GFXMODEL=`rocminfo | grep gfx | sed -e 's/Name://' | head -1 |sed 's/ //g'`

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
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
   apt-get update -y \
     && apt-cache search libpmi* \
     && apt-get install -y libpmi2-0-dev \
     && apt-get  install -y slurmd slurmctld

   apt-get -q clean && sudo rm -rf /var/lib/apt/lists/*

   cp /tmp/slurm.conf /etc/slurm/slurm.conf
   cp /tmp/gres.conf /etc/slurm/gres.conf

   chown slurm /etc/slurm/slurm.conf \
    && chgrp slurm /etc/slurm/slurm.conf  \
    && chmod 777 /etc/slurm

   echo "OPTIONS=\"--force --key-file /etc/munge/munge.key --num-threads 10\"" > /etc/default/munge
fi

