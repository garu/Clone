#!/usr/bin/perl

# Test cloning objects that rely on XS-backed opaque data
# See: https://github.com/garu/Clone/issues/16
#
# Math::BigInt with GMP backend stores data in opaque C structs (mpz pointers).
# Cloning these objects copies the Perl structure but the GMP pointer becomes
# a dangling reference, causing "failed to fetch mpz pointer" errors.
#
# This test reproduces the issue so CI can show which platforms/perls are affected.

use strict;
use warnings;
use Test::More;
use Clone qw(clone);
use Scalar::Util qw(refaddr);

# --- Control tests: Clone handles Regexp and basic blessed refs fine ---

subtest 'clone Regexp objects (control - known to work)' => sub {
    my $pattern = 'foo\d+bar';
    my $re = qr/$pattern/i;
    my $cloned = clone($re);

    is(ref($cloned), 'Regexp', 'cloned regexp has correct type');
    ok('FOO42BAR' =~ $cloned, 'cloned regexp matches correctly');
    ok('baz' !~ $cloned, 'cloned regexp rejects non-matches');
};

# --- Math::BigInt with pure Perl backend (control - should work) ---

subtest 'clone Math::BigInt with Calc backend (control)' => sub {
    eval { require Math::BigInt };
    plan skip_all => 'Math::BigInt not available' if $@;

    my $orig = Math::BigInt->new('12345678901234567890');
    my $cloned = clone($orig);

    isnt(refaddr($cloned), refaddr($orig), 'cloned BigInt is a different reference');
    is(ref($cloned), ref($orig), 'cloned BigInt has same class');
    is($cloned->bstr(), '12345678901234567890', 'cloned BigInt has correct value');

    # Mutating clone should not affect original
    $cloned->badd(1);
    is($orig->bstr(), '12345678901234567890', 'original unchanged after mutating clone');
    is($cloned->bstr(), '12345678901234567891', 'clone reflects mutation');
};

# --- Math::BigInt with GMP backend (the actual bug from issue #16) ---

subtest 'clone Math::BigInt::GMP objects (issue #16)' => sub {
    eval { require Math::BigInt::GMP };
    plan skip_all => 'Math::BigInt::GMP not available' if $@;

    require Math::BigInt;
    Math::BigInt->import(lib => 'GMP');

    # Verify we are actually using GMP backend
    my $lib = Math::BigInt->config()->{lib};
    like($lib, qr/GMP/, "using GMP backend: $lib");

    my $orig = Math::BigInt->new('42');

    # This is the core reproduction of issue #16:
    # clone() copies the Perl structure but the GMP mpz pointer becomes invalid
    my $cloned = eval { clone($orig) };
    ok(!$@, 'clone() does not die') or diag("clone() died: $@");

    SKIP: {
        skip 'clone() failed', 3 unless defined $cloned;

        is(ref($cloned), ref($orig), 'cloned object has same class');

        # This is where the bug manifests:
        # "failed to fetch mpz pointer"
        my $value = eval { $cloned->bstr() };
        ok(!$@, 'bstr() on cloned object does not die')
            or diag("bstr() died: $@");

        SKIP: {
            skip 'bstr() failed', 1 if $@;
            is($value, '42', 'cloned value is correct');
        }
    }
};

# --- Math::BigFloat with GMP backend (related case) ---

subtest 'clone Math::BigFloat::GMP objects (related)' => sub {
    eval { require Math::BigInt::GMP };
    plan skip_all => 'Math::BigFloat with GMP not available' if $@;

    require Math::BigFloat;
    Math::BigFloat->import(lib => 'GMP');

    my $orig = Math::BigFloat->new('3.14159');
    my $cloned = eval { clone($orig) };
    ok(!$@, 'clone() does not die') or diag("clone() died: $@");

    SKIP: {
        skip 'clone() failed', 2 unless defined $cloned;

        is(ref($cloned), ref($orig), 'cloned float has same class');

        my $value = eval { $cloned->bstr() };
        ok(!$@, 'bstr() on cloned float does not die')
            or diag("bstr() died: $@");
    }
};

done_testing();
