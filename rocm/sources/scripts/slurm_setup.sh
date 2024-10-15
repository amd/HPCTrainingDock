#!/bin/bash

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

usage()
{
   echo "Usage:"
   echo "  --help: this usage information"
   exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi
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

echo ""
echo "====================================="
echo "Installing Slurm with:"
echo "====================================="
echo ""

if [ "${DISTRO}" = "ubuntu" ]; then
   # these are for slurm   :  libpmi2-0-dev 
   ${SUDO} apt-get update -y
   ${SUDO} apt-cache search libpmi*
   ${SUDO} ${DEB_FRONTEND} apt-get install -y libpmi2-0-dev \
                           slurmd slurmctld

   apt-get -q clean && ${SUDO} rm -rf /var/lib/apt/lists/*
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   ${SUDO} yum install -y munge munge-devel
   ${SUDO} yum install -y slurm-slurmd slurm-slurmctld
   ${SUDO} groupadd -g 900 slurm
   ${SUDO} useradd -m -c "SLURM workload manager" -d /var/lib/slurm -u 900 -g slurm -s /bin/bash slurm
else
   echo "DISTRO version ${DISTRO} not recognized or supported"
   exit
fi

${SUDO} cp /tmp/slurm.conf /etc/slurm/slurm.conf
${SUDO} cp /tmp/gres.conf /etc/slurm/gres.conf

${SUDO} chown slurm /etc/slurm/slurm.conf
${SUDO} chgrp slurm /etc/slurm/slurm.conf
${SUDO} chmod 777 /etc/slurm

${SUDO} echo "OPTIONS=\"--force --key-file /etc/munge/munge.key --num-threads 10\"" > /etc/default/munge

