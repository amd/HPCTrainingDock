#!/bin/bash -x

pwd
. /kernel.data

echo TARGET = $TARGET
echo DISTRO = $DISTRO
echo HWE    = $HWE
echo

export PACKAGE_NAME=linux-image-generic
export HEADERS_NAME=linux-headers-generic
export REL=`echo ${DISTRO} | sed 's/ubuntu//i'`

if [[ $HWE == 1 ]]; then 
  export PACKAGE_NAME=${PACKAGE_NAME}-hwe-${REL}
  export HEADERS_NAME=${HEADERS_NAME}-hwe-${REL}
fi

export DEBIAN_FRONTEND=noninteractive ; apt-get  -y  \
		install ${PACKAGE_NAME}  ${HEADERS_NAME} \
     module-assistant

export KERNEL_VERSION=`/root/get_kver.bash`

# now prepare the modules
m-a prepare --non-inter -l ${KERNEL_VERSION}

echo KERNEL_VERSION=${KERNEL_VERSION} >> /kernel.data
