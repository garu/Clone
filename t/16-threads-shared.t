#!/usr/bin/perl

# Test cloning of threads::shared data structures
# See: https://github.com/garu/Clone/issues/18
#      (migrated from rt.cpan.org #93821)
#
# threads::shared uses tie magic to synchronize shared data.
# Clone copies the tie binding, producing a clone that tries
# to FETCH via threads::shared::tie — which crashes because
# the cloned tie object is not a real shared variable.
#
# Expected behavior: either Clone strips the tie (producing
# a plain unshared copy) or it handles the magic correctly.
# Current behavior: accessing the clone dies with
#   "Can't locate object method "FETCH" via package "threads::shared::tie""

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

# All tests are marked TODO: this is a known bug (GH #18).
# The tests document the expected behavior once the bug is fixed.

# --- Test 1: Clone a shared hash ---

subtest 'clone a shared hash (GH #18 core reproduction)' => sub {
    my $shared = shared_clone({ foo => 100, bar => 200 });

    # Verify setup: original works fine
    is($shared->{foo}, 100, 'original shared hash accessible');
    is($shared->{bar}, 200, 'original shared hash bar accessible');

    # This is the bug: clone succeeds but accessing the clone crashes
    my $cloned = eval { clone($shared) };
    ok(!$@, 'clone() on shared hash does not die')
        or diag("clone() died: $@");

    SKIP: {
        skip 'clone() failed', 3 unless defined $cloned;

        is(ref($cloned), 'HASH', 'cloned result is a hash reference');

        TODO: {
            local $TODO = 'GH #18: threads::shared tie magic not handled';

            # This is where the crash happens per the bug report:
            # "Can't locate object method "FETCH" via package "threads::shared::tie""
            my $val = eval { $cloned->{foo} };
            ok(!$@, 'accessing cloned hash does not die')
                or diag("access died: $@");

            is($val, 100, 'cloned hash value is correct');
        }
    }
};

# --- Test 2: Clone a shared array ---

subtest 'clone a shared array' => sub {
    my $shared = shared_clone([10, 20, 30]);

    is($shared->[0], 10, 'original shared array accessible');

    my $cloned = eval { clone($shared) };
    ok(!$@, 'clone() on shared array does not die')
        or diag("clone() died: $@");

    SKIP: {
        skip 'clone() failed', 2 unless defined $cloned;

        is(ref($cloned), 'ARRAY', 'cloned result is an array reference');

        TODO: {
            local $TODO = 'GH #18: threads::shared tie magic not handled';

            my $val = eval { $cloned->[0] };
            ok(!$@, 'accessing cloned array does not die')
                or diag("access died: $@");
        }
    }
};

# --- Test 3: Clone a shared scalar ---

subtest 'clone a shared scalar ref' => sub {
    my $val :shared = 42;

    is($val, 42, 'original shared scalar accessible');

    my $cloned = eval { clone(\$val) };
    ok(!$@, 'clone() on shared scalar ref does not die')
        or diag("clone() died: $@");

    SKIP: {
        skip 'clone() failed', 1 unless defined $cloned;

        TODO: {
            local $TODO = 'GH #18: threads::shared tie magic not handled';

            my $got = eval { $$cloned };
            ok(!$@, 'dereferencing cloned scalar does not die')
                or diag("deref died: $@");
        }
    }
};

# --- Test 4: Clone a nested shared structure ---

subtest 'clone a nested shared structure' => sub {
    my $shared = shared_clone({
        name   => 'test',
        values => [1, 2, 3],
        nested => { a => 'deep' },
    });

    is($shared->{name}, 'test', 'original nested shared accessible');

    my $cloned = eval { clone($shared) };
    ok(!$@, 'clone() on nested shared structure does not die')
        or diag("clone() died: $@");

    SKIP: {
        skip 'clone() failed', 3 unless defined $cloned;

        TODO: {
            local $TODO = 'GH #18: threads::shared tie magic not handled';

            my $name = eval { $cloned->{name} };
            ok(!$@, 'top-level access does not die')
                or diag("access died: $@");

            my $arr = eval { $cloned->{values}[1] };
            ok(!$@, 'nested array access does not die')
                or diag("access died: $@");

            my $deep = eval { $cloned->{nested}{a} };
            ok(!$@, 'deeply nested access does not die')
                or diag("access died: $@");
        }
    }
};

# --- Test 5: Clone in a thread context ---

subtest 'clone shared data inside a thread' => sub {
    my $shared = shared_clone({ key => 'value' });

    my $thr = threads->create(sub {
        my $cloned = eval { clone($shared) };
        return { ok => !$@, error => $@ // '' };
    });

    my $result = $thr->join();

    TODO: {
        local $TODO = 'GH #18: threads::shared tie magic not handled';

        ok($result->{ok}, 'clone() inside thread does not die')
            or diag("thread clone died: $result->{error}");
    }
};

done_testing();
