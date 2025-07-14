#!/bin/bash

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"
PYTHON_VERSION="10"
BUILD_MINIFORGE3=0
MODULE_PATH=/etc/lmod/modules/LinuxPlus/miniforge3/
MINIFORGE3_VERSION="24.9.0"
MINIFORGE3_VERSION_DOWNLOAD=${MINIFORGE3_VERSION}-0
MINIFORGE3_PATH=/opt/miniforge3-v${MINIFORGE3_VERSION}
MINIFORGE3_PATH_INPUT=""


if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  WARNING: when specifying --install-path and --module-path, the directories have to already exist because the script checks for write permissions"
   echo "  --python-version [ PYTHON_VERSION ], python3 minor release, default $PYTHON_VERSION"
   echo "  --build-miniforge3 [ BUILD_MINIFORGE3 ], installs Miniforge3, default $BUILD_MINIFORGE3"
   echo "  --miniforge3-version [ MINIFORGE3_VERSION ], Miniforge3 version, default $MINIFORGE3_VERSION"
   echo "  --install-path [ MINIFORGE3_PATH_INPUT ], default is $MINIFORGE3_PATH "
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
      "--miniforge3-version")
          shift
          MINIFORGE3_VERSION=${1}
	  reset-last
          ;;
       "--build-miniforge3")
          shift
          BUILD_MINIFORGE3=${1}
          reset-last
          ;;
       "--install-path")
          shift
          MINIFORGE3_PATH_INPUT=${1}
          reset-last
          ;;
       "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--help")
          usage
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

if [ "${MINIFORGE3_PATH_INPUT}" != "" ]; then
   MINIFORGE3_PATH=${MINIFORGE3_PATH_INPUT}
else
   # override path in case MINIFORGE3_VERSION has been supplied as input
   MINIFORGE3_PATH=/opt/miniforge3-v${MINIFORGE3_VERSION}
fi

echo ""
echo "============================"
echo " Installing Miniforge3 with:"
echo "MINIFORGE3_VERSION is $MINIFORGE3_VERSION"
echo "PYTHON_VERSION (python3 minor release) is $PYTHON_VERSION"
echo "BUILD_MINIFORGE3 is $BUILD_MINIFORGE3"
echo "Installing in: $MINIFORGE3_PATH"
echo "Creating module file in: $MODULE_PATH"
echo "============================"
echo ""


if [ "${BUILD_MINIFORGE3}" = "0" ]; then

   echo "Miniforge3 will not be built, according to the specified value of BUILD_MINIFORGE3"
   echo "BUILD_MINIFORGE3: $BUILD_MINIFORGE3"
   exit

else
   echo ""
   echo "============================"
   echo " Building Miniforge3"
   echo "============================"
   echo ""

   # don't use sudo if user has write access to install path
   if [ -d "$MINIFORGE3_PATH" ]; then
      # don't use sudo if user has write access to install path
      if [ -w ${MINIFORGE3_PATH} ]; then
         SUDO=""
      else
         echo "WARNING: using an install path that requires sudo"
      fi
   else
      # if install path does not exist yet, the check on write access will fail
      echo "WARNING: using sudo, make sure you have sudo privileges"
   fi

   # getting Miniforge3 version 24.9.0
   wget -q "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE3_VERSION_DOWNLOAD}/Miniforge3-$(uname)-$(uname -m).sh" -O /tmp/Miniforge3-$(uname)-$(uname -m).sh
   chmod +x /tmp/Miniforge3-*.sh
   ${SUDO} mkdir -p ${MINIFORGE3_PATH}
   ${SUDO} /tmp/Miniforge3-*.sh -b -u -p ${MINIFORGE3_PATH}
   rm -f /tmp/Miniforge3-*.sh

   # Create a module file for miniforge3
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
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/24.9.0.lua
	conflict("miniconda3")
	local root = "${MINIFORGE3_PATH}"
	setenv("MINIFORGE3_ROOT", root)
	setenv("CONDA_ENVS_PATH", pathJoin(root, "envs"))
	setenv("MAMBA_ROOT_PREFIX", root)
	prepend_path("PATH",pathJoin(root,"bin"))
	prepend_path("PATH",pathJoin(root,"condabin"))

	local myShell = myShellName()
	if (mode() == "load") then
	   if (myShell == "bash") then
	      cmd = "source " .. root .. "/etc/profile.d/conda.sh"
	      cmd1 = "source " .. root .. "/etc/profile.d/mamba.sh"
	   else
	      cmd = "source " .. root .. "/etc/profile.d/conda.csh"
	      cmd1 = "source " .. root .. "/etc/profile.d/mamba.csh"
	   end
	   execute{cmd=cmd, modeA = {"load"}}
	   execute{cmd=cmd1, modeA = {"load"}}
	end

	if (mode() == "unload") then
	   remove_path("PATH",pathJoin(root,"bin"))
	   remove_path("PATH",pathJoin(root,"condabin"))

	   if (myShell == "bash") then
	      cmd2 = "unset CONDA_EXE; unset _CE_CONDA; unset _CE_M; " ..
	            "unset CONDA_PYTHON_EXE; unset CONDA_SHLVL; " ..
	            "unset MAMBA_ROOT_PREFIX; " ..
	            "unset -f __m_activate; unset -f __conda_reactivate; " ..
	            "unset -f __conda_hashr; unset -f conda; " ..
	            "unset CONDA_PREFIX; unset CONDA_DEFAULT_ENV; " ..
	            "unset CONDA_PROMPT_MODIFIER; unset CONDA_ENV_PATH; " ..
	            "unset _CONDA_EXE; unset _CONDA_ROOT; unset CONDA_BACKUP_PATH; " ..
	            "unset MAMBA_NO_BANNER; " ..
	            "unset -f __conda_activate; unset -f __conda_reactivate; " ..
	            "unset -f __conda_hashr; unset -f conda; unset -f __conda_exe"
	   else
	      cmd2 = "unsetenv CONDA_EXE; unsetenv CONDA_PYTHON_EXE; unsetenv CONDA_SHLVL; " ..
	             "unsetenv _CONDA_EXE; unsetenv _CONDA_ROOT;" ..
	             "unsetenv MAMBA_NO_BANNER; unalias conda; " ..
	             "unsetenv _CE_CONDA; unsetenv _CE_M; " ..
	             "unsetenv CONDA_PREFIX; unsetenv CONDA_DEFAULT_ENV; " ..
	             "unsetenv CONDA_PROMPT_MODIFIER; unsetenv CONDA_ENV_PATH; " ..
	             "unsetenv CONDA_BACKUP_PATH; unsetenv MAMBA_ROOT_PREFIX; "
	   end
	   execute{cmd=cmd2, modeA={"unload"}}
	end

EOF

fi
