#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 7;
use Clone qw(clone);

# Partial clone graph must not leak when cloning croaks half-way.
#
# clone() builds the copy bottom-up: each cloned SV is held only by the
# C frame that made it until the frame returns and hands it to its
# parent container.  A croak inside the recursion -- here a tied FETCH
# that dies, reached through newSVsv() on a magical scalar -- longjmps
# straight out of every frame at once, discarding those references
# without freeing anything.
#
# hseen is registered with SAVEFREESV, so clones recorded in it are
# released while the stack unwinds.  Clones of single-referenced,
# non-magical SVs are deliberately *not* recorded there (the "visible"
# optimisation in sv_clone), so they need their own savestack owner.
# Partially filled array clones need AvFILLp set up front for the same
# reason: free-time only walks slots below the fill mark.
#
# Every test below counts DESTROY on cloned blessed hashes: the
# originals stay alive in scope, so any DESTROY seen inside the test is
# a clone that was correctly reclaimed.

package DieOnFetch;
sub TIESCALAR { bless {}, shift }
sub FETCH     { die "FETCH died mid-clone\n" }
sub STORE     { }

package Tracker;
our $destroyed = 0;
sub new     { bless { id => $_[1] }, $_[0] }
sub DESTROY { $destroyed++ }

package main;

tie my $boom, 'DieOnFetch';

# 1-2: array elements cloned before the croak are reclaimed
{
    my @list = (Tracker->new(1), Tracker->new(2), \$boom);

    $Tracker::destroyed = 0;
    my $clone = eval { clone(\@list) };

    like($@, qr/FETCH died mid-clone/, 'clone() croaked mid-graph');
    is($Tracker::destroyed, 2,
       'array: both cloned elements freed during unwinding');
}

# 3: a deeper partial graph (nested containers + many leaves)
{
    my @inner = map { Tracker->new($_) } 1 .. 20;
    my %outer = (data => [@inner, \$boom]);

    $Tracker::destroyed = 0;
    eval { clone(\%outer) };

    is($Tracker::destroyed, 20,
       'nested hash/array: all 20 cloned objects freed during unwinding');
}

# 4: repeated failures do not accumulate
{
    my @list = (Tracker->new(1), \$boom);

    $Tracker::destroyed = 0;
    eval { clone(\@list) } for 1 .. 10;

    is($Tracker::destroyed, 10,
       'repeated croaks free one clone each, nothing accumulates');
}

# 5: a shared (hseen-tracked) object is reclaimed too
{
    my $shared = Tracker->new('shared');
    my @list = ($shared, $shared, \$boom);

    $Tracker::destroyed = 0;
    eval { clone(\@list) };

    is($Tracker::destroyed, 1,
       'shared object cloned once and freed during unwinding');
}

# 6: the same holds past MAX_DEPTH, where the iterative cloner owns the
#    graph instead.  Platform-adaptive depth: MAX_DEPTH is 2000 on
#    Windows/Cygwin and 4000 elsewhere, and each array level costs ~2
#    rdepth, so this spans both the recursive and the iterative path.
{
    my $is_limited = ($^O eq 'MSWin32' || $^O eq 'cygwin');
    my $depth      = $is_limited ? 1200 : 2200;

    my @keep;
    my $deep = \$boom;
    for my $i (1 .. $depth) {
        my $tracker = Tracker->new($i);
        push @keep, $tracker;		# keep the originals alive
        $deep = [ $tracker, $deep ];
    }

    $Tracker::destroyed = 0;
    eval {
        local $SIG{__WARN__} = sub { };
        clone($deep);
    };

    is($Tracker::destroyed, $depth,
       "deep structure: all $depth cloned objects freed during unwinding");
}

# 7: cloning still works after a croak (no corrupted internal state)
{
    my $ok = clone({ a => [1, 2, 3], b => \'x' });
    is_deeply($ok, { a => [1, 2, 3], b => \'x' },
              'clone() still correct after a croak');
}
