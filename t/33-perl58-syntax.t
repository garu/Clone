#!perl -w

# GH #162: t/16 and t/17 used the defined-or operator (//), which only exists
# from perl 5.10 on.  A 5.8 parser tokenizes // as the start of an empty match
# and dies with "Search pattern not terminated" at compile time.
#
# The CI matrix did not catch it.  Both thread tests exit 0 from a BEGIN block
# when $Config{useithreads} is false, and the old-perl matrix images are not
# threaded -- so the process is gone before the parser ever reaches the
# offending line.  Only a *threaded* 5.8 parses the whole file, and the only
# threaded perl in CI is the latest Strawberry build on Windows.  The failure
# therefore surfaced solely on CPAN Testers (Strawberry 5.8.9, MSWin32).
#
# Clone still supports perl 5.8, so no file shipped in this distribution may
# use 5.10+ syntax outside of a string eval.  We cannot verify that by
# compiling (we are not on 5.8, and no pragma makes a modern perl reject //),
# so this is a static check over the token stream.
#
# PPI is used rather than hand-rolled regexes because the constructs are only
# distinguishable with real tokenization: "s/^\s+//" and "split //" are not
# defined-or, "a // b" inside a string is not code, "~~" is smartmatch only
# when it has a left operand, and "$h->{say}" is a hash key.  Code inside
# eval q{...} is a single string token to PPI and so is correctly ignored --
# that is how t/29-class-objects.t tests 5.38 class syntax on old perls.
#
# This is a net for the constructs that have actually bitten us, not a full
# 5.8 compatibility checker.  Known gaps, all of which also break 5.8: sub
# signatures (PPI cannot reliably tell "sub f ($a, $b)" from a prototype),
# regex named captures, and postfix dereference (->@*).  Add them here if
# one ever escapes to CPAN Testers.
#
# PPI is not declared as a test dependency on purpose: PPI itself requires
# Clone at runtime, so making it a prereq of Clone's own suite would be a
# circular install and could pull a CPAN Clone into the tree being tested.
# So this test skips when PPI is absent -- which would make it useless in
# CI, the very gap GH #162 exposed.  The "perl 5.8 syntax guard" job in
# .github/workflows/test.yml closes that: it installs PPI on its own, with
# no Clone build to shadow, asserts PPI loaded, and runs this file alone.

use strict;
use warnings;

use version;

use Test::More;

BEGIN {
    plan skip_all => 'PPI required for this static syntax check'
      unless eval { require PPI; 1 };
}

my @FILES = sort( glob('t/*.t'), glob('t/*.pl'), glob('*.pm'), glob('*.PL') );

plan skip_all => 'must be run from the distribution root'
  unless @FILES;

# Words that introduce 5.10+ syntax when used as a keyword.
my %BAD_WORD = (
    say   => 'use print with an explicit "\n" instead',
    state => 'use a file-scoped "my" instead',
    given => 'use if/elsif instead',
    when  => 'use if/elsif instead',
);

# True when a word token is really a keyword, rather than a hash key, a
# method name, or a bareword in some other position.
sub is_keyword {
    my ($word) = @_;

    # A bareword hash key: $h{state}, $cfg->{say}.  PPI nests the key in a
    # Statement::Expression inside the Subscript, so walk up rather than
    # testing the immediate parent.
    return 0 if in_bareword_subscript($word);

    my $next = $word->snext_sibling;
    return 0 if $next && $next->isa('PPI::Token::Operator') && $next eq '=>';

    my $prev = $word->sprevious_sibling;
    return 0 if $prev && $prev->isa('PPI::Token::Operator') && $prev eq '->';

    # "sub say {...}" would be a definition, not a use of the keyword.
    return 0 if $prev && $prev->isa('PPI::Token::Word') && $prev eq 'sub';

    return 1;
}

# True when $word is the sole content of a hash subscript, i.e. a bareword
# key.  A subscript holding an expression ($h->{ foo() }) is not excluded.
sub in_bareword_subscript {
    my ($word) = @_;

    my $node = $word;
    while ( my $parent = $node->parent ) {
        if ( $parent->isa('PPI::Structure::Subscript') ) {
            my @sig = grep { $_->significant } $parent->schildren;
            return 0 if @sig != 1;
            my @inner = grep { $_->significant } $sig[0]->schildren;
            return @inner == 1 && $inner[0] == $word ? 1 : 0;
        }
        last if $parent->isa('PPI::Statement::Compound');
        $node = $parent;
    }

    return 0;
}

# "~~" is smartmatch only when it has a left operand.  Prefix "~~" is a
# double bitwise complement, which works on every perl -- and it appears
# after an operator ("= ~~$x"), after a named operator ("return ~~@a"), or
# at the start of a statement.  Only a genuine term on the left makes it
# smartmatch, so whitelist those rather than guessing at the alternatives.
sub is_smartmatch {
    my ($op) = @_;

    my $prev = $op->sprevious_sibling;
    return 0 unless $prev;

    return 1
      if $prev->isa('PPI::Token::Symbol')
      || $prev->isa('PPI::Token::Number')
      || $prev->isa('PPI::Token::Quote')
      || $prev->isa('PPI::Token::QuoteLike::Words')
      || $prev->isa('PPI::Structure::Subscript')
      || $prev->isa('PPI::Structure::List');

    return 0;
}

# "use 5.010" (or any floor above 5.8) makes 5.8 refuse to run the file.
sub bad_use_version {
    my ($statement) = @_;

    return 0 unless $statement->isa('PPI::Statement::Include');
    return 0 if $statement->type eq 'no';

    # Only a bare "use 5.010" sets a perl floor.  "use Test::More 0.88"
    # names a module, and its version has nothing to do with perl's.
    my $module = $statement->module;
    return 0 if defined $module && length $module;

    my $version = $statement->version;
    return 0 unless defined $version && length $version;

    # A floor is spelled "5.010", "v5.14", "5.8.8" or "5.010_001", and these
    # do not compare like plain numbers -- "use 5.8" asks for perl 5.800, not
    # 5.008.  version.pm applies perl's own rules; underscores mark an alpha
    # version it refuses to parse, so drop them first.
    my $numeric = $version;
    $numeric =~ tr/_//d;

    my $floor = eval { version->parse($numeric) };
    return 0 unless defined $floor;

    return $floor >= version->parse('v5.10.0') ? $version : 0;
}

for my $file (@FILES) {
    my $doc = PPI::Document->new($file);

    unless ($doc) {
        fail("$file: PPI could not parse: $PPI::Document::errstr");
        next;
    }

    $doc->index_locations;

    my @found;
    for my $token ( @{ $doc->find('PPI::Token') || [] } ) {
        my ( $label, $hint );

        if ( $token->isa('PPI::Token::Operator') ) {
            if ( $token eq '//' || $token eq '//=' ) {
                $label = "defined-or ($token)";
                $hint  = 'use "defined $x ? $x : $default" instead';
            }
            elsif ( $token eq '~~' && is_smartmatch($token) ) {
                $label = 'smartmatch (~~)';
                $hint  = 'compare explicitly instead';
            }
        }
        elsif ( $token->isa('PPI::Token::Word')
            && $BAD_WORD{ $token->content }
            && is_keyword($token) )
        {
            $label = $token->content;
            $hint  = $BAD_WORD{ $token->content };
        }

        next unless $label;

        my $line = ( $token->location || [0] )->[0];
        push @found, "line $line: $label -- $hint";
    }

    for my $statement ( @{ $doc->find('PPI::Statement::Include') || [] } ) {
        my $version = bad_use_version($statement) or next;
        my $line = ( $statement->location || [0] )->[0];
        push @found,
          "line $line: version floor ($version) -- Clone supports perl 5.8";
    }

    ok( !@found, "$file is free of perl 5.10+ syntax" )
      or diag( "$file uses syntax that does not compile on perl 5.8:\n  "
             . join( "\n  ", @found ) );
}

done_testing();
