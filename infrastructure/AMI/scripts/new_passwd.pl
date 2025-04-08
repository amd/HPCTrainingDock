#!/usr/bin/env perl

#  note:  you will need Crypt::PRNG in your perl.  If you don't have it
#         you can install it using
#
#		cpan Crypt::PRNG
#
#	  Note that compiling this may take a long time.  If you have it in 
#	  your package system, you can install it from there.
#
#		apt-get install $package_name.deb
#
#
use strict;
my $length = 12;
use Crypt::PRNG qw(random_string_from);

# make rand random;
#srand (time ^ $$ ^ unpack "%L*", `ps axww | gzip -f`);
my $prng = Crypt::PRNG->new;

my $pass;
my $ch  = join("",('0'..'9', 'A'..'Z', 'a'..'z'));
# ,'_', ' ', '!', '@', '#', '$', '%', '^' , '&' , '-', '=', '+');
$pass 	= random_string_from($ch, $length);

printf "%s\n",$pass;
