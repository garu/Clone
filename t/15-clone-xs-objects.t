#!/usr/bin/perl

# Test cloning objects that rely on XS-backed opaque data
# See: https://github.com/garu/Clone/issues/16
#
# Math::BigInt with GMP backend stores data in opaque mpz_t pointers
# via PERL_MAGIC_ext. Cloning must invoke the vtable's svt_dup callback
# to properly duplicate the underlying C data.

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

    # Force Calc backend (pure Perl) to ensure no GMP interference
    Math::BigInt->import(lib => 'Calc');

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
    # Must check availability first, then use at compile-time equivalent
    eval { require Math::BigInt::GMP };
    plan skip_all => 'Math::BigInt::GMP not available' if $@;

    # Use a fresh package to get a clean GMP backend binding
    my $orig = eval q{
        package CloneTestGMP;
        use Math::BigInt lib => 'GMP';
        Math::BigInt->new('42');
    };

    plan skip_all => "Failed to create GMP-backed BigInt: $@" if $@;

    # Verify we are actually using GMP backend
    my $lib = Math::BigInt->config()->{lib} || '';

    SKIP: {
        skip 'GMP backend not active despite module being installed', 5
            unless $lib =~ /GMP/;

        ok(1, "using GMP backend: $lib");

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
    }
};

# --- Math::BigFloat with GMP backend (related case) ---

subtest 'clone Math::BigFloat::GMP objects (related)' => sub {
    eval { require Math::BigInt::GMP };
    plan skip_all => 'Math::BigFloat with GMP not available' if $@;

    my $orig = eval q{
        package CloneTestGMPFloat;
        use Math::BigFloat lib => 'GMP';
        Math::BigFloat->new('3.14159');
    };

    plan skip_all => "Failed to create GMP-backed BigFloat: $@" if $@;

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
