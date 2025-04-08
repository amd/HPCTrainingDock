#!/bin/bash

# pick up the right kernel version
. /kernel.data
 /usr/sbin/mkinitramfs \
	 -v \
	 -o /boot/initramfs-ramboot-${KERNEL_VERSION} \
	 ${KERNEL_VERSION}

