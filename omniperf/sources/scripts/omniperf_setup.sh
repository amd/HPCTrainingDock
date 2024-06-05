#!/bin/bash

ROCM_VERSION=6.0

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
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

INSTALL_DIR=/opt/rocmplus-${ROCM_VERSION}/omniperf-2.0.0
wget -q https://github.com/AMDResearch/omniperf/releases/download/v2.0.0-RC1/omniperf-2.0.0-RC1.tar.gz && \
     sudo tar xfz omniperf-2.0.0-RC1.tar.gz && \
     cd ./omniperf-2.0.0-RC1\
     && sudo python3 -m pip install -t ${INSTALL_DIR}/python-libs -r requirements.txt \
     && sudo python3 -m pip install -t ${INSTALL_DIR}/python-libs pytest \
     && sudo mkdir build \
     && cd build  \
     &&  cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR}/ \
        -DCMAKE_BUILD_TYPE=Release \
        -DPYTHON_DEPS=${INSTALL_DIR}/python-libs \
        -DMOD_INSTALL_PATH=${INSTALL_DIR}/modulefiles .. \
     && sudo make install
cd ../.. && sudo rm -rf omniperf-2.0.0-RC1 omniperf-2.0.0-RC1.tar.gz

sed -i -e 's/ascii/utf-8/' /opt/rocmplus-*/omniperf-*/bin/utils/specs.py

# Create a module file for Mvapich
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-AMDResearchTools/omniperf

sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/2.0.0.lua <<-EOF
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
