#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Clone qw(clone);

BEGIN {
    eval "use Devel::Peek";
    plan skip_all => "Devel::Peek required for testing deep recursion implementation" if $@;

    eval "use Devel::Size";
    plan skip_all => "Devel::Size required for testing deep recursion implementation" if $@;
}

plan tests => 5;

# Test 1: Basic deep recursion test with verification
{
    my $deep = [];
    $deep = [$deep] for 1..1000;  # Create a deeply nested structure
    my $cloned = eval { clone($deep) };
    ok(!$@, "Cloning deeply nested structure (1000 levels) should not die")
        or diag("Error: $@");
    is(ref($cloned), 'ARRAY', "Cloned structure should be an array reference");
}

# Test 2: Very deep recursion test with verification
{
    # Create a structure that will definitely hit the recursion limit
    my $recursion_limit = 50000;  # This should hit the limit on most systems
    my $very_deep = [];
    my $original = $very_deep;

    # Force Perl to actually create the deep structure
    my $curr = $very_deep;
    for (1..$recursion_limit) {
        my $new = [];
        $curr->[0] = $new;
        $curr = $new;
    }

    # Get the size of the original structure
    my $orig_size = eval { Devel::Size::total_size($very_deep) };
    ok(defined($orig_size), "Should be able to measure original structure size")
        or diag("Error measuring size: $@");

    # Now try to clone it
    my $cloned = eval {
        local $SIG{__WARN__} = sub {}; # Suppress warnings
        clone($very_deep);
    };

    ok(!$@ && defined($cloned), "Should be able to clone deep structure without stack overflow")
        or diag("Error during clone: " . ($@ || "undefined result"));

    # If we got this far and the clone succeeded, verify the structure
    SKIP: {
        skip "Clone failed, can't verify structure", 1 if !defined $cloned;

        my $depth = 0;
        my $curr = $cloned;
        while (ref($curr) eq 'ARRAY' && @$curr == 1) {
            $curr = $curr->[0];
            $depth++;
        }

        is($depth, $recursion_limit, "Cloned structure should maintain full depth");
    }
}
