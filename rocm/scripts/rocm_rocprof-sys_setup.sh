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

TOOL_NAME=omnitrace
TOOL_EXEC_NAME=omnitrace
TOOL_NAME_MC=Omnitrace
TOOL_NAME_UC=OMNITRACE
# if ROCM_VERSION is greater than 6.2.9, the awk command will give the ROCM_VERSION number
result=`echo ${ROCM_VERSION} | awk '$1>6.2.9'` && echo $result
if [[ "${result}" ]]; then
   TOOL_NAME=rocprofiler-systems
   TOOL_EXEC_NAME=rocprof-sys-avail
   TOOL_NAME_MC=Rocprofiler-systems
   TOOL_NAME_UC=ROCPROFILER_SYSTEMS
fi

echo ""
echo "=================================="
echo "Starting ROCm ${TOOL_NAME_MC} Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_ROCM_VERSION: $AMDGPU_ROCM_VERSION"
echo "AMDGPU_INSTALL_VERSION: $AMDGPU_INSTALL_VERSION"
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

if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then
   export MODULE_PATH=/etc/lmod/modules/ROCm/${TOOL_NAME}
   ${SUDO} mkdir -p ${MODULE_PATH}
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ${TOOL_NAME}")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("${TOOL_NAME}")

        -- Export environmental variables
        local topDir="/opt/rocm-${ROCM_VERSION}"
        local binDir="/opt/rocm-${ROCM_VERSION}/bin"
        local shareDir="/opt/rocm-${ROCM_VERSION}/share/${TOOL_NAME}"

        setenv("${TOOL_NAME_UC}_DIR",topDir)
        setenv("${TOOL_NAME_UC}_BIN",binDir)
        setenv("${TOOL_NAME_UC}_SHARE",shareDir)
        prepend_path("PATH", pathJoin(shareDir, "bin"))

	load("rocm/${ROCM_VERSION}")
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
        set_shell_function("omnitrace-avail",'/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-avail "$@"',"/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-avail $*")
        set_shell_function("omnitrace-instrument",'/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-instrument "$@"',"/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-instrument $*")
        set_shell_function("omnitrace-run",'/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-run "$@"',"/opt/rocm-${ROCM_VERSION}/bin/rocprof-sys-run $*")
EOF

fi
