#!/bin/bash

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

usage()
{
   echo "--help: this usage information"
   echo "--rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
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
         usage
         ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
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
echo "=================================="
echo "Starting ROCm Omniperf Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "=================================="
echo ""

result=`echo $ROCM_VERSION | awk '$1<6.2.0'` && echo $result
if [[ "${result}" ]]; then
   echo "ROCm built-in Omniperf version cannot be installed on ROCm versions before 6.2.0"
   exit
fi
if [[ -f /opt/rocm-${ROCM_VERSION}/bin/omniperf ]] ; then
   echo "ROCm built-in Omniperf already installed"
   exit
fi

if [ "${DISTRO}" == "ubuntu" ]; then
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -q -y omniperf
   sudo python3 -m pip install -t /opt/rocm-${ROCM_VERSION}/libexec/omniperf/python-libs -r /opt/rocm-${ROCM_VERSION}/libexec/omniperf/requirements.txt
fi

if [[ -f /opt/rocm-${ROCM_VERSION}/bin/omniperf ]] ; then
   export MODULE_PATH=/etc/lmod/modules/ROCm/omniperf
   sudo mkdir -p ${MODULE_PATH}
   # The - option suppresses tabs
   cat <<-EOF | sudo tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	local help_message = [[

	Omniperf is an open-source performance analysis tool for profiling
	machine learning/HPC workloads running on AMD MI GPUs.

	Version 6.2.0
	]]

	help(help_message,"\n")

	whatis("Name: omniperf")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Keywords: Profiling, Performance, GPU")
	whatis("Description: tool for GPU performance profiling")
	whatis("URL: https://github.com/AMDResearch/omniperf")

	-- Export environmental variables
	local topDir="/opt/rocm-${ROCM_VERSION}"
	local binDir="/opt/rocm-${ROCM_VERSION}/bin"
	local shareDir="/opt/rocm-${ROCM_VERSION}/share/omniperf"
	local pythonDeps="/opt/rocm-${ROCM_VERSION}/libexec/omniperf/python-libs"
	local roofline="/opt/rocm-${ROCM_VERSION}/libexec/omniperf/bin/utils/rooflines/roofline-ubuntu20_04-mi200-rocm5"

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

fi
