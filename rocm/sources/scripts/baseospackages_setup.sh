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
   sudo chown -Rv _apt:root /var/cache/apt/archives/partial/
   sudo chmod -Rv 700 /var/cache/apt/archives/partial/

   # Python3-dev and python3-venv are for AI/ML
   # Make sure we have a default compiler for the system -- gcc, g++, gfortran
   sudo apt-get update && \
   sudo apt-get dist-upgrade -y && \
   sudo apt-get install -y build-essential cmake libnuma1 wget gnupg2 m4 bash-completion git-core autoconf libtool autotools-dev \
      python3-pip lsb-release libpapi-dev libpfm4-dev libudev1 rpm librpm-dev curl apt-utils vim tmux rsync sudo \
      bison flex texinfo  libnuma-dev pkg-config  libibverbs-dev  rdmacm-utils ssh locales \
      python3-dev python3-venv \
      gcc g++ gfortran

   localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8

# Install needed dependencies -- tcl and lmod
   sudo apt-get install -y tcl tcl-dev \
     lmod && \
     sed -i -e '1,$s!/etc/lmod/modules!/etc/lmod/modules/Linux\n/etc/lmod/modules/ROCm\n/etc/lmod/modules/ROCmPlus\n/etc/lmod/modules/ROCmPlus-MPI\n/etc/lmod/modules/ROCmPlus-AMDResearchTools\n/etc/lmod/modules/ROCmPlus-LatestCompilers\n//etc/lmod/modules/ROCmPlus-AI!' /etc/lmod/modulespath && \
     ln -s /usr/share/lmod/6.6/init/profile /etc/profile.d/z00_lmod.sh &&  ln -s /usr/share/lmod/6.6/init/cshrc /etc/profile.d/z00_lmod.csh
fi

if [ "${DISTRO}" = "opensuse leap" ]; then
   zypper update -y && \
   zypper dist-upgrade -y && \
   zypper install -y -t pattern devel_basis && \
   zypper install -y python3-pip openmpi3-devel gcc-c++ git libnuma-devel dpkg-devel rpm-build wget curl binutils-gold
fi

if [ "${DISTRO}" = "rocky linux" ]; then
   yum groupinstall -y "Development Tools"
   yum install -y epel-release
   yum install -y --allowerasing curl dpkg-devel numactl-devel openmpi-devel papi-devel python3-pip wget zlib-devel 
   yum clean all
fi

python3 -m pip install 'cmake==3.28.3'
