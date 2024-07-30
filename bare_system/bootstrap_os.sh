#!/bin/sh

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [ "${DISTRO}" = "ubuntu" ]; then
   apt-get -q -y update
   apt-get install -q -y vim sudo apt-utils make
   groupadd render -g 109
   groupadd renderalt -g 110
fi

if [ "${DISTRO}" = "rocky linux" ]; then
   yum update -y
   yum install -y sudo
   groupadd render -g 109
   groupadd renderalt -g 110
fi

if [ "${DISTRO}" = "opensuse leap" ]; then
   zypper update -y
   zypper dist-upgrade -y
   zypper --non-interactive in sudo vim
fi
