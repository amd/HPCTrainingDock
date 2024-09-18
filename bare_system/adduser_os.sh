#!/bin/bash

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

if [ "${DISTRO}" = "ubuntu" ]; then
   result=`which adduser |& grep -v "not found" | wc -l`
   if [[ "${result}" == "0" ]]; then
      ${SUDO} apt-get update
      ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y adduser
   fi
   adduser --home /home/sysadmin --uid 20000 --shell /bin/bash --disabled-password --gecos '' sysadmin
   echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
   usermod -a -G sudo,video,render,renderalt sysadmin
fi

if [ "${DISTRO}" = "rocky linux" ]; then
# password is disabled by default and --disable-password option is not portable. Same with --gecos
   adduser --home /home/sysadmin --uid 20000 --shell /bin/bash sysadmin
   echo '/^#\s*\%wheel\s*ALL=(ALL)\s*NOPASSWD/s/^#\s*//' | EDITOR='sed -f- -i' visudo
#  grep wheel /etc/sudoers
   usermod -a -G wheel,video,render sysadmin
fi

if [ "${DISTRO}" = "opensuse leap" ]; then
   useradd --create-home --user-group --home-dir /home/sysadmin --uid 20000 --shell /bin/bash sysadmin
   # Need to install the system-group-wheel package -- see bootstrap_os.sh script
   usermod -a -G wheel,video,render sysadmin
   echo '/^#\s*\%wheel\s*ALL=(ALL:ALL)\s*NOPASSWD/s/^#\s*//' | EDITOR='sed -f- -i' visudo
   #groups sysadmin
   #cat /etc/sudoers
fi
