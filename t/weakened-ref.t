#!/usr/bin/perl
use strict;
use warnings;

package Parent;
sub new { bless { children => [] }, shift }

package Child;

sub new {
    my ( $class, $parent ) = @_;
    my $child = bless { parent => $parent }, $class;
    Scalar::Util::weaken( $child->{parent} );    ### this is weakened...
    push @{ $parent->{children} }, $child;
    return $child;
}

package main;

use Test::More;
use Clone qw(clone);

BEGIN {
    $| = 1;

    eval 'use Scalar::Util qw( weaken isweak );';
    if ($@) {
        plan skip_all => "cannot weaken";
        exit;
    }
    plan tests => 4;
}

my $p       = Parent->new( foo => 123, bar => 456 );
my $c       = Child->new($p);
my $c_clone = clone($c);

## debug
# note "Child:\n", explain $c;
# note "Child Cloned:\n", explain $c_clone;
# use Devel::Peek; Dump $c;
# note "==========";
# use Devel::Peek; Dump $c_clone;

ok defined $c->{parent}, 'parent defined in child';
ok defined $c_clone->{parent},, 'parent defined in cloned child';

is $c->{parent},         $p, "parent points to parent";
isnt $c_clone->{parent}, $p, "clone parent points to a cloned parent";

exit;
