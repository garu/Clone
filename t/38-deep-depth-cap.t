#!/usr/bin/perl

# clone($ref, $depth) must keep capping the copy once the clone crosses
# MAX_DEPTH and switches to the iterative work queue.
#
# The iterative path used to drop the depth argument entirely: the queue
# carried no budget and clone_elem cloned leaves with a hardcoded depth of
# 1, so every level below the MAX_DEPTH crossing was deep-copied no matter
# what the caller asked for.  That only shows up when the cap is *above*
# the crossing point (a cap below it expires on the recursive path, before
# the queue is ever involved), hence the deliberately large numbers here.
#
# Semantics being checked (see t/31-depth-parameter.t):
#   - a container level is copied while its budget is non-zero
#   - with depth = N, levels 1..N are copies and level N+1 is the
#     original's own SV, shared with the clone
#   - only containers consume a depth unit; RV dereference does not

use strict;
use warnings;
use Test::More tests => 11;
use Scalar::Util qw(refaddr);
use Clone qw(clone);

# MAX_DEPTH is 2000 on Windows/Cygwin, 4000 elsewhere, counted in rdepth
# units (~2 per nesting level), so the iterative path takes over at
# roughly MAX_DEPTH/2 levels.  Both numbers below are above that.
my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $levels = $is_limited_stack ? 1600 : 2600;
my $cap    = $is_limited_stack ? 1200 : 2200;

# Walk two parallel spines and return the first level at which both sides
# are the same SV, i.e. where the clone stopped copying and started
# sharing.  $descend maps a container to the one below it.
sub first_shared_level {
    my ($orig, $clone, $descend) = @_;
    for my $level (1 .. $levels) {
        return $level if refaddr($orig) == refaddr($clone);
        $orig  = $descend->($orig);
        $clone = $descend->($clone);
        return undef if !defined $orig || !defined $clone;
    }
    return undef;
}

my $av_down = sub { $_[0]->[0] };
my $hv_down = sub { $_[0]->{next} };

# Each level carries a payload in a second slot so sharing can also be
# checked behaviourally, not just by address.
sub deep_av {
    my $root = [];
    my $curr = $root;
    $curr->[1] = "level 1";
    for my $i (2 .. $levels) {
        my $next = [];
        $next->[1] = "level $i";
        $curr->[0] = $next;
        $curr = $next;
    }
    return $root;
}

sub deep_hv {
    my $root = {};
    my $curr = $root;
    $curr->{payload} = "level 1";
    for my $i (2 .. $levels) {
        my $next = { payload => "level $i" };
        $curr->{next} = $next;
        $curr = $next;
    }
    return $root;
}

# ---------------------------------------------------------------------------
# Arrays: the cap survives the switch to the iterative cloner
# ---------------------------------------------------------------------------

{
    my $orig  = deep_av();
    my $clone = clone($orig, $cap);

    is(first_shared_level($orig, $clone, $av_down), $cap + 1,
       "deep array: level $cap is copied, the one below it is shared");

    # Everything above the cap is an independent copy.
    my $o = $orig;
    my $c = $clone;
    for (2 .. 100) {
        $o = $av_down->($o);
        $c = $av_down->($c);
    }
    $c->[1] = "mutated";
    is($o->[1], "level 100",
       "deep array: writing above the cap leaves the original alone");

    # ...and the shared tail really is the original's own data.
    ($o, $c) = ($orig, $clone);
    for (2 .. $cap + 2) {
        $o = $av_down->($o);
        $c = $av_down->($c);
    }
    is(refaddr($o), refaddr($c),
       "deep array: level @{[ $cap + 2 ]} is shared too");
    $c->[1] = "shared write";
    is($o->[1], "shared write",
       "deep array: writing below the cap is visible in the original");
}

# ---------------------------------------------------------------------------
# Hashes: same, through clone_fill_hv
# ---------------------------------------------------------------------------

{
    my $orig  = deep_hv();
    my $clone = clone($orig, $cap);

    is(first_shared_level($orig, $clone, $hv_down), $cap + 1,
       "deep hash: level $cap is copied, the one below it is shared");

    my $o = $orig;
    my $c = $clone;
    for (2 .. $cap) {
        $o = $hv_down->($o);
        $c = $hv_down->($c);
    }
    isnt(refaddr($o), refaddr($c), "deep hash: level $cap is still a copy");

    # The last copied container holds the original's own value SVs: its
    # elements are cloned with a budget of 0, which means share.  This is
    # what the recursive path does too (t/31-depth-parameter.t), so a write
    # through the clone is visible in the original.
    is(refaddr(\$o->{payload}), refaddr(\$c->{payload}),
       "deep hash: the last copied level shares the original's value SVs");
}

# ---------------------------------------------------------------------------
# A cap deeper than the structure must not truncate anything
# ---------------------------------------------------------------------------

{
    my $orig  = deep_av();
    my $clone = clone($orig, $levels + 10);

    is(first_shared_level($orig, $clone, $av_down), undef,
       "cap deeper than the structure: nothing is shared");

    my $c = $clone;
    $c = $av_down->($c) for 2 .. $levels;
    is($c->[1], "level $levels", "generous cap: full spine was copied");
}

# ---------------------------------------------------------------------------
# RV dereference does not consume a depth unit, past MAX_DEPTH either.
# Each link here is an array whose slot holds a ref to a scalar holding a
# ref to the next array, so the elements go through rv_clone_chain rather
# than the inline container branch of clone_elem.
# ---------------------------------------------------------------------------

{
    my $root = [];
    my $curr = $root;
    my @orig = ($root);
    for my $i (2 .. $levels) {
        my $next = [];
        $curr->[0] = \$next;
        $curr = $next;
        push @orig, $next;
    }

    my $clone = clone($root, $cap);

    my $down = sub { ${ $_[0]->[0] } };
    my $c = $clone;
    my $shared;
    for my $level (1 .. $levels) {
        if (refaddr($orig[$level - 1]) == refaddr($c)) {
            $shared = $level;
            last;
        }
        last if !defined $c->[0];    # bottom reached: nothing shared
        $c = $down->($c);
    }

    is($shared, $cap + 1,
       "ref-to-ref spine: the extra RV links consume no depth unit");
    isnt(refaddr($orig[0]), refaddr($clone),
         "ref-to-ref spine: the root is still a copy");
}
