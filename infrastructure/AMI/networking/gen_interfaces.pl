#!/usr/bin/env perl

use strict;

my $type = lc(shift) || "vm";
my $fh;

open($fh,"> interfaces_generated");
printf $fh <<EOF;

source-directory /etc/network/interfaces.d

auto lo
iface lo inet loopback

EOF


if ($type eq "vm") {

	printf $fh <<EOF;

auto ens3
iface ens3 inet dhcp

auto dummy0
iface dummy0 inet manual
	pre-up modprobe -v dummy numdummies=1
	post-down rmmod dummy

auto br0
iface br0 inet static
	bridge_ports dummy0
	bridge_stp off       # disable Spanning Tree Protocol
        bridge_waitport 0    # no delay before a port becomes available
        bridge_fd 0 
	address 127.0.0.2/8

EOF

}

if (($type eq "bare-metal") || ($type eq "physical")) {


   # type
	my (@nics,$nic);
	my $first = 0;

	chomp( @nics = split(/\n/,`ls /sys/class/net`) );

	foreach $nic (sort @nics) {

	# first, skip lo, and other nics
	next if ($nic =~ /lo/);
	
	# second, any nic with a carrier signal (e.g. primary interface during install)
	# will be entered in with dhcp
	if ((&get_carrier($nic) == 1) && ($first == 0)) {
		printf $fh <<EOM2;
auto $nic
iface $nic inet dhcp

EOM2
		$first = 1;
	   }
	 else
	   {
printf $fh <<EOM3;
auto $nic
iface $nic inet static

EOM3
	   }
	}
}

sub get_carrier {
	my $nic = shift;
	return 0 if (!defined($nic));
	my $cfile = sprintf "/sys/class/net/%s/carrier",$nic;

	open(my $nfh,"<".$cfile);
	my $carrier=<$nfh>;
	chomp($carrier);
	close($nfh);
	return $carrier;
}
