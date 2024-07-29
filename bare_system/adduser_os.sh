#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [ "${DISTRO}" = "ubuntu" ]; then
   adduser --home /home/sysadmin --uid 20000 --shell /bin/bash --disabled-password --gecos '' sysadmin
   echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
   #usermod -a -G video,render,renderalt,sudo --password $(echo amdtest | openssl passwd -1 -stdin) sysadmin
   usermod -a -G video,render,renderalt,sudo sysadmin
fi

if [ "${DISTRO}" = "rocky linux" ]; then
# password is disable by default and option is not portable. Same with --gecos
   adduser --home /home/sysadmin --uid 20000 --shell /bin/bash sysadmin
   usermod -a -G video,render,renderalt,wheel sysadmin
fi
