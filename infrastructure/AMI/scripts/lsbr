#!/usr/bin/perl
# copyright 2012-2016 Scalable Informatics Inc
# copyright 2017-2019 Joe Landman
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

my ($line,$kver,$kmajor,$kminor,$krel,@kv);
my ($bridge,@bridges,$net);
my ($brname,$brid,$brstp,$brif,@br,@if);

($kmajor,$kminor,$krel,@kv) = split(/\./,`uname -r`);
$kver=$kmajor+$kminor/100;
# grab kernel revision, because things change between releases ...

chomp(@bridges    = split(/\n/,`brctl show`));
map {shift @bridges} (1 .. 1);


foreach $bridge (@bridges) {
     $bridge =~ s/^\s+//g;
     $bridge =~ s/\s+$//g;
     $bridge =~ s/\s+/ /g;
     @br=split(/\s+/,$bridge);

     if ($#br == 3) {
         $brname = $br[0];
         $net->{$brname}->{id}      = $br[1];
         $net->{$brname}->{stp}     = $br[2];
         push @{$net->{$brname}->{interfaces}},$br[3];
       }
      else
       {
         $brname = $br[0];
         $net->{$brname}->{id}      = $br[1];
         $net->{$brname}->{stp}     = $br[2];
         push @{$net->{$brname}->{interfaces}},"";
       }
}

foreach $bridge (sort keys %{$net}) {
  @if = @{$net->{$bridge}->{interfaces}};
  printf "%s:\tinterfaces %s\n",
    $bridge,
    join(",",@if);
}
printf "\n\n";
