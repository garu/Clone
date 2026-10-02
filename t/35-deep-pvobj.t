#!/usr/bin/perl

# Test that SVt_PVOBJ class instances (Perl 5.38+) are deep-cloned when
# they are reached past MAX_DEPTH, i.e. through the iterative path.
#
# Bug: the iterative path knew only about AV and HV.  A class instance
# below MAX_DEPTH levels of nesting therefore fell into the two
# "everything else" branches:
#
#   * rv_clone_chain's leaf switch hit `default: newSVsv(current)`, which
#     croaks "Bizarre copy of OBJECT in subroutine entry" — a deep class
#     instance could not be cloned at all.
#   * sv_clone's past-MAX_DEPTH guard fell through to the
#     share-with-warning fallback, so the "clone" aliased the original's
#     fields (plus a spurious depth-limit warning).
#
# Both are fixed by treating PVOBJ as a third container kind in the work
# queue: clone_shell creates and blesses the shell, clone_fill_obj copies
# the fields through it.

use strict;
use warnings;
use Test::More;

BEGIN {
    plan skip_all => 'Perl 5.38+ required for the class feature'
        unless $] >= 5.038;
}

use Clone qw(clone);
use Scalar::Util qw(refaddr);

# Platform-adaptive depth: MAX_DEPTH is 2000 on Windows/Cygwin, 4000
# elsewhere.  Each [$x] nesting level costs 2 rdepth (RV + AV), so more
# than MAX_DEPTH/2 levels reach the iterative path.
my $is_limited = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $max_depth  = $is_limited ? 2000 : 4000;
my $depth      = $is_limited ? 1200 : 2200;

my $have_b = eval { require B; 1 };

plan tests => 20;

eval q{
    use feature 'class';
    no warnings 'experimental::class';

    class DeepPVOBJ::Point {
        field $x :param = 0;
        method x       { $x }
        method set_x   { $x = shift }
    }

    class DeepPVOBJ::Bag {
        field $items :param = undef;
        method items     { $items }
        method set_items { $items = shift }
    }

    class DeepPVOBJ::Node {
        field $next :param = undef;
        method next     { $next }
        method set_next { $next = shift }
    }

    class DeepPVOBJ::Empty { }
    1;
} or die "class declarations: $@";

# Wrap $inner in $levels arrayrefs, then $extra scalar refs.
sub nest {
    my ($inner, $levels, $extra) = @_;
    my $out = $inner;
    $out = [$out] for 1 .. $levels;
    for (1 .. $extra) {
        my $tmp = $out;       # fresh SV per link, kept alive by the ref
        $out = \$tmp;
    }
    return $out;
}

sub descend {
    my ($node, $levels, $extra) = @_;
    $node = $$node for 1 .. $extra;
    $node = $node->[0] for 1 .. $levels;
    return $node;
}

sub clone_quietly {
    my ($thing) = @_;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $copy = eval { clone($thing) };
    return ($copy, $@, \@warnings);
}

# --- Tests 1-6: a class instance nested past MAX_DEPTH ---------------
{
    my $orig = nest(DeepPVOBJ::Point->new(x => 42), $depth, 0);
    my ($copy, $err, $warnings) = clone_quietly($orig);

    ok(!$err, "clone of a class instance $depth levels deep does not die")
        or diag("Error: $err");
    is(scalar @$warnings, 0, 'no depth-limit warning for a deep class instance')
        or diag("Warnings: @$warnings");

    SKIP: {
        skip 'clone failed', 4 unless defined $copy;

        my $orig_leaf = descend($orig, $depth, 0);
        my $copy_leaf = descend($copy, $depth, 0);

        is(ref($copy_leaf), 'DeepPVOBJ::Point', 'deep clone preserves class');
        isnt(refaddr($copy_leaf), refaddr($orig_leaf),
             'deep clone is a distinct instance, not an alias');
        is($copy_leaf->x, 42, 'deep clone preserves the field value');

        $copy_leaf->set_x(99);
        is($orig_leaf->x, 42, 'mutating the deep clone leaves the original alone');
    }
}

# --- Tests 7-8: the MAX_DEPTH boundary itself ------------------------
# rdepth crosses MAX_DEPTH at a different point depending on the shape
# above the object, and the two broken branches sat on opposite sides of
# that crossing.  Sweep enough shapes to land on both.
{
    my @bad;
    my @noisy;

    for my $extra (0 .. 3) {
        for my $off (-1, 0, 1) {
            my $levels = ($max_depth / 2) + $off;
            my $orig   = nest(DeepPVOBJ::Point->new(x => 7), $levels, $extra);
            my ($copy, $err, $warnings) = clone_quietly($orig);

            my $label = "levels=$levels extra=$extra";
            push @noisy, "$label: @$warnings" if @$warnings;

            if ($err || !defined $copy) {
                push @bad, "$label: died (" . ($err || 'undef') . ")";
                next;
            }

            my $orig_leaf = descend($orig, $levels, $extra);
            my $copy_leaf = descend($copy, $levels, $extra);

            push @bad, "$label: class is " . (ref($copy_leaf) || 'not an object')
                unless ref($copy_leaf) eq 'DeepPVOBJ::Point';
            push @bad, "$label: aliased the original"
                if refaddr($copy_leaf) == refaddr($orig_leaf);
            push @bad, "$label: x is " . ($copy_leaf->x // 'undef')
                unless eval { $copy_leaf->x } == 7;
        }
    }

    is_deeply(\@bad, [], 'class instances clone correctly across the MAX_DEPTH boundary')
        or diag(join "\n", @bad);
    is_deeply(\@noisy, [], 'no warnings across the MAX_DEPTH boundary')
        or diag(join "\n", @noisy);
}

# --- Tests 9-11: fields of a deep instance are themselves cloned -----
{
    my $bag  = DeepPVOBJ::Bag->new(items => { list => [1, 2, 3] });
    my $orig = nest($bag, $depth, 0);
    my ($copy, $err) = clone_quietly($orig);

    ok(!$err, 'clone of a deep instance holding a nested field does not die')
        or diag("Error: $err");

    SKIP: {
        skip 'clone failed', 2 unless defined $copy;

        my $copy_leaf = descend($copy, $depth, 0);
        is_deeply($copy_leaf->items, { list => [1, 2, 3] },
                  'deep instance field structure is preserved');

        $copy_leaf->items->{list}[0] = 'mutated';
        is($bag->items->{list}[0], 1,
           'deep instance field is a copy, not shared with the original');
    }
}

# --- Tests 12-13: the same deep instance in two slots clones once ----
{
    my $shared = DeepPVOBJ::Point->new(x => 5);
    my $inner  = [$shared, $shared];
    my $orig   = nest($inner, $depth, 0);
    my ($copy, $err) = clone_quietly($orig);

    ok(!$err, 'clone of a deep instance aliased from two slots does not die')
        or diag("Error: $err");

    SKIP: {
        skip 'clone failed', 1 unless defined $copy;

        my $copy_inner = descend($copy, $depth, 0);
        is(refaddr($copy_inner->[0]), refaddr($copy_inner->[1]),
           'aliased deep instance clones to a single shared instance');
    }
}

# --- Tests 14-16: a deep instance whose field closes a cycle ---------
{
    my $node = DeepPVOBJ::Node->new;
    $node->set_next($node);
    my $orig = nest($node, $depth, 0);

    my ($copy, $err) = clone_quietly($orig);

    ok(!$err, 'clone of a self-referential deep instance does not die')
        or diag("Error: $err");

    SKIP: {
        skip 'clone failed', 2 unless defined $copy;

        my $copy_leaf = descend($copy, $depth, 0);
        is(refaddr($copy_leaf->next), refaddr($copy_leaf),
           'cycle closes onto the clone');
        isnt(refaddr($copy_leaf->next), refaddr($node),
             'cycle does not point back at the original');

        $copy_leaf->set_next(undef);    # break the clone's cycle
    }

    $node->set_next(undef);             # break the original's cycle
}

# --- Tests 17-19: a field-less class, and an instance behind a hash --
{
    my $orig = nest(DeepPVOBJ::Empty->new, $depth, 0);
    my ($copy, $err) = clone_quietly($orig);

    ok(!$err, 'clone of a deep field-less instance does not die')
        or diag("Error: $err");
    is(defined $copy ? ref(descend($copy, $depth, 0)) : undef,
       'DeepPVOBJ::Empty', 'deep field-less instance keeps its class');
}

{
    my $deep = { obj => DeepPVOBJ::Point->new(x => 11) };
    $deep = { inner => $deep } for 1 .. $depth;

    my ($copy, $err) = clone_quietly($deep);
    my $leaf = $copy;
    $leaf = $leaf->{inner} for 1 .. $depth;

    is(!$err && eval { $leaf->{obj}->x }, 11,
       'class instance reached through a deep hash is cloned intact')
        or diag("Error: " . ($err || $@));
}

# --- Test 20: the class stash reference taken per shell is released ---
# clone_shell stamps the class by incrementing the stash's refcount
# directly (sv_bless, which would balance it, rejects a class stash), so
# a missed release would leak one reference per deep clone.
SKIP: {
    skip 'B not available', 1 unless $have_b;

    my $stash = \%DeepPVOBJ::Point::;
    my $orig  = nest(DeepPVOBJ::Point->new(x => 1), $depth, 0);

    clone_quietly($orig) for 1 .. 5;        # warm up
    my $before = B::svref_2object($stash)->REFCNT;
    clone_quietly($orig) for 1 .. 20;
    my $after = B::svref_2object($stash)->REFCNT;

    is($after, $before, 'deep cloning does not leak class stash references');
}
