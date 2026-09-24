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

plan tests => 5;

# Platform-adaptive depth: must exceed MAX_DEPTH/2 to trigger
# the iterative clone path (clone_container_iterative / rv_clone_chain).
# MAX_DEPTH is 2000 on Windows/Cygwin, 4000 elsewhere.
# rdepth increments twice per nesting level (RV + AV), so the
# iterative path kicks in at roughly MAX_DEPTH/2 nesting levels.
my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $deep_target      = $is_limited_stack ? 2500 : 5000;

# The iterative path starts at level ~(deep_target - MAX_DEPTH/2)
# from the bottom.  Place weakrefs well below that threshold.
my $weak_level = int($deep_target / 4);  # ~1250 — well within iterative zone

# Weakrefs in deeply nested array chains should survive
# the iterative clone path.
#
# The iterative cloner builds each nested container's RV directly via
# newRV_noinc (clone_elem) rather than going through the recursive
# sv_clone path.  If it doesn't check SvWEAKREF on the original RV,
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
        skip "clone failed", 3 if $@;
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
        ok(!isweak($cloned->[1]),
           "strong anchor not over-weakened");
    }
}
