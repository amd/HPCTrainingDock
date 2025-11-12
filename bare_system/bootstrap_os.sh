#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

if [ "${DISTRO}" = "ubuntu" ]; then
   apt-get -q -y update
   apt-get install -q -y vim ${SUDO} apt-utils make
   groupadd render -g 109
   groupadd renderalt -g 110
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   yum update -y
   yum install -y ${SUDO} make which yum
   groupadd render -g 109
   groupadd renderalt -g 110
   dnf install -y cmake wget
   groupadd sudo
elif [ "${DISTRO}" = "opensuse leap" ]; then
   zypper update -y
   zypper dist-upgrade -y
   zypper --non-interactive in ${SUDO} vim make system-group-wheel
else
   echo "DISTRO version ${DISTRO} not recognized or supported"
   exit
fi
