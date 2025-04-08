#!/usr/bin/perl

use strict;
my ($cmdline,$k,@cmd,$_k,$_v);
$k=shift;
chomp($cmdline = `cat /proc/cmdline`);
@cmd = split(/\s+/,$cmdline);
foreach my $c (@cmd) {
 if ($c =~ /$k=(.*?)/) {
   ($_k,$_v)=split(/\=/,$c);
   printf "%s\n",$_v;
 }
}
