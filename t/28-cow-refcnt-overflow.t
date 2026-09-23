use strict;
use warnings;
use Test::More;
use Clone 'clone';
use Config;

# COW (Copy-on-Write) optimization shares string buffers between
# original and clone, tracked by a per-buffer refcount (CowREFCNT).
# When CowREFCNT reaches SV_COW_REFCNT_MAX (typically 255), Clone's
# else branch runs newSVsv() which may still share the buffer, then
# resets CowREFCNT to 0 — corrupting the refcount for all sharers.
#
# This test verifies that cloning a string 260+ times (past the 255
# boundary) does not cause data corruption between original and clones.

# COW requires Perl 5.20+ and a non-debugging build
my $has_cow = defined $Config{ccflags}
           && $] >= 5.020
           && $Config{ccflags} !~ /PERL_DEBUG_READONLY_COW/;

plan skip_all => 'Copy-on-Write not available' unless $has_cow;

plan tests => 3;

# Use a string long enough to be COW-eligible (short strings may be
# inlined and bypass COW entirely).
my $original = "cow_boundary_test_" x 10;
my $expected = $original;

my @clones;
for my $i (1 .. 260) {
    push @clones, clone(\$original);
}

# Modify one clone past the boundary — this triggers sv_force_normal
# which checks CowREFCNT to decide whether to copy or modify in place.
${$clones[255]} = "MUTATED";

is($original, $expected,
   'original string unchanged after 260 COW clones + mutation');

# Check a clone created before the boundary
is(${$clones[0]}, $expected,
   'early clone unchanged after mutation past boundary');

# Check a clone created after the boundary
is(${$clones[259]}, $expected,
   'late clone unchanged after mutation past boundary');
