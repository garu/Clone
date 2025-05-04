#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 3;
use Clone qw(clone);

# Test 1: Simple circular reference in array
{
    my $array = [];
    $array->[0] = $array;  # Create circular reference
    my $clone = eval { clone($array) };
    ok(!$@, "Cloning circular array reference should not die");
    is($clone->[0], $clone, "Circular reference should be maintained in clone");
}

# Test 2: Memory leak test with Devel::Leak
SKIP: {
    eval { require Devel::Leak };
    skip "Devel::Leak required for memory leak test", 1 if $@;

    my $handle = Devel::Leak::NoteSV(my $count);
    {
        my $array = [];
        $array->[0] = $array;
        my $clone = clone($array);
    }
    Devel::Leak::CheckSV($handle);
    cmp_ok($count, '==', 0, "No memory leak detected with circular references");
}
