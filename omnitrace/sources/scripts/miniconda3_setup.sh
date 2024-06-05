#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          ;;
      "--python-versions")
          shift
          PYTHON_VERSIONS=${1}
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done


echo ""
echo "============================"
echo " Installing Miniconda3 with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "PYTHON_VERSIONS is $PYTHON_VERSIONS"
echo "============================"
echo ""


if [ "${DISTRO}" = "ubuntu" ] ; then
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda-installer.sh 
    chmod +x /tmp/miniconda-installer.sh
    sudo /tmp/miniconda-installer.sh -b -p /opt/miniconda3 
    export PATH="/opt/miniconda3/bin:${PATH}" 
    conda config --set always_yes yes --set changeps1 no 
    conda update -c defaults -n base conda 
    for i in ${PYTHON_VERSIONS}; do conda create -n py3.${i} -c defaults -c conda-forge python=3.${i} pip; done 
    for i in ${PYTHON_VERSIONS}; do /opt/conda/envs/py3.${i}/bin/python -m pip install numpy perfetto dataclasses; done
    conda clean -a -y 
    rm -f /tmp/miniconda-installer.sh
fi

## Create a module file for miniconda3
export MODULE_PATH=/etc/lmod/modules/Linux/miniconda3/

sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | sudo tee ${MODULE_PATH}/23.11.0.lua
	local root = "/opt/miniconda3"
	setenv("ANACONDA3ROOT", root)
	setenv("PYTHONROOT", root)
	local python_version = capture(root .. "/bin/python -V | awk '{print $2}'")
	local conda_version = capture(root .. "/bin/conda --version | awk '{print $2}'")
	function trim(s)
	  return (s:gsub("^%s*(.-)%s*$", "%1"))
	end
	conda_version = trim(conda_version)
	help([[ Loads the Miniconda environment supporting Community-Collections. ]])
	whatis("Sets the environment to use the Community-Collections Miniconda.")
	local myShell = myShellName()
	if (myShell == "bash") then
	  cmd = "source " .. root .. "/etc/profile.d/conda.sh"
	else
	  cmd = "source " .. root .. "/etc/profile.d/conda.csh"
	end
	execute{cmd=cmd, modeA = {"load"}}
	prepend_path("PATH", "/opt/miniconda3/bin")

	load("rocm/${ROCM_VERSION}")

EOF
