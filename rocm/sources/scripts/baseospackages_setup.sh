#!/bin/bash

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_CODENAME=`cat /etc/os-release | grep '^VERSION_CODENAME' | sed -e 's/VERSION_CODENAME=//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

echo ""
echo "==================================="
echo "Starting BaseOSPackages Install with"
echo "DISTRO: $DISTRO" 
echo "DISTRO_VERSION: $DISTRO_VERSION" 
echo "DISTRO_CODENAME is $DISTRO_CODENAME"
echo "==================================="
echo ""

if [ "${DISTRO}" = "ubuntu" ]; then
   # Not needed -- should already be these owner/permissions
   #sudo chown -Rv _apt:root /var/cache/apt/archives/partial/
   #sudo chmod -Rv 700 /var/cache/apt/archives/partial/

   export DEBIAN_FRONTEND=noninteractive
   # Python3-dev and python3-venv are for AI/ML
   # Make sure we have a default compiler for the system -- gcc, g++, gfortran
   SUDO_COMMAND=`which sudo`
   if [ "${SUDO_COMMAND}" != "/usr/bin/sudo" ]; then
      apt-get -q -y update
      apt-get -q -y install sudo
   fi
   sudo apt-get -q -y update
   sudo DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -q -y build-essential cmake libnuma1 wget gnupg2 m4 bash-completion git-core autoconf libtool autotools-dev \
      lsb-release libpapi-dev libpfm4-dev libudev1 rpm librpm-dev curl apt-utils vim tmux rsync sudo \
      bison flex texinfo libnuma-dev pkg-config libibverbs-dev rdmacm-utils ssh locales gpg ca-certificates \
      gcc g++ gfortran ninja-build pipx libboost-all-dev liblzma-dev

# Install python packages
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -q -y python3-pip python3-dev python3-venv

   sudo DEBIAN_FRONTEND=noninteractive localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
fi

if [ "${DISTRO}" = "opensuse leap" ]; then
   sudo zypper update -y && \
   sudo zypper dist-upgrade -y && \
   sudo zypper install -y -t pattern devel_basis && \
   sudo zypper install -y python3-pip openmpi3-devel gcc-c++ git libnuma-devel dpkg-devel rpm-build wget curl binutils-gold
fi

if [ "${DISTRO}" = "rocky linux" ]; then
   sudo yum groupinstall -y "Development Tools"
   sudo yum install -y sudo
   sudo yum install -y epel-release
   sudo yum install -y --allowerasing curl dpkg-devel numactl-devel openmpi-devel papi-devel python3-pip wget zlib-devel 
   sudo yum clean all
fi

if [[ `which python3-pip | wc -l` -ge 1 ]]; then
   sudo python3 -m pip install 'cmake==3.28.3'
else
   # Instructions from https://apt.kitware.com/
   # Remove standard version installed with ubuntu packages
   sudo DEBIAN_FRONTEND=noninteractive apt-get purge --auto-remove -y cmake

   # Step 1
   sudo DEBIAN_FRONTEND=noninteractive apt-get -y update
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates gpg wget
   # Step 2
   test -f /usr/share/doc/kitware-archive-keyring/copyright || \
      wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | \
      gpg --dearmor - | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null
   # Step 3
   echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${DISTRO_CODENAME} main" | \
      sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null
   # Step 4
   sudo DEBIAN_FRONTEND=noninteractive apt-get -y update
   test -f /usr/share/doc/kitware-archive-keyring/copyright || \
      sudo rm /usr/share/keyrings/kitware-archive-keyring.gpg
   # Step 5
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kitware-archive-keyring

   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cmake
   CMAKE_VERSION=`cmake --version`
   echo "Installed latest version of cmake ($CMAKE_VERSION)"
fi
