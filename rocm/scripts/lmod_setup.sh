#!/bin/bash

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

SUDO="sudo"
export DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi


echo ""
echo "############# Lmod Setup script ################"
echo ""

if [ "${DISTRO}" = "ubuntu" ]; then
   ${SUDO} apt-get -qq update
   ${SUDO} ${DEB_FRONTEND} apt-get -qqy install lmod
   #${SUDO}  sed -i -e '1,$s!/etc/lmod/modules!/etc/lmod/modules/Linux\n/etc/lmod/modules/LinuxPlus\n/etc/lmod/modules/ROCm\n/etc/lmod/modules/ROCmPlus\n/etc/lmod/modules/ROCmPlus-MPI\n/etc/lmod/modules/ROCmPlus-AMDResearchTools\n/etc/lmod/modules/ROCmPlus-LatestCompilers\n/etc/lmod/modules/ROCmPlus-AI\n/etc/lmod/modules/misc!' /etc/lmod/modulespath
   #cat /etc/lmod/modulespath
   export BASH_INIT_FILE=/etc/bash.bashrc
fi
echo "DISTRO is ${DISTRO}"

if [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   ${SUDO} yum -y install epel-release
   ${SUDO} yum repolist
   ${SUDO} yum update -y
   ${SUDO} yum upgrade -y
   ${SUDO} dnf -y install Lmod
   export BASH_INIT_FILE=/etc/bashrc
fi
if [ "${DISTRO}" = "opensuse leap" ]; then
   zypper --non-interactive install lua-lmod
fi

NUM_PROFILE_D=`grep '/etc/profile.d' ${BASH_INIT_FILE} |wc -l`
if test "$NUM_PROFILE_D" -lt 1; then
  echo "Lmod setup in ${BASH_INIT_FILE} not found"
  echo "Adding the following to the end of the ${BASH_INIT_FILE}"

cat << EOF | ${SUDO} tee -a ${BASH_INIT_FILE}
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
  echo "Lmod setup in ${BASH_INIT_FILE} found"
fi

if test -L /etc/profile.d/z00_lmod.sh; then
  echo "File /etc/profile.d/z00_lmod.sh already exists"
else
  echo "File /etc/profile.d/z00_lmod.sh does not exist"
  echo "Creating /etc/profile.d/z00_lmod.sh file"
  LMOD_VERSION=`ls /usr/share/lmod | grep -v lmod`
  ${SUDO} ln -s /usr/share/lmod/${LMOD_VERSION}/init/profile /etc/profile.d/z00_lmod.sh
fi

if test -f /etc/profile.d/z01_StdEnv.sh; then
   echo "File /etc/profile.d/z01_lmod.sh already exists"
else
  echo "File /etc/profile.d/z01_lmod.sh does not exist"
  echo "Creating /etc/profile.d/z01_lmod.sh file"
  #default is /etc/lmod/modules:/usr/share/lmod/lmod/modulefiles/
  echo "MODULEPATH=/etc/lmod/modules/Linux:/etc/lmod/modules/LinuxPlus:/etc/lmod/modules/ROCm:/etc/lmod/modules/ROCmPlus:/etc/lmod/modules/ROCmPlus-MPI:/etc/lmod/modules/ROCmPlus-AMDResearchTools:/etc/lmod/modules/ROCmPlus-LatestCompilers:/etc/lmod/modules/ROCmPlus-AI:/etc/lmod/modules/misc" > /etc/profile.d/z01_lmod.sh
fi

if test -L /etc/profile.d/z00_lmod.csh; then
  echo "File /etc/profile.d/z00_lmod.csh already exists"
else
  echo "File /etc/profile.d/z00_lmod.csh does not exist"
  echo "Creating /etc/profile.d/z00_lmod.csh file"
  LMOD_VERSION=`ls /usr/share/lmod | grep -v lmod`
  ${SUDO} ln -s /usr/share/lmod/${LMOD_VERSION}/init/cshrc /etc/profile.d/z00_lmod.csh
fi

if [ "${DISTRO}" = "ubuntu" ]; then
   ${SUDO} apt-get -q clean && ${SUDO} rm -rf /var/lib/apt/lists/*
fi

if test -f /etc/profile.d/z01_StdEnv.csh; then
   echo "File /etc/profile.d/z01_lmod.csh already exists"
else
  echo "File /etc/profile.d/z01_lmod.csh does not exist"
  echo "Creating /etc/profile.d/z01_lmod.csh file"
  echo "MODULEPATH=/etc/lmod/modules/Linux:/etc/lmod/modules/LinuxPlus:/etc/lmod/modules/ROCm:/etc/lmod/modules/ROCmPlus:/etc/lmod/modules/ROCmPlus-MPI:/etc/lmod/modules/ROCmPlus-AMDResearchTools:/etc/lmod/modules/ROCmPlus-LatestCompilers:/etc/lmod/modules/ROCmPlus-AI:/etc/lmod/modules/misc" > /etc/profile.d/z01_lmod.csh
fi
