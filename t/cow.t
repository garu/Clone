#!perl

use strict;
use warnings;

use Test::More;    # we should consider moving to Test2...

use Clone 'clone';
use B::COW qw{:all};

if ( !can_cow() ) {
    plan skip_all => 'this test is only designed to work on Perl Versions supporting COW';
}
else {
    plan tests => 42;
}

{
    note "Simple SvPV";

    my $str = "abcdef";
    ok is_cow($str);
    is cowrefcnt($str), 1;

    my $clone = clone($str);
    ok is_cow($clone);
    is cowrefcnt($str),   2, q[the $str PV cowrefcnt is now at 2];
    is cowrefcnt($clone), 2, q[the $clone is sharing the same PV];
}

{
    note "COW SvPV used in Array";

    my $str = "abcdef";
    ok is_cow($str);
    is cowrefcnt($str), 1;

    my @a;
    push @a, $str for 1 .. 10;

    is cowrefcnt($str), 11;
    is cowrefcnt( $a[0] ),  11;
    is cowrefcnt( $a[-1] ), 11;

    my $clone_array = clone( \@a );

    is cowrefcnt($str), 21;
    is cowrefcnt( $a[-1] ), 21;
    is cowrefcnt( $clone_array->[-1] ), 21;
}

{
    note "COW SvPV used in Hashes";

    my $a_string = "something";

    my $h = {
        'a' .. 'd',
        k1        => $a_string,
        k2        => $a_string,
        $a_string => $a_string,
    };

    is cowrefcnt($a_string), 4, 'a_string PV is used 3 times';

    my $clone_h = clone($h);
    is cowrefcnt($a_string), 7, 'a_string PV is now used 5 times after clone';

    foreach my $k ( sort keys %$h ) {

        ok is_cow($k), "key is cow...";
        is cowrefcnt($k), 0, "cowrefcnt on key $k is 0...";

        my $clone_key = clone($k);
      TODO: {
            local $TODO = "losing the COW status when cowrefcnt=0...";
            ok !is_cow($clone_key), "clone_key lost its cow value (LEN=0)";
            is cowrefcnt($clone_key), undef, "clone_key has lost cow...";
        }
        is $clone_key, $k, " clone_key eq k";
    }

    my @keys       = sort keys %$h;
    my $clone_keys = clone( \@keys );
    is scalar @$clone_keys, scalar @keys, "clone keys array";

}

{
    # reproducing SEGV described as part of GH #10 - https://github.com/garu/Clone/issues/10
    note "hash with subs...";

    my $hash = {
        'caption' => {
            'db'      => 1,
            'default' => 1,
            'i18n'    => 1
        },
        'fix_db' => {
            'db'  => 1,
            'get' => sub { 1 }
        },
    };

    my $clone = clone($hash);
    ok ref $clone, "clone success - no SEGV";
}
