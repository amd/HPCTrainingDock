#!/bin/bash -x
#
# chkconfig: 235 99 99
# description: able post boot config
### BEGIN INIT INFO
# Provides:          able
# Required-Start:    $local_fs $syslog
# Required-Stop:     $local_fs $syslog sendsigs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: able post boot configuration script
# Description:       able provides a post boot configuration mechanism
#
### END INIT INFO

### the opening brace below is matched by the closing brace at the 
#   bottom of the file.  DONT REMOVE IT, or you lose logging.
{


#
# able provides post boot config for non-systemd based
#
# description: Provide post boot config
# Author: joseph.landman\@amd.com
#
# /etc/init.d/able
#

RETVAL=0

/sbin/ldconfig
if [ -e /etc/debian_version ]; then
DHCLIENT=/sbin/dhclient
fi

if [ -e /etc/redhat-release ]; then
DHCLIENT=/sbin/dhclient
fi

#. /etc/init.d/functions
# See how we were called.
case "$1" in
    start)

	  echo -n "Starting post boot process configuration: "

	  # sanity check /proc /sys and /dev
	  if [ ! -d /proc ]; then
	     mkdir -p /proc
	     mount -t procfs procfs /proc
	  fi

	  if [ ! -d /sys ]; then
	     mkdir -p /sys
	     mount -t sysfs sysfs /sys
	  fi

	  if [ ! -d /dev ]; then
	     mkdir -p /dev
	     mount -t devtmpfs devtmpfs /dev
	  fi

	  # grab rootpw= if it exists
	  if (grep -q rootpw= /proc/cmdline); then
	     rootpw=$(/opt/able/bin/get_cmdline_key.pl rootpw)
	     echo "root:$rootpw" | chpasswd
	  fi

	  # resize root ramdisk if rootsize= exists and root is on tmpfs
	  if (grep -q rootsize= /proc/cmdline); then
	     rootfstype=$(mount | grep `df -h / | tail -1 | cut -d" " -f1` | head -1 | cut -f5 -d" ")
	     if [[ "$rootfstype" == "tmpfs" ]]; then
	  	 rootsize=$(/opt/able/bin/get_cmdline_key.pl rootsize)
		 mount -o remount,size=$rootsize /
	     fi
	  fi

	  # disablettyS0=1 turns off serial console on ttyS0
	  if (grep -q disablettyS0=1 /proc/cmdline); then
	     systemctl disable serial-getty@ttyS0.service
	     systemctl stop serial-getty@ttyS0.service
	  fi

	  # disablettyS1=1 turns off serial console on ttyS1
	  if (grep -q disablettyS1=1 /proc/cmdline); then
	     systemctl disable serial-getty@ttyS1.service
	     systemctl stop serial-getty@ttyS1.service
	  fi

	  # disablettyS2=1 turns off serial console on ttyS2
	  if (grep -q disablettyS2=1 /proc/cmdline); then
	     systemctl disable serial-getty@ttyS2.service
	     systemctl stop serial-getty@ttyS2.service
	  fi


	# use simplified networking if simplenet=1 is in boot commandline
	# basically bring up each ethernet (eth*) and then see whom has a
	# carrier.  DHCP those interfaces.  This breaks if portfast is not
	# enabled on your switches (it should be enabled unless there is a
	# very good reason to disable it)
	# reset network state, loading specific drivers

	# bring interfaces up
	for net in $(ls /sys/class/net/ | grep -v lo ) ; do
	   /usr/sbin/ifconfig $net up
	done
	sleep 3
	
	allports=""
	ports=""
	for net in $(ls /sys/class/net/ | grep -v lo ); do
	     allports="$allports $net"
             carrier="$( cat  /sys/class/net/$net/carrier )"
             if [ $carrier -eq 1 ] ; then
                ports="$ports $net"
             fi
	done

	# startup openibd if we have Mellanox cards
	if [ `lspci | grep Mell | wc -l` -gt 0 ]; then
	  /etc/init.d/openibd start
	fi

	if (grep -q simplenet=1 /proc/cmdline); then
	   sleep 10
	   # sleep 10 seconds to make sure they establish link, then
	   # probe for link.  dhclient on all interfaces with a link

	   ${DHCLIENT} -x
	   echo "ports= $ports"
	   ${DHCLIENT} -v  $ports
	fi

	#set specific network IP/mask, DNS, default GW
	if (grep -q net_if= /proc/cmdline); then
           net_if=$(/opt/able/bin/get_cmdline_key.pl net_if)
           if (grep -q net_addr= /proc/cmdline); then
		net_addr=$(/opt/able/bin/get_cmdline_key.pl net_addr)
		ifconfig $net_if $net_addr up
	      else
		dhclient -x
		sleep 2
		dhclient -v $net_if
	   fi
	fi
        if (grep -q net_dns= /proc/cmdline); then
                net_dns=$(/opt/able/bin/get_cmdline_key.pl net_dns)
		echo "nameserver $net_dns" > /etc/resolv.conf
        fi
        if (grep -q net_gw= /proc/cmdline); then
                net_gw=$(/opt/able/bin/get_cmdline_key.pl net_gw)
		route add default gw $net_gw
        fi
        
        #bridge control:  set specific network IP/mask, DNS, default GW, bridge ports
        if (grep -q br_name= /proc/cmdline); then
           br_name=$(/opt/able/bin/get_cmdline_key.pl br_name)
	   brctl addbr $br_name

	   # either specify interface names with br_if ...
	   if (grep -q br_if= /proc/cmdline); then
                br_ifs=$(/opt/able/bin/get_cmdline_key.pl br_if)
		list=$(echo $br_ifs | sed 's|\,| |g')
		for br_if in $list; do
		    brctl addif $br_name $br_if
		    ifconfig $br_if up
		done
	    else
	    # or have the system add interfaces that are marked as 
	    # having a carrier after being brought up, as being in
	    # the bridge 
	        echo "Bridged interfaces = " $ports
		for br_if in $ports; do
		    brctl addif $br_name $br_if
                    ifconfig $br_if up
		done
           fi
	   ifconfig $br_name up

           if (grep -q br_addr= /proc/cmdline); then
                net_addr=$(/opt/able/bin/get_cmdline_key.pl net_addr)
                ifconfig $br_name $net_addr up
              else
                dhclient -x
                sleep 3
                dhclient -v $br_name
           fi

           if (grep -q net_dns= /proc/cmdline); then
                net_dns=$(/opt/able/bin/get_cmdline_key.pl net_dns)
                echo "nameserver $net_dns" > /etc/resolv.conf
           fi
	   
           if (grep -q net_gw= /proc/cmdline); then
                net_gw=$(/opt/able/bin/get_cmdline_key.pl net_gw)
                route add default gw $net_gw
           fi

           if (grep -q br_stp= /proc/cmdline); then
                br_stp=$(/opt/able/bin/get_cmdline_key.pl br_stp)
		brctl stp $br_name $br_stp                
           fi

           if (grep -q br_fd= /proc/cmdline); then
                br_fd=$(/opt/able/bin/get_cmdline_key.pl br_fd)
                brctl setfd $br_name $br_fd
           fi
        fi

	# set system clock from chrony
	#ntpdate pool.ntp.org


	# grab rootpw= if it exists
	if (grep -q rootpw= /proc/cmdline); then
	   rootpw=$(/opt/able/bin/get_cmdline_key.pl rootpw)
	   echo "root:$rootpw" | chpasswd
	fi

	# grab sssdconfig= if it exists
	if (grep -q sssdconfig= /proc/cmdline); then
	   sssdconfig=$(/opt/able/bin/get_cmdline_key.pl ssdconfig)
	   mkdir -p /etc/sssd
	   cd /etc/sssd ; wget $sssdconfig -O sssd.config
	   chmod 700 /etc/sssd
	   chroot 600 /etc/sssd/sssd.config
	   systemctl enable sssd.service
	   systemctl start sssd.service
	fi

	# grab rootauthorizedkeys= if it exists
	if (grep -q rootauthorizedkeys= /proc/cmdline); then
	   rootauthorizedkeys=$(/opt/able/bin/get_cmdline_key.pl rootauthorizedkeys)
	   mkdir -p ~root/.ssh
	   cd ~root/.ssh ; wget $rootauthorizedkeys -O authorized_keys
	   chmod 600 ~root/.ssh/authorized_keys
	fi

	# this is how to do late loading of drivers, so they don't interfere with boot.
        # driverprobe=list,of,drivers,to,modprobe,post,boot
        if (grep -q driverprobe= /proc/cmdline); then
          drivers=$(/opt/able/bin/get_cmdline_key.pl driverprobe)
          list=$(echo $drivers | sed 's|\,| |g')
          for driver in $list; do
                modprobe -v $driver
          done
        fi

	# mdadmassemble=0 forces no default assembly of MDRAID devices
        mdadm --examine --scan > /tmp/mdadm.conf
        mdadm -S /dev/md*
        if (grep -q mdadmassemble=0 /proc/cmdline); then
           echo "Not assembling MDRAID devices"
          else        
           mdadm -As -c /tmp/mdadm.conf
        fi

	# grab runscript= if it exists
	if (grep -q runscript= /proc/cmdline); then
	   runscript=$(/opt/able/bin/get_cmdline_key.pl runscript)
	   cd /tmp ; wget $runscript -O runscript
	   chmod 700 runscript
	   ./runscript
	fi


	if (grep -q nfsserver= /proc/cmdline); then
	   mkdir -p /var/lib/nfs/
	   cd /tmp

	   # grab the nfsserver option from the command line
	   nfsserver=$(/opt/able/bin/get_cmdline_key.pl nfsserver)
	   echo "nfsserver=${nfsserver}"
	   mkdir -p /new_root
	   mount -t nfs -o soft,rsize=65536,wsize=65536,retry=1,tcp,nolock,intr ${nfsserver} /new_root
	   cd /new_root
	   mkdir old_root
	   pivot_root . old_root
	   ./bin/mount -n --move ./old_root/sys ./sys
	   ./bin/mount -n --move ./old_root/proc ./proc
	   ./bin/mount -n --move ./old_root/dev ./dev
	   ./bin/mount -n --move ./old_root/run ./run
	   ./bin/mount -n --move ./old_root/var ./var
	   ./bin/mount -n --move ./old_root/var/lib/nfs ./var/lib/nfs
	   ./bin/mount -n --move ./old_root/tmp ./tmp
	   ./bin/umount ./old_root/var/tmp
	   ./bin/umount ./old_root/var/lib/nfs
	   ./bin/umount ./old_root/data
	   exec chroot . /bin/bash -c 'umount -l /old_root ; /sbin/init 3 ' <dev/console >dev/console 2>&1
	fi

	# enablecloudinit=1 turns on cloud-init
	if (grep -q enablecloudinit=1 /proc/cmdline); then
	   systemctl enable cloud-init
	   systemctl start cloud-init
	fi

	# enablepuppet=1 turns on puppet
	if (grep -q enablepuppet=1 /proc/cmdline); then
	      systemctl enable puppet
	      systemctl start puppet
	fi

        # enablelldpd=1 turns on lldpd
        if (grep -q enablelldpd=1 /proc/cmdline); then
              systemctl enable lldpd
              systemctl start lldpd
        fi

	# disablezfs=1 forces zfs modules to not be loaded
	if (grep -q disablezfs=1 /proc/cmdline); then
	   echo "zfs module not loaded"
	  else
	   # 2GiB of RAM max for zfs arc
	   modprobe -v zfs zfs_arc_max=2147483648 
	
	   # zpoolimport=1 forces a zpool import
           if (grep -q zpoolimport= /proc/cmdline); then
	      pool=$(/opt/able/bin/get_cmdline_key.pl zpoolimport)
              zpool import -f $pool
           fi
	fi

	      ;;

	stop)
	      ;;

	restart)
		echo -n "Restarting post boot process configuration: "
		/etc/init.d/able stop
		/etc/init.d/able start
	      ;;

	*)
	      echo "Usage: able {start|stop|restart}"
	      RETVAL=1
esac

} 2>&1 | tee -a /var/log/able

exit ${RETVAL}
