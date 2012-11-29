# $Id: 07magic.t,v 1.8 2007/04/20 05:40:48 ray Exp $

use strict;
use warnings;
use Test::More;

use Clone 'clone';
use Hash::Util::FieldHash::Compat 'fieldhash';

fieldhash my %hash;

my $var = {};

exists $hash{ \$var };

my $cloned = clone($var);
cmp_ok($cloned, '!=', $var);

done_testing;
