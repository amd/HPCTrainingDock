#!/bin/bash

ROCM_VERSION=6.0
GITHUB_BRANCH="develop"
REPLACE=0
INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=0
PYTHON_VERSION=10
SUDO="sudo"
TOOL_NAME="rocprofiler-compute"
TOOL_CONFIG="ROCPROF_COMPUTE"
TOOL_REPO="https://github.com/ROCm/${TOOL_NAME}"
MODULE_PATH="/etc/lmod/modules/ROCmPlus-AMDResearchTools/${TOOL_NAME}"
MODULE_PATH_INPUT=""
INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/${TOOL_NAME}-${GITHUB_BRANCH}"
INSTALL_PATH_INPUT=""

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi

usage()
{
   echo "Usage:"
   echo "  --help: display this usage information"
   echo "  --install-path: default is: $INSTALL_PATH"
   echo "  --python-version: minor version of Python3, default is: $PYTHON_VERSION"
   echo "  --module-path: default is: $MODULE_PATH"
   echo "  --install-rocprof-compute-from-source: default is $INSTALL_ROCPROF_COMPUTE_FROM_SOURCE"
   echo "  --rocm-version: default is $ROCM_VERSION"
   echo "  --github-branch: default is $GITHUB_BRANCH"
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
      "--install-rocprof-compute-from-source")
          shift
          INSTALL_ROCPROF_COMPUTE_FROM_SOURCE=${1}
          reset-last
          ;;
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
	  reset-last
          ;;
      "--install-path")
          shift
          INSTALL_PATH_INPUT=${1}
	  reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH_INPUT=${1}
	  reset-last
          ;;
      "--python-version")
          shift
          PYTHON_VERSION=${1}
	  reset-last
          ;;
      "--github-branch")
          shift
          GITHUB_BRANCH=${1}
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

if [ "${INSTALL_PATH_INPUT}" != "" ]; then
   INSTALL_PATH=${INSTALL_PATH_INPUT}
else
   # override path in case ROCM_VERSION has been supplied as input
   INSTALL_PATH="/opt/rocmplus-${ROCM_VERSION}/${TOOL_NAME}-${GITHUB_BRANCH}"
fi

if [ "${MODULE_PATH_INPUT}" != "" ]; then
   MODULE_PATH=${MODULE_PATH_INPUT}
fi

# don't use sudo if user has write access to install path
if [ -w ${INSTALL_PATH} ]; then
   SUDO=""
fi

echo ""
echo "====================================="
echo "Installing ${TOOL_NAME}:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "INSTALL_PATH is $INSTALL_PATH"
echo "MODULE_PATH is $MODULE_PATH"
echo "GITHUB_BRANCH is $GITHUB_BRANCH"
echo "PYTHON_VERSION is 3.$PYTHON_VERSION"
echo "====================================="
echo ""

if [[ "$INSTALL_ROCPROF_COMPUTE_FROM_SOURCE" == "0" ]];then
   echo " The script is aborting due to the value of the INSTALL_ROCPROF_COMPUTE_FROM_SOURCE flag: $INSTALL_ROCPROF_COMPUTE_FROM_SOURCE	"
   echo " Please supply this option when running the script: '--install-rocprof-compute-from-source 1'"
   exit
fi

git clone -b ${GITHUB_BRANCH} https://github.com/ROCm/rocprofiler-compute
cd rocprofiler-compute

${SUDO} mkdir -p ${INSTALL_PATH}
if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod -R a+w ${INSTALL_PATH}
fi

python3.${PYTHON_VERSION} -m pip install -t ${INSTALL_PATH}/python-libs -r requirements.txt --upgrade
python3.${PYTHON_VERSION} -m pip install -t ${INSTALL_PATH}/python-libs pytest --upgrade
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=${INSTALL_PATH}/ \
      -DCMAKE_BUILD_TYPE=Release \
      -DPYTHON_DEPS=${INSTALL_PATH}/python-libs \
      -DMOD_INSTALL_PATH=${INSTALL_PATH}/modulefiles ..
      make install
cd ../..
rm -rf rocprofiler-compute

if [[ "${USER}" != "root" ]]; then
   ${SUDO} chmod go-w ${INSTALL_PATH}
fi

# Create a module file for ${TOOL_NAME}
if [ ! -w ${MODULE_PATH} ]; then
   SUDO="sudo"
fi

${SUDO} mkdir -p ${MODULE_PATH}

cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${GITHUB_BRANCH}.lua
	local help_message = [[

	${TOOL_NAME} is an open-source performance analysis tool for profiling
	machine learning/HPC workloads running on AMD MI GPUs.

	Source cloned from branch ${GITHUB_BRANCH}
	]]

	help(help_message,"\n")

	whatis("Name: ${TOOL_NAME}")
	whatis("Github Branch: ${GITHUB_BRANCH}")
	whatis("Keywords: Profiling, Performance, GPU")
	whatis("Description: tool for GPU performance profiling")
	whatis("URL: https://github.com/ROCm/rocprofiler-compute")

	-- Export environmental variables
	local topDir="${INSTALL_PATH}"
	local binDir="${INSTALL_PATH}/bin"
	local shareDir="${INSTALL_PATH}/share"
	local pythonDeps="${INSTALL_PATH}/python-libs"
	-- no need to set: local roofline="${ROOFLINE_BIN}"

	setenv("${TOOL_CONFIG}_DIR",topDir)
	setenv("${TOOL_CONFIG}_BIN",binDir)
	setenv("${TOOL_CONFIG}_SHARE",shareDir)
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
        set_shell_function("omniperf",'${INSTALL_PATH}/bin/rocprof-compute "$@"',"${INSTALL_PATH}/bin/rocprof-compute $*")
EOF
