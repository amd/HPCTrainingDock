# AMDGPU Base Linux Environment (ABLE) Machine Image
# aka AMI. This is the image building makefile.
#
LODEV	= $(shell scripts/lodev.sh)
DS 		= $(shell date +%s)
BD 		= $(shell pwd)
ARTIF=${BD}/artifacts
RAWIMG=${ARTIF}/AMI.raw
ISOIMG=${ARTIF}/AMI.iso


all:	finalizebase able_machine_image_build_last
	

osinst: able_machine_image_build_1 osinst_last
	
	touch osinst

finalizebase: osinst fb_last
	
	touch finalizebase

#  pull in config options
include config/all.conf


# attach to distro specific build
include OS/${DISTRO}/base.conf		# base OS install including relevant 
									# base packages

include OS/${DISTRO}/config.conf	# OS configuration

#  place new packages to install in the packages/ directory
include packages/packages.conf

# 
# compressor file extension and binary
#
include config/compressor.conf


#
# for tarball we will use for some image formats, and the squashfs file
# system for rocm-$ROCM_VERS
#
ABLE_SNAP=able_snap.tar.${COMP_EXT}
ABLE_OPT_SQSH=able_opt.sqsh
ABLE_ULLP_SQSH=able_usr_local_lib_python.sqsh


#
# create the able_machine_image for the OS image construction
# this will wipe ${TARGET} if it is already mounted (it shouldn't be unless
# it is a physcal device )
able_machine_image_build_1:
	
	bash -c "if [ `grep -q  ${TARGET} /proc/mounts ` ]; then rm -rf ${TARGET} ;	fi"
	rm -f ${TARGET}/able_snap.tar*
	echo TARGET = ${TARGET}
	mkdir -p ${TARGET}

ifeq (${DEST},file)
	# generate a bootable raw hard disk image in UEFI format
	# assume an (at least) 128GB drive image
	mkdir -p ${ARTIF}
	fallocate  -l 128G ${RAWIMG}
	losetup  ${LODEV} ${RAWIMG}

	# partition the device image, 4GB for EFI, 1GB for BIOS, rest for OS
	parted ${LODEV} mklabel gpt
	parted ${LODEV} -a optimal mkpart primary fat32 1MB 4GB
	parted ${LODEV} -a optimal mkpart primary fat32 4GB 5GB
	parted ${LODEV} -a optimal mkpart primary xfs 5GB 128GB
	
	# format the device partitions
	mkfs.fat ${LODEV}p1
	mkfs.xfs ${LODEV}p3
	
	# set the boot flag on for partition 1
	parted ${LODEV} set 1 boot on

	# set the esp flag on for partition 1
	parted ${LODEV} set 1 esp on

	# mount the image at TARGET and the BOOT partition as TARGET/boot
	mount  ${LODEV}p3 ${TARGET}
	mkdir -p ${TARGET}/boot/efi
	mount ${LODEV}p1 ${TARGET}/boot/efi
endif

ifeq (${DEST},mem)
	touch /mnt/able_snap.tar
	# need to have a local image storage as well, this uses ram disk
	mount -o size=64g -t tmpfs none ${TARGET} 
endif

	touch able_machine_image_build_1


able_machine_image_build_2:	finalizebase
	# place scripts where they need to be for startup
	mkdir -p ${TARGET}/usr/local/bin
	for s in get_cmdline_key.pl get_kver.bash lsbond lsbr lsint.pl lsnet local_disk_install.bash lodev.sh mount_sys.sh pcilist.pl spark ; do \
		cp -fv scripts/$$s ${TARGET}/usr/local/bin ;\
	done
	touch able_machine_image_build_2

image_gen: able_machine_image_build_2

ifeq (${IMAGE},raw)
	# prep for raw image
	
endif

ifeq (${IMAGE},iso)
	# Createa squashfs file system with /opt from the TARGET
	cd ${TARGET} ;	mksquashfs opt ${BD}/artifacts/${ABLE_ROCM_SQSH}.${DS} \
		-comp zstd \
		-one-file-system \
		-progress \
		-info \
		-processors 32 \
		-mem 32G

	# now trim off the /opt directory
	rm -rf ${TARGET}/opt
	mkdir ${TARGET}/opt

	# make a blob dir, and copy the squashfs into that
	mkdir -p ${TARGET}/blob
	cp -vf  ${BD}/artifacts/${ABLE_OPT_SQSH}.${DS} ${TARGET}/blob

	# create a mount line in ${TARGET}/etc/fstab
	echo "/blob/${ABLE_OPT_SQSH}.${DS} /opt squashfs	ro,defaults	0 0" >> ${TARGET}/etc/fstab
	chroot ${TARGET} systemctl daemon-reload

endif

ifeq (${IMAGE},kvm)
	# generate a kvm bootable image with vmlinuz, initramfs-ramboot, and able_opt.sqsh
	# which is a squashfs version of the /opt directory (compressed and read only)

	cd ${TARGET} ;	 tar -I "${COMP_BIN}" -cSf /mnt/${ABLE_SNAP}  \
		--exclude="^./run/docker*" \
		--exclude="./run/samba/winbindd/pipe*" \
		--exclude="^./sys/*" \
		--exclude="^./proc/*" \
		--exclude="./dev/*"  \
		--exclude="^./var/lib/docker/devicemapper/devicemapper/*"  \
		bin  boot  data dev  etc  home  lib lib64  media  mnt proc root \
		run  sbin  srv sys tmp  usr  var
	# build a sqashfs out of ${TARGET}/opt/rocm, and deposit into the 
	# artifacts directory
	
	cd ${TARGET}/opt ;	mksquashfs rocm ${BD}/artifacts/${ABLE_OPT_SQSH}.${DS} \
		-comp zstd \
		-one-file-system \
		-progress \
		-info \
		-processors 32 \
		-mem 32G
	mv -fv /mnt/${ABLE_SNAP} ${TARGET}
	cp -fv ${TARGET}/${ABLE_SNAP} artifacts/${ABLE_SNAP}.${DS}
endif

	touch image_gen

able_machine_image_build_3:	image_gen

	umount -l -q ${TARGET}/dev/pts
	umount -l -q ${TARGET}/dev
	umount -l -q ${TARGET}/sys
	umount -l -q ${TARGET}/proc
	rm -f /mnt/${ABLE_SNAP}
	rm -rf ${TARGET}/usr/games ${TARGET}/usr/local/games
	
	touch able_machine_image_build_3

able_machine_image_build_final: able_machine_image_build_3
	#
	# remove the policy bits now to allow able_machine_image and other services to rebuild
	rm -f ${TARGET}/usr/sbin/policy-rc.d
	#
ifeq (${IMAGE},kvm)
	OS/${DISTRO}/prepare_initramfs.bash ${TARGET} ${ABLE_SNAP} ${COMP_BIN}
	cp scripts/build_initramfs.bash ${TARGET}/root
	chroot ${TARGET} /root/build_initramfs.bash
	scripts/copy_to_artifact_dir.bash ${TARGET}
endif
	touch able_machine_image_build_final


able_machine_image_build_distribution:	able_machine_image_build_final
ifeq (${IMAGE},iso)
	# build iso from mounted fs
endif
ifeq (${IMAGE},raw)
	# compress the machine image with zstd
	ls -alF ${RAWIMG}
	zstd -T0 -19 --rsyncable ${RAWIMG}
	ls -alF ${RAWIMG}*
endif
ifeq (${IMAGE},qcow2)
	# compress the machine image with zstd
	qemu-img convert -c  -p -S 16384 -O qcow2 -o compression_type=zstd -o compat=1.1 ${RAWIMG} ${RAWIMG}.qcow2
	ls -alF ${RAWIMG}*
endif

	touch able_machine_image_build_distribution

able_machine_image_build_last: able_machine_image_build_distribution

	touch able_machine_image_build_last

umount:
ifeq (${DEST},mem)
	$(shell umount -f -q -l ${TARGET}/dev/pts ${TARGET}/dev ${TARGET}/proc ${TARGET}/sys ${TARGET} )
endif
ifeq (${DEST},file)
	$(shell umount -f -q -l ${TARGET}/dev/pts ${TARGET}/dev ${TARGET}/proc ${TARGET}/sys ${TARGET}/boot/efi ${TARGET} )
endif

	# unmount the loopback setup
ifneq ("$(wildcard ${LODEV})","")
	losetup -d ${LODEV}  
endif
	touch umount

clean: umount clean_all_loopdevs
	rm -f osinst finalizebase fb_* osinst_* able_machine_image_build_* /mnt/nyble_snap.tar* \
		able_machine_image_build_* kernel.data usbkey wget-log* umount clean_all_loopdevs
	cd packages ; $(MAKE) clean 
	
	rm -rf artifacts
	rm -f lodev.data
	$(shell ( grep -q ${TARGET} /etc/mtab ) && umount -l -f -q ${TARGET} )

clean_all_loopdevs: umount
	losetup -D
	touch clean_all_loopdevs

test_clean:
	grep  ${TARGET}  /proc/mounts


###################################################
## debugging targets

print-%  : ; @echo $* = $($*)
# use as "make print-VARIABLE_NAME" to see variable name
