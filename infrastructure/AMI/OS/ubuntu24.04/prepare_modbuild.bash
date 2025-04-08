#!/bin/bash -x

pwd
. /root/kernel.data

echo K VERS = $KERNEL_VERSION
echo ABLE K= $NK

if [[ $NK -eq 1 ]]; then
  pushd .
  cd /lib/modules/${KERNEL_VERSION}/build
  cp .config /tmp
  make clean
  cp /tmp/.config .
  make modules_prepare
  popd
else
  cd /usr/src
  tar -Jxf /usr/src/linux-source-${KV}.tar.xz
  cd linux-source-${KV}
  cp ../linux-headers-${KERNEL_VERSION}/.config .
  make modules_prepare
  rm -f /lib/modules/${KERNEL_VERSION}/build
  ln -s /usr/src/linux-source-${KV} /lib/modules/${KERNEL_VERSION}/build
fi
