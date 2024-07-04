#!/bin/bash

reset-last()
{
    last() { send-error "Unsupported argument :: ${1}"; }
}

ROCM_VERSION=6.0

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

echo ""
echo "============================"
echo " Installing MVAPICH with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "============================"
echo ""

#
# Install mvapich
#

if [ "${DISTRO}" = "ubuntu" ]; then
   sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/mvapich2
   sudo wget http://mvapich.cse.ohio-state.edu/download/mvapich/mv2/mvapich2-2.3.7.tar.gz
   sudo  gzip -dc mvapich2-2.3.7.tar.gz | tar -x
   cd mvapich2-2.3.7
   export FFLAGS=-fallow-argument-mismatch
   echo 'Defaults:%sudo env_keep += "FFLAGS"' | sudo EDITOR='tee -a' visudo
   sudo ./configure --prefix=/opt/rocmplus-${ROCM_VERSION}/mvapich2
   sudo make -j
   sudo make install
   cd ../
   sudo rm -rf mvapich2-2.3.7
   sudo rm mvapich2-2.3.7.tar.gz

fi
if [ "${DISTRO}" = "rocky linux" ]; then
   yum install http://mvapich.cse.ohio-state.edu/download/mvapich/gdr/2.3.7/mofed5.0/mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.rpm
fi

# Adding -p option to avoid error if directory already exists
#sudo mv /opt/mvapich2 /opt/rocmplus-${ROCM_VERSION}/mvapich2
#rm -f mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.rpm

# Create a module file for Mvapich
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mvapich2

sudo mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | sudo tee ${MODULE_PATH}/2.3.7.lua
	whatis("Name: GPU-aware mvapich")
	whatis("Version: 2.3.7")
	whatis("Description: An open source Message Passing Interface implementation")
	whatis(" This is a GPU-aware version of Mvapich")

	local base = "/opt/rocmplus-${ROCM_VERSION}/mvapich2/"
	local mbase = "/etc/lmod/modules/ROCmPlus-MPI"

	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH",pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH",pathJoin(base, "include"))
	prepend_path("PATH",pathJoin(base, "bin"))
	load("rocm/${ROCM_VERSION}")
	family("MPI")
EOF
