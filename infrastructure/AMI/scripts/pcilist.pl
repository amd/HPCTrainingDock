#!/usr/bin/env perl

use strict;
use Data::Dumper;

use constant true => 1==1;
use constant false=> 1==0;

my (@lspci,$kmajor,$kminor,$krel,@kv);
my ($kver,$newsection,@fields,$pci,$id);

($kmajor,$kminor,$krel,@kv)= split(/\./,`uname -r`);
@lspci = split(/\n/,`lspci -vvvkb`);


$kver=$kmajor+$kminor/100;
# grab kernel revision, because things change between releases ...

### Ok ... the -m and -mm option on lspci are almost useless
#   so parse the output by hand, throwing away what you don't need
#   ... and yes ... the output is structured by indentation ...
#   ... /sigh

$newsection = true;
$id = -1;
foreach my $line (@lspci) {
  if ($newsection) {
    if ($line =~ /^(..:..\..)\s(.*?):\s(.*?)$/) {
      $id = $1;
      $pci->{$id}->{'function'} = $2;
      $pci->{$id}->{'description'} = $3;
      $newsection = false;
      next;
    }
  }
  if (!$newsection) {
    if ($line =~ /Interrupt\:\spin\s(.*?)\srouted\sto\sIRQ\s(.*?)$/) {
      $pci->{$id}->{'irq'} = $2;
      $pci->{$id}->{'irq_pin'} = $1;
      #printf "IRQ: %i\n",$2;
    }
    if ($line =~ /Kernel driver in use: (.*?)$/) {
      $pci->{$id}->{'driver'} = $1;
    }
    if ($line =~ /LnkCap:.*Speed (.*?)GT\/s, Width x(\d+)/) {
      $pci->{$id}->{'Max_speed'} = $1;
      $pci->{$id}->{'Max_width'} = $2;
    }
    if ($line =~ /LnkSta:.*Speed (.*?)GT\/s, Width x(\d+)/) {
      $pci->{$id}->{'actual_speed'} = $1;
      $pci->{$id}->{'actual_width'} = $2;
    }
    if ($line eq "") {
      $newsection = true;
    }
  }
}

#printf "Dump: %s\n",Dumper($pci);
printf "PCIid   MaxWidth ActWidth MaxSpeed ActSpeed     driver       description\n";
foreach my $id (sort keys %{$pci}) {
  next if (!defined($pci->{$id}->{Max_width}));
  printf "%7s %8i %8i %8s %8s %16s %31s\n",
    $id,
    $pci->{$id}->{Max_width},
    $pci->{$id}->{actual_width},
    $pci->{$id}->{Max_speed},
    $pci->{$id}->{actual_speed},
    $pci->{$id}->{driver},
    $pci->{$id}->{description};
}
