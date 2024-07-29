#!/bin/sh

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

if [ "${DISTRO}" = "ubuntu" ]; then
   apt-get -q -y update
   apt-get install -q -y vim sudo apt-utils make
fi

if [ "${DISTRO}" = "rocky linux" ]; then
   yum update -y
   yum install -y sudo
fi
