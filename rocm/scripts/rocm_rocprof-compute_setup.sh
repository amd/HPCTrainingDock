#!/bin/bash

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi


usage()
{
   echo "Usage:"
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION"
   echo "  --python-version [ PYTHON_VERSION ] Python3 minor version, default not set"
   echo "  --help: this usage information"
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

TOOL_NAME=omniperf
TOOL_EXEC_NAME=omniperf
TOOL_NAME_MC=Omniperf
TOOL_NAME_UC=OMNIPERF
# if ROCM_VERSION is greater than 6.2.9, the awk command will give the ROCM_VERSION number
result=`echo ${ROCM_VERSION} | awk '$1>6.2.9'` && echo $result
if [[ "${result}" ]]; then
   TOOL_NAME=rocprofiler-compute
   TOOL_EXEC_NAME=rocprof-compute
   TOOL_NAME_MC=Rocprofiler-compute
   TOOL_NAME_UC=ROCPROFILER_COMPUTE
fi

echo ""
echo "=================================="
echo "Starting ROCm ${TOOL_NAME_MC} Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "=================================="
echo ""

# if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
# if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
if [[ "${result}" == "" ]]; then
   echo "ROCm built-in ${TOOL_NAME_MC} version cannot be installed on ROCm versions before 6.2.0"
   exit
fi
if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
   echo "ROCm built-in ${TOOL_NAME_MC} already installed"
else
   if [ "${DISTRO}" == "ubuntu" ]; then
      ${SUDO} ${DEB_FRONTEND} apt-get install -q -y ${TOOL_NAME}
   fi
fi

if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod -R a+w /opt/rocm-${ROCM_VERSION}
fi

PYTHON=python3
if [ "${PYTHON_VERSION}" != "" ]; then
   PYTHON=python3.${PYTHON_VERSION}
fi

${PYTHON} -m pip install -t /opt/rocm-${ROCM_VERSION}/libexec/${TOOL_NAME}/python-libs -r /opt/rocm-${ROCM_VERSION}/libexec/${TOOL_NAME}/requirements.txt

if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod go-w /opt/rocm-${ROCM_VERSION}
fi

if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
   export MODULE_PATH=/etc/lmod/modules/ROCm/${TOOL_NAME}
   ${SUDO} mkdir -p ${MODULE_PATH}
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	local help_message = [[

	${TOOL_NAME_MC} is an open-source performance analysis tool for profiling
	machine learning/HPC workloads running on AMD MI GPUs.

	Version ${ROCM_VERSION}
	]]

	help(help_message,"\n")

	whatis("Name: ${TOOL_NAME}")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Keywords: Profiling, Performance, GPU")
	whatis("Description: tool for GPU performance profiling")
	whatis("URL: https://github.com/ROCm/${TOOL_NAME}")

	-- Export environmental variables
	local topDir="/opt/rocm-${ROCM_VERSION}"
	local binDir="/opt/rocm-${ROCM_VERSION}/bin"
	local shareDir="/opt/rocm-${ROCM_VERSION}/share/${TOOL_NAME}"
	local pythonDeps="/opt/rocm-${ROCM_VERSION}/libexec/${TOOL_NAME}/python-libs"
	-- no need to set: local roofline="${ROOFLINE_BIN}"

	setenv("${TOOL_NAME_UC}_DIR",topDir)
	setenv("${TOOL_NAME_UC}_BIN",binDir)
	setenv("${TOOL_NAME_UC}_SHARE",shareDir)
	-- no need to set: setenv("ROOFLINE_BIN",roofline)

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
        set_shell_function("omniperf",'/opt/rocm-${ROCM_VERSION}/bin/rocprof-compute "$@"',"/opt/rocm-${ROCM_VERSION}/bin/rocprof-compute $*")

EOF

fi
