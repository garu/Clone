#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Clone qw(clone);
use Config;

# hv_clone_iterative must walk single-entry hash chains iteratively.
# Without this, deeply nested {k=>{k=>...}} structures past MAX_DEPTH
# overflow the C stack via recursive sv_clone -> hv_clone_iterative calls.

my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $max_depth_val    = $is_limited_stack ? 2000 : 4000;

# Suppress depth-limit warnings from leaf scalars past MAX_DEPTH (GH #113)
$Clone::WARN = 0;

# Build a hash chain {k=>{k=>{k=>...}}} of given depth.
# Returns the outermost hashref.
sub make_deep_hash_chain {
    my ($depth) = @_;
    my $leaf = { leaf => 1 };
    my $curr = $leaf;
    for (1 .. $depth) {
        $curr = { next => $curr };
    }
    return ($curr, $leaf);
}

# Test 1: deep hash chain past MAX_DEPTH must not crash
{
    my $depth = $max_depth_val + 500;
    my ($deep, $leaf) = make_deep_hash_chain($depth);

    my $clone = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(30);
        my $r = clone($deep);
        alarm(0);
        $r;
    };
    alarm(0);

    ok(!$@, "deep hash chain ($depth levels): no crash or timeout")
        or diag("Error: $@");
    ok(defined $clone, "clone result is defined");
}

# Test 2: verify correct structure at the leaf
{
    my $depth = $max_depth_val + 100;
    my ($deep, $leaf) = make_deep_hash_chain($depth);

    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm(30);
    my $clone = eval { clone($deep) };
    alarm(0);

    SKIP: {
        skip "clone failed", 2 unless defined $clone;

        # Walk to the leaf
        my $walk = $clone;
        my $steps = 0;
        while (ref($walk) eq 'HASH' && exists $walk->{next}) {
            $walk = $walk->{next};
            last if ++$steps > $depth + 5;
        }

        is($steps, $depth, "walked $depth levels to reach leaf");
        is($walk->{leaf}, 1, "leaf value preserved");
    }
}

# Test 3: clone hash structures are distinct objects from the originals
# Note: leaf scalar VALUES may be aliased at depth > MAX_DEPTH (GH #113,
# a separate issue). Here we verify the hash containers themselves are
# independent — adding a key to a clone hash must not affect the original.
{
    my $depth = $max_depth_val + 50;
    my ($deep, $leaf) = make_deep_hash_chain($depth);

    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm(30);
    my $clone = eval { clone($deep) };
    alarm(0);

    SKIP: {
        skip "clone failed", 2 unless defined $clone;

        isnt("$clone", "$deep", "clone is a different hashref from original");

        # Walk clone to an intermediate node and add a key
        my $walk = $clone;
        $walk = $walk->{next} for 1 .. int($depth / 2);
        $walk->{extra} = "injected";

        # Walk original to the same depth — extra key must be absent
        my $orig_walk = $deep;
        $orig_walk = $orig_walk->{next} for 1 .. int($depth / 2);
        ok(!exists $orig_walk->{extra},
           "adding key to clone doesn't affect original");
    }
}

# Test 4: blessed hash chain preserves class
{
    my $depth = $max_depth_val + 50;
    my $curr = bless { leaf => 1 }, "DeepNode";
    for (1 .. $depth) {
        $curr = bless { next => $curr }, "DeepNode";
    }

    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm(30);
    my $clone = eval { clone($curr) };
    alarm(0);

    SKIP: {
        skip "clone failed", 2 unless defined $clone;

        isa_ok($clone, "DeepNode", "top-level blessing preserved");

        # Check an intermediate node
        my $mid = $clone;
        $mid = $mid->{next} for 1 .. int($depth / 2);
        isa_ok($mid, "DeepNode", "intermediate node blessing preserved");
    }
}

# Test 5: circular hash chain at depth > MAX_DEPTH
{
    my $depth = $max_depth_val + 50;
    my $leaf = { tag => "circ" };
    my $curr = $leaf;
    for (1 .. $depth) {
        $curr = { next => $curr };
    }
    $leaf->{next} = $curr;  # close the loop

    my $clone = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(30);
        my $r = clone($curr);
        alarm(0);
        $r;
    };
    alarm(0);

    ok(!$@, "circular hash chain: no crash or hang")
        or diag("Error: $@");
    ok(defined $clone, "circular hash chain: clone defined");
}

# Test 6: multi-key hash at the end of a single-key chain
{
    my $depth = $max_depth_val + 50;
    my $leaf = { a => 1, b => 2, c => 3 };
    my $curr = $leaf;
    for (1 .. $depth) {
        $curr = { next => $curr };
    }

    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm(30);
    my $clone = eval { clone($curr) };
    alarm(0);

    SKIP: {
        skip "clone failed", 3 unless defined $clone;

        my $walk = $clone;
        $walk = $walk->{next} for 1 .. $depth;
        is($walk->{a}, 1, "multi-key leaf: a preserved");
        is($walk->{b}, 2, "multi-key leaf: b preserved");
        is($walk->{c}, 3, "multi-key leaf: c preserved");
    }
}

done_testing;
