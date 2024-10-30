#/bin/bash

# Variables controlling setup process

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

if [ "${DISTRO}" = "ubuntu" ]; then
   apt-get update
   apt-get install -y  net-tools iproute2 openssh-server iputils-ping
   systemctl enable ssh
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   yum update -y
   yum install -y net-tools iproute openssh-server iputils
   #systemctl enable ssh
#elif [ "${DISTRO}" = "opensuse leap" ]; then
fi
