#!/bin/bash

# pick up the right kernel version
. $1/kernel.data

cp -fv ${TARGET}/boot/{config-${KERNEL_VERSION},vmlinuz-${KERNEL_VERSION},initramfs-ramboot-${KERNEL_VERSION}} artifacts
