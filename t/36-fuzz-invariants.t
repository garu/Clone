#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Clone qw(clone);
use Scalar::Util qw(blessed reftype refaddr);
use Data::Dumper;
use B ();

# Seeded clone-invariant fuzzer.
#
# Generates pseudo-random nested structures (hashes, arrays, scalar refs,
# blessed objects, shared refs and cycles) from a fixed seed set, then checks
# the three invariants every clone must satisfy:
#
#   1. structural equality  — clone looks exactly like the original, including
#                             which slots alias the same referent
#   2. isolation            — mutating every reachable slot of the clone leaves
#                             the original byte-identical
#   3. refcount neutrality  — cloning does not change the refcount of any SV
#                             reachable from the original, and dropping the
#                             clone restores the pre-clone refcounts
#
# The seeds are fixed so a failure is reproducible.  Set
# CLONE_FUZZ_SEEDS=7 (or 7,8,9) to re-run only the seeds you care about.

my @SEEDS = $ENV{CLONE_FUZZ_SEEDS}
    ? split( /\s*,\s*/, $ENV{CLONE_FUZZ_SEEDS} )
    : ( 1 .. 40 );

# --- deterministic PRNG (we cannot rely on rand() being stable across perls) ---

my $state;

sub srnd { $state = ( shift() * 2654435761 ) % 2147483647 || 1 }

sub rnd {
    my ($n) = @_;
    $state = ( $state * 1103515245 + 12345 ) % 2147483647;
    return $state % $n;
}

# --- structure generator ---

my @LEAVES = ( 0, 1, -42, 3.25, '', 'str', 'x' x 40, undef, "0 but true", 1e9 );

my @POOL;    # every ref generated so far, for sharing and cycles

sub gen {
    my ($budget) = @_;

    # out of budget, or 1-in-4 otherwise: a plain scalar leaf
    return $LEAVES[ rnd( scalar @LEAVES ) ]
        if $budget <= 0 || rnd(4) == 0;

    # reuse an existing ref: creates shared referents and, when the reused ref
    # is an ancestor, cycles
    return $POOL[ rnd( scalar @POOL ) ]
        if @POOL && rnd(4) == 0;

    my $kind = rnd(3);
    my $ref;

    if ( $kind == 0 ) {
        $ref = {};
        push @POOL, $ref;
        for my $i ( 0 .. rnd(4) ) {
            $ref->{ "k$i" } = gen( $budget - 1 );
        }
    }
    elsif ( $kind == 1 ) {
        $ref = [];
        push @POOL, $ref;
        for my $i ( 0 .. rnd(4) ) {
            $ref->[$i] = gen( $budget - 1 );
        }
    }
    else {
        my $inner = gen( $budget - 1 );
        $ref = \$inner;
        push @POOL, $ref;
    }

    bless $ref, 'Clone::Fuzz::Obj' if rnd(6) == 0;
    return $ref;
}

# --- canonical, address-free, cycle-safe rendering ---
#
# Data::Dumper renders a repeated referent as the *path* of its first
# occurrence ($VAR1->{k0}), not as an address, so two structurally identical
# graphs render identically and aliasing differences do show up.

# A fresh Dumper per call on purpose: a reused one keeps a reference to the
# last value it rendered, which would show up as a refcount delta below.
sub canon {
    my ($thing) = @_;
    return Data::Dumper->new( [$thing] )->Indent(0)->Sortkeys(1)->Terse(1)
        ->Useqq(1)->Dump;
}

# --- traversal: every reachable ref, and every mutable slot ---

sub walk {
    my ( $root, $on_ref, $on_slot ) = @_;
    my @queue = ($root);
    my %seen;

    while (@queue) {
        my $ref = shift @queue;
        next if !ref($ref) || $seen{ refaddr $ref }++;
        $on_ref->($ref);

        my $type = reftype($ref);
        my @slots
            = $type eq 'HASH'  ? map { \$ref->{$_} } sort keys %$ref
            : $type eq 'ARRAY' ? map { \$ref->[$_] } 0 .. $#$ref
            : $type eq 'SCALAR' || $type eq 'REF' ? ($ref)
            :                                       ();

        for my $slot (@slots) {
            $on_slot->($slot);
            push @queue, $$slot if ref $$slot;
        }
    }
    return;
}

sub refcounts {
    my ($root) = @_;
    my %count;
    walk( $root, sub { $count{ refaddr $_[0] } = B::svref_2object( $_[0] )->REFCNT }, sub { } );
    return \%count;
}

sub all_refs {
    my ($root) = @_;
    my @refs;
    walk( $root, sub { push @refs, $_[0] }, sub { } );
    return \@refs;
}

# --- the invariant check ---

sub check_seed {
    my ($seed) = @_;

    srnd($seed);
    @POOL = ();
    my $orig = gen(5);

    # a bare leaf is not interesting — force at least one container
    $orig = { root => $orig } unless ref $orig;

    my $before = canon($orig);

    # Hold every original ref for the whole check so the two refcount
    # snapshots are taken under identical conditions.
    my $held = all_refs($orig);
    my $rc_before = refcounts($orig);

    my $clone = clone($orig);

    is( canon($clone), $before, "seed $seed: clone is structurally equal" );

    my $rc_after = refcounts($orig);
    is_deeply( $rc_after, $rc_before,
        "seed $seed: cloning leaves original refcounts untouched" );

    # The clone must share no ref with the original.
    my %orig_addr = map { refaddr($_) => 1 } @$held;
    my @shared;
    walk( $clone, sub { push @shared, $_[0] if $orig_addr{ refaddr $_[0] } }, sub { } );
    is( scalar @shared, 0, "seed $seed: clone shares no referent with original" );

    # Isolation: scribble over every slot the clone can reach.
    my $n = 0;
    walk(
        $clone,
        sub { },
        sub {
            my ($slot) = @_;
            $$slot = "mutated-" . $n++ unless ref $$slot;
        }
    );
    is( canon($orig), $before,
        "seed $seed: mutating $n clone slots leaves original unchanged" );

    undef $clone;
    is_deeply( refcounts($orig), $rc_before,
        "seed $seed: freeing the clone restores original refcounts" );

    return;
}

check_seed($_) for @SEEDS;

done_testing;
