#!/bin/bash

# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
SUDO="sudo"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
fi


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
echo "Starting ROCm Omnitrace Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_ROCM_VERSION: $AMDGPU_ROCM_VERSION"
echo "AMDGPU_INSTALL_VERSION: $AMDGPU_INSTALL_VERSION"
echo "=================================="
echo ""

# if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
# if ROCM_VERSION is less than or equalt to 6.1.2, the awk command result will be blank
result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
if [[ "${result}" == "" ]]; then
   echo "ROCm built-in Omnitrace version cannot be installed on ROCm versions before 6.2.0"
   exit
fi
if [[ -f /opt/rocm-${ROCM_VERSION}/bin/omnitrace ]] ; then
   echo "ROCm built-in Omnitrace already installed"
   exit
fi

if [ "${DISTRO}" == "ubuntu" ]; then
   ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -q -y omnitrace
fi

if [[ -f /opt/rocm-${ROCM_VERSION}/bin/omnitrace ]] ; then
   export MODULE_PATH=/etc/lmod/modules/ROCm/omnitrace
   ${SUDO} mkdir -p ${MODULE_PATH}
   # The - option suppresses tabs
   cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: omnitrace")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("omnitrace")

	local base = "/opt/rocm-${ROCM_VERSION}"

	setenv("OMNITRACE_PATH", base)
	load("rocm/${ROCM_VERSION}")
	setenv("ROCP_METRICS", pathJoin(os.getenv("ROCM_PATH"), "/lib/rocprofiler/metrics.xml"))
EOF

fi
