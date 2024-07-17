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

#MVAPICH2_RPM_NAME=mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1.slurm-2.3.7-1.t4.x86_64.rpm
MVAPICH2_RPM_NAME=mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.rpm
MVAPICH2_DOWNLOAD_URL=https://mvapich.cse.ohio-state.edu/download/mvapich/gdr/2.3.7/mofed5.0/${MVAPICH2_RPM_NAME}

if [ "${DISTRO}" = "ubuntu" ]; then
   sudo mkdir -p /opt/rocmplus-${ROCM_VERSION}/mvapich2

   # install the GPU aware version of mvapich2 using an rpm (MV2-GDR 2.3.7)
   #sudo DEBIAN_FRONTEND=noninteractive apt-get -qqy install alien
   sudo wget -q MVAPICH2_DOWNLOAD_URL=https://mvapich.cse.ohio-state.edu/download/mvapich/gdr/2.3.7/mofed5.0/${MVAPICH2_RPM_NAME}
   ls -l ${MVAPICH2_RPM_NAME}
   #sudo alien --scripts -i mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.rpm
   #sudo dpkg-deb -x mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.deb /opt/rocmplus-${ROCM_VERSION}/mvapich2
   sudo rpm --prefix /opt/rocmplus-${ROCM_VERSION}/mvapich2 -Uvh --nodeps ${{MVAPICH2_RPM_NAME}
   sudo rm {MVAPICH2_RPM_NAME}
   #sudo rm mvapich2-gdr-rocm5.1.mofed5.0.gnu10.3.1-2.3.7-1.t4.x86_64.deb

   sed -i -e "s/5.1.0/$ROCM_VERSION/g" \
          -e '/^final_ldflags/s!"$!-L/usr/lib/x86_64-linux-gnu/ -lc"!' \
          -e '/gcc-tce/s!tce/packages/gcc-tce/gcc-10.2.1/!!' \
          -e '/redhat/s!-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1!!' /opt/rocmplus-6.1.2/mvapich2/bin/mpicc

   sed -i -e "s/5.1.0/$ROCM_VERSION/g" \
          -e '/^final_ldflags/s!"$!-L/usr/lib/x86_64-linux-gnu/ -lc"!' \
          -e '/gcc-tce/s!tce/packages/gcc-tce/gcc-10.2.1/!!' \
          -e '/redhat/s!-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1!!' /opt/rocmplus-6.1.2/mvapich2/bin/mpic++

   sed -i -e "s/5.1.0/$ROCM_VERSION/g" \
          -e '/^final_ldflags/s!"$!-L/usr/lib/x86_64-linux-gnu/ -lc"!' \
          -e '/gcc-tce/s!tce/packages/gcc-tce/gcc-10.2.1/!!' \
          -e '/redhat/s!-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1!!' /opt/rocmplus-6.1.2/mvapich2/bin/mpicxx

   sed -i -e "s/5.1.0/$ROCM_VERSION/g" \
          -e '/^final_ldflags/s!"$!-L/usr/lib/x86_64-linux-gnu/ -lc"!' \
          -e '/gcc-tce/s!tce/packages/gcc-tce/gcc-10.2.1/!!' \
          -e '/redhat/s!-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1!!' /opt/rocmplus-6.1.2/mvapich2/bin/mpif77

   sed -i -e "s/5.1.0/$ROCM_VERSION/g" \
          -e '/^final_ldflags/s!"$!-L/usr/lib/x86_64-linux-gnu/ -lc"!' \
          -e '/gcc-tce/s!tce/packages/gcc-tce/gcc-10.2.1/!!' \
          -e '/redhat/s!-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1!!' /opt/rocmplus-6.1.2/mvapich2/bin/mpifort

   sed -i -e "s/5.1.0/$ROCM_VERSION/g" \
          -e '/^final_ldflags/s!"$!-L/usr/lib/x86_64-linux-gnu/ -lc"!' \
          -e '/gcc-tce/s!tce/packages/gcc-tce/gcc-10.2.1/!!' \
          -e '/redhat/s!-specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1!!' /opt/rocmplus-6.1.2/mvapich2/bin/mpif90

   # install a non GPU aware version of mvapich2 from source (MV2 2.3.7)
   #sudo wget -q http://mvapich.cse.ohio-state.edu/download/mvapich/mv2/mvapich2-2.3.7.tar.gz
   #sudo  gzip -dc mvapich2-2.3.7.tar.gz | tar -x
   #cd mvapich2-2.3.7
   #export FFLAGS=-fallow-argument-mismatch
   #echo 'Defaults:%sudo env_keep += "FFLAGS"' | sudo EDITOR='tee -a' visudo
   #sudo ./configure --prefix=/opt/rocmplus-${ROCM_VERSION}/mvapich2
   #sudo make -j
   #sudo make install
   #cd ../
   #sudo rm -rf mvapich2-2.3.7
   #sudo rm mvapich2-2.3.7.tar.gz

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
	whatis(" This is a GPU-aware version of Mvapich2 (MV2-GDR 2.3.7)")

	local base = "/opt/rocmplus-${ROCM_VERSION}/mvapich2/"
	local mbase = "/etc/lmod/modules/ROCmPlus-MPI"

        setenv("MV2_PATH", base)
	prepend_path("LD_LIBRARY_PATH",pathJoin(base, "lib64"))
	prepend_path("C_INCLUDE_PATH",pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH",pathJoin(base, "include"))
	prepend_path("PATH",pathJoin(base, "bin"))
	load("rocm/${ROCM_VERSION}")
	family("MPI")
EOF
