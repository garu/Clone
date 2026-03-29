#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 18;
use Scalar::Util qw(refaddr);
use Clone qw(clone);
use Config;

# Platform-adaptive depth targets.
# Windows has a 1 MB default thread stack; Cygwin typically 2 MB;
# Linux/macOS default to 8 MB but some smokers have less.
# The depths must be safe for both Clone XS recursion AND Perl's
# own recursive SvREFCNT_dec when freeing deeply nested structures.
#
# Clone.xs uses MAX_DEPTH (in rdepth units) to switch from recursive
# to iterative cloning: 2000 on Windows/Cygwin, 4000 elsewhere.
# rdepth increments twice per nesting level (once for AV, once for RV),
# so the switch happens at roughly MAX_DEPTH/2 nesting levels.
# The deep target must exceed MAX_DEPTH/2 to exercise both paths.
my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');

my $deep_target     = $is_limited_stack ? 2500 : 5000;

# Moderate depth used for basic tests (safe everywhere).
my $moderate_target  = 1000;

# Test 1-2: Basic deep recursion
{
    my $deep = [];
    my $curr = $deep;
    for (1..$moderate_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }

    my $cloned = eval { clone($deep) };
    ok(!$@, "Cloning deeply nested structure ($moderate_target levels) should not die")
        or diag("Error: $@");
    is(ref($cloned), 'ARRAY', "Cloned structure should be an array reference");
}

# Test 3-5: Very deep recursion (platform-adaptive depth)
{
    my $very_deep = [];
    my $curr = $very_deep;
    for (1..$deep_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        clone($very_deep);
    };

    ok(!$@ && defined($cloned),
       "Should be able to clone $deep_target-deep structure without stack overflow")
        or diag("Error during clone: " . ($@ || "undefined result"));

    SKIP: {
        skip "Clone failed, can't verify structure", 2 if !defined $cloned;

        # Measure cloned depth
        my $measured = 0;
        my $walk = $cloned;
        while (ref($walk) eq 'ARRAY' && @$walk == 1) {
            $walk = $walk->[0];
            $measured++;
        }

        is($measured, $deep_target,
           "Cloned structure should maintain full depth ($deep_target levels)");

        # Verify clone independence: mutating the clone must not affect original
        $cloned->[0] = "mutated";
        is(ref($very_deep->[0]), 'ARRAY',
           "Mutating clone should not affect original (clone independence)");
    }
}

# Test 6-7: Deep recursion with multi-element arrays at leaves
{
    my $deep = [];
    my $curr = $deep;
    for (1..$moderate_target) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }
    # Put multi-element array at the leaf
    $curr->[0] = "leaf_a";
    $curr->[1] = "leaf_b";

    my $cloned = eval { clone($deep) };
    ok(!$@, "Cloning deep structure with multi-element leaf should not die")
        or diag("Error: $@");

    SKIP: {
        skip "Clone failed", 1 if !defined $cloned;

        # Walk to the leaf
        my $walk = $cloned;
        while (ref($walk) eq 'ARRAY' && @$walk == 1) {
            $walk = $walk->[0];
        }
        is_deeply($walk, ["leaf_a", "leaf_b"],
                  "Leaf multi-element array should be cloned correctly");
    }
}

# Test 8-10: Deep recursion with hashes (GH #93)
# At depth > MAX_DEPTH/2, the guard previously returned SvREFCNT_inc(ref)
# for hash types, silently aliasing inner nodes instead of deep-copying them.
{
    my $deep_hash = {x => undef};
    my $curr = $deep_hash;
    for (1..$deep_target) {
        my $next = {x => undef};
        $curr->{x} = $next;
        $curr = $next;
    }

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        clone($deep_hash);
    };

    ok(!$@ && defined($cloned),
       "Should be able to clone $deep_target-deep hash structure without stack overflow")
        or diag("Error during clone: " . ($@ || "undefined result"));

    SKIP: {
        skip "Clone failed, can't verify structure", 2 if !defined $cloned;

        # Measure cloned depth
        my $measured = 0;
        my $walk = $cloned;
        while (ref($walk) eq 'HASH' && exists $walk->{x} && ref($walk->{x}) eq 'HASH') {
            $walk = $walk->{x};
            $measured++;
        }

        is($measured, $deep_target,
           "Cloned hash structure should maintain full depth ($deep_target levels)");

        # Verify clone independence at deep nodes: navigate to a node past
        # MAX_DEPTH/2 in both original and clone, then mutate the clone and
        # verify the original is unaffected (proves deep copy, not aliasing).
        my $depth_target = $is_limited_stack ? 1500 : 2500;
        my $walk_orig = $deep_hash;
        my $walk_clone = $cloned;
        for (1..$depth_target) {
            $walk_orig  = $walk_orig->{x};
            $walk_clone = $walk_clone->{x};
        }
        $walk_clone->{_sentinel} = "mutation";
        ok(!exists $walk_orig->{_sentinel},
           "Mutating clone at depth $depth_target should not affect original (no aliasing)");
    }
}

# Test 11-13: Mixed deep structure (arrays containing hashes) past MAX_DEPTH
{
    my $deep_mixed = [];
    my $curr = $deep_mixed;
    for (1..$deep_target) {
        my $next = [];
        push @$curr, {val => $next};
        $curr = $next;
    }

    my $cloned = eval {
        local $SIG{__WARN__} = sub {};
        clone($deep_mixed);
    };

    ok(!$@ && defined($cloned),
       "Should clone $deep_target-deep mixed array/hash structure without stack overflow")
        or diag("Error during clone: " . ($@ || "undefined result"));

    SKIP: {
        skip "Clone failed, can't verify", 2 if !defined $cloned;

        # Measure depth
        my $measured = 0;
        my $walk = $cloned;
        while (ref($walk) eq 'ARRAY' && @$walk == 1 && ref($walk->[0]) eq 'HASH') {
            $walk = $walk->[0]{val};
            $measured++;
        }
        is($measured, $deep_target,
           "Mixed deep structure should maintain full depth ($deep_target levels)");

        # Clone independence: mutate a deep hash node in clone
        my $depth_target = $is_limited_stack ? 1500 : 2500;
        my $walk_orig  = $deep_mixed;
        my $walk_clone = $cloned;
        for (1..$depth_target) {
            $walk_orig  = $walk_orig->[0]{val};
            $walk_clone = $walk_clone->[0]{val};
        }
        $walk_clone->[0]{_sentinel} = "mutation";
        ok(!exists $walk_orig->[0]{_sentinel},
           "Mutating clone hash at depth $depth_target should not affect original");
    }
}

# Tests 14-17: Deep scalar ref chains past MAX_DEPTH — iterative cloning
# (GH #107: shallow copy silently violated isolation for deeply nested scalar refs)
#
# Each scalar ref adds 1 rdepth, so we need > MAX_DEPTH levels to exercise
# the MAX_DEPTH guard.  We must build a true chain via an array of refs, not
# "$ref = \$ref" which creates a cycle (back to the same SV).
{
    my $max_depth_val = $is_limited_stack ? 2000 : 4000;
    my $ref_depth     = $max_depth_val + 500;

    # Chain: $chain[0] = \$leaf_val,  $chain[i] = \$chain[i-1]
    # So $chain[-1] is a ref_depth-deep scalar-ref chain whose ultimate leaf
    # is $leaf_val.
    my $leaf_val = "original";
    my @chain;
    $chain[0] = \$leaf_val;
    for my $i (1 .. $ref_depth) {
        $chain[$i] = \$chain[$i - 1];
    }
    my $deep = $chain[-1];

    # Test 14: clone must not die
    my @warnings;
    my $cloned = eval {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        clone($deep);
    };
    ok(!$@ && defined($cloned),
       "Should clone $ref_depth-deep scalar ref chain without dying")
        or diag("Error: " . ($@ || "undefined result"));

    # Test 15: clone must be a genuine deep copy, not a shared alias
    # (FAILS before the fix: old code returns SvREFCNT_inc(ref) which IS the
    # original SV — any write through the clone pollutes the original object)
    SKIP: {
        skip "Clone failed or not a ref", 2 unless defined($cloned) && ref($cloned);

        # Navigate down $ref_depth levels through the CLONED chain to reach
        # the innermost ref (the clone of $chain[0] = \$leaf_val).
        my $clone_inner = $cloned;
        for (1 .. $ref_depth) {
            last unless ref $clone_inner;
            $clone_inner = $$clone_inner;
        }

        SKIP: {
            skip "Could not reach innermost ref in clone", 2
                unless ref $clone_inner;

            # Mutating through the cloned innermost ref must NOT affect $leaf_val.
            $$clone_inner = "mutated";
            is($leaf_val, "original",
               "Mutating through deeply-cloned scalar ref must not affect original (GH #107)");

            # The innermost ref in the clone must be a different SV from the
            # corresponding original ($chain[0] = \$leaf_val).
            isnt(refaddr($clone_inner), refaddr($chain[0]),
                 "Clone innermost ref must be a distinct SV, not an alias");
        }
    }

    # Test 16: no warning should be emitted for deep scalar ref chains
    # (FAILS before the fix: old code emitted "depth limit exceeded" warnings)
    is(scalar @warnings, 0,
       "No warnings should be emitted when cloning deep scalar ref chain (GH #107)");

    # Test 17: $Clone::WARN = 0 must not cause errors (regression guard)
    my $ok = eval { local $Clone::WARN = 0; clone($deep); 1 };
    ok($ok, "\$Clone::WARN = 0 must not cause errors when cloning deep scalar refs");
}
