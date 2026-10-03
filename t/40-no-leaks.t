#!/usr/bin/perl
# Refcount-leak regression net.
#
# Clone's bugs have overwhelmingly been refcount bugs: an SvREFCNT_inc
# with no matching dec (or the reverse) on one of the many type/magic
# paths through sv_clone().  Those are invisible to the behavioural
# tests -- the clone is correct, it just never goes away.
#
# Test::LeakTrace::no_leaks_ok() runs the block several times and fails
# if the number of live SVs grows, which catches exactly that class of
# bug.  Each case below is one path through sv_clone().

use strict;
use warnings;
use Test::More;

BEGIN {
    eval { require Test::LeakTrace; Test::LeakTrace->import('no_leaks_ok'); 1 }
        or plan skip_all => 'Test::LeakTrace required for leak detection';
}

use Clone 'clone';
use Scalar::Util qw(weaken);

# Warm every lazily-initialised cache (symbol lookups, the XS stash,
# the COW string table) before measuring: a first-call allocation is
# not a leak, but no_leaks_ok() would still see the SV count move.
clone({ a => [1, 2, { b => \'x' }] });

no_leaks_ok { my $c = clone({ a => 1, b => 'two' }) } 'flat hash';

no_leaks_ok { my $c = clone([1, 'two', 3.5, undef]) } 'flat array';

no_leaks_ok { my $c = clone(\'scalar') } 'scalar ref';

no_leaks_ok {
    my $c = clone({ list => [1, [2, [3]]], hash => { k => { k2 => 'v' } } });
} 'nested containers';

# A cycle is self-sustaining: both the source and the clone must have
# theirs broken inside the block, or the leak reported is the test data's
# own, not Clone's.
no_leaks_ok {
    my $h = { name => 'x' };
    $h->{self} = $h;
    my $c = clone($h);
    delete $h->{self};
    delete $c->{self};
} 'self-referential hash';

no_leaks_ok {
    my $a = [1];
    push @$a, \$a;
    my $c = clone($a);
    @$a = ();
    @$c = ();
} 'self-referential array';

no_leaks_ok {
    my $obj = bless { id => 7, kids => [bless({}, 'Clone::Leak::Kid')] },
        'Clone::Leak::Parent';
    my $c = clone($obj);
} 'blessed objects';

no_leaks_ok {
    my $target = { v => 1 };
    my $h = { strong => $target, weak => $target };
    weaken $h->{weak};
    my $c = clone($h);
} 'weak reference';

no_leaks_ok {
    my %h;
    tie %h, 'Clone::Leak::Tie';
    $h{k} = 'v';
    my $c = clone(\%h);
} 'tied hash';

no_leaks_ok {
    my $code = sub { 42 };
    my $c = clone({ cb => $code, data => [1, 2] });
} 'non-cloneable coderef is shared';

no_leaks_ok {
    my $qr = qr/\d+(abc)?/;
    my $c = clone({ re => $qr });
} 'compiled regexp';

no_leaks_ok {
    my $obj = bless { n => 3 }, 'Clone::Leak::Overload';
    my $c = clone([$obj]);
} 'overloaded object';

# An explicit depth of 1 shares every referent below the top level --
# a different exit from sv_clone() than a full deep copy.
no_leaks_ok {
    my $c = clone({ deep => { deeper => [1] } }, 1);
} 'depth-limited clone shares referents';

# Deep enough to leave the recursive path for the heap work queue
# (clone_container_iterative / clone_shell / clone_drain).  MAX_DEPTH is
# 2000 on Windows/Cygwin, 4000 elsewhere; rdepth advances twice per
# nesting level, so this clears the threshold on either platform.
no_leaks_ok {
    my $deep = ['leaf'];
    $deep = [$deep] for 1 .. 2600;
    my $c = clone($deep);
} 'deep nesting via the iterative path';

done_testing;

package Clone::Leak::Tie;

sub TIEHASH { bless {}, shift }
sub FETCH    { $_[0]->{ $_[1] } }
sub STORE    { $_[0]->{ $_[1] } = $_[2] }
sub EXISTS   { exists $_[0]->{ $_[1] } }
sub DELETE   { delete $_[0]->{ $_[1] } }
sub FIRSTKEY { my @k = keys %{ $_[0] }; $k[0] }
sub NEXTKEY  { undef }

package Clone::Leak::Overload;

use overload '""' => sub { 'overloaded(' . $_[0]->{n} . ')' }, fallback => 1;
