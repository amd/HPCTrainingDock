# Install needed dependencies -- tcl and lmod

SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y tcl tcl-dev lmod

${SUDO} sed -i -e '1,$s!/etc/lmod/modules!/etc/lmod/modules/Linux\n/etc/lmod/modules/ROCm\n/etc/lmod/modules/ROCmPlus\n/etc/lmod/modules/ROCmPlus-MPI\n/etc/lmod/modules/ROCmPlus-AMDResearchTools\n/etc/lmod/modules/ROCmPlus-LatestCompilers\n/etc/lmod/modules/ROCmPlus-AI\n/etc/lmod/modules/misc!' /etc/lmod/modulespath

${SUDO} ln -s /usr/share/lmod/6.6/init/profile /etc/profile.d/z00_lmod.sh

${SUDO} ln -s /usr/share/lmod/6.6/init/cshrc /etc/profile.d/z00_lmod.csh
