#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Clone qw(clone);
use Scalar::Util qw(refaddr);

# Element-store parity between the recursive and the iterative cloners.
#
# Clone has two independent element-store sites per container type: the
# recursive path (hv_clone / av_clone) and the past-MAX_DEPTH work queue
# (clone_drain).  Both must store elements with identical semantics --
# UTF-8 key negation for hv_store, embedded-NUL-safe key lengths,
# array holes left as holes, the fill mark set to the source's, and
# shared referents cloned once.
#
# The two loops used to be copy-pasted, and had already drifted.  These
# tests pin the observable behaviour down on BOTH paths so a future fix
# applied to only one of them fails here.

# Platform-adaptive depth: MAX_DEPTH is 2000 on Windows/Cygwin, 4000
# elsewhere.  Each nesting level costs ~2 rdepth (RV + container), so we
# need > MAX_DEPTH/2 levels to reach the iterative path.
my $is_limited = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $DEPTH      = $is_limited ? 1200 : 2200;

# Set by clone_deep() and asserted at the end of the file: proof that
# the "iterative" arm of every check below really crossed MAX_DEPTH, so
# raising MAX_DEPTH cannot silently turn these into a second run of the
# recursive checks.
my $crossed_max_depth = 0;

# Wrap $payload $DEPTH levels deep, clone, and dig back down to the
# clone of $payload.  The returned value went through the iterative
# path; cloning $payload directly goes through the recursive one.
sub clone_deep {
    my ($payload) = @_;

    # A bare glob (not a glob ref) cannot be deep-copied past MAX_DEPTH,
    # and the iterative path -- only the iterative path -- warns when it
    # has to share one instead.  Carrying one next to the payload makes
    # each deep clone self-certifying.
    my $deep = { payload => $payload, sentinel => *STDOUT };
    $deep = { inner => $deep } for 1 .. $DEPTH;

    my @warnings;
    my $cloned = eval {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        clone($deep);
    };
    die "deep clone failed: $@" if $@ || !defined $cloned;

    $crossed_max_depth = 1
        if grep { /depth limit \(\d+\) exceeded/ } @warnings;

    $cloned = $cloned->{inner} for 1 .. $DEPTH;
    return $cloned->{payload};
}

# Run the same checks against the recursive clone and the iterative one.
sub both_paths {
    my ($payload, $checks) = @_;

    $checks->(clone($payload), 'recursive');
    $checks->(clone_deep($payload), 'iterative');
}

# --- Hash keys: UTF-8, embedded NUL, empty string ---
{
    my $utf8_key = "key-\x{263a}-\x{1f600}";
    my $nul_key  = "a\0b";

    my %src = (
        $utf8_key  => 'smiley',
        $nul_key   => 'embedded nul',
        ''         => 'empty key',
        'plain'    => 'ascii',
    );
    # Enough keys that hv_ksplit pre-sizing and bucket splitting kick in.
    $src{"bulk-$_"} = $_ for 1 .. 64;

    both_paths(\%src, sub {
        my ($c, $path) = @_;

        is(scalar keys %$c, scalar keys %src, "$path: key count preserved");
        is_deeply([sort keys %$c], [sort keys %src], "$path: key set preserved");

        is($c->{$utf8_key}, 'smiley', "$path: UTF-8 key round-trips");
        ok(exists $c->{$utf8_key}, "$path: UTF-8 key exists");
        ok(utf8::is_utf8((grep { /\x{263a}/ } keys %$c)[0] || ''),
           "$path: UTF-8 key keeps its UTF-8 flag");

        is($c->{$nul_key}, 'embedded nul', "$path: embedded-NUL key round-trips");
        ok(!exists $c->{"a"}, "$path: embedded-NUL key not truncated at the NUL");

        is($c->{''}, 'empty key', "$path: empty-string key round-trips");
        is($c->{'bulk-64'}, 64, "$path: bulk key round-trips");
    });
}

# --- Array: holes stay holes, fill mark follows the source ---
{
    my @src;
    $src[0] = 'zero';
    $src[3] = 'three';
    $src[6] = undef;    # assigned undef: exists, but false
    $src[9] = 'nine';
    $#src = 12;         # trailing holes past the last assigned element

    both_paths(\@src, sub {
        my ($c, $path) = @_;

        is($#$c, $#src, "$path: fill mark matches the source");
        is($c->[0], 'zero',  "$path: element 0 copied");
        is($c->[3], 'three', "$path: element 3 copied");
        is($c->[9], 'nine',  "$path: element 9 copied");

        ok(!exists $c->[1],  "$path: hole at 1 stays a hole");
        ok(!exists $c->[2],  "$path: hole at 2 stays a hole");
        ok(!exists $c->[12], "$path: trailing hole stays a hole");

        ok(exists $c->[6], "$path: assigned undef still exists");
        ok(!defined $c->[6], "$path: assigned undef is undef");
    });
}

# --- Shared referents are cloned once, not duplicated ---
{
    my $shared = { tag => 'shared' };
    my $src    = { a => $shared, b => $shared, list => [ $shared, $shared ] };

    both_paths($src, sub {
        my ($c, $path) = @_;

        is(refaddr($c->{a}), refaddr($c->{b}),
           "$path: shared hash value cloned once");
        is(refaddr($c->{list}[0]), refaddr($c->{list}[1]),
           "$path: shared array element cloned once");
        is(refaddr($c->{list}[0]), refaddr($c->{a}),
           "$path: sharing holds across container types");
        isnt(refaddr($c->{a}), refaddr($shared),
             "$path: the shared referent is a clone, not the original");
        is($c->{a}{tag}, 'shared', "$path: shared referent contents copied");
    });
}

# --- Blessed containers keep their package on both paths ---
{
    my $src = {
        obj  => bless({ n => 1 }, 'Clone::Test::Elem'),
        list => bless([ 1, 2, 3 ], 'Clone::Test::Elem'),
    };

    both_paths($src, sub {
        my ($c, $path) = @_;

        is(ref $c->{obj},  'Clone::Test::Elem', "$path: blessed hash keeps package");
        is(ref $c->{list}, 'Clone::Test::Elem', "$path: blessed array keeps package");
        is($c->{obj}{n}, 1, "$path: blessed hash contents copied");
        is_deeply($c->{list}, [ 1, 2, 3 ], "$path: blessed array contents copied");
    });
}

# --- Empty containers clone cleanly on both paths ---
{
    both_paths({ h => {}, a => [] }, sub {
        my ($c, $path) = @_;

        is_deeply($c->{h}, {}, "$path: empty hash cloned");
        is_deeply($c->{a}, [], "$path: empty array cloned");
        is($#{ $c->{a} }, -1, "$path: empty array fill mark is -1");
    });
}

# If this fails, every "iterative:" assertion above silently re-ran the
# recursive path and proved nothing: raise $DEPTH past MAX_DEPTH/2.
ok($crossed_max_depth,
   "the iterative arm crossed MAX_DEPTH (nested $DEPTH levels)");

done_testing();
