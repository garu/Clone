#!/usr/bin/perl -w

# PERL_MAGIC_utf8 ('w') magic carries two unrelated values:
#
#   mg_len  - the string's cached character length (>= 0), or -1 when the
#             length is not known yet
#   mg_ptr  - a fixed-size byte<->char offset cache of
#             PERL_MAGIC_UTF8_CACHESIZE * 2 STRLENs, or NULL
#
# mg_len is NOT the length of mg_ptr.  Clone used to hand both to
# sv_magic() as name/namlen whenever mg_len >= 0, so sv_magicext()'s
# savepvn() read mg_len bytes out of the 32-byte offset cache -- a heap
# over-read that copied adjacent heap into the clone's magic and
# segfaulted once the string got large enough (SIGBUS at ~12 MB here).
#
# The over-read itself is only directly visible under a memory checker:
#
#   perl Makefile.PL OPTIMIZE="-O0 -g -fsanitize=address" \
#       LDDLFLAGS="$(perl -V:lddlflags) -fsanitize=address" && make
#   ASAN_OPTIONS=detect_leaks=0 \
#   DYLD_INSERT_LIBRARIES=$(clang -print-file-name=libclang_rt.asan_osx_dynamic.dylib) \
#       perl -Mblib t/35-utf8-magic-cache.t
#
# so the large-string case below is what makes this file fail on its own:
# a 12 MB over-read walks off the heap.
#
# Everything here works through the *reference* returned by clone(), never
# through a copy of the string: assigning the cloned string to a plain
# scalar goes through sv_setsv(), which does not carry magic over, so the
# assertions would run against a magic-free SV and the cloned magic would
# never be exercised at all.  mg_len is read back directly with B so the
# new branch has at least one assertion that fails if it stops running;
# mg_ptr's contents have no Perl-visible effect (the offset cache is a
# pure accelerator), so only ASAN and the large-string case cover it.

use strict;
use warnings;
use Test::More tests => 22;
use B ();
use Clone qw(clone);

# mg_len of the 'w' magic on the SV behind $ref, or undef if there is
# none.  B::MAGIC::PTR deliberately refuses PERL_MAGIC_utf8 (it would
# perform the very over-read this file is about), so mg_ptr stays
# unreadable from Perl.
sub utf8_magic_len {
    my ($ref) = @_;
    my $sv = B::svref_2object($ref);
    return undef unless $sv->can('MAGIC');
    my $mg = $sv->MAGIC;
    while ( ref($mg) eq 'B::MAGIC' ) {
        return $mg->LENGTH if $mg->TYPE eq 'w';
        $mg = $mg->MOREMAGIC;
    }
    return undef;
}

# Build a UTF-8 string carrying both halves of the utf8 magic:
# length() populates the character-length cache (mg_len), the match and
# substr() populate the byte<->char offset cache (mg_ptr).
sub utf8_with_full_cache {
    my ($repeat) = @_;
    my $s = "\x{100}" . ( "abcdef" x $repeat );
    my $len = length $s;
    $s =~ /def/g;
    my $mid = substr( $s, int( $len / 2 ), 3 );
    return \$s;
}

# ---------------------------------------------------------------------
# cached character length + offset cache (mg_len >= 0, mg_ptr != NULL)
# ---------------------------------------------------------------------
{
    my $sr    = utf8_with_full_cache(400);
    my $fresh = "\x{100}" . ( "abcdef" x 400 );
    my $cr    = clone($sr);

    my $src_len = utf8_magic_len($sr);
    ok( defined($src_len) && $src_len >= 0,
        'source carries utf8 magic with a cached character length' );
    is( utf8_magic_len($cr), $src_len,
        'clone carries utf8 magic with the same cached length' );

    is( length($$cr), length($fresh), 'clone has the right character length' );
    ok( $$cr eq $fresh, 'clone has the right contents' );
    ok( utf8::is_utf8($$cr), 'clone keeps its UTF-8 flag' );

    # Exercise the offset cache on the clone from both ends: a corrupted
    # cache would send sv_pos_u2b() to the wrong byte offset.
    for my $off ( 0, 1, 7, 1200, 2398 ) {
        is( substr( $$cr, $off, 3 ), substr( $fresh, $off, 3 ),
            "substr at char offset $off" );
    }

    # The clone must own its cache, not share the source's.
    pos($$sr) = 0;
    substr( $$sr, 0, 6 ) = "XYZABC";
    ok( $$cr eq $fresh, 'clone unaffected by later writes to the source' );
}

# ---------------------------------------------------------------------
# offset cache with no cached length (mg_len == -1, mg_ptr != NULL)
# ---------------------------------------------------------------------
{
    my $s = "\x{100}" . ( "abcdef" x 400 );
    $s =~ /def/g;
    pos($s);            # offset cache only, length never requested

    my $fresh = "\x{100}" . ( "abcdef" x 400 );
    my $cr    = clone( \$s );

    is( utf8_magic_len($cr), utf8_magic_len( \$s ),
        'uncached length carried over verbatim' );
    ok( $$cr eq $fresh, 'clone of an uncached-length string has the right contents' );
    is( length($$cr), length($fresh), 'character length still correct' );
    is( substr( $$cr, 1200, 3 ), substr( $fresh, 1200, 3 ), 'offset cache usable' );
}

# ---------------------------------------------------------------------
# large string: mg_len is ~12e6, the offset cache is 32 bytes.  Reading
# mg_len bytes out of it walks off the heap.
# ---------------------------------------------------------------------
{
    my $sr = utf8_with_full_cache(2_000_000);
    my $cr = clone($sr);

    is( utf8_magic_len($cr), utf8_magic_len($sr),
        'large string: cached length carried over, not used as a buffer size' );
    is( length($$cr), length($$sr), 'large string: character length preserved' );
    ok( $$cr eq $$sr, 'large string: contents preserved' );
    is( substr( $$cr, 6_000_000, 3 ),
        substr( $$sr, 6_000_000, 3 ),
        'large string: offset cache usable on the clone' );
}

# ---------------------------------------------------------------------
# nested: utf8 magic inside a container, cloned recursively
# ---------------------------------------------------------------------
{
    my $sr   = utf8_with_full_cache(400);
    my $data = { text => $sr, list => [$sr] };
    my $c    = clone($data);

    is( utf8_magic_len( $c->{text} ), utf8_magic_len($sr),
        'utf8 magic survives cloning inside a container' );
    is( ${ $c->{text} }, $$sr, 'utf8-magic string cloned inside a hash' );
    is( ${ $c->{list}[0] }, $$sr, 'utf8-magic string cloned inside an array' );
}
