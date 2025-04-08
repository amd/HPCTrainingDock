#!/bin/bash

TARGET=$1
ABLE_SNAP=$2
COMP_BIN=$3

cp -vf OS/ubuntu24.04/able.hook ${TARGET}/usr/share/initramfs-tools/hooks/able
cp -vf OS/ubuntu24.04/tools.hook ${TARGET}/usr/share/initramfs-tools/hooks/tools
 # insert our modified local script to insure that ROOT=ram doesn't error out
cp -vf OS/ubuntu24.04/local ${TARGET}/usr/share/initramfs-tools/scripts

chmod +x ${TARGET}/usr/share/initramfs-tools/hooks/able
chmod +x ${TARGET}/usr/share/initramfs-tools/hooks/tools
mkdir -p ${TARGET}/usr/share/initramfs-tools/scripts/local-top/
cp -vf OS/ubuntu24.04/ramboot.initramfs \
       ${TARGET}/usr/share/initramfs-tools/scripts/local-top/ramboot
sed -i "s|__ABLE_SNAP__|${ABLE_SNAP}|g" ${TARGET}/usr/share/initramfs-tools/scripts/local-top/ramboot
sed -i "s|__COMP_BIN__|${COMP_BIN}|g" ${TARGET}/usr/share/initramfs-tools/scripts/local-top/ramboot
chmod +x ${TARGET}/usr/share/initramfs-tools/scripts/local-top/ramboot
