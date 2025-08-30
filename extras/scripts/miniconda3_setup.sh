#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"
PYTHON_VERSION="10"
BUILD_MINICONDA3=0
MINICONDA3_VERSION="25.3.1"
MINICONDA3_VERSION_DOWNLOAD=${MINICONDA3_VERSION}-1
MODULE_PATH=/etc/lmod/modules/LinuxPlus/miniconda3/
MINICONDA3_PATH=/opt/miniconda3-v${MINICONDA3_VERSION}
MINICONDA3_PATH_INPUT=""



if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --python-version [ PYTHON_VERSION ], python3 minor release, default $PYTHON_VERSION"
   echo "  --build-miniconda3 [BUILD_MINICONDA3], installs Miniconda3, default $BUILD_MINICONDA3"
   echo "  --miniconda3-version [MINICONDA3_VERSION], Miniconda3 version, default $MINICONDA3_VERSION"
   echo "  --install-path [ MINICONDA3_PATH_INPUT ], default is $MINICONDA3_PATH "
   echo "  --module-path [ MODULE_PATH ], default is $MODULE_PATH "
   echo "  --help: print this usage information"
   exit 1
}

send-error()
{
    usage
    echo -e "\nError: ${@}"
    exit 1
}

reset-last()
{
   last() { send-error "Unsupported argument :: ${1}"; }
}

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
       "--build-miniconda3")
          shift
          BUILD_MINICONDA3=${1}
          reset-last
          ;;
      "--help")
          usage
          ;;
       "--install-path")
          shift
          MINICONDA3_PATH_INPUT=${1}
          reset-last
          ;;
       "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
       "--miniconda3-version")
          shift
          MINICONDA3_VERSION=${1}
          reset-last
          ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
          reset-last
          ;;
      "--*")
          send-error "Unsupported argument at position $((${n} + 1)) :: ${1}"
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

if [ "${MINICONDA3_PATH_INPUT}" != "" ]; then
   MINICONDA3_PATH=${MINICONDA3_PATH_INPUT}
else
   # override path in case MINICONDA3_VERSION has been supplied as input
   MINICONDA3_PATH=/opt/miniconda3-v${MINICONDA3_VERSION}
fi

echo ""
echo "============================"
echo " Installing Miniconda3 with:"
echo "MINICONDA3_VERSION is $MINICONDA3_VERSION"
echo "PYTHON_VERSION (python 3 minor release) is $PYTHON_VERSION"
echo "BUILD_MINICONDA3 is $BUILD_MINICONDA3"
echo "Installing in: $MINICONDA3_PATH"
echo "Creating module file in: $MODULE_PATH"
echo "============================"
echo ""


if [ "${BUILD_MINICONDA3}" = "0" ]; then

   echo "Miniconda3 will not be built, according to the specified value of BUILD_MINICONDA3"
   echo "BUILD_MINICONDA3: $BUILD_MINICONDA3"
   exit

else
   echo ""
   echo "============================"
   echo " Building Miniconda3"
   echo "============================"
   echo ""


   # don't use sudo if user has write access to install path
   if [ -d "$MINICONDA3_PATH" ]; then
      # don't use sudo if user has write access to install path
      if [ -w ${MINICONDA3_PATH} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      # if install path does not exist yet, the check on write access will fail
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   wget -q https://repo.anaconda.com/miniconda/Miniconda3-py3${PYTHON_VERSION}_${MINICONDA3_VERSION_DOWNLOAD}-$(uname)-$(uname -m).sh -O /tmp/miniconda-installer.sh
   chmod +x /tmp/miniconda-installer.sh
   ${SUDO} mkdir -p ${MINICONDA3_PATH}
   ${SUDO} /tmp/miniconda-installer.sh -b -u -p ${MINICONDA3_PATH}
   export PATH="${MINICONDA3_PATH}/bin:${PATH}"
   conda config --set always_yes yes --set changeps1 no
   # conda update -c defaults -n base conda
   ${SUDO} mkdir -p ${MINICONDA3_PATH}/envs/py3.${PYTHON_VERSION}
   ${SUDO} chown -R ${USER}:${USER} ${MINICONDA3_PATH}/*
   conda create -p ${MINICONDA3_PATH}/envs/py3.${PYTHON_VERSION} -c defaults -c conda-forge python=3.${PYTHON_VERSION} pip
   ${MINICONDA3_PATH}/envs/py3.${PYTHON_VERSION}/bin/python -m pip install numpy perfetto dataclasses
   conda clean -a -y
   ${SUDO} chown -R root:root ${MINICONDA3_PATH}/*
   rm -f /tmp/miniconda-installer.sh

   # Create a module file for miniconda3
   if [ -d "$MODULE_PATH" ]; then
      # use sudo if user does not have write access to module path
      if [ ! -w ${MODULE_PATH} ]; then
         SUDO="sudo"
      else
         echo "WARNING: not using sudo since user has write access to module path"
      fi
   else
      # if module path dir does not exist yet, the check on write access will fail
      SUDO="sudo"
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   ${SUDO} mkdir -p ${MODULE_PATH}

   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${MINICONDA3_VERSION}.lua
	conflict("miniforge3")
	local root = "${MINICONDA3_PATH}"
	local python_version = capture(root .. "/bin/python -V | awk '{print $2}'")
	local conda_version = capture(root .. "/bin/conda --version | awk '{print $2}'")
	function trim(s)
	  return (s:gsub("^%s*(.-)%s*$", "%1"))
	end
	conda_version = trim(conda_version)
	help([[ Loads the Miniconda environment supporting Community-Collections. ]])
	whatis("Sets the environment to use the Community-Collections Miniconda.")

	setenv("PYTHONPREFIX",root)
	prepend_path("PATH",pathJoin(root,"bin"))
	prepend_path("PATH",pathJoin(root,"condabin"))

	local myShell = myShellName()
	if (mode() == "load") then
	   if (myShell == "bash") then
	      cmd = "source " .. root .. "/etc/profile.d/conda.sh"
	   else
	      cmd = "source " .. root .. "/etc/profile.d/conda.csh"
	   end
	   execute{cmd=cmd, modeA = {"load"}}
	end

	if (myShell == "bash") then
	   if (mode() == "unload") then
	   remove_path("PATH", pathJoin(root,"condabin"))
	   end
	   cmd1 = "unset CONDA_EXE; unset _CE_CONDA; unset _CE_M; " ..
	         "unset -f __conda_activate; unset -f __conda_reactivate; " ..
	         "unset -f __conda_hashr; unset CONDA_SHLVL; unset _CONDA_EXE; " ..
	         "unset _CONDA_ROOT; unset -f conda; unset CONDA_PYTHON_EXE"
	   execute{cmd=cmd1, modeA={"unload"}}
	else
	   cmd2 = "unsetenv CONDA_EXE; unsetenv _CONDA_ROOT; unsetenv _CONDA_EXE; " ..
	   "unsetenv CONDA_SHLVL; unalias conda; unsetenv CONDA_PYTHON_EXE"
	   execute{cmd=cmd2, modeA={"unload"}}
	end

EOF

fi
