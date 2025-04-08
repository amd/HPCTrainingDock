# About AMI (AMD Able Machine Image)

AMI (AMD Able Machine Image) solves the problem of configuration drift and bootable image divergence across fleets of physical/virtual machines, by creating immutable OS images that can be used as building blocks for a cluster, a set of functions, as a rescue environment, etc.
These images can be network (PXE, SAN), USB, and local disk booted.  AMI (AMD Able Machine Image)
instances, the booted version of a AMI (AMD Able Machine Image) image, may be configured
programmatically upon boot, using any mechanism you prefer for configuration
management.

With a AMI (AMD Able Machine Image) based OS image, you cannot get image divergence or configuration
drift across your fleet.  It solves this by creating a fixed bootable initramfs
artifact for a particular linux distribution.  The initramfs creation is driven
by the Makefile in this repo.  

Far more importantly, you should never have an errant driver or configuration stop a node from correctly booting.  You should always be able to come up to an operational state of an OS, and apply configuration

## Theory of operation

AMI (AMD Able Machine Image) sits atop the basic distro packaging mechanisms (apt, yum/dnf/zypper) and adds
specific configuration, tools, drivers, and packages that you may modify.  
One should be able to build an image from any distro as long as the
relevant target distro's tools are installed.

AMI (AMD Able Machine Image) will build an image from the tools into a temporary scratch space.  This
build will then be snapshot into a compressed tar image using tar and a compressor.
After that the image will be incorporated into an initramfs, after adjusting the 
initramfs configuration to include the tarball, and the elements required to 
unpack it.

You can select different compressors by adding a `COMP=pigz` or similar on the
build line.  Your options are gzip, bzip2, lbzip2, pigz, xz, pxz, zstd.  Current
default is set to zstd, given how fast it compresses and decompresses compared
to the others.  Compression ratios are similar across all of the compressors.

This effectively limits the size of the tarball to 2GB, as cpio cannot handle
larger files at this moment.  If you are willing to forgo the PXE bootable capability,
and generate binary machine images which may be installed on any bootable device.

### Build variables

Several important variables used for the build are
* DISTRO : which distribution you will use as the base of your image.  Current choices are ubuntu24.04, with debian12, debian11,  ubuntu22.04, and Rocky9 in process.  RHEL 10/9 and SLES15SP6  may require additional 
configuration options.

* TARGET : top level scratch directory for building the image.  Defaults to ```/mnt/root```.


### Build configuration outside of variables

The Makefile includes distro specific configuration in ```OS/$DISTRO/{base,config}.conf``` .  The Makefile uses 1 target, ```finalizebase``` which should be the last target in ```OS/$DISTRO/config.conf```.  The ```OS/$DISTRO/base.conf``` portion of
the distro specific included Makefile should handle all of the base distro
package installation, and kernel installation.  The ```OS/$DISTRO/config.conf```
should handle all of the post installation configuration, additional driver,
package, and feature installation.

### Running builds

In short (though only ubuntu24.04 is currently supported)

```
# # create a debian12 based distro
make DISTRO=debian12

# # create a debian11 based distro
make DISTRO=debian11

# # create a ubuntu20.04 based distro
make DISTRO=ubuntu20.04

# # create a ubuntu22.04 based distro
make DISTRO=ubuntu22.04

# # create a ubuntu24.04 based distro
make DISTRO=ubuntu24.04

# # create a Rocky9 based distro
make DISTRO=rocky9


# # install to a physical disk / raid / device you have mounted at /mnt/root
# # capability being re-worked
# # make PHYSICAL=1 [DISTRO=...]
# # note this isn't working right now

```

This will take some time even with a good internet connection and a close mirror.  It will, upon completion, leave two specific files you need in /mnt/root/boot.  These will be named initramfs-ramboot-$SOME_KERNEL_VERSION and vmlinuz-$SOME_KERNEL_VERSION.  You should preserve these as the build artifacts.  

You may take these two files, and using virt-manager (or qemu) do a direct kernel boot.  Add in kernel boot arguments like this:

```
	root=ram rootfstype=ramdisk simplenet=1 verbose udev.children-max=4 rootpw=nyble
```

You will have a nice console to a ramdisk based full distro running in about 10GB of RAM.  You can tweak that amount by adding a 'ramdisksize=X ' option for values of X from 6-32.  Units are GB.  

These files may be served by PXE (I use ipxe for this), or placed into a systems /boot as a rescue distribution.  For that, I create an /etc/grub.d/40_custom file with these contents

```
#!/bin/sh
cat <<EOF

menuentry ' AMI (AMD Able Machine Image) Ubuntu 18.04 hwe' {
        linux   /boot/nyble/vmlinuz-5.3.0-40-generic root=ram rootfstype=ramdisk simplenet=1 verbose udev.children-max=4 rootpw=nyble ramdisktype=zram ramdisksize=12
        initrd  /boot/nyble/initramfs-ramboot-5.3.0-40-generic
}

EOF
```

Of course, modify your kernel version in the initrd and kernel lines to suit what you have built.


You can execute up to a specific target, for example ```fb_final``` by running
  ```make fb_final```.  You can continue the image build process by running ```make```.

You can inspect any variable in the Makefile, by using ```make print-VARIABLE_NAME```

```
# make print-DISTRO
DISTRO = debian12

# make DISTRO=debian11 print-DISTRO
DISTRO = debian11

# make print-TARGET
TARGET = /mnt/root

# make TARGET=/outerspace  print-TARGET
TARGET = /outerspace

```



Upon successful completion of the build, you will have a kernel and initramfs located in ```${TARGET}/boot/``` that you may use for PXE booting.

Since git does not allow for large BLOB artifacts, you need to store them in
a different location which can be easily pulled during build.  This is


### Workflow

The Makefile includes distro specific configuration in OS/$DISTRO.  There are two
specific mechanisms for adding functionality, using the drivers or packages directory off of the main repository directory.

## Build a PXE bootable OS image

* building

You will need a machine with a fast network, and at least 64 GB RAM.  This
builds the image in a ramdisk, which you can copy out to permanent storage.
You can alter this behavior, by changing the TARGET= variable in the Makefile.


  ```
     git clone able_repo 
     cd able
     # point to local repos and kernel repos
     # Edit config/all.conf to adjust default features/functionality
     make [FEATURE_1=0|1] [FEATURE_2=0|1] ... [FEATURE_N=0|1]
  ```

Support for a bootable usb exists if you use the ```usb``` target.  That is, to
make a bootable USB drive image

	```make usb [DISTRO=...]```

at the end of the process, you will find a file named `nyble.usb` in your directory.
To use this, copy it to a USB drive.  The easiest way to do this is using the
dd command in linux.

	```umount /dev/$USB ; dd if=nyble.usb of=/dev/$USB oflag=direct bs=1M status=progress```

You may determine your USB drive device using the `lsscsi` command,

	```
	joe@gandalf:~$ lsscsi
	[0:0:0:0]    disk    ATA      WDC WDS250G2B0B- 30WD  /dev/sda
	[2:0:0:0]    disk    ATA      Samsung SSD 840  6B0Q  /dev/sdb
	[3:0:0:0]    disk    ATA      SAMSUNG MZ7KM960 003Q  /dev/sdc
   ...
	[6:0:0:0]    disk    JetFlash Transcend 16GB   1100  /dev/sdh

	```
In this case, /dev/sdh is my /dev/$USB .

If you wish to turn package inclusion off (on by default), add ```PACKAGES=0``` 
to the make command.

  ```make PACKAGES=0```

Packages include AMDGPU drivers, and a few related tools.  

The bootable kernel and initramfs will be located in /mnt/root/boot.  Copy them
to the appropriate location for serving using iPXE and http on your machine.

## Using

  After configuring your system for iPXE boot, with the kernel and initramfs
located and available for service via http (much faster than tftp), make sure
you add the following boot options to the kernel line.

```
  root=ram rootfstype=ramdisk udev.children-max=1 simplenet=1 verbose console=tty0
```

You can add options to this as needed.

### Boot Options

#### Networking
* ```net.ifnames=0|1``` setting this to 0 will disable renaming networks from
eth$N. Setting this to 1 will use _new_ naming scheme.  Default is 1.


* ```simplenet=0|1``` will remove/re-insert drivers for NICs, loop through all
     the network devices, bringing the NIC up, and then looking for a carrier.
     Those that have a carrier will be dhcp'ed.  Using ```simplenet=1``` is
     is the simplest way to bring up a network

* ```net_if=NET``` configure the NET device (must come before sub options
     below)

     * ```net_addr=IP/MASK``` set a particular IPv4 IP address/CIDR MASK to the
       NET address



* ```br_name=NAME``` create a linux bridge device named NAME (must come
  before the sub options below)

     * ```br_if=NET``` attach NET network device to the NAME bridge

     * ```br_addr=IP/MASK``` set a particular IPv4 IP address/CIDR MASK to the
       NAME bridge.  If not included, the bridge NAME will dhcp for an address

- For both ```net_if=NET``` and ```br_name=NAME```, the following suboptions exist

     * ```net_dns=IPDNS``` creates an ```nameserver IPDNS``` entry in ```/etc/resolv.conf```

     * ```net_gw=IPGW``` add a network gateway at address IPGW

* ```rootpw=PLAINTXT``` set a root password on boot.  Not secure, but usable
  in an emergency.  The image is immutable, but the instance of the image is not.
  So you can use this to start up an image instance with a new root password for
  running you own tests.  Since the instance image will not, by default, attach
  any specific durable storage, you can use this as a sandbox for testing.

* ```rootsize=X{G.M,K}``` set the tmpfs (if used) root disk size to X with units
  as indicated.

* ```disablettyS{0,1,2}=0|1``` enable (0) or disable any of the serial consoles (activated by default) from being used for logins.

* ```enablelldpd=0|1```  turn LLPD off (0) or on (1).  Off by default.

* ```zpoolimport=1```  For ZFS builds only, force a zpool import.

* ```ramdisktype=zram``` to use a zram (compressed ramdisk block device) rather
than the default tmpfs device.  This will create an ext4 file system atop the
```/dev/zram0``` device, and mount it as your root file system.

* ```ramdisksize=SIZE_IN_GB``` to set the ramdisk size to be SIZE_IN_GB number of
GB.  So if you wish to use a 5GB ramdisk, use ```ramdisksize=5```.  

* ```image=keep``` copies the boot tarball into / on the booted image.  This
is useful if you would like to use this to install this (exact) booted system to
physical disk.  You will need to install and configure grub-pc after this,
but that is generally a simple process.

Normal kernel boot parameters also apply to the image instance.  Due to udev
issues on startup, using ```udev.children-max=1``` is highly recommended.  You
may encounter race conditions if you use a number higher than 4.  You may turn
on basic deugging using ```debug```, or set console to physical terminal ```console=tty0```.

### Debugging

It is possible to break startup at a number of points before, during, and after
unpacking the rootfs into the ramdisk.

* ```break=preunpack``` will launch a shell before the system creates the ramdisk

* ```debug``` on the command line will also return the environment variables
prior to creating the ramdisk

* ```break=postunpack``` will launch a shell after the system creates the ramdisk
and unpacks the snapshot tarball.

Exiting these shells should continue startup operation.
