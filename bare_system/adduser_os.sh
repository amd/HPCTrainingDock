#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [ "${DISTRO}" = "ubuntu" ]; then
   adduser --home /home/sysadmin --uid 20000 --shell /bin/bash --disabled-password --gecos '' sysadmin
   echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
   usermod -a -G video,render,renderalt,sudo sysadmin
fi

if [ "${DISTRO}" = "rocky linux" ]; then
# password is disabled by default and --disable-password option is not portable. Same with --gecos
#  yum install diffutils -y
   adduser --home /home/sysadmin --uid 20000 --shell /bin/bash sysadmin
   #echo '%wheel ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
#  grep wheel /etc/sudoers
#  cp /etc/sudoers /tmp
   echo '/^#\s*\%wheel\s*ALL=(ALL)\s*NOPASSWD/s/^#\s*//' | EDITOR='sed -f- -i' visudo
#  echo "Changed lines"
#  echo "============="
#  diff /etc/sudoers /tmp
#  echo "============="
#  grep wheel /etc/sudoers
   usermod -a -G video,render,renderalt,wheel sysadmin
fi

if [ "${DISTRO}" = "opensuse leap" ]; then
   useradd --create-home --user-group --home-dir /home/sysadmin --uid 20000 --shell /bin/bash sysadmin
   # not working yet
   #echo '%wheel ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
#  cp /etc/sudoers /tmp
   #echo '%wheel ALL=(ALL) NOPASSWD:ALL' | EDITOR='tee -a' visudo
   echo '/^#\s*\%wheel\s*ALL=(ALL:ALL)\s*NOPASSWD/s/^#\s*//' | EDITOR='sed -f- -i' visudo
   #usermod -a -G video,render,wheel sysadmin
   usermod -a -G video,render sysadmin
#  echo "Changed lines"
#  echo "============="
#  diff /etc/sudoers /tmp
#  echo "============="
   #cat /etc/sudoers
fi
