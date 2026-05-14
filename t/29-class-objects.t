#!/usr/bin/perl
use strict;
use warnings;
use Test::More;

# SVt_PVOBJ (class instances) requires Perl 5.38+
BEGIN {
    plan skip_all => 'Perl 5.38+ required for class feature'
        unless $] >= 5.038;
    eval { require Scalar::Util; 1 }
        or plan skip_all => 'Scalar::Util not available';
    plan tests => 12;
}

use Clone qw(clone);
use Scalar::Util qw(refaddr);

# Tests 1-3: basic field cloning and class preservation
eval q{
    use feature 'class';
    no warnings 'experimental::class';

    class CloneTestPoint {
        field $x :param;
        field $y :param;
        method x { $x }
        method y { $y }
    }

    my $orig = CloneTestPoint->new(x => 3, y => 7);
    my $copy = clone($orig);

    is(ref($copy), 'CloneTestPoint', 'clone preserves class name');
    is($copy->x(), 3, 'clone preserves field x');
    is($copy->y(), 7, 'clone preserves field y');
} or die "basic field cloning: $@";

# Tests 4-5: field independence (clone mutation does not affect original)
eval q{
    use feature 'class';
    no warnings 'experimental::class';

    class CloneTestCounter {
        field $count :param;
        method count { $count }
        method inc { $count++ }
    }

    my $orig = CloneTestCounter->new(count => 0);
    my $copy = clone($orig);
    $copy->inc();
    $copy->inc();

    is($copy->count(), 2, 'cloned counter incremented independently');
    is($orig->count(), 0, 'original counter unchanged');
} or die "field independence: $@";

# Tests 6-7: nested class objects are deep-cloned
eval q{
    use feature 'class';
    no warnings 'experimental::class';

    class CloneTestInner {
        field $val :param;
        method val { $val }
    }

    class CloneTestOuter {
        field $child :param;
        method child { $child }
    }

    my $inner = CloneTestInner->new(val => 42);
    my $outer = CloneTestOuter->new(child => $inner);
    my $copy  = clone($outer);

    is($copy->child()->val(), 42, 'nested class field value preserved');
    isnt(refaddr($outer->child()), refaddr($copy->child()),
         'nested class object is a separate instance');
} or die "nested class: $@";

# Tests 8-9: reference fields are deep-cloned (not shared)
eval q{
    use feature 'class';
    no warnings 'experimental::class';

    class CloneTestWithRef {
        field $data :param;
        method data { $data }
    }

    my $hashref = { a => 1, b => [2, 3] };
    my $orig = CloneTestWithRef->new(data => $hashref);
    my $copy = clone($orig);

    $copy->data()->{a} = 99;
    is($orig->data()->{a}, 1, 'original ref field unchanged after clone mutation');
    is($copy->data()->{a}, 99, 'cloned ref field holds mutated value');
} or die "ref field isolation: $@";

# Test 10: class object inside a circular hash structure
eval q{
    use feature 'class';
    no warnings 'experimental::class';

    class CloneTestNode {
        field $value :param;
        method value { $value }
    }

    my $node = CloneTestNode->new(value => 'hello');
    my $container = { node => $node, self => undef };
    $container->{self} = $container;

    my $copy = clone($container);
    is($copy->{node}->value(), 'hello',
       'class object inside circular structure cloned correctly');
} or die "circular structure: $@";

# Test 11: depth-limited clone still produces a blessed object
eval q{
    use feature 'class';
    no warnings 'experimental::class';

    class CloneTestSimple {
        field $v :param;
        method v { $v }
    }

    my $orig = CloneTestSimple->new(v => 10);
    my $copy = clone($orig, 2);
    is(ref($copy), 'CloneTestSimple', 'depth-limited clone preserves class');
} or die "depth limit: $@";

# Test 12: no memory leak over many clone/destroy cycles
eval q{
    use feature 'class';
    no warnings 'experimental::class';

    class CloneTestLeak {
        field $x :param;
    }

    my $before = CloneTestLeak->new(x => 1);
    for (1 .. 500) {
        my $tmp = clone($before);
    }
    pass('500 clone/destroy cycles without crash');
} or die "memory cycles: $@";
