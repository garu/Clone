#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 11;
use Clone qw(clone);

# Magic types whose mg_obj perl's sv_magic() stores *unreferenced*.
#
# regdata ('D', on @-/@+) and regdatum ('d', on their elements) do not even
# hold an SV in the mg_obj slot -- perl stores the literal character '-' or
# '+' there (0x2d / 0x2b).  Recursively cloning mg_obj therefore dereferenced
# a small integer and segfaulted.
#
# arylen ('#', on $#array) does hold an SV -- the parent AV -- but sv_magic()
# takes no reference on it, so a cloned AV could never be released and leaked
# on every clone().
#
# Both are now skipped: @-/@+ contents still come through av_len()/av_fetch()
# (their get vtable), and a cloned $#a is a plain index snapshot.

# Tests 1-5: @- and @+ (regdata magic)
{
    ok("hello world" =~ /(o)(\s)(w)/, 'regex matched');

    my $starts = clone(\@-);
    my $ends   = clone(\@+);

    is_deeply($starts, [@-], 'clone(\@-) copies the match-start offsets');
    is_deeply($ends,   [@+], 'clone(\@+) copies the match-end offsets');

    # The clone must be a detached snapshot, not a live view on the engine.
    my @before = @$starts;
    ok("zzz" =~ /(z)/, 'second regex matched');
    is_deeply($starts, \@before,
              'clone(\@-) is a snapshot, not affected by a later match');
}

# Test 6: @-/@+ nested inside a larger structure
{
    ok("abcabc" =~ /(b)(c)/, 'third regex matched');
    my $c = clone({ starts => \@-, ends => \@+, label => 'm' });
    is_deeply($c, { starts => [@-], ends => [@+], label => 'm' },
              'nested \@- / \@+ clone inside a hashref');
}

# Test 7: a single element of @- (regdatum magic) -- the mg_obj char again
{
    ok("xyz" =~ /(y)/, 'fourth regex matched');
    my $c = clone(\$-[1]);
    is($$c, 1, 'clone of a single \$-[n] copies the offset');
}

# Tests 10-11: arylen magic ('#')
{
    my @a = (1, 2, 3);
    my $c = clone(\$#a);

    is($$c, 2, 'clone(\$#a) copies the last index');

    # With arylen magic cloned, assignment went through perl's av_fill(),
    # which clamps a negative length to -1.  A plain scalar keeps the value,
    # which also proves no AV was cloned behind the clone (nothing to leak).
    $$c = -5;
    is($$c, -5, 'clone(\$#a) is a plain index snapshot, not live arylen magic');
}
