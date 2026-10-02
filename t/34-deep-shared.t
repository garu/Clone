#!/usr/bin/perl

# threads::shared data nested past MAX_DEPTH.
#
# Shallow clones of shared structures produce plain unshared deep copies
# (GH #18, t/16-threads-shared.t).  The iterative cloner used below the
# depth limit had none of that handling:
#
#   - a shared array's elements are LV proxies into the shared backing
#     store.  sv_clone() shared any PVLV past MAX_DEPTH (with a
#     depth-limit warning), so the clone's slots *were* the original's
#     proxies: writing the clone wrote through to the shared array.
#   - a shared hash/scalar lost nothing observable, but is covered here
#     so the whole shape is pinned down.
#
# NOTE: uses bare blocks instead of subtest to avoid Test2::API::Context
# global destruction warnings on older Perls (GH #78).

use strict;
use warnings;
use Test::More;

# threads must be loaded before anything else
BEGIN {
    my $has_threads = eval {
        require Config;
        $Config::Config{useithreads};
    };

    unless ($has_threads) {
        plan skip_all => 'Perl not compiled with thread support (useithreads)';
        exit 0;
    }

    eval { require threads };
    if ($@) {
        plan skip_all => "threads module not available: $@";
        exit 0;
    }

    eval { require threads::shared };
    if ($@) {
        plan skip_all => "threads::shared module not available: $@";
        exit 0;
    }
}

use threads;
use threads::shared;
use Clone qw(clone);

my $is_limited = ( $^O eq 'MSWin32' || $^O eq 'cygwin' );
my $depth      = $is_limited ? 1200 : 2200;

sub wrap {
    my ($leaf) = @_;
    $leaf = { inner => $leaf } for 1 .. $depth;
    return $leaf;
}

sub descend {
    my ($top) = @_;
    $top = $top->{inner} for 1 .. $depth;
    return $top;
}

my @warnings;
my $shared_hash   = shared_clone( { k => 'shared-value' } );
my $shared_array  = shared_clone( [ 'shared-elem', 'second' ] );
my $shared_scalar = shared_clone('shared-scalar');

my $cloned = do {
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    clone(
        wrap(
            {   h => $shared_hash,
                a => $shared_array,
                s => \$shared_scalar,
            }
        )
    );
};
my $leaf = descend($cloned);

# --- Values survive the trip through the tie ---
is( $leaf->{h}{k},    'shared-value',  'deep shared hash value cloned' );
is( $leaf->{a}[0],    'shared-elem',   'deep shared array element cloned' );
is( $leaf->{a}[1],    'second',        'deep shared array element 1 cloned' );
is( ${ $leaf->{s} },  'shared-scalar', 'deep shared scalar cloned' );

# --- The clone is a plain, unshared structure ---
ok( !defined threads::shared::is_shared( $leaf->{h} ),
    'cloned deep shared hash is not shared' );
ok( !defined threads::shared::is_shared( $leaf->{a} ),
    'cloned deep shared array is not shared' );
ok( !defined threads::shared::is_shared( ${ $leaf->{s} } ),
    'cloned deep shared scalar is not shared' );

# --- The regression: writes to the clone must not reach shared storage ---
$leaf->{h}{k}   = 'mutated';
$leaf->{a}[0]   = 'mutated';
${ $leaf->{s} } = 'mutated';

is( $shared_hash->{k}, 'shared-value',
    'original shared hash unaffected by clone write' );
is( $shared_array->[0], 'shared-elem',
    'original shared array unaffected by clone write' );
is( $shared_scalar, 'shared-scalar',
    'original shared scalar unaffected by clone write' );

is( scalar @warnings, 0,
    'no depth-limit warning for deep shared structures' )
    or diag("Warnings: @warnings");

done_testing;
