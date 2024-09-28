#!/bin/bash

ROCM_VERSION=6.0
AMD_STAGING=0
REPLACE=0
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi


n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          ;;
      "--amd-staging")
          shift
          AMD_STAGING=${1}
          ;;
      "--replace")
          shift
          REPLACE=${1}
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

INSTALL_DIR=/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.1

if [ -d "$INSTALL_DIR" ]; then
   if [ "$REPLACE" != 1 ]; then
      echo "Installation directory $INSTALLATION_DIR exists and replace option is false"
      echo "Exiting"
      exit
   else
      ${SUDO} rm -rf ${INSTALLATION_DIR}
   fi
fi

if [ "$AMD_STAGING" = 1 ]; then
   git clone -b amd-staging https://github.com/ROCm/omniperf.git
   cd omniperf
else
   wget -q https://github.com/AMDResearch/omniperf/releases/download/v2.0.1/omniperf-2.0.1.tar.gz && \
     ${SUDO} tar xfz omniperf-2.0.1.tar.gz && \
     cd ./omniperf-2.0.1
fi

${SUDO} sed -i '152i \                                            .astype(str)' src/utils/tty.py \
     && ${SUDO} python3 -m pip install -t ${INSTALL_DIR}/python-libs -r requirements.txt --upgrade \
     && ${SUDO} python3 -m pip install -t ${INSTALL_DIR}/python-libs pytest --upgrade \
     && ${SUDO} mkdir build \
     && cd build  \
     &&  ${SUDO} cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/ \
        -DCMAKE_BUILD_TYPE=Release \
        -DPYTHON_DEPS=${INSTALL_DIR}/python-libs \
        -DMOD_INSTALL_PATH=${INSTALL_DIR}/modulefiles .. \
     && ${SUDO} make install
cd ../.. && ${SUDO} rm -rf omniperf-2.0.1 omniperf-2.0.1.tar.gz omniperf

${SUDO} sed -i -e 's/ascii/utf-8/' /opt/rocmplus-*/omniperf-*/bin/utils/specs.py

# Create a module file for Mvapich
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf

if [ -d "$MODULE_PATH" ]; then
   if [ "$REPLACE" != 1 ]; then
      echo "Installation directory $MODULE_PATH exists and replace option is false"
      echo "Exiting"
      exit
   else
      ${SUDO} rm -rf ${MODULE_PATH}/2.0.*.lua 
   fi
fi


${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
if [ "$AMD_STAGING" = 1 ]; then
   MODULE_VERSION=2.0.1-dev.lua
else
   MODULE_VERSION=2.0.1.lua
fi

cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${MODULE_VERSION}
	local help_message = [[

	Omniperf is an open-source performance analysis tool for profiling
	machine learning/HPC workloads running on AMD MI GPUs.

	Version 2.0.1
	]]

	help(help_message,"\n")

	whatis("Name: omniperf")
	whatis("Version: 2.0.1")
	whatis("Keywords: Profiling, Performance, GPU")
	whatis("Description: tool for GPU performance profiling")
	whatis("URL: https://github.com/AMDResearch/omniperf")

	-- Export environmental variables
	local topDir="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.1"
	local binDir="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.1/bin"
	local shareDir="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.1/share"
	local pythonDeps="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.1/python-libs"
	local roofline="/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.1/1in/utils/rooflines/roofline-ubuntu20_04-mi200-rocm5"

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
