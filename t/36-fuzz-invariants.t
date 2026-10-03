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
# blessed objects, non-cloneable leaves, shared refs and cycles) from a fixed
# seed set, then checks the three invariants every clone must satisfy:
#
#   1. structural equality  — clone looks exactly like the original, including
#                             which slots alias the same referent
#   2. isolation            — mutating every reachable slot of the clone leaves
#                             the original byte-identical, and the clone shares
#                             no *cloneable* referent with the original
#   3. refcount neutrality  — cloning does not change the refcount of any
#                             cloneable SV reachable from the original, and
#                             dropping the clone restores the pre-clone
#                             refcounts
#
# Invariants 2 and 3 are deliberately scoped to *cloneable* referents.  A
# non-cloneable leaf (a code ref, a glob, an IO handle) is by design shared
# between original and clone rather than copied, so its address legitimately
# appears in both graphs and its refcount legitimately rises while the clone is
# alive.  Those referents are excluded from the sharing and refcount checks;
# everything else must be a fresh SV.
#
# Environment knobs (all optional):
#
#   CLONE_FUZZ_SEEDS=7           re-run a single seed
#   CLONE_FUZZ_SEEDS=7,8,9       re-run a list
#   CLONE_FUZZ_SEEDS=1..500      run a range (for a nightly/soak job)
#   CLONE_FUZZ_BUDGET=8          generator nesting budget (default 5)
#
# The seeds are fixed and the PRNG is integer-exact on every perl, so a
# failure is reproducible from its seed alone.

my @SEEDS = parse_seeds( $ENV{CLONE_FUZZ_SEEDS} );
my $BUDGET = $ENV{CLONE_FUZZ_BUDGET} || 5;

sub parse_seeds {
    my ($spec) = @_;
    return ( 1 .. 40 ) unless defined $spec && length $spec;

    my @seeds;
    for my $part ( split /\s*,\s*/, $spec ) {
        if ( $part =~ /^(\d+)\s*\.\.\s*(\d+)$/ ) {
            push @seeds, ( $1 .. $2 );
        }
        elsif ( $part =~ /^(\d+)$/ ) {
            push @seeds, $1;
        }
        else {
            die "CLONE_FUZZ_SEEDS: cannot parse '$part'\n";
        }
    }
    die "CLONE_FUZZ_SEEDS: no seeds\n" unless @seeds;
    return @seeds;
}

# --- deterministic PRNG -------------------------------------------------
#
# MINSTD (Lehmer, a=16807 m=2^31-1) via Schrage's method.  rand() is not
# stable across perls, and a plain LCG is not stable either: a 32-bit
# multiplier overflows IV on a 32-bit perl and silently degrades to an
# inexact NV, so the same seed yields different streams on different
# builds of the CI matrix.  Schrage keeps every intermediate below
# a*q = 16807*127773 ~= 2.1e9, which is exact in both an IV and an NV, so
# the stream is identical everywhere.

use constant {
    PRNG_M => 2147483647,    # 2^31 - 1
    PRNG_A => 16807,
    PRNG_Q => 127773,        # m / a
    PRNG_R => 2836,          # m % a
};

my $state;

sub srnd {
    my ($seed) = @_;
    $state = ( $seed % ( PRNG_M - 1 ) ) + 1;    # keep state in 1 .. m-1
    return;
}

sub rnd {
    my ($n) = @_;
    my $hi = int( $state / PRNG_Q );
    $state = PRNG_A * ( $state - $hi * PRNG_Q ) - PRNG_R * $hi;
    $state += PRNG_M if $state <= 0;
    return $state % $n;
}

# --- structure generator ------------------------------------------------

my @LEAVES = ( 0, 1, -42, 3.25, '', 'str', 'x' x 40, undef, "0 but true", 1e9 );

# Non-cloneable leaves: Clone shares these by refcount instead of copying
# them, which is exactly the behaviour invariants 2 and 3 have to tolerate.
my @NONCLONEABLE = ( sub { 42 }, sub { 'fuzz' }, \*STDOUT );

sub is_noncloneable {
    my $type = reftype( $_[0] ) || '';
    return $type eq 'CODE' || $type eq 'GLOB' || $type eq 'IO';
}

my @POOL;    # every ref generated so far, for sharing and cycles

sub gen {
    my ($budget) = @_;

    # out of budget, or 1-in-4 otherwise: a leaf
    if ( $budget <= 0 || rnd(4) == 0 ) {
        return $NONCLONEABLE[ rnd( scalar @NONCLONEABLE ) ] if rnd(8) == 0;
        return $LEAVES[ rnd( scalar @LEAVES ) ];
    }

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
            $ref->{"k$i"} = gen( $budget - 1 );
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

# Generate a top-level *container*.  Wrapping a stray leaf in { root => ... }
# instead would waste the ~1-in-4 seeds whose first gen() call takes the leaf
# branch: they would all assert the same trivial one-key hash.
sub gen_root {
    my ($budget) = @_;
    while (1) {
        @POOL = ();
        my $root = gen($budget);
        my $type = ref($root) ? reftype($root) : '';
        return $root
            if $type eq 'HASH' || $type eq 'ARRAY' || $type eq 'SCALAR' || $type eq 'REF';
    }
}

# --- canonical, address-free, cycle-safe rendering ----------------------
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

# --- traversal: every reachable ref, and every mutable slot -------------
#
# Each callback also receives the *path* of what it is looking at, in the same
# addressing scheme canon() uses ($VAR1->{k0}[2]).  Keying the refcount map by
# path instead of by refaddr is what makes a CI failure actionable: is_deeply
# then names the offending node rather than printing a bare heap address.

sub walk {
    my ( $root, $on_ref, $on_slot ) = @_;
    my @queue = ( [ $root, '$VAR1' ] );
    my %seen;

    while (@queue) {
        my ( $ref, $path ) = @{ shift @queue };
        next if !ref($ref) || $seen{ refaddr $ref }++;
        $on_ref->( $ref, $path );

        my $type = reftype($ref) || '';
        my @slots
            = $type eq 'HASH' ? map { [ \$ref->{$_}, $path . "->{$_}" ] } sort keys %$ref
            : $type eq 'ARRAY' ? map { [ \$ref->[$_], $path . "->[$_]" ] } 0 .. $#$ref
            : $type eq 'SCALAR' || $type eq 'REF' ? ( [ $ref, "\${$path}" ] )
            :                                      ();

        for my $slot (@slots) {
            $on_slot->( @$slot );
            push @queue, [ ${ $slot->[0] }, $slot->[1] ] if ref ${ $slot->[0] };
        }
    }
    return;
}

# Refcounts of every cloneable referent, keyed by path (see walk()).
sub refcounts {
    my ($root) = @_;
    my %count;
    walk(
        $root,
        sub {
            my ( $ref, $path ) = @_;
            return if is_noncloneable($ref);
            $count{$path} = B::svref_2object($ref)->REFCNT;
        },
        sub { }
    );
    return \%count;
}

sub all_refs {
    my ($root) = @_;
    my @refs;
    walk( $root, sub { push @refs, $_[0] }, sub { } );
    return \@refs;
}

# --- the invariant check ------------------------------------------------

sub check_seed {
    my ($seed) = @_;

    srnd($seed);
    my $orig = gen_root($BUDGET);

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

    # The clone must share no cloneable ref with the original.
    my %orig_addr = map { refaddr($_) => 1 } grep { !is_noncloneable($_) } @$held;
    my @shared;
    walk(
        $clone,
        sub {
            my ( $ref, $path ) = @_;
            push @shared, $path if $orig_addr{ refaddr $ref };
        },
        sub { }
    );
    is( scalar @shared, 0, "seed $seed: clone shares no referent with original" )
        or diag( "seed $seed: clone slots aliasing the original:\n  "
            . join( "\n  ", @shared ) );

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

# --- deep chains: the same invariants on the iterative clone path -------
#
# The generator's budget keeps every seed shallow, so it only ever exercises
# Clone's recursive path.  Past MAX_DEPTH (2000 on Windows/Cygwin, 4000
# elsewhere, in rdepth units that increment twice per nesting level) Clone
# switches to its heap work queue, so these chains go deeper than
# MAX_DEPTH/2 levels to bring that path under the same three invariants.
#
# canon()/walk() are not used here: Data::Dumper recurses, and a path-keyed
# refcount map over a chain this long is O(depth^2) in memory.  The chain is
# walked by hand instead and the refcounts keyed by depth index, which is just
# as actionable on failure.

my $DEEP = ( $^O eq 'MSWin32' || $^O eq 'cygwin' ) ? 2500 : 5000;

sub check_deep_chain {
    my ($type) = @_;
    my $is_hash = $type eq 'HASH';
    my $label   = "deep $type chain ($DEEP levels)";

    my $orig = $is_hash ? {} : [];
    my $tip  = $orig;
    my @nodes = ($orig);
    for ( 1 .. $DEEP ) {
        my $next = $is_hash ? {} : [];
        if   ($is_hash) { $tip->{inner} = $next }
        else            { $tip->[0]     = $next }
        $tip = $next;
        push @nodes, $next;
    }
    if   ($is_hash) { $tip->{leaf} = 'bottom' }
    else            { $tip->[1]    = 'bottom' }

    my @rc_before = map { B::svref_2object($_)->REFCNT } @nodes;
    my %orig_addr = map { refaddr($_) => 1 } @nodes;

    my $clone = eval { clone($orig) };
    if ( !ref $clone ) {
        fail("$label: clone survives");
        diag("error: $@");
        return;
    }

    # Structural equality, by hand: same depth, same leaf.
    my $node   = $clone;
    my $levels = 0;
    my $shared = 0;
    my @clone_nodes;
    while (1) {
        push @clone_nodes, $node;
        $shared++ if $orig_addr{ refaddr $node };
        my $next = $is_hash ? $node->{inner} : $node->[0];
        last unless ref $next;
        $node = $next;
        $levels++;
    }
    is( $levels, $DEEP, "$label: clone has the same depth" );
    is( $is_hash ? $node->{leaf} : $node->[1],
        'bottom', "$label: clone reaches the same leaf" );
    is( $shared, 0, "$label: clone shares no node with the original" );

    my @rc_after = map { B::svref_2object($_)->REFCNT } @nodes;
    is_deeply( \@rc_after, \@rc_before,
        "$label: cloning leaves original refcounts untouched" );

    # Isolation at the bottom of the chain.
    if   ($is_hash) { $node->{leaf} = 'mutated' }
    else            { $node->[1]    = 'mutated' }
    is( $is_hash ? $nodes[-1]{leaf} : $nodes[-1][1],
        'bottom', "$label: mutating the clone's leaf leaves the original intact" );

    undef $node;
    undef @clone_nodes;
    undef $clone;
    is_deeply( [ map { B::svref_2object($_)->REFCNT } @nodes ],
        \@rc_before, "$label: freeing the clone restores original refcounts" );

    return;
}

check_seed($_) for @SEEDS;
check_deep_chain($_) for qw(HASH ARRAY);

done_testing;
