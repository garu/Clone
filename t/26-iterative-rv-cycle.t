#!/usr/bin/perl

# Test that circular scalar-ref chains embedded past MAX_DEPTH are cloned
# correctly (no infinite loop, proper cycle topology in clone).
#
# Bug: rv_clone_iterative walked the RV chain without checking hseen or
# detecting cycles.  A circular pair ($a = \$b; $b = \$a) embedded past
# MAX_DEPTH caused an infinite loop and eventual memory exhaustion.

use strict;
use warnings;
use Test::More;
use Clone qw(clone);
use Scalar::Util qw(refaddr);

# Platform-adaptive depth (mirrors t/10-deep_recursion.t).
# Must exceed MAX_DEPTH/2 to exercise the iterative path.
my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $deep_target = $is_limited_stack ? 2500 : 5000;

plan tests => 10;

# Test 1-4: circular RV pair at the bottom of a deep array chain
{
    # Build array chain deep enough to exceed MAX_DEPTH
    my $bottom = [];
    my $curr = $bottom;
    for (1 .. $deep_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }

    # Create circular scalar-ref pair at the bottom
    my ($a, $b);
    $a = \$b;
    $b = \$a;
    $curr->[0] = $a;

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        local $SIG{ALRM} = sub { die "timeout — probable infinite loop\n" };
        alarm(10);
        my $c = clone($bottom);
        alarm(0);
        $c;
    };

    ok(!$@, "clone of deep structure with circular RV pair does not die/hang")
        or diag("Error: $@");

    SKIP: {
        skip 'clone failed', 3 unless defined $cloned;

        # Walk to the bottom of the clone
        my $walk = $cloned;
        $walk = $walk->[0] while ref($walk) eq 'ARRAY' && ref($walk->[0]) eq 'ARRAY';

        # The bottom element should be an RV (scalar ref)
        my $clone_a = $walk->[0];
        ok(ref($clone_a) eq 'REF' || ref($clone_a) eq 'SCALAR',
           'bottom element is a reference');

        # The clone should be independent from the original
        isnt(refaddr($clone_a), refaddr($a),
             'cloned circular ref is a different SV from original');

        # The circular topology should be preserved:
        # clone_a -> clone_b -> clone_a
        my $clone_b = $$clone_a;
        if (ref($clone_b)) {
            is(refaddr($$clone_b), refaddr($clone_a),
               'circular RV topology preserved in clone');
        } else {
            fail('circular RV topology preserved in clone');
        }
    }
}

# Test 5-7: longer circular RV chain (A -> B -> C -> A) at depth
{
    my $bottom = [];
    my $curr = $bottom;
    for (1 .. $deep_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }

    # Create a 3-node RV cycle: A -> B -> C -> A
    my ($a, $b, $c);
    $a = \$b;
    $b = \$c;
    $c = \$a;
    $curr->[0] = $a;

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        local $SIG{ALRM} = sub { die "timeout — probable infinite loop\n" };
        alarm(10);
        my $r = clone($bottom);
        alarm(0);
        $r;
    };

    ok(!$@, "clone of deep structure with 3-node RV cycle does not die/hang")
        or diag("Error: $@");

    SKIP: {
        skip 'clone failed', 2 unless defined $cloned;

        my $walk = $cloned;
        $walk = $walk->[0] while ref($walk) eq 'ARRAY' && ref($walk->[0]) eq 'ARRAY';

        my $ca = $walk->[0];
        isnt(refaddr($ca), refaddr($a),
             '3-node cycle: clone is independent');

        # Verify 3-step cycle: ca -> cb -> cc -> ca
        my $ok = eval {
            my $cb = $$ca;
            my $cc = $$cb;
            refaddr($$cc) == refaddr($ca);
        };
        ok($ok, '3-node RV cycle topology preserved in clone');
    }
}

# Test 8-10: shared (non-circular) RV at depth — CLONE_STORE ensures
# the same clone is returned for both paths to the shared RV
{
    my $bottom = [];
    my $curr = $bottom;
    for (1 .. $deep_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }

    # Two slots in the bottom array point to the same scalar ref
    my $shared_val = 42;
    my $shared_ref = \$shared_val;
    $curr->[0] = $shared_ref;
    $curr->[1] = $shared_ref;

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        clone($bottom);
    };

    ok(!$@, "clone of deep structure with shared RV does not die")
        or diag("Error: $@");

    SKIP: {
        skip 'clone failed', 2 unless defined $cloned;

        my $walk = $cloned;
        $walk = $walk->[0] while ref($walk) eq 'ARRAY' && ref($walk->[0]) eq 'ARRAY';

        isnt(refaddr($walk->[0]), refaddr($shared_ref),
             'shared RV is cloned (not aliased)');

        is(refaddr($walk->[0]), refaddr($walk->[1]),
           'both paths to shared RV resolve to same clone');
    }
}
