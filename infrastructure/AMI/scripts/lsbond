#!/usr/bin/perl

# copyright 2012-2019 Joe Landman
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


use strict;

my ($f,$dev,@devices,$cmd,$rc,@bonds,$bond,$slave_net,@slaves,$bond_nic);
my ($path,$net,@ethtool,@ip,$ipv4,$ipv6,$line,$first,@proc);
my ($bm,$line,$kver,$kmajor,$kminor,$krel,@kv);

exit if (!(-e '/sys/class/net/bonding_masters'));
($kmajor,$kminor,$krel,@kv) = split(/\./,`uname -r`);
$kver=$kmajor+$kminor/100;
# grab kernel revision, because things change between releases ...

chomp(@devices    = `ls /sys/class/net/ `);
open($bm,"<".'/sys/class/net/bonding_masters');
chomp($line = <$bm>);
close($bm);

@bonds = split(/\s+/,$line);   

   foreach $bond (@bonds) {
     $net->{$bond}->{state} =
          &get_sys_nic_data($bond,'operstate');
     $net->{$bond}->{carrier} =
               &get_sys_nic_data($bond,'carrier');
     $net->{$bond}->{mac} =
               &get_sys_nic_data($bond,'address');
     @proc = split(/\n/,`cat /proc/net/bonding/$bond`);
     foreach $line (@proc) {
       if ($line =~ /Bonding Mode:\s+(.*)/) { $net->{$bond}->{mode} = $1;}
       if ($kver < 3.15) {
          if ($line =~ /Transmit Hash Policy:\s+(.*)/) { $net->{$bond}->{xmit_hash_policy} = $1;}
         }
       if ($line =~ /MII Polling Interval(.*?):\s+(.*)/) { $net->{$bond}->{polling_interval} = $2;}
       if ($line =~ /Up Delay(.*?):\s+(.*)/) { $net->{$bond}->{up_delay} = $2;}
       if ($line =~ /Down Delay(.*?):\s+(.*)/) { $net->{$bond}->{down_delay} = $2;}
     }
     if (($kver >= 3.15) ) {
           $net->{$bond}->{xmit_hash_policy} = &get_sys_nic_data($bond,'bonding/xmit_hash_policy');
	   $net->{$bond}->{active_slave}     = &get_sys_nic_data($bond,'bonding/active_slave');
     }

     chomp(@ip = split(/\n/,`ip addr show $bond`));

     foreach my $line (@ip) {
       $line =~ s/\s+$//;
       $line =~ s/^\s+//;
       if ($line =~ /inet\s+(.*?)\s+brd\s+(.*?)\s+/) {
         push @{$net->{$bond}->{ipv4}},{addr => $1, mask => $2};
       }
       if ($line =~ /inet6\s+(.*?)\s+scope/) {
         push @{$net->{$bond}->{ipv6}},{addr => $1};
       }
     }

     # bonding slave status has changed substantially in kver > 3.14
     if ($kver < 3.14) {
      chomp(@slaves    = `ls /sys/class/net/$bond`);
      foreach $slave_net (@slaves) {
       #printf "++slave: %s\n",$slave_net;
       next if ($slave_net !~ /slave_(.*?)/) ;
       $bond_nic = $slave_net;
       $bond_nic =~ s/slave_//;

       #printf "++bond nic: %s\n",$bond_nic;
       $net->{$bond}->{nics}->{$bond_nic}->{carrier} =
        &get_sys_nic_data($bond_nic,'carrier');
       $net->{$bond}->{nics}->{$bond_nic}->{speed} =
         &get_sys_nic_data($bond_nic,'speed');
       $net->{$bond}->{nics}->{$bond_nic}->{state} =
           &get_sys_nic_data($bond_nic,'operstate');
       chomp(@ethtool = split(/\n/,`ethtool -i $bond_nic`));
       foreach my $line (@ethtool) {
         $line =~ s/\s+//g;
         my ($k,$v) = split(/:/,$line);
         $net->{$bond}->{nics}->{$bond_nic}->{$k}=$v
       }
       chomp(@ethtool = split(/\n/,`ethtool -P $bond_nic`));
       foreach my $line (@ethtool) {
         $line =~ s/\s+//g;
         my ($k,$v) = split(/:/,$line,2);
         $net->{$bond}->{nics}->{$bond_nic}->{mac}=$v
       }
      }
     }
    if (($kver >= 3.15)) {
      $line = &get_sys_nic_data($bond,'bonding/slaves');
      @slaves = split(/\s+/,$line);
      #printf "D[%i]: slaves = %s\n",$$,join(",",@slaves);
      foreach $slave_net (@slaves) {
       $bond_nic = $slave_net;
       
       #printf "++bond nic: %s\n",$bond_nic;
       $net->{$bond}->{nics}->{$bond_nic}->{carrier} =
        &get_sys_nic_data($bond_nic,'carrier');
       $net->{$bond}->{nics}->{$bond_nic}->{speed} =
         &get_sys_nic_data($bond_nic,'speed');
       $net->{$bond}->{nics}->{$bond_nic}->{state} =
           &get_sys_nic_data($bond_nic,'operstate');
       chomp(@ethtool = split(/\n/,`ethtool -i $bond_nic`));
       foreach my $line (@ethtool) {
         $line =~ s/\s+//g;
         my ($k,$v) = split(/:/,$line);
         $net->{$bond}->{nics}->{$bond_nic}->{$k}=$v
       } 
       chomp(@ethtool = split(/\n/,`ethtool -P $bond_nic`));
       foreach my $line (@ethtool) {
         $line =~ s/\s+//g;
         my ($k,$v) = split(/:/,$line,2);
         $net->{$bond}->{nics}->{$bond_nic}->{mac}=$v
       } 
      }

    }
   }
foreach $bond (sort keys %{$net}) {
  printf "%s:\tmac %s\n\tstate %4s\n\tmode %s\n\txmit_hash %s\n\tactive slave %s\n\tpolling %s ms\n\tup_delay %s ms\n\tdown_delay %s ms\n",
    $bond,
    &format_mac($net->{$bond}->{mac},"default"),
    ($net->{$bond}->{state} =~ /up/ ? "up" : "down"),
    $net->{$bond}->{mode},
    $net->{$bond}->{xmit_hash_policy},
    (defined($net->{$bond}->{active_slave}) ? $net->{$bond}->{active_slave} : ""),
    $net->{$bond}->{polling_interval},
    $net->{$bond}->{up_delay},
    $net->{$bond}->{down_delay}
    ;
    $first = 1;
    foreach $ipv4 (@{$net->{$bond}->{ipv4}}) {
      if (!$first) {
        printf ","
      }
      else
      {
        print "  ipv4 ";
        $first = 0;
      }
      printf "%s ",$ipv4->{addr};
    }
    printf "\n";
    $first = 1;
    foreach $ipv6 (@{$net->{$bond}->{ipv6}}) {
      if (!$first) {
        printf ",";
      }
      else
      {
        printf "  ipv6 ";
        $first = 0;
      }
      printf "%s ",$ipv6->{addr};
    }
  printf "\n  slave nics:\n";
  foreach $slave_net (sort keys %{$net->{$bond}->{nics}}) {
    printf "\t%s: mac %s, link %s, state %4s, speed %7s,\n\t\tdriver %s, version %s\n\t\tfirmware version %s\n",
      $slave_net,
      $net->{$bond}->{nics}->{$slave_net}->{mac},
      $net->{$bond}->{nics}->{$slave_net}->{carrier},
      $net->{$bond}->{nics}->{$slave_net}->{state},
      $net->{$bond}->{nics}->{$slave_net}->{speed},
      $net->{$bond}->{nics}->{$slave_net}->{driver},
      $net->{$bond}->{nics}->{$slave_net}->{version},
      $net->{$bond}->{nics}->{$slave_net}->{'firmware-version'};
  }
  printf "\n\n";
}

sub get_sys_nic_data {
  my ($b,$f) = @_;
  my ($fh,$data,$buf,$len);
  my $path = sprintf '/sys/class/net/%s/%s',$b,$f;
  sysopen $fh,$path,'O_RDONLY' or return undef;
  $len = sysread $fh,$buf,4096 or return undef;
  close($fh);
  return "" if ($len == 0);
  $buf =~ s/\s+$//;
  return $buf;
}

sub format_mac {
  my ($mac,$fmt) = @_;

  if ($fmt eq "default") {
    return $mac;
    }
    elsif ($fmt eq "cisco") {
      my @octants = split(":",$mac);
      $mac="";
      for(my $i=0;$i<6;$i++) {
        $mac .= $octants[$i];
        $mac .= "." if (($i % 2) && ($i != 5));
      }
      return $mac;
    }
}
