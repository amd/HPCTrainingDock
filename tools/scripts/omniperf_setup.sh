#!/bin/bash

ROCM_VERSION=6.0
AMD_STAGING=0
REPLACE=0
INSTALL_OMNIPERF_RESEARCH=0
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  --help: display this usage information"
   echo "  --install_omniperf_research: [INSTALL_OMNIPERF_RESEARCH default is false]"
   echo "  --rocm-version: default is $ROCM_VERSION"
   echo "  --amd-staging: set to 1 to build the amd-staging branch, default is 0"
   echo "  --replace: set to 1 to remove existing installation directory, default is 0"
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
      "--help")
          shift
          usage
	  ;;
      "--install-omniperf_research")
          shift
          INSTALL_OMNIPERF_RESEARCH=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--amd-staging")
          shift
          AMD_STAGING=${1}
          reset-last
          ;;
      "--replace")
          shift
          REPLACE=${1}
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

echo ""
echo "====================================="
echo "Installing OmniPerf:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "====================================="
echo ""

if [[ "$INSTALL_OMNIPERF_RESEARCH" == "0" ]];then
   exit
fi

INSTALL_DIR=/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.0

if [ -d "$INSTALL_DIR" ]; then
   if [ "$REPLACE" != 1 ]; then
      echo "Installation directory $INSTALLATION_DIR exists and replace option is false"
      echo "Exiting"
      exit
   else
      ${SUDO} rm -rf ${INSTALLATION_DIR}
   fi
fi

set -v
if [ "$AMD_STAGING" = 1 ]; then
   git clone -b amd-staging https://github.com/ROCm/rocprofiler-compute
   cd omniperf
else
   wget -q wget https://github.com/ROCm/rocprofiler-compute/releases/download/v2.0.0-RC1/omniperf-2.0.0-RC1.tar.gz
   tar xfz omniperf-2.0.0-RC1.tar.gz
   cd ./omniperf-2.0.0-RC1
fi

${SUDO} mkdir -p ${INSTALL_DIR}
if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod a+w ${INSTALL_DIR}
fi

sed -i '152i \                                            .astype(str)' src/utils/tty.py
python3 -m pip install -t ${INSTALL_DIR}/python-libs -r requirements.txt --upgrade
python3 -m pip install -t ${INSTALL_DIR}/python-libs pytest --upgrade
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/ \
      -DCMAKE_BUILD_TYPE=Release \
      -DPYTHON_DEPS=${INSTALL_DIR}/python-libs \
      -DMOD_INSTALL_PATH=${INSTALL_DIR}/modulefiles ..
${SUDO} make install
cd ../..
rm -rf omniperf-2.0.0-RC1 omniperf-2.0.0-RC1.tar.gz omniperf

if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod go-w ${INSTALL_DIR}
fi

${SUDO} sed -i -e 's/ascii/utf-8/' /opt/rocmplus-*/omniperf-*/bin/utils/specs.py

# Create a module file for Mvapich
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf

if [ -d "$MODULE_PATH" ]; then
   if [ "$REPLACE" != 1 ]; then
      echo "Installation directory $MODULE_PATH exists and replace option is false"
      echo "Exiting"
      exit
   else
      ${SUDO} rm -rf ${MODULE_PATH}/2.0.0*.lua 
   fi
fi


${SUDO} mkdir -p ${MODULE_PATH}

if [ "$AMD_STAGING" = 1 ]; then
   MODULE_VERSION=2.0.0-dev.lua
else
   MODULE_VERSION=2.0.0.lua
fi

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${MODULE_VERSION}
	local help_message = [[

	Omniperf is an open-source performance analysis tool for profiling
	machine learning/HPC workloads running on AMD MI GPUs.

	Version 2.0.0
	]]

	help(help_message,"\n")

	whatis("Name: omniperf")
	whatis("Version: 2.0.0")
	whatis("Keywords: Profiling, Performance, GPU")
	whatis("Description: tool for GPU performance profiling")
	whatis("URL: https://github.com/AMDResearch/omniperf")

	-- Export environmental variables
	local topDir="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.0"
	local binDir="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.0/bin"
	local shareDir="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.0/share"
	local pythonDeps="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.0/python-libs"
	local roofline="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.0/bin/utils/rooflines/roofline-ubuntu20_04-mi200-rocm5"

	setenv("OMNIPERF_DIR",topDir)
	setenv("OMNIPERF_BIN",binDir)
	setenv("OMNIPERF_SHARE",shareDir)
	setenv("ROOFLINE_BIN",roofline)

	-- Update relevant PATH variables
	prepend_path("PATH",binDir)
	if ( pythonDeps  ~= "" ) then
   	prepend_path("PYTHONPATH",pythonDeps)
	end

	-- Site-specific additions
	-- depends_on "python"
	-- depends_on "rocm"
	prereq(atleast("rocm","${ROCM_VERSION}"))
	--  prereq("mongodb-tools")
	local home = os.getenv("HOME")
	setenv("MPLCONFIGDIR",pathJoin(home,".matplotlib"))
EOF
