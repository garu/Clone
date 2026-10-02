#!/usr/bin/perl
# Clone::MAX_DEPTH() exposes the compiled-in recursion limit so tests
# stop hardcoding the platform defaults (2000 / 4000) and keep working
# when the limit is overridden with -DMAX_DEPTH at build time.

use strict;
use warnings;
use Test::More;
use Clone 'clone';

my $max = Clone::MAX_DEPTH();

like($max, qr/^\d+$/, 'Clone::MAX_DEPTH() returns a non-negative integer');
is(Clone::MAX_DEPTH(), $max, 'the value is stable across calls');

# The reported value must be the one the XS code actually enforces --
# a stale or mismatched constant would make every test that derives a
# depth from it silently test the wrong code path.  The depth-limit
# warning quotes the limit verbatim, which ties the two together.
{
    # A bare glob leaf -- non-clonable and not behind a reference, which
    # is the case the depth-limit warning covers.
    my $levels = $max + 10;
    my $deep   = [];
    my $curr   = $deep;
    for (1 .. $levels) {
        my $next = [];
        $curr->[0] = $next;
        $curr = $next;
    }
    $curr->[1] = *STDOUT;

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        clone($deep);
    }

    ok(scalar(@warnings), 'a glob leaf past the limit emits a warning')
        or diag("no warning raised at nesting depth $levels");
    like($warnings[0] || '', qr/depth limit \(\Q$max\E\) exceeded/,
         'the warning quotes the value Clone::MAX_DEPTH() reports');
}

done_testing;
