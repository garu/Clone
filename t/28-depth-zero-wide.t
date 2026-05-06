#!/usr/bin/perl
# Test that depth=0 (share, don't clone) is honoured even when rdepth
# exceeds MAX_DEPTH due to wide structures (many sibling elements).
#
# Bug: rdepth increments on every sv_clone() call, including siblings
# in flat arrays.  An array with >MAX_DEPTH elements pushed rdepth past
# the limit, causing the iterative fallback to deep-copy elements that
# should have been shared (depth=0 means "just SvREFCNT_inc").

use strict;
use warnings;
use Test::More;
use Clone 'clone';

# We need enough elements to exceed MAX_DEPTH (4000 on Linux/macOS,
# 2000 on Windows).  Use 5000 to cover both platforms.
my $n = 5000;

# --- Test 1: depth=1 with arrayref elements ---------------------
# clone(\@arr, 1) should shallow-copy the outer array but share
# every element.  Mutating through the clone should affect the original.

my @arr = map { [$_] } 1..$n;
my $cloned = clone(\@arr, 1);

# Early element (well within MAX_DEPTH) — baseline
is($cloned->[0], $arr[0],
   'depth=1: early element is shared (same arrayref)');

# Late element (past MAX_DEPTH rdepth threshold)
is($cloned->[$n-1], $arr[$n-1],
   'depth=1: late element is shared despite high rdepth');

# Mutation through the clone should be visible in the original
$cloned->[$n-1][0] = 'mutated';
is($arr[$n-1][0], 'mutated',
   'depth=1: mutation through shared late element visible in original');

# --- Test 2: depth=1 with hashref values ------------------------

my %hash;
for my $i (1..$n) {
    $hash{"k$i"} = { val => $i };
}
my $hcloned = clone(\%hash, 1);

# A value from the cloned hash should be the same hashref
is($hcloned->{"k$n"}, $hash{"k$n"},
   'depth=1 hash: late value is shared');

$hcloned->{"k$n"}{val} = 'changed';
is($hash{"k$n"}{val}, 'changed',
   'depth=1 hash: mutation through shared late value visible in original');

# --- Test 3: depth=0 is a no-op (sanity check) -----------------

my @simple = (1..100);
my $d0 = clone(\@simple, 0);
is($d0, \@simple,
   'depth=0 returns the same reference');

# --- Test 4: no spurious warnings for non-clonable types -------
# A coderef element at a high index should not trigger the
# "depth limit exceeded" warning when depth=0.

{
    my @with_code;
    $with_code[0] = sub { 42 };
    # Pad the array to push rdepth past MAX_DEPTH
    $with_code[$n] = sub { 99 };
    my $warned = 0;
    local $SIG{__WARN__} = sub { $warned++ };
    my $wc = clone(\@with_code, 1);
    is($warned, 0, 'no spurious depth-limit warning for shared coderefs');
    is($wc->[$n], $with_code[$n],
       'coderef element shared, not deep-copied');
}

done_testing;
