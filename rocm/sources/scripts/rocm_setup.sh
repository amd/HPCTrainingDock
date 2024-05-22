#!/bin/bash

: ${ROCM_VERSION:="6.0"}
: ${DISTRO:="ubuntu"}
: ${DISTRO_VERSION:="22.04"}

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
      AMDGPU_INSTALL_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_MAJOR}0${ROCM_MINOR}0${ROCM_PATCH}-1
      AMDGPU_ROCM_VERSION=${ROCM_MAJOR}.${ROCM_MINOR}.${ROCM_PATCH}
   fi
}

rocm-repo-dist-set()
{
   if [ "${DISTRO}" = "ubuntu" ]; then
       ubuntu-set
   elif [ "${DISTRO}" = "rhel" ]; then
       rhel-set
   elif [ "${DISTRO}" = "opensuse" ]; then
       opensuse-set
   fi
}

ubuntu-set()
{
   ROCM_REPO_DIST="ubuntu"
   case "${ROCM_VERSION}" in
       4.1* | 4.0*)
          ROCM_REPO_DIST="xenial"
           ;;
       5.3* | 5.4* | 5.5* | 5.6* | 5.7*)
           case "${DISTRO_VERSION}" in
               22.04)
                   ROCM_REPO_DIST="jammy"
                   ;;
               20.04)
                   ROCM_REPO_DIST="focal"
                   ;;
               18.04)
                   ROCM_REPO_DIST="bionic"
                   ;;
               *)
                   ;;
           esac
           ;;
       6.0* | 6.1*)
           case "${DISTRO_VERSION}" in
               22.04)
                   ROCM_REPO_DIST="jammy"
                   ;;
               20.04)
                   ROCM_REPO_DIST="focal"
                   ;;
               *)
                   ;;
           esac
           ;;
       *)
           ;;
   esac
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

   #verbose-build docker build . ${PULL} -f ${DOCKER_FILE} --tag ${CONTAINER} --build-arg DISTRO=${DISTRO_BASE_IMAGE} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION} --build-arg AMDGPU_RPM=${ROCM_RPM} --build-arg PYTHON_VERSIONS=\"${PYTHON_VERSIONS}\"

#  ROCM_DOCKER_OPTS="${ROCM_DOCKER_OPTS} --tag ${CONTAINER} --build-arg DISTRO=${DISTRO_BASE_IMAGE} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION} --build-arg AMDGPU_RPM=${ROCM_RPM}"
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
   #verbose-build docker build . ${PULL} -f rocm/${DOCKER_FILE} --tag ${CONTAINER} --build-arg DISTRO=${DISTRO_IMAGE} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION} --build-arg AMDGPU_RPM=${ROCM_RPM} --build-arg PERL_REPO=${PERL_REPO} --build-arg PYTHON_VERSIONS=\"${PYTHON_VERSIONS}\"

#  ROCM_DOCKER_OPTS="${ROCM_DOCKER_OPTS} --tag ${CONTAINER} --build-arg DISTRO=${DISTRO_IMAGE} --build-arg DISTRO_VERSION=${DISTRO_VERSION} --build-arg ROCM_VERSION=${ROCM_VERSION} --build-arg AMDGPU_RPM=${ROCM_RPM} --build-arg PERL_REPO=${PERL_REPO}"
}

reset-last()
{
    last() { send-error "Unsupported argument :: ${1}"; }
}


ROCM_REPO_DIST=`lsb_release -c | cut -f2`
DISTRO=`lsb_release -i | cut -f2`
DISTRO_VERSION=`lsb_release -r | cut -f2`

#echo "After autodetection"
#echo "ROCM_REPO_DIST is $ROCM_REPO_DIST" 
#echo "DISTRO is $DISTRO" 
#echo "DISTRO_VERSION is $DISTRO_VERSION" 
#echo ""

reset-last

n=0
while [[ $# -gt 0 ]]
do
   case "${1}" in
      "--rocm-version")
          shift
          ROCM_VERSION=${1}
          reset-last
          ;;
      "--distro")
          shift
          DISTRO_OVERRIDE=${1}
          reset-last
          ;;
      "--distro-version")
          shift
          DISTRO_VERSION_OVERRIDE=${1}
          reset-last
          ;;
      *)
         last ${1}
         ;;
   esac
   n=$((${n} + 1))
   shift
done

OVERRIDE="0"
if [ -z "$DISTRO_OVERRIDE}" ]; then
   DISTRO=$DISTRO_OVERRIDE
   OVERRIDE="1"
fi

if [ -z "$DISTRO_VERSION_OVERRIDE}" ]; then
   DISTRO_VERSION=$DISTRO_VERSION_OVERRIDE
   OVERRIDE="1"
fi

if [ "$OVERRIDE}" = "1" ]; then
   # Only need to do this if the distro or version is overridden
   rocm-repo-dist-set
fi

#echo "After input parsing"
#echo "DISTRO is $DISTRO" 
#echo "DISTRO_VERSION is $DISTRO_VERSION" 
#echo "ROCM_VERSION is $ROCM_VERSION" 
#echo ""
#echo "ROCM_REPO_DIST is $ROCM_REPO_DIST" 
#echo ""

# This sets variations of the ROCM_VERSION needed by installers
# AMDGPU_ROCM_VERSION
# AMDGPU_INSTALL_VERSION 
version-set

echo "Starting ROCm Install with"
echo "DISTRO: $DISTRO" 
echo "DISTRO_VERSION: $DISTRO_VERSION" 
echo "ROCM_REPO_DIST: $ROCM_REPO_DIST" 
echo "ROCM_VERSION: $ROCM_VERSION" 
echo "AMDGPU_ROCM_VERSION: $AMDGPU_ROCM_VERSION" 
echo "AMDGPU_INSTALL_VERSION: $AMDGPU_INSTALL_VERSION" 

wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | apt-key add -
apt-get update
wget -q https://repo.radeon.com/amdgpu-install/${AMDGPU_ROCM_VERSION}/ubuntu/${ROCM_REPO_DIST}/amdgpu-install_${AMDGPU_INSTALL_VERSION}_all.deb
apt-get install -y ./amdgpu-install_${AMDGPU_INSTALL_VERSION}_all.deb
amdgpu-install -y  --usecase=hiplibsdk,rocm --no-dkms

# Required by DeepSpeed
ln -s /opt/rocm-${ROCM_VERSION}/.info/version /opt/rocm-${ROCM_VERSION}/.info/version-dev

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
export MODULE_PATH=/etc/lmod/modules/ROCm/rocm

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/${ROCM_VERSION}.lua <<-EOF
	whatis("Name: ROCm")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("ROCm")

	local base = "/opt/rocm-${ROCM_VERSION}/"
	local mbase = " /etc/lmod/modules/ROCm/rocm"

	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib64"))
	prepend_path("C_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPLUS_INCLUDE_PATH", pathJoin(base, "include"))
	prepend_path("CPATH", pathJoin(base, "include"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("INCLUDE", pathJoin(base, "include"))
	setenv("ROCM_PATH", base)
	family("GPUSDK")
EOF

# Create a module file for amdclang compiler
export MODULE_PATH=/etc/lmod/modules/ROCm/amdclang

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/17.0-${ROCM_VERSION}.lua <<-EOF
	whatis("Name: AMDCLANG")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("AMDCLANG")

	local base = "/opt/rocm-${ROCM_VERSION}/llvm"
	local mbase = "/etc/lmod/modules/ROCm/amdclang"

	setenv("CC", pathJoin(base, "bin/amdclang"))
	setenv("CXX", pathJoin(base, "bin/amdclang++"))
	setenv("FC", pathJoin(base, "bin/amdflang"))
	setenv("F77", pathJoin(base, "bin/amdflang"))
	setenv("F90", pathJoin(base, "bin/amdflang"))
	prepend_path("PATH", pathJoin(base, "bin"))
	prepend_path("LD_LIBRARY_PATH", pathJoin(base, "lib"))
	prepend_path("LD_RUN_PATH", pathJoin(base, "lib"))
	prepend_path("CPATH", pathJoin(base, "include"))
	load("rocm/${ROCM_VERSION}")
	family("compiler")
EOF

# Create a module file for hipfort package
export MODULE_PATH=/etc/lmod/modules/ROCm/hipfort

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/${ROCM_VERSION}.lua <<-EOF
	whatis("Name: ROCm HIPFort")
	whatis("Version: ${ROCM_VERSION}")

	setenv("HIPFORT_HOME", "/opt/rocm-${ROCM_VERSION}")
	append_path("LD_LIBRARY_PATH", "/opt/rocm-${ROCM_VERSION}/lib")
	setenv("LIBS", "-L/opt/rocm-${ROCM_VERSION}/lib -lhipfort-amdgcn.a")
	load("rocm/${ROCM_VERSION}")
EOF

# Create a module file for opencl compiler
export MODULE_PATH=/etc/lmod/modules/ROCm/opencl

mkdir -p ${MODULE_PATH}

# The - option suppresses tabs
cat > ${MODULE_PATH}/${ROCM_VERSION}.lua <<-EOF
	whatis("Name: ROCm OpenCL")
	whatis("Version: ${ROCM_VERSION}")
	whatis("Category: AMD")
	whatis("ROCm OpenCL")

	local base = "/opt/rocm-${ROCM_VERSION}/opencl"
	local mbase = " /etc/lmod/modules/ROCm/opencl"

	prepend_path("PATH", pathJoin(base, "bin"))
	family("OpenCL")
EOF

