#!/bin/bash

echo ""
echo "############# Lmod Setup script ################"
echo ""

sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update
sudo DEBIAN_FRONTEND=noninteractive apt-get -qqy install lmod

sudo sed -i -e '1,$s!/etc/lmod/modules!/etc/lmod/modules/Linux\n/etc/lmod/modules/ROCm\n/etc/lmod/modules/ROCmPlus\n/etc/lmod/modules/ROCmPlus-MPI\n/etc/lmod/modules/ROCmPlus-AMDResearchTools\n/etc/lmod/modules/ROCmPlus-LatestCompilers\n/etc/lmod/modules/ROCmPlus-AI!' /etc/lmod/modulespath
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

sudo DEBIAN_FRONTEND=noninteractive apt-get -q clean && sudo rm -rf /var/lib/apt/lists/*
