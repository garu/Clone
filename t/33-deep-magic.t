#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Clone qw(clone);
use Scalar::Util qw(refaddr);

# Magic cloning past MAX_DEPTH.
#
# The iterative cloner (used once rdepth exceeds MAX_DEPTH) built bare
# newHV()/newAV() shells and copied leaf scalars with a plain newSVsv(),
# never calling clone_magic().  Everything the recursive path does with
# magic was therefore silently dropped below the depth limit:
#
#   - a tied hash/array/scalar came out as a plain untied copy
#   - a tied array was *filled from its own tie*, so the clone's elements
#     were the original array's LV proxies: writing the clone wrote
#     through to the original
#   - PERL_MAGIC_utf8 (and any other scalar magic) was lost
#   - COW sharing was lost (newSVsv bypassed the SvIsCOW branch)
#
# Tie packages are defined inline rather than reusing t/tied.pl so the
# assertions do not depend on that file's global FETCH counters.

{
    package KoanTieHash;
    sub TIEHASH  { bless {}, shift }
    sub FETCH    { $_[0]->{ $_[1] } }
    sub STORE    { $_[0]->{ $_[1] } = $_[2] }
    sub FIRSTKEY { my $s = shift; scalar keys %$s; each %$s }
    sub NEXTKEY  { each %{ $_[0] } }
}

{
    package KoanTieArray;
    sub TIEARRAY  { bless [], shift }
    sub FETCH     { $_[0]->[ $_[1] ] }
    sub STORE     { $_[0]->[ $_[1] ] = $_[2] }
    sub FETCHSIZE { scalar @{ $_[0] } }
}

{
    package KoanTieScalar;
    sub TIESCALAR { my $v; bless \$v, shift }
    sub FETCH     { ${ $_[0] } }
    sub STORE     { ${ $_[0] } = $_[1] }
}

# Platform-adaptive depth: MAX_DEPTH is 2000 on Windows/Cygwin, 4000
# elsewhere, and each hash nesting level costs ~2 rdepth (RV + HV).
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

# --- Tied hash past MAX_DEPTH ---
{
    tie my %th, 'KoanTieHash';
    $th{k} = 'tied-value';

    my @warnings;
    my $cloned = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        clone( wrap( { h => \%th } ) );
    };
    my $leaf = descend($cloned);

    isa_ok( tied( %{ $leaf->{h} } ), 'KoanTieHash',
        'deep tied hash keeps its tie' );
    is( $leaf->{h}{k}, 'tied-value',
        'value readable through the cloned tie' );
    isnt( refaddr( tied( %{ $leaf->{h} } ) ), refaddr( tied %th ),
        'tie object was cloned, not shared' );
    is( scalar @warnings, 0, 'no depth-limit warning for a deep tied hash' )
        or diag("Warnings: @warnings");

    # Writing the clone must not reach the original's tie object.
    $leaf->{h}{k} = 'mutated';
    is( $th{k}, 'tied-value', 'original tied hash unaffected by clone write' );
}

# --- Tied array past MAX_DEPTH ---
{
    tie my @ta, 'KoanTieArray';
    $ta[0] = 'tied-elem';

    my @warnings;
    my $cloned = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        clone( wrap( { a => \@ta } ) );
    };
    my $leaf = descend($cloned);

    isa_ok( tied( @{ $leaf->{a} } ), 'KoanTieArray',
        'deep tied array keeps its tie' );
    is( $leaf->{a}[0], 'tied-elem', 'element readable through the cloned tie' );
    is( scalar @warnings, 0, 'no depth-limit warning for a deep tied array' )
        or diag("Warnings: @warnings");

    # The regression: the clone's slot used to be the original array's LV
    # proxy, so this write went straight through to @ta.
    $leaf->{a}[0] = 'mutated';
    is( $ta[0], 'tied-elem', 'original tied array unaffected by clone write' );
}

# --- Tied scalar past MAX_DEPTH (reached through a reference) ---
{
    tie my $ts, 'KoanTieScalar';
    $ts = 'tied-scalar';

    my @warnings;
    my $cloned = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        clone( wrap( { s => \$ts } ) );
    };
    my $leaf = descend($cloned);

    isa_ok( tied( ${ $leaf->{s} } ), 'KoanTieScalar',
        'deep tied scalar keeps its tie' );
    is( ${ $leaf->{s} }, 'tied-scalar',
        'value readable through the cloned scalar tie' );
    is( scalar @warnings, 0, 'no depth-limit warning for a deep tied scalar' )
        or diag("Warnings: @warnings");

    ${ $leaf->{s} } = 'mutated';
    is( $ts, 'tied-scalar', 'original tied scalar unaffected by clone write' );

    # KoanTieScalar's object is `bless \$v` -- a reference to a plain
    # scalar, not to a container.  Cloning that mg_obj inline re-entered
    # the RV-chain walk that was busy cloning \$ts and overwrote its
    # chain[] entries, so the slot came back holding the cloned *tie
    # object* (blessed, and pointing at its own tied scalar) instead of a
    # reference to the cloned tied scalar.  Reads still answered
    # 'tied-scalar' only because perl disables magic while FETCH runs.
    is( ref( $leaf->{s} ), 'SCALAR',
        'deep slot holds a plain scalar ref, not the cloned tie object' );
    isnt( refaddr( tied ${ $leaf->{s} } ), refaddr( $leaf->{s} ),
        'cloned tie object is not the slot value itself' );
    isnt( refaddr( tied ${ $leaf->{s} } ), refaddr( tied $ts ),
        'scalar tie object was cloned, not shared' );
}

# --- One reference to a tied scalar in two slots past MAX_DEPTH ---
# rv_clone_chain registers a placeholder in hseen for every link it walks
# and retargets it during the rebuild.  When the leaf's magic re-entered
# that walk, the rebuild retargeted the *inner* walk's placeholder instead,
# leaving the one registered for the reference itself untouched -- so a
# second slot holding the same reference resolved to the wrong SV.
{
    tie my $ts, 'KoanTieScalar';
    $ts = 'shared-tied';
    my $r = \$ts;

    my $cloned = do {
        local $SIG{__WARN__} = sub { };
        clone( wrap( { a => $r, b => $r } ) );
    };
    my $leaf = descend($cloned);

    is( ref( $leaf->{a} ), 'SCALAR', 'shared slot is a plain scalar ref' );
    is( refaddr( $leaf->{a} ), refaddr( $leaf->{b} ),
        'both slots share one clone of the reference' );
    isa_ok( tied( ${ $leaf->{b} } ), 'KoanTieScalar',
        'shared deep tied scalar keeps its tie' );
    is( ${ $leaf->{b} }, 'shared-tied',
        'value readable through the second slot' );
}

# --- Scalar magic (PERL_MAGIC_utf8) past MAX_DEPTH ---
SKIP: {
    eval { require B; 1 } or skip "B not available", 2;

    my $content = "a\r\n";
    utf8::upgrade($content);
    my $ignored = index( $content, "\n" );    # sets PERL_MAGIC_utf8 ('w')

    sub magic_type {
        my $obj = B::svref_2object( $_[0] );
        my $mg  = $obj->can('MAGIC') ? $obj->MAGIC : undef;
        return $mg ? $mg->TYPE : 'none';
    }

    # Positive control: without this the assertion below could pass on a
    # perl where index() never set the cache magic in the first place.
    is( magic_type( \$content ), 'w', 'source scalar carries utf8 magic' );

    my $cloned = do {
        local $SIG{__WARN__} = sub { };
        clone( wrap( { viaref => \$content } ) );
    };
    my $leaf = descend($cloned);

    is( magic_type( $leaf->{viaref} ), 'w',
        'utf8 magic preserved on a deep leaf scalar' );
}

# --- COW sharing past MAX_DEPTH ---
SKIP: {
    eval { require B::COW; B::COW->import(qw(is_cow cowrefcnt)); 1 }
        or skip "B::COW not available", 2;
    skip "perl without COW support", 2 unless B::COW::can_cow();

    my $str  = "a string long enough to be worth sharing";
    my $deep = wrap( { s => $str } );

    # Measured after building the structure: the leaf hash holds its own
    # SV sharing the same buffer, so the source refcount is already > 1.
    my $before = cowrefcnt($str);

    my $cloned = do {
        local $SIG{__WARN__} = sub { };
        clone($deep);
    };
    my $leaf = descend($cloned);

    ok( is_cow( $leaf->{s} ), 'deep leaf PV is still COW after cloning' );
    is( cowrefcnt( $leaf->{s} ), $before + 1,
        'deep leaf PV shares the source buffer (cowrefcnt bumped)' );
}

done_testing;
