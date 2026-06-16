#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" == *"rocky"* || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

if [ "${DISTRO}" = "ubuntu" ]; then
   apt-get -q -y update
   apt-get install -q -y vim ${SUDO} apt-utils make
   groupadd render -g 109
   groupadd renderalt -g 110
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   # NOTE: deliberately NOT running a blanket `yum update -y` here. On the
   # rolling RHEL-family base images (almalinux/rockylinux), a full update
   # upgrades the *-release package and bumps /etc/os-release VERSION_ID to the
   # newest minor (e.g. 9.6 -> 9.8). rocm_setup.sh derives the amdgpu-install
   # repo path from VERSION_ID (.../rhel/<minor>/), and repo.radeon.com only
   # publishes the minors AMD has qualified (e.g. 9.4/9.6/9.7 for ROCm 7.2.4),
   # so a bumped 9.8 yields a 404 and the ROCm install silently no-ops. The
   # base image already pins the requested minor, so we just refresh metadata.
   yum makecache -y || true
   yum install -y ${SUDO} make which yum
   groupadd render -g 109
   groupadd renderalt -g 110
   dnf install -y cmake wget
   groupadd sudo
elif [ "${DISTRO}" = "opensuse leap" ]; then
   zypper update -y
   zypper dist-upgrade -y
   zypper --non-interactive in ${SUDO} vim make system-group-wheel
else
   echo "DISTRO version ${DISTRO} not recognized or supported"
   exit
fi
