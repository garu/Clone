#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Clone qw(clone);
use Config;

BEGIN {
    eval 'use Scalar::Util qw( weaken isweak );';
    if ($@) {
        plan skip_all => "Scalar::Util::weaken not available";
        exit;
    }
}

plan tests => 8;

# Platform-adaptive depth: must exceed MAX_DEPTH/2 to trigger
# the iterative clone path in av_clone_iterative.
# MAX_DEPTH is 2000 on Windows/Cygwin, 4000 elsewhere.
# rdepth increments twice per nesting level (RV + AV), so the
# iterative path kicks in at roughly MAX_DEPTH/2 nesting levels.
my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $deep_target      = $is_limited_stack ? 2500 : 5000;

# The iterative path starts at level ~(deep_target - MAX_DEPTH/2)
# from the bottom.  Place weakrefs well below that threshold.
my $weak_level = int($deep_target / 4);  # ~1250 — well within iterative zone

# Test 1-4: Weakrefs in deeply nested array chains should survive
# the iterative clone path.
#
# av_clone_iterative unrolls [[[...]]] chains by creating RVs directly
# via newRV_noinc.  If it doesn't check SvWEAKREF on the original RV,
# the cloned reference loses its weak status.
#
# To test this properly, the weakref target must also have a strong
# reference elsewhere in the clone graph (otherwise the weakened
# referent would correctly be freed, same as Storable::dclone behavior).
{
    my @levels;
    $levels[0] = ["leaf"];
    for my $i (1 .. $deep_target) {
        $levels[$i] = [ $levels[$i - 1] ];
    }

    # Weaken the chain reference deep in the iterative zone
    weaken($levels[$weak_level + 1]->[0]);
    ok(isweak($levels[$weak_level + 1]->[0]),
       "sanity: deep reference is weak before clone");

    # Add a strong anchor to the weakened target at the top level.
    # This ensures the target stays alive after deferred weakening.
    push @{$levels[$deep_target]}, $levels[$weak_level];

    my $cloned = eval { clone($levels[$deep_target]) };
    ok(!$@, "clone deeply nested weakref structure without dying")
        or diag("Error: $@");

    SKIP: {
        skip "clone failed", 2 if $@;
        # Walk down from the top to the weakened level
        my $walk = $cloned;
        my $steps = $deep_target - $weak_level - 1;
        for (1 .. $steps) {
            $walk = $walk->[0];
        }
        ok(isweak($walk->[0]),
           "weakref preserved in iterative clone path");
        ok(defined $walk->[0],
           "weakref target alive via strong anchor");
    }
}

# Test 5-8: Weakref at the entry point to iterative zone (sv_clone
# MAX_DEPTH block).  The RV that triggers the switch to iterative mode
# must also preserve its weak status.
{
    # Build an outer hash with strong and weak refs to a deep chain.
    # The chain itself is deep enough that the RV→AV at the boundary
    # is processed by sv_clone's MAX_DEPTH block.
    my @levels;
    $levels[0] = ["leaf"];
    for my $i (1 .. $deep_target) {
        $levels[$i] = [ $levels[$i - 1] ];
    }

    # Create a structure where two paths reference the same deep target.
    # The hash has 'weak' (weakened ref) and 'strong' (strong ref) to
    # the same deep-chain root.
    my $data = {
        weak   => $levels[$deep_target],
        strong => $levels[$deep_target],
    };
    weaken($data->{weak});
    ok(isweak($data->{weak}),
       "sanity: top-level weak ref is weak before clone");

    my $cloned = eval { clone($data) };
    ok(!$@, "clone structure with weakened deep chain without dying")
        or diag("Error: $@");

    SKIP: {
        skip "clone failed", 2 if $@;
        ok(isweak($cloned->{weak}),
           "top-level weak ref to deep chain preserved");
        is($cloned->{strong}, $cloned->{weak},
           "strong and weak point to same cloned chain");
    }
}
