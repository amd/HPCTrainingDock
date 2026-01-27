#!/bin/bash

# Variables controlling setup process
: ${ROCM_VERSION:="6.0"}
REPLACE=0
MODULE_PATH=/etc/lmod/modules/ROCm
#if [[ ! "${MODULEPATH}" == *"/etc/lmod/modules/ROCm"* ]]; then
#   MODULE_PATH=/etc/lmod/modules
#fi

INCLUDE_TOOLS=0
# Autodetect defaults
DISTRO=`cat /etc/os-release | grep '^NAME' | sed -e 's/NAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_VERSION=`cat /etc/os-release | grep '^VERSION_ID' | sed -e 's/VERSION_ID="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
DISTRO_CODENAME=`cat /etc/os-release | grep '^VERSION_CODENAME' | sed -e 's/VERSION_CODENAME=//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `

RHEL_COMPATIBLE=0
if [[ "${DISTRO}" = "red hat enterprise linux" || "${DISTRO}" = "rocky linux" || "${DISTRO}" == "almalinux" ]]; then
   RHEL_COMPATIBLE=1
fi

SUDO="sudo"
DEB_FRONTEND="DEBIAN_FRONTEND=noninteractive"

if [  -f /.singularity.d/Singularity ]; then
   SUDO=""
   DEB_FRONTEND=""
fi


usage()
{
   echo "Usage:"
   echo "  --replace default off"
   echo "  --amdgpu-gfxmodel [ AMDGPU_GFXMODEL ] default autodetected "
   echo "  --rocm-version [ ROCM_VERSION ] default $ROCM_VERSION "
   echo "  --python-version [ PYTHON_VERSION ] Python3 minor version, default not set"
   echo "  --module-path [ MODULE_PATH ] default $MODULE_PATH "
   echo "  --include-tools [INCLUDE_TOOLS] default $INCLUDE_TOOLS "
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
      "--amdgpu-gfxmodel")
          shift
          AMDGPU_GFXMODEL=${1}
          reset-last
          ;;
      "--module-path")
          shift
          MODULE_PATH=${1}
          reset-last
          ;;
      "--replace")
          REPLACE=1
          reset-last
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
      "--include-tools")
          shift
          INCLUDE_TOOLS=${1}
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

version-set()
{
   VERSION_MAJOR=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $1}')
   VERSION_MINOR=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $2}')
   VERSION_PATCH=$(echo ${DISTRO_VERSION} | sed 's/\./ /g' | awk '{print $3}')

   ROCM_MAJOR=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $1}')
   ROCM_MINOR=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $2}')
   ROCM_PATCH=$(echo ${ROCM_VERSION} | sed 's/\./ /g' | awk '{print $3}')
   if [ -n "${ROCM_PATCH}" ]; then
       ROCM_VERSN=$(( (${ROCM_MAJOR}*10000)+(${ROCM_MINOR}*100)+(${ROCM_PATCH}) ))
       ROCM_SEP="."
   else
       ROCM_VERSN=$(( (${ROCM_MAJOR}*10000)+(${ROCM_MINOR}*100) ))
       ROCM_SEP=""
   fi

   if [ "x${ROCM_PATCH}" == "x" ]; then
      AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}00-1
      AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}
   elif [ "${ROCM_PATCH}" == "0" ]; then
      AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
      AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}
   else
      if [[ "${ROCM_MAJOR}" == "6" ]]; then
         AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
      else
         AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_PATCH}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
      fi
      AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_PATCH}
   fi
}

rocm-repo-dist-set()
{
   if [ "${DISTRO}" = "ubuntu" ]; then
       DISTRO_CODENAME=`cat /etc/os-release | grep '^VERSION_CODENAME' | sed -e 's/VERSION_CODENAME="//' -e 's/"$//' | tr '[:upper:]' '[:lower:]' `
       ROCM_REPO_DIST=${DISTRO_CODENAME}
   elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
       rhel-set
   elif [ "${DISTRO}" = "opensuse" ]; then
       opensuse-set
   fi
}

rhel-set()
{
   if [ -z "${VERSION_MINOR}" ]; then
       send-error "Please provide a major and minor version of the OS. Supported: >= 8.7, <= 9.1"
   fi

   # Components used to create the sub-URL below
   #   set <OS-DISTRO_VERSION> in amdgpu-install/<ROCM-VERSION>/rhel/<OS-DISTRO_VERSION>
   RPM_PATH=${VERSION_MAJOR}.${VERSION_MINOR}
   RPM_TAG=".el${VERSION_MAJOR}"

   # set the sub-URL in https://repo.radeon.com/amdgpu-install/<sub-URL>
   case "${ROCM_VERSION}" in
       5.4 | 5.4.*)
           ROCM_RPM=${ROCM_VERSION}/rhel/${RPM_PATH}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1${RPM_TAG}.noarch.rpm
           ;;
       5.3 | 5.3.*)
           ROCM_RPM=${ROCM_VERSION}/rhel/${RPM_PATH}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1${RPM_TAG}.noarch.rpm
           ;;
       5.2 | 5.2.* | 5.1 | 5.1.* | 5.0 | 5.0.* | 4.*)
           send-error "Invalid ROCm version ${ROCM_VERSION}. Supported: >= 5.3.0, <= 5.4.x"
           ;;
       0.0)
           ;;
       *)
           send-error "Unsupported combination :: ${DISTRO}-${DISTRO_VERSION} + ROCm ${ROCM_VERSION}"
           ;;
   esac

   # use Rocky Linux as a base image for RHEL builds
   DISTRO_BASE_IMAGE=rockylinux

}

opensuse-set()
{
   case "${DISTRO_VERSION}" in
       15.*)
           DISTRO_IMAGE="opensuse/leap"
           echo "DISTRO_IMAGE: ${DISTRO_IMAGE}"
           ;;
       *)
           send-error "Invalid opensuse version ${DISTRO_VERSION}. Supported: 15.x"
           ;;
   esac
   case "${ROCM_VERSION}" in
       5.4 | 5.4.*)
           ROCM_RPM=${ROCM_VERSION}/sle/${DISTRO_VERSION}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       5.3 | 5.3.*)
           ROCM_RPM=${ROCM_VERSION}/sle/${DISTRO_VERSION}/amdgpu-install-${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       5.2 | 5.2.*)
           ROCM_RPM=22.20${ROCM_SEP}${ROCM_PATCH}/sle/${DISTRO_VERSION}/amdgpu-install-22.20.${ROCM_VERSN}-1.noarch.rpm
           ;;
       5.1 | 5.1.*)
           ROCM_RPM=22.10${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-22.10${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       5.0 | 5.0.*)
           ROCM_RPM=21.50${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-21.50${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       4.5 | 4.5.*)
           ROCM_RPM=21.40${ROCM_SEP}${ROCM_PATCH}/sle/15/amdgpu-install-21.40${ROCM_SEP}${ROCM_PATCH}.${ROCM_VERSN}-1.noarch.rpm
           ;;
       0.0)
           ;;
       *)
           send-error "Unsupported combination :: ${DISTRO}-${DISTRO_VERSION} + ROCm ${ROCM_VERSION}"
       ;;
   esac
   PERL_REPO="SLE_${VERSION_MAJOR}_SP${VERSION_MINOR}"
}

if [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
   ROCM_REPO_DIST=${DISTRO_VERSION}
else
   ROCM_REPO_DIST=`lsb_release -c | cut -f2`
fi

#echo "After autodetection"
#echo "DISTRO is $DISTRO"
#echo "DISTRO_VERSION is $DISTRO_VERSION"
#echo ""

#echo "ROCM_VERSION is $ROCM_VERSION"
#echo ""
#echo "ROCM_REPO_DIST is $ROCM_REPO_DIST"
#echo ""

# This sets variations of the ROCM_VERSION needed by installers
# AMDGPU_ROCM_VERSION
# AMDGPU_INSTALL_VERSION
version-set

echo ""
echo "=================================="
echo "Starting ROCm Install with"
echo "DISTRO: $DISTRO"
echo "DISTRO_VERSION: $DISTRO_VERSION"
echo "ROCM_REPO_DIST: $ROCM_REPO_DIST"
echo "ROCM_VERSION: $ROCM_VERSION"
echo "AMDGPU_ROCM_VERSION: $AMDGPU_ROCM_VERSION"
echo "AMDGPU_INSTALL_VERSION: $AMDGPU_INSTALL_VERSION"
echo "=================================="
echo ""

AMDGPU_GFXMODEL_STRING=`echo ${AMDGPU_GFXMODEL} | sed -e 's/;/_/g'`
CACHE_FILES=/CacheFiles/${DISTRO}-${DISTRO_VERSION}-rocm-${ROCM_VERSION}-${AMDGPU_GFXMODEL_STRING}

if [[ -d "/opt/rocm-${ROCM_VERSION}" ]] && [[ "${REPLACE}" == "0" ]] ; then
   echo "There is a previous installation and the replace flag is false"
   echo "  use --replace to request replacing the current installation"
   exit
fi

INSTALL_PATH=/opt/rocm-${ROCM_VERSION}

   if [[ -d "${INSTALL_PATH}" ]] && [[ "${REPLACE}" != "0" ]] ; then
      ${SUDO} rm -rf ${INSTALL_PATH}
   fi

   if [[ -f ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz ]]; then
      echo ""
      echo "============================"
      echo " Installing Cached ROCm"
      echo "============================"
      echo ""

      #install the cached version
      echo "cached file is ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz"
      cd /opt
      ${SUDO} tar -xzf ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz
      ${SUDO} chown -R root:root ${INSTALL_PATH}
      if [ "${USER}" != "sysadmin" ]; then
         ${SUDO} rm ${CACHE_FILES}/rocm-${ROCM_VERSION}.tgz
      fi
      ROCM_ALTERNATIVES_BIN_LIST="amd-smi clinfo hipcc hipcc.bin hipcc_cmake_linker_helper hipcc.pl hipconfig hipconfig.bin hipconfig.pl hipconvertinplace-perl.sh hipconvertinplace.sh hipdemangleatp hipexamine-perl.sh hipexamine.sh hipify-clang hipify-perl roccoremerge rocgdb rocm_agent_enumerator rocminfo rocm-smi roc-obj roc-obj-extract roc-obj-ls rocprof rocprofv2 rocsys"
      for file in $ROCM_ALTERNATIVES_BIN_LIST
      do
         ${SUDO} update-alternatives --install /usr/bin/$file $file /opt/rocm-${ROCM_VERSION}/bin/$file 100
      done
      ${SUDO} update-alternatives --install /opt/rocm rocm /opt/rocm-${ROCM_VERSION} 100

   else

# if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
# if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" ]]; then # ROCM_VERSION >= 6.2
         INCLUDE_TOOLS=1
      fi

      if [ "${DISTRO}" == "ubuntu" ]; then
         ${SUDO} apt-get update
         ${SUDO} ${DEB_FRONTEND} apt-get install -y libdrm-dev logrotate

         #mkdir --parents --mode=0755 /etc/apt/keyrings
         #${SUDO} mkdir --parents --mode=0755 /etc/apt/keyrings

         # The installation below makes use of an AMD provided install script

         result1=`echo $ROCM_VERSION | awk '$1>6.3.0'` && echo "result at line 300 is ",$result1
         result2=`echo $ROCM_VERSION | awk '$1>6.3.5'` && echo "result at line 301 is ",$result2
         if [[ "${result1}" != "$ROCM_VERSION" ]] && [[ "${result2}" ]]; then # ROCM_VERSION < 6.3.0 and > 6.3.5
            # Get the key for the ROCm software
            wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | ${SUDO} tee /etc/apt/keyrings/rocm.gpg > /dev/null
         fi

         # Update package list
         ${SUDO} apt-get update

         # Get the amdgpu-install script
         wget -q https://repo.radeon.com/amdgpu-install/${AMDGPU_ROCM_VERSION}/${DISTRO}/${ROCM_REPO_DIST}/amdgpu-install_${AMDGPU_INSTALL_VERSION}_all.deb

         # Run the amdgpu-install script. We have already installed the kernel driver, so use we use --no-dkms
         ${SUDO} ${DEB_FRONTEND} apt-get install -q -y --allow-downgrades ./amdgpu-install_${AMDGPU_INSTALL_VERSION}_all.deb
      elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
	 ${SUDO} dnf config-manager --set-enabled crb
         ${SUDO} dnf install -y python3-setuptools python3-wheel
#	 ${SUDO} dnf --enablerepo=crb install python3-wheel -y
#	 ${SUDO} dnf install python3-setuptools python3-wheel -y

	 ${SUDO} touch /etc/yum.repos.d/rocm.repo
	 ${SUDO} chmod a+w /etc/yum.repos.d/rocm.repo

	 cat <<-EOF | ${SUDO} tee -a /etc/yum.repos.d/rocm.repo
	[ROCm-${AMDGPU_ROCM_VERSION}]
	name=ROCm${AMDGPU_ROCM_VERSION}
	baseurl=https://repo.radeon.com/rocm/rhel9/${AMDGPU_ROCM_VERSION}/main
	enabled=1
	priority=50
	gpgcheck=1
	gpgkey=https://repo.radeon.com/rocm/rocm.gpg.key
EOF
         cat /etc/yum.repos.d/rocm.repo

	 echo "${SUDO} dnf install -y https://repo.radeon.com/amdgpu-install/${AMDGPU_ROCM_VERSION}/rhel/${DISTRO_VERSION}/amdgpu-install-${AMDGPU_INSTALL_VERSION}.el9.noarch.rpm"
	 ${SUDO} dnf install -y https://repo.radeon.com/amdgpu-install/${AMDGPU_ROCM_VERSION}/rhel/${DISTRO_VERSION}/amdgpu-install-${AMDGPU_INSTALL_VERSION}.el9.noarch.rpm
      fi
# if ROCM_VERSION is greater than 6.1.2, the awk command will give the ROCM_VERSION number
# if ROCM_VERSION is less than or equal to 6.1.2, the awk command result will be blank
      result=`echo $ROCM_VERSION | awk '$1>6.1.2'` && echo $result
      if [[ "${result}" ]]; then # ROCM_VERSION >= 6.2
         result=`echo $DISTRO_VERSION | awk '$1>24.00'` && echo $result
         if [[ "${result}" ]]; then
            # rocm-asan not available in Ubuntu 24.04
            amdgpu-install -q -y --usecase=hiplibsdk,rocmdev,rocmdevtools,lrt,openclsdk,openmpsdk,mlsdk --no-dkms --rocmrelease=${ROCM_VERSION}
	 else
            # removing asan to reduce image size
            #amdgpu-install -q -y --usecase=hiplibsdk,rocmdev,lrt,openclsdk,openmpsdk,mlsdk,asan --no-dkms
            amdgpu-install -q -y --usecase=hiplibsdk,rocmdev,rocmdevtools,lrt,openclsdk,openmpsdk,mlsdk --no-dkms --rocmrelease=${ROCM_VERSION}
            #${SUDO} apt-get install rocm_bandwidth_test
	 fi
         if [ "${DISTRO}" == "ubuntu" ]; then
            ${SUDO} apt-get install -y rocm-llvm-dev${ROCM_VERSION} rocm-device-libs${ROCM_VERSION} rocm-core${ROCM_VERSION} rocm-llvm${ROCM_VERSION}
         #elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
            # error message that rocm-llvm-dev does not exist
            #${SUDO} dnf install -y rocm-llvm-dev
	 fi
      else # ROCM_VERSION < 6.2
         amdgpu-install -q -y --usecase=hiplibsdk,rocm --no-dkms --rocmrelease=${ROCM_VERSION}
      fi

#      if [[ ! -f /opt/rocm-${ROCM_VERSION}/.info/version-dev ]]; then
#         # Required by DeepSpeed
#	 # Exists in Ubuntu 24.04 and not 22.04
#         ${SUDO} ln -s /opt/rocm-${ROCM_VERSION}/.info/version /opt/rocm-${ROCM_VERSION}/.info/version-dev
#      fi

      rm -rf amdgpu-install_${AMDGPU_INSTALL_VERSION}_all.deb
   fi
   amdgpu-install -q -y --usecase=rocm,hip,hiplibsdk --no-dkms --rocmrelease=${ROCM_VERSION}
#else
#   echo "DISTRO version ${DISTRO} not recognized or supported"
#   exit
#fi

# rocm-validation-suite is optional
#apt-get install -qy rocm-validation-suite

# Uncomment the appropriate one for your system if you want
# to hardwire the code generation
#RUN echo "gfx90a" > /opt/rocm/bin/target.lst
#RUN echo "gfx908" >>/opt/rocm/bin/target.lst
#RUN echo "gfx906" >>/opt/rocm/bin/target.lst
#RUN echo "gfx1030" >>/opt/rocm/bin/target.lst

#ENV ROCM_TARGET_LST=/opt/rocm/bin/target.lst

#RUN mkdir -p rocinfo \
#    && cd rocinfo \
#    && git clone  https://github.com/RadeonOpenCompute/rocminfo.git \
#    && cd rocminfo  \
#    && ls -lsa  \
#    && mkdir -p build \
#    && cd build  \
#    && cmake -DCMAKE_PREFIX_PATH=/opt/rocm .. \
#    && make install

#RUN if [ "${ROCM_VERSION}" != "0.0" ]; then \
#        if [ -d /etc/apt/trusted.gpg.d ]; then \
#            wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor > /etc/apt/trusted.gpg.d/rocm.gpg; \
#        else \
#            wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | apt-key add -; \
#        fi && \
#        echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/${ROCM_REPO_VERSION}/ ${ROCM_REPO_DIST} main" | tee /etc/apt/sources.list.d/rocm.list && \
#        apt-get update && \
#        apt-get dist-upgrade -y && \
#        apt-get install -y hsa-amd-aqlprofile hsa-rocr-dev hsakmt-roct-dev && \
#        apt-get install -y hip-base hip-runtime-amd hip-dev && \
#        apt-get install -y rocm-llvm rocm-core rocm-smi-lib rocm-device-libs && \
#        apt-get install -y roctracer-dev rocprofiler-dev rccl-dev ${EXTRA_PACKAGES} && \
#        apt-get install -y rocfft  hipfft  rocm-libs rocsolver rocblas && \
#        apt-get install -y rocminfo rocm-bandwidth-test  && \
#        if [ "$(echo ${ROCM_VERSION} | awk -F '.' '{print $1}')" -lt "5" ]; then apt-get install -y rocm-dev; fi && \
#        apt-get autoclean; \
#    fi

# set up up module files

# Create a module file for rocm sdk
MODULE_PATH=${MODULE_PATH}/rocm

${SUDO} mkdir -p ${MODULE_PATH}

# autodetecting default version for distro and getting available gcc version list
GCC_BASE_VERSION=`ls /usr/bin/gcc-* | cut -f2 -d'-' | grep '^[[:digit:]]' | head -1`

if [ "${DISTRO}" == "ubuntu" ]; then
# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ROCm")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("ROCm")
	whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")

	local base = "/opt/rocm-${ROCM_VERSION}"
	local mbase = " /etc/lmod/modules/ROCm/rocm"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	setenv("HSA_NO_SCRATCH_RECLAIM","1")
	setenv("HIPCC_COMPILE_FLAGS_APPEND","--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/${GCC_BASE_VERSION}")
	setenv("HIPCC_LINK_FLAGS_APPEND","--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/${GCC_BASE_VERSION}")
	setenv("ROCM_PATH", base)
	family("GPUSDK")
EOF
elif [[ "${RHEL_COMPATIBLE}" == 1 ]]; then
# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ROCm")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("ROCm")
	whatis("Set HIPCC_VERBOSE=7 to see what hipcc is doing for the compilation and link")

	local base = "/opt/rocm-${ROCM_VERSION}"
	local mbase = " /etc/lmod/modules/ROCm/rocm"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	setenv("ROCM_PATH", base)
	family("GPUSDK")
EOF
fi

# Create a module file for amdclang compiler
export MODULE_PATH=/etc/lmod/modules/ROCm/amdclang

${SUDO} mkdir -p ${MODULE_PATH}
AMDCLANG_VERSION=`/opt/rocm-${ROCM_VERSION}/llvm/bin/amdclang --version |head -1 | cut -f 4 -d' ' | tr -d -c '[:digit:]\.'`

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${AMDCLANG_VERSION}-${ROCM_VERSION}.lua
	whatis("Name: AMDCLANG")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("AMDCLANG")

	local base = "/opt/rocm-${ROCM_VERSION}/llvm"
	local mbase = "/etc/lmod/modules/ROCm/amdclang"

	setenv("CC", pathJoin(base, "bin/amdclang"))
	setenv("CXX", pathJoin(base, "bin/amdclang++"))
	setenv("FC", pathJoin(base, "bin/amdflang"))
	setenv("OMPI_CC", pathJoin(base, "bin/amdclang"))
	setenv("OMPI_CXX", pathJoin(base, "bin/amdclang++"))
	setenv("OMPI_FC", pathJoin(base, "bin/amdflang"))
	setenv("F77", pathJoin(base, "bin/amdflang"))
	setenv("F90", pathJoin(base, "bin/amdflang"))
	setenv("STDPAR_PATH", "/opt/rocm-${ROCM_VERSION}/include/thrust/system/hip/hipstdpar")
        setenv("STDPAR_CXX", pathJoin(base, "bin/amdclang++"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_RUN_PATH", pathJoin(base, "lib"))
	prepend_path("CPATH", pathJoin(base, "include"))
	load("rocm/${ROCM_VERSION}")
	family("compiler")
EOF

# Create a module file for hipfort package
export MODULE_PATH=/etc/lmod/modules/ROCm/hipfort

${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ROCm HIPFort")
	whatis("Version: ${ROCM_VERSION}")

        local base = "/opt/rocm-${ROCM_VERSION}"
        append_path("LD_LIBRARY_PATH", pathJoin(base, "/lib"))
        setenv("LIBS", "-L" .. pathJoin(base, "/lib") .. " -lhipfort-amdgcn.a")
        setenv("HIPFORT_LIB", pathJoin(base, "/lib"))
        setenv("HIPFORT_INC", pathJoin(base, "/include/hipfort"))
	load("rocm/${ROCM_VERSION}")
EOF

# Create a module file for opencl compiler
export MODULE_PATH=/etc/lmod/modules/ROCm/opencl

${SUDO} mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat <<-EOF | ${SUDO} tee ${MODULE_PATH}/${ROCM_VERSION}.lua
	whatis("Name: ROCm OpenCL")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("ROCm OpenCL")

	local base = "/opt/rocm-${ROCM_VERSION}/opencl"
	local mbase = " /etc/lmod/modules/ROCm/opencl"

	prepend_path("PATH", pathJoin(base, "bin"))
	family("OpenCL")
EOF

echo "DEBUG INCLUDE_TOOLS is ${INCLUDE_TOOLS}"

if [ "${INCLUDE_TOOLS}" = "1" ]; then

   # if ROCM_VERSION is greater than equal to 7.1.0, the sort by version will give the smaller ROCM_VERSION number
   if [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" != "7.1.0" ]; then

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
   fi

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

   # if ROCM_VERSION is greater than or equal to 7.0.0, the sort by version will give the smaller ROCM_VERSION number
   if [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" = "7.1.0" ]; then
      echo "This is where we put the nuitka installation"
      ROCM_PATH=$INSTALL_PATH
      PATH="${ROCM_PATH}:${PATH}"

      #rm -rf standalonebinary
      python3 -m venv standalonebinary
      source standalonebinary/bin/activate
      cd standalonebinary
      # if ROCM_VERSION is greater than or equal to 7.1.0, the sort by version will give the smaller ROCM_VERSION number
      if [ "$(printf '%s\n' "7.1.0" "$ROCM_VERSION" | sort -V | head -n1)" = "7.1.0" ]; then
         git clone --no-checkout --filter=blob:none https://github.com/ROCm/rocm-systems.git
         cd rocm-systems
         git sparse-checkout init --cone
         git sparse-checkout set projects/rocprofiler-compute
         git branch --list
	 ROCM_VERSION_CHECKOUT=$ROCM_VERSION
	 if [ "$ROCM_VERSION" = "7.2" ]; then
            ROCM_VERSION_CHECKOUT="7.2.0"
         fi
         git checkout rocm-${ROCM_VERSION_CHECKOUT}
         #git checkout develop
         cd projects/rocprofiler-compute
	 mv requirements.txt requirements.txt.back

	 # Locking down the python package versions
         cat <<-EOF > requirements.txt
	astunparse==1.6.2
	blinker==1.9.0
	certifi==2026.1.4
	charset-normalizer==3.4.4
	click==8.3.1
	colorlover==0.3.0
	contourpy==1.3.2
	cycler==0.12.1
	dash==3.3.0
	dash-bootstrap-components==2.0.4
	dash-svg==0.0.12
	dnspython==2.8.0
	Flask==3.1.2
	fonttools==4.61.1
	greenlet==3.3.0
	idna==3.11
	importlib_metadata==8.7.1
	itsdangerous==2.2.0
	Jinja2==3.1.6
	kaleido==0.2.1
	kiwisolver==1.4.9
	linkify-it-py==2.0.3
	markdown-it-py==4.0.0
	MarkupSafe==3.0.3
	matplotlib==3.10.8
	mdit-py-plugins==0.5.0
	mdurl==0.1.2
	narwhals==2.15.0
	nest-asyncio==1.6.0
	Nuitka==2.6
	numpy==2.2.6
	ordered-set==4.1.0
	packaging==25.0
	pandas==2.3.3
	patchelf==0.17.2.4
	pillow==12.1.0
	platformdirs==4.5.1
	plotext==5.3.2
	plotille==5.0.0
	plotly==6.5.1
	Pygments==2.19.2
	pymongo==4.16.0
	pyparsing==3.3.1
	python-dateutil==2.9.0
	pytz==2025.2
	PyYAML==6.0.3
	requests==2.32.5
	retrying==1.4.2
	rich==14.2.0
	six==1.17.0
	SQLAlchemy==2.0.45
	tabulate==0.9.0
	textual==7.0.1
	textual-fspicker==0.6.0
	textual-plotext==1.0.1
	tqdm==4.67.1
	typing_extensions==4.15.0
	tzdata==2025.3
	uc-micro-py==1.0.3
	urllib3==2.6.3
	Werkzeug==3.1.5
	zipp==3.23.0
	zstandard==0.25.0
EOF
      else
         # versions 7.0.2 and earlier get a UCC_Bubble counter error, so not enabling for earlier
         python3 -m pip install nuitka==2.6 patchelf
         git clone https://github.com/ROCm/rocprofiler-compute.git
         git checkout rocm-${ROCM_VERSION}
	 cd rocprofiler-compute
      fi

      python3 -m pip install -r requirements.txt

      # Using CMakeLists.txt
      #cmake -B build -DCMAKE_INSTALL_PREFIX=$ROCM_PATH/bin -S .
      #cmake --build build --target standalonebinary

      # Local version from CMakeLists.txt example
      # Change working directory to src
      cd src
      # Create VERSION.sha file
      git -C .. rev-parse HEAD > VERSION.sha
      # Build standalone binary
      # NOTE: --no-deployment-flag=self-execution is used to avoid self-execution
      # and fork bombs as explained in
      # https://nuitka.net/user-documentation/common-issue-solutions.html#fork-bombs-self-execution
      export PROJECT_SOURCE_DIR=`pwd`/..
         python3 -m nuitka --mode=onefile --no-deployment-flag=self-execution \
           --include-data-files=${PROJECT_SOURCE_DIR}/VERSION*=./ --enable-plugin=no-qt --enable-plugin=no-qt \
           --include-package=dash_svg --include-package-data=dash_svg \
           --include-package=dash_bootstrap_components \
           --include-package-data=dash_bootstrap_components --include-package=plotly \
           --include-package-data=plotly --noinclude-data-files=plotly/datasets/* --include-package=kaleido \
           --include-package-data=kaleido --include-package=rocprof_compute_analyze \
           --include-package-data=rocprof_compute_analyze \
           --include-package=rocprof_compute_profile \
           --include-package-data=rocprof_compute_profile \
           --include-package=rocprof_compute_tui --include-package-data=rocprof_compute_tui \
           --include-package=rocprof_compute_soc --include-package-data=rocprof_compute_soc \
           --include-package=utils --include-package-data=utils rocprof-compute
      # Remove library rpath from executable
      patchelf --remove-rpath rocprof-compute.bin
      # Move to build directory
      echo "ROCM_PATH is ${ROCM_PATH}"
      echo "sudo cp rocprof-compute.bin $ROCM_PATH/bin/rocprof-compute.bin"
      sudo cp rocprof-compute.bin $ROCM_PATH/bin/rocprof-compute.bin
      cd ..

      src/rocprof-compute.bin --help
      echo "return code is $?"

      echo ""
      find . -name rocprof-compute.bin -print

      if [[ ! -L $ROCM_PATH/bin/rocprof-compute.py ]]; then
         sudo mv $ROCM_PATH/bin/rocprof-compute $ROCM_PATH/bin/rocprof-compute.py
      fi
      if [[ ! -L $ROCM_PATH/bin/rocprof-compute ]]; then
         pushd $ROCM_PATH/bin && sudo ln -s rocprof-compute.bin rocprof-compute && popd
      fi

      du -skh $ROCM_PATH/bin/rocprof-compute.bin

      deactivate
      cd ../../../..
      rm -rf standalonebinary

   else

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

      if [[ -f /opt/rocm-${ROCM_VERSION}/bin/${TOOL_EXEC_NAME} ]] ; then

         python3 -m venv rocprof-compute-exec
         source rocprof-compute-exec/bin/activate
         pip install pyinstaller
         pip install -r /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/requirements.txt

         if [[ -f /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/VERSION.sha ]]; then
            pyinstaller --onefile /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/rocprof-compute \
              --add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/utils:utils" \
              --add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/VERSION:." \
              --add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/VERSION.sha:." \
              --distpath rocprof-compute-exec/dist
         else
            pyinstaller --onefile /opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/rocprof-compute \
              --add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute:." \
              --distpath rocprof-compute-exec/dist
              #--add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/utils:utils" \
              #--add-data "/opt/rocm-${ROCM_VERSION}/libexec/rocprofiler-compute/rocprof_compute_soc:rocprof_compute_soc" \
         fi

         ls -RC rocprof-compute-exec/dist/
         rocprof-compute-exec/dist/rocprof-compute --version
         ${SUDO} cp rocprof-compute-exec/dist/rocprof-compute /opt/rocm-${ROCM_VERSION}/bin/rocprof-compute.exe
         #${SUDO} rm -f /opt/rocm-${ROCM_VERSION}/bin/rocprof-compute
         #cd /opt/rocm-${ROCM_VERSION}/bin && ${SUDO} ln -s rocprof-compute.exe rocprof-compute && cd -
         rocprof-compute --version
         deactivate
         rm -rf rocprof-compute-exec

         # Restore original version
         #${SUDO} rm -f /opt/rocm-${ROCM_VERSION}/bin/rocprof-compute
         #cd /opt/rocm-${ROCM_VERSION}/bin && ${SUDO} ln -s ../libexec/rocprofiler-compute rocprof-compute && cd -
      fi

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
   fi
fi
