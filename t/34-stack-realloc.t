#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 2;
use Clone qw(clone);

# Cloning can run perl code -- here a tied FETCH -- and that code can
# grow the argument stack, which reallocates PL_stack_base's buffer.  The
# SP the XSUB cached on entry then points into freed memory, so clone()
# recomputes it from `ax` (an index, which survives the realloc) before
# pushing its result.  Without that, the return value is written into the
# old buffer and the caller reads garbage.
#
# Asserting on the returned value rather than on a crash: a stale write
# does not reliably segfault, but it does reliably fail to deliver the
# clone.

sub eat_args { return scalar @_ }

package GrowStack;
sub TIESCALAR { bless {}, shift }
sub FETCH     { main::eat_args((1) x 200_000); return 'fetched' }
sub STORE     { }

package main;

tie my $grow, 'GrowStack';

my $src   = { before => 'a', grow => \$grow, after => 'b' };
my $copy  = clone($src);

is(ref $copy, 'HASH', 'clone() returned its result after a stack realloc');
is_deeply([ sort keys %$copy ], [ qw(after before grow) ],
          'returned clone is intact, not a stale-SP write');
