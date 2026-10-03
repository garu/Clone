#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 5;
use Clone qw(clone);

# hv_clone() and clone_fill_hv() call hv_iterinit() on the *source* hash to
# walk its keys. That is the same cursor each() uses, so cloning a hash --
# or anything that happens to contain it -- silently rewound a caller that
# was sitting in the middle of an each() loop over it. The visible symptom
# is keys being handed out twice (and, with a delete/insert in the loop
# body, potentially never terminating).

# Walk %h with each(), cloning something mid-loop, and report every key
# each() handed us. $make_arg builds the thing we pass to clone().
sub keys_seen_while_cloning {
    my ($h, $make_arg) = @_;
    my @seen;
    while (my ($k) = each %$h) {
        push @seen, $k;
        clone($make_arg->()) if @seen == 1;
        last if @seen > 20;    # guard against a runaway rewind
    }
    return \@seen;
}

my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $deep_target      = $is_limited_stack ? 2100 : 4100;

{
    my %h = map { ("k$_" => $_) } 1 .. 5;
    my $seen = keys_seen_while_cloning(\%h, sub { \%h });
    is(scalar @$seen, 5, 'cloning a hash mid-each() does not rewind its iterator');
    is_deeply([sort @$seen], [sort keys %h], 'each() still visited every key exactly once');
}

{
    # Same hash, reached as a nested value rather than the clone root.
    my %inner = (a => 1, b => 2, c => 3);
    my $outer = { payload => \%inner };
    my $seen = keys_seen_while_cloning(\%inner, sub { $outer });
    is(scalar @$seen, 3, 'cloning a structure containing the hash does not rewind it');
}

{
    # Past MAX_DEPTH clone() switches to the heap work-queue cloner, which
    # fills hashes through clone_fill_hv() -- a separate hv_iterinit() site.
    my %inner = (a => 1, b => 2, c => 3);
    my $deep  = \%inner;
    $deep = { next => $deep } for 1 .. $deep_target;

    my $seen = keys_seen_while_cloning(\%inner, sub { $deep });
    is(scalar @$seen, 3, 'iterative deep clone does not rewind a nested hash iterator');
}

{
    # The restored cursor must still be usable: finish the loop, then
    # confirm a fresh each() walk starts from scratch.
    my %h = map { ("k$_" => $_) } 1 .. 4;
    keys_seen_while_cloning(\%h, sub { \%h });
    my @fresh;
    push @fresh, $_ while defined($_ = each %h);
    is(scalar @fresh, 4, 'a later each() walk over the cloned hash is unaffected');
}
