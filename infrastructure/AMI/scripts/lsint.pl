#!/usr/bin/env perl

use strict;
use Data::Dumper;
use JSON::PP;

my ($f,$dev,@devices,$cmd,$rc,@bonds,$bond,$slave_net,@slaves,$bond_nic);
my ($path,$net,@ethtool,@ip,$ipv4,$ipv6,$line,$first,@proc);
my ($bm,@dev,$kver,$kmajor,$kminor,$krel,@kv);
my (@interrupts,%ints,@cpu,$cpuline,$NCPU,@int,$irq,%nodes,@numa);
my ($usenuma,$usespark,$sum,$maskwidth,$dwidth);

# check for sparkline binary
$usespark = (-e '/usr/local/bin/spark' ? 1 : 0);

# try to grab numa info for cpus
eval {@numa = split(/\n/,`numactl -H | grep cpus`)};
$usenuma  = ($#numa > -1);

# width guesses
$maskwidth  = 8;
$dwidth     = 8;

exit if (!(-e '/proc/interrupts'));

($kmajor,$kminor,$krel,@kv) = split(/\./,`uname -r`);
$kver=$kmajor+$kminor/100;
# grab kernel revision, because things change between releases ...

chomp(@interrupts    = `cat /proc/interrupts`);
# first line has CPU mapping
$cpuline       = shift @interrupts;
@cpu           = ( $cpuline =~ /CPU(\d+)/g );
$NCPU          = $#cpu+1;

# subsequent line structures are "int_number: counts x NCPU irq_type driver(s)"
foreach $line (@interrupts) {
   $line    =~ s/^\s+]//g; # trim line begin space
   @int     = ($line =~ /(\S+)/g);
   $irq     = shift @int;
   $irq     =~ s/\://g;
   next if ($irq !~ /\d+/);  # skip non-numeric bits
   $sum     = 0;
   map { push @{$ints{$irq}->{cpu}},$int[$_] ; $sum += $int[$_]} (0 .. $NCPU-1);
   
   # skip entries without any interrupts
   if ($sum == 0) {
      delete $ints{$irq};
      next;
   }
   
   $ints{$irq}->{'node'}     = &get_irq_data($irq,'node');  
   $ints{$irq}->{'mask'}     = &get_irq_data($irq,'smp_affinity');
   $ints{$irq}->{'mask'}      =~ s/\s+$//g;
   $maskwidth = ( $maskwidth < length($ints{$irq}->{'mask'})
                  ? length($ints{$irq}->{'mask'})
                  : $maskwidth );
   $ints{$irq}->{'driver'}   = (pop @int);
   $dwidth     = ( $dwidth < length($ints{$irq}->{'driver'})
                  ? length($ints{$irq}->{'driver'})
                  : $dwidth );
}

    
printf "%5s %4s %".$maskwidth."s %".$dwidth."s %s\n",
   "IRQ","Node","Mask","Driver","Counts on CPU".($NCPU-1)." to CPU0";
 
@int =  sort {$a <=> $b} keys %ints;
foreach $irq (@int) {
   if (!$usespark) {
      printf "%5i %4i %".$maskwidth."s %".$dwidth."s %10i\n",
         $irq,
         $ints{$irq}->{'node'},
         $ints{$irq}->{'mask'},
         $ints{$irq}->{'driver'},
         (join(",",reverse @{$ints{$irq}->{cpu}}));
   }
     if ($usespark) {
      my $_c = join(" ",reverse @{$ints{$irq}->{cpu}});
      my $_sl = `/opt/nyble/bin/spark $_c`;
      printf "%5i %4i %".$maskwidth."s %".$dwidth."s %s",
         $irq,
         $ints{$irq}->{'node'},
         $ints{$irq}->{'mask'},
         $ints{$irq}->{'driver'},
         $_sl;
   } 
}


sub get_irq_data {
  my ($b,$f) = @_;
  my ($fh,$data,$buf,$len);
  my $path = sprintf '/proc/irq/%s/%s',$b,$f;
  sysopen $fh,$path,'O_RDONLY' or return undef;
  $len = sysread $fh,$buf,4096 or return undef;
  close($fh);
  return "" if ($len == 0);
  $buf =~ s/\s+$//;
  return $buf;
}
