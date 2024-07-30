#!/bin/bash

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

echo ""
echo "############# Lmod Setup script ################"
echo ""

if [ "${DISTRO}" = "ubuntu" ]; then
   sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update
   sudo DEBIAN_FRONTEND=noninteractive apt-get -qqy install lmod
fi
if [ "${DISTRO}" = "rocky linux" ]; then
   sudo yum -y install lmod
fi
if [ "${DISTRO}" = "opensuse leap" ]; then
   zypper --non-interactive install lua-lmod
fi

sudo sed -i -e '1,$s!/etc/lmod/modules!/etc/lmod/modules/Linux\n/etc/lmod/modules/ROCm\n/etc/lmod/modules/ROCmPlus\n/etc/lmod/modules/ROCmPlus-MPI\n/etc/lmod/modules/ROCmPlus-AMDResearchTools\n/etc/lmod/modules/ROCmPlus-LatestCompilers\n/etc/lmod/modules/ROCmPlus-AI\n/etc/lmod/modules/misc!' /etc/lmod/modulespath
cat /etc/lmod/modulespath

NUM_PROFILE_D=`grep '/etc/profile.d' /etc/bash.bashrc |wc -l`
if test "$NUM_PROFILE_D" -lt 1; then
  echo "Lmod setup in /etc/bash.bashrc not found"
  echo "Adding the following to the end of the /etc/bash.bashrc"

cat << EOF | sudo tee -a /etc/bash.bashrc
if ! shopt -q login_shell; then
  if [ -d /etc/profile.d ]; then
    for i in /etc/profile.d/*.sh; do
      if [ -r \$i ]; then
        . \$i
      fi
    done
  fi
fi
EOF

else
  echo "Lmod setup in /etc/bash.bashrc found"
fi

if test -L /etc/profile.d/z00_lmod.sh; then
  echo "File /etc/profile.d/z00_lmod.sh already exists"
else
  echo "File /etc/profile.d/z00_lmod.sh does not exist"
  echo "Creating /etc/profile.d/z00_lmod.sh file"
  sudo ln -s /usr/share/lmod/6.6/init/profile /etc/profile.d/z00_lmod.sh
fi

if test -L /etc/profile.d/z00_lmod.csh; then
  echo "File /etc/profile.d/z00_lmod.csh already exists"
else
  echo "File /etc/profile.d/z00_lmod.csh does not exist"
  echo "Creating /etc/profile.d/z00_lmod.csh file"
  sudo ln -s /usr/share/lmod/6.6/init/cshrc /etc/profile.d/z00_lmod.csh
fi

if [ "${DISTRO}" = "ubuntu" ]; then
   sudo DEBIAN_FRONTEND=noninteractive apt-get -q clean && sudo rm -rf /var/lib/apt/lists/*
fi
