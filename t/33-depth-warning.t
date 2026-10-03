#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use Clone qw(clone);

# The "shared, not deep-copied" notice emitted when a non-clonable SV
# (glob, coderef, format, IO handle, ...) is reached past MAX_DEPTH.
#
# Three properties are locked in here:
#
#   accurate    -- it names the type that could not be copied and does not
#                  claim the depth limit caused the sharing.  Those types
#                  are shared at *any* depth; crossing the limit is only
#                  what makes Clone mention it.
#   deduplicated-- at most one notice per clone() call, however many
#                  non-clonable SVs the structure holds.
#   manageable  -- it lives in the 'recursion' warnings category, so
#                  `no warnings 'recursion'` silences it and
#                  `use warnings FATAL => 'recursion'` promotes it.
#                  $Clone::WARN = 0 still works as the global off switch.

my $is_limited_stack = ($^O eq 'MSWin32' || $^O eq 'cygwin');
my $max_depth_val    = $is_limited_stack ? 2000 : 4000;

# Comfortably past MAX_DEPTH: ~2 rdepth units per nesting level.
my $levels = int($max_depth_val / 2) + 100;

plan tests => 14;

# A chain of $levels nested arrays whose innermost node holds @$leaves in
# slots 1..n.  Slot 0 is the spine.
sub deep_container {
    my @leaves = @_;
    my $root = [];
    my $cur  = $root;
    for (1 .. $levels) {
        my $next = [];
        $cur->[0] = $next;
        $cur = $next;
    }
    $cur->[$_ + 1] = $leaves[$_] for 0 .. $#leaves;
    return $root;
}

# A linear chain of RVs ending at $leaf.  Returns the top RV plus a
# keepalive for the slot array.
sub deep_rv_chain {
    my ($leaf) = @_;
    my @slots;
    $slots[0] = $leaf;
    my $r = \$slots[0];
    for my $i (1 .. $max_depth_val + 1000) {
        $slots[$i] = $r;
        $r = \$slots[$i];
    }
    return ($r, \@slots);
}

sub warnings_from {
    my ($code) = @_;
    my @w;
    local $SIG{__WARN__} = sub { push @w, @_ };
    $code->();
    return @w;
}

# ---------------------------------------------------------------- accurate

{
    my @w = warnings_from(sub { clone(deep_container(*STDOUT)) });

    is(scalar @w, 1, "one notice for a glob leaf past the depth limit");
    like($w[0] || '', qr/\bGLOB\b/,
         "notice names the type that could not be copied");
    like($w[0] || '', qr/shar/i, "notice says the SV is shared");
    unlike($w[0] || '', qr/reference will be shared/,
           "notice no longer calls a bare glob a 'reference'");
}

{
    # A different non-clonable type must be reported as itself, not as a
    # generic "depth limit exceeded".
    my @w = warnings_from(sub { clone(deep_container(\&deep_container)) });
    like($w[0] || '', qr/\bCODE\b/, "coderef leaf is reported as CODE");
}

{
    # Below the limit the very same leaf is shared silently.  This is what
    # makes "the depth limit caused the sharing" a false statement.
    my $shallow = [[[ *STDOUT ]]];
    my @w = warnings_from(sub { clone($shallow) });
    is(scalar @w, 0, "a shallow glob leaf is shared with no notice at all");
}

# ----------------------------------------------------------- deduplicated

{
    my $many = deep_container((*STDOUT) x 200);
    my @w = warnings_from(sub { clone($many) });
    is(scalar @w, 1, "200 non-clonable leaves in one clone() -> one notice")
        or diag("Got " . scalar(@w) . " warnings");
}

{
    # Dedup is per clone() call, not process-wide: a second call reports
    # again.  (The flag lives in the per-call seen-hash.)
    my $d = deep_container(*STDOUT);
    my @first  = warnings_from(sub { clone($d) });
    my @second = warnings_from(sub { clone($d) });
    is(scalar @second, 1, "the next clone() call reports again (not a global latch)")
        or diag("first=" . scalar(@first) . " second=" . scalar(@second));
}

{
    # Both past-MAX_DEPTH sharing sites report: the container-element one
    # (sv_clone's type switch) and the ref-chain leaf one (rv_clone_chain).
    my ($r, $keep) = deep_rv_chain(sub { 42 });
    my @w = warnings_from(sub { clone($r) });
    is(scalar @w, 1,
       "a non-clonable leaf at the end of a deep ref chain reports too");
    like($w[0] || '', qr/\bCODE\b/, "ref-chain leaf type is named");
}

# ------------------------------------------------------------- manageable

{
    my $d = deep_container(*STDOUT);

    my @w = warnings_from(sub { no warnings 'recursion'; clone($d) });
    is(scalar @w, 0, "no warnings 'recursion' silences the notice");

    @w = warnings_from(sub { local $Clone::WARN = 0; clone($d) });
    is(scalar @w, 0, "\$Clone::WARN = 0 still silences the notice");

    my $survived = eval {
        local $SIG{__WARN__} = sub { };
        use warnings FATAL => 'recursion';
        clone($d);
        1;
    };
    ok(!$survived, "use warnings FATAL => 'recursion' promotes it to a die");
    like($@ || '', qr/cannot deep-copy/,
         "the fatal error carries the notice text");
}
