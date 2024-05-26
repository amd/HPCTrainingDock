#!/bin/bash

reset-last()
{
    last() { send-error "Unsupported argument :: ${1}"; }
}

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


echo ""
echo "============================"
echo " Installing MVAPICH with:"
echo "ROCM_VERSION is $ROCM_VERSION"
echo "============================"
echo ""

#
# Install mvapich
#

apt-get -qqy install alien 
wget -q http://mvapich.cse.ohio-state.edu/download/mvapich/gdr/2.3.7/mofed5.0/mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.rpm
alien --scripts -i mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.rpm

# Adding -p option to avoid error if directory already exists
mkdir -p /opt/rocmplus-${ROCM_VERSION}
mv /opt/mvapich2 /opt/rocmplus-${ROCM_VERSION}/mvapich2
rm -f mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.rpm

# Create a module file for Mvapich
export MODULE_PATH=/etc/lmod/modules/ROCmPlus-MPI/mvapich2

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/2.3.7.lua <<-EOF
	whatis("Name: GPU-aware mvapich")
	whatis("Version: 2.3.7")
	whatis("Description: An open source Message Passing Interface implementation")
	whatis(" This is a GPU-aware version of Mvapich")

	local base = "/opt/rocmplus-${ROCM_VERSION}/mvapich2/gdr/2.3.7/no-mcast/no-openacc/rocm5.1/mofed5.0/mpirun/gnu10.3.1"
	local mbase = "/etc/lmod/modules/ROCmPlus-MPI"

	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH",pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH",pathJoin(base, "include"))
	prepend_path("PATH",pathJoin(base, "bin"))
	load("rocm/${ROCM_VERSION}")
	family("MPI")
EOF



