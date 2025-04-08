#!/usr/bin/env -S perl

my @lines = split(/\n/,`blkid | grep loop`);
my $fh;

open(my $fh,">> /etc/fstab");
foreach my $l (@lines) {
	#printf "l=%s\n",$l;
 if ($l =~ /loop0p(\d+):.*?\sUUID=\"(.*?)\"/) {
	 # k=1 -> /boot/efi partition
	 # k=3 -> / partition
	my $uuid = $2;
	if ($1 == "1") {
		printf $fh "UUID=%s %s vfat umask=0077 0 1\n",$uuid,"/boot/efi";
	} elsif ($1 =="3") {
		printf $fh "UUID=%s %s xfs defaults 0 0\n",$uuid,"/";
	} 
 }
}
close($fh);

