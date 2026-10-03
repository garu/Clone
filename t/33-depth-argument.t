#!/usr/bin/perl

# Validation of the optional second argument of clone($ref, $depth).
#
# $depth is a *cap* on how many container levels get copied, not a
# recursion-limit override.  depth=0 means "share, don't clone" and hands
# back the original SV, so any value that silently collapses to 0 turns a
# clone() call into an alias — writes through the "copy" land in the
# original.  Two ways that used to happen:
#
#   clone($x, 2**32)   32-bit truncation of the C `int` parameter -> 0
#   clone($x, undef)   numeric coercion of undef                  -> 0
#
# Both now mean "unlimited", matching the no-argument form.  A value that
# is not a number at all -- or is a NaN -- is a programming error and croaks.
#
# Depth semantics themselves live in t/31-depth-parameter.t.

use strict;
use warnings;
use Test::More tests => 24;
use Scalar::Util qw(refaddr);
use Clone qw(clone);

sub nested { { child => { leaf => 'x' } } }

# ---------------------------------------------------------------------------
# Values past INT_MAX are clamped, not truncated
# ---------------------------------------------------------------------------

for my $big (2**32, 2**32 + 1, 2**40, 2**62) {
    my $x = nested();
    my $c = clone($x, $big);
    isnt(refaddr($c), refaddr($x), "depth=$big: returns a copy, not the original");
    isnt(refaddr($c->{child}), refaddr($x->{child}),
         "depth=$big: deep copy (clamped, not truncated to a small cap)");
}

# ---------------------------------------------------------------------------
# undef means "no cap", exactly like omitting the argument
# ---------------------------------------------------------------------------

{
    my $x = nested();
    my $c = clone($x, undef);
    isnt(refaddr($c), refaddr($x), "depth=undef: returns a copy");
    isnt(refaddr($c->{child}), refaddr($x->{child}), "depth=undef: unlimited depth");
}

# ---------------------------------------------------------------------------
# Negative caps stay unlimited
# ---------------------------------------------------------------------------

{
    my $x = nested();
    my $c = clone($x, -2**40);
    isnt(refaddr($c->{child}), refaddr($x->{child}),
         "large negative depth: unlimited (no wrap into a small cap)");
}

# ---------------------------------------------------------------------------
# Non-numbers are a programming error
# ---------------------------------------------------------------------------

for my $bad ('deep', '', [], bless({}, 'Foo')) {
    my $label = ref($bad) || (length($bad) ? $bad : 'empty string');
    my $ok = eval { clone(nested(), $bad); 1 };
    ok(!$ok, "depth='$label': croaks instead of silently sharing");
    like($@, qr/depth must be a number/, "depth='$label': croak message names the cause");
}

# ---------------------------------------------------------------------------
# Non-finite values: SvIV() of an infinity or a NaN is 0 on some platforms,
# which must not turn into "share, don't clone".
#
# Numeric literals only -- whether the *strings* "inf"/"nan" count as
# numbers varies across perl versions.
# ---------------------------------------------------------------------------

for my $inf (9**9**9, -9**9**9) {
    my $x = nested();
    my $c = clone($x, $inf);
    isnt(refaddr($c->{child}), refaddr($x->{child}),
         "depth=$inf: deep copy (not collapsed to a cap of 0)");
}

SKIP: {
    my $nan = 9**9**9 - 9**9**9;
    skip "no NaN on this platform", 2 if $nan == $nan;
    my $ok = eval { clone(nested(), $nan); 1 };
    ok(!$ok, "depth=NaN: croaks instead of silently sharing");
    like($@, qr/depth must be a number/, "depth=NaN: croak message names the cause");
}

# ---------------------------------------------------------------------------
# The exact-0 no-op is unchanged (documented, relied upon)
# ---------------------------------------------------------------------------

{
    my $x = nested();
    is(refaddr(clone($x, 0)), refaddr($x), "depth=0 still returns the original");
}
