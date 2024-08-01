#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

echo ""
echo "==================================="
echo "Starting BaseOSPackages Install with"
echo "DISTRO: $DISTRO" 
echo "DISTRO_VERSION: $DISTRO_VERSION" 
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
      python3-pip lsb-release libpapi-dev libpfm4-dev libudev1 rpm librpm-dev curl apt-utils vim tmux rsync sudo \
      bison flex texinfo  libnuma-dev pkg-config  libibverbs-dev  rdmacm-utils ssh locales \
      python3-dev python3-venv \
      gcc g++ gfortran

   sudo DEBIAN_FRONTEND=noninteractive localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

# Install needed dependencies -- tcl and lmod
#   sudo DEBIAN_FRONTEND=noninteractive apt-get install -q -y tcl tcl-dev lmod 
#   sudo sed -i -e '1,$s!/etc/lmod/modules!/etc/lmod/modules/Linux\n/etc/lmod/modules/ROCm\n/etc/lmod/modules/ROCmPlus\n/etc/lmod/modules/ROCmPlus-MPI\n/etc/lmod/modules/ROCmPlus-AMDResearchTools\n/etc/lmod/modules/ROCmPlus-LatestCompilers\n//etc/lmod/modules/ROCmPlus-AI!' /etc/lmod/modulespath
#   sudo ln -s /usr/share/lmod/6.6/init/profile /etc/profile.d/z00_lmod.sh
#   sudo ln -s /usr/share/lmod/6.6/init/cshrc /etc/profile.d/z00_lmod.csh
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

sudo python3 -m pip install 'cmake==3.28.3'
