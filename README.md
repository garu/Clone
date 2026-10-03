Clone - recursively copy Perl datatypes
=======================================

[![Build Status](https://github.com/garu/Clone/actions/workflows/test.yml/badge.svg)](https://github.com/garu/Clone/actions/workflows/test.yml)
[![CPAN version](https://badge.fury.io/pl/Clone.svg)](https://metacpan.org/pod/Clone)

## Synopsis

```perl
use Clone 'clone';

my $data = {
   set => [ 1 .. 50 ],
   foo => {
       answer => 42,
       object => SomeObject->new,
   },
};

my $cloned_data = clone($data);

$cloned_data->{foo}{answer} = 1;
print $cloned_data->{foo}{answer};  # '1'
print $data->{foo}{answer};         # '42'
```

You can also add it to your class:

```perl
package Foo;
use parent 'Clone';
sub new { bless {}, shift }

package main;

my $obj = Foo->new;
my $copy = $obj->clone;
```

## Description

This module provides a `clone()` method which makes recursive
copies of nested hash, array, scalar and reference types,
including tied variables and objects.

`clone()` takes a scalar argument and duplicates it. To duplicate lists,
arrays or hashes, pass them in by reference, e.g.

```perl
my $copy = clone (\@array);

# or

my %copy = %{ clone (\%hash) };
```

## Installation

From CPAN:

```bash
    cpanm Clone
```

From source:

```bash
    perl Makefile.PL
    make
    make test
    make install
```

## Examples

### Cloning Blessed Objects

```perl
    package Person;
    sub new {
        my ($class, $name) = @_;
        bless { name => $name, friends => [] }, $class;
    }

    package main;
    use Clone 'clone';

    my $person = Person->new('Alice');
    my $clone = clone($person);

    # $clone is a separate object with the same data
    push @{$person->{friends}}, 'Bob';
    print scalar @{$clone->{friends}};  # 0
```

### Handling Circular References

Clone properly handles circular references, preventing infinite loops:

```perl
    my $a = { name => 'A' };
    my $b = { name => 'B', ref => $a };
    $a->{ref} = $b;  # circular reference

    my $clone = clone($a);
    # Circular structure is preserved in the clone
```

### Cloning Weakened References

```perl
    use Scalar::Util 'weaken';

    my $obj = { data => 'important' };
    my $container = { strong => $obj, weak => $obj };
    weaken($container->{weak});

    my $clone = clone($container);
    # Both strong and weak references are preserved correctly
```

### Cloning Tied Variables

```perl
    use Tie::Hash;
    tie my %hash, 'Tie::StdHash';
    %hash = (a => 1, b => 2);

    my $clone = clone(\%hash);
    # The tied behavior is preserved in the clone
```

## Limitations

* **Maximum Recursion Depth**: Clone uses a recursion depth counter to prevent stack overflow. The default limit is 4000 rdepth units on Linux/macOS and 2000 on Windows/Cygwin. Each nesting level consumes approximately 2 rdepth units, so the effective limits are roughly 2000 nesting levels on Linux/macOS and 1000 on Windows/Cygwin. Exceeding the limit triggers an iterative fallback that still deep-copies arrays, hashes and all reference types (including deeply nested scalar references); it drives nested containers through a heap-allocated work queue, so its C stack usage does not grow with nesting depth. Only non-clonable types (globs, code refs, formats, IO handles) are shared past the limit, as they are at any depth. The limit is a compile-time constant and cannot be raised at runtime — `clone($data, $depth)` does something else entirely, see the next bullet.

* **The depth argument**: `clone()`'s optional second argument is a *cap* on how far the copy goes, not a recursion-limit override. `clone($data, 2)` copies two container levels and shares everything below them; `clone($data, 0)` copies nothing and returns `$data` itself. Only hashes and arrays consume a depth unit — following a reference does not. Below the cap the "clone" shares the original's scalars, so writing to it writes to the original:

```perl
    my $inner = { n => 1 };
    my $copy  = clone({ child => $inner }, 1);
    $copy->{child}{n} = 2;      # $inner->{n} is now 2 as well
```

  `undef` and negative values mean unlimited, like omitting the argument; values above `INT_MAX` are clamped, not truncated; anything that is not a number is a fatal error.

* **Filehandles and IO Objects**: Filehandles and IO objects are not duplicated. A reference to a handle clones to the very same reference (its reference count is incremented), so the "clone" *is* the original handle: one file descriptor, one shared file position — reading from one advances the other. For DBI database handles, Clone skips opaque XS magic to avoid dangling pointers, but the resulting clone should not be used as a database handle.

* **Code References**: Code references (subroutines) are cloned by reference, not by value. The cloned coderef points to the same subroutine as the original.

* **Thread Safety**: Clone is not explicitly thread-safe. Use appropriate synchronization when cloning data structures across threads.

## Performance

Clone is implemented in C using Perl's XS interface and copies data structures directly, with no intermediate serialized form. On the shapes most programs clone it is the faster of the two obvious options: measured on perl 5.34 with Storable 3.23, Clone ran 1.3 to 3 times faster than [Storable](https://metacpan.org/pod/Storable)'s `dclone()` on structures nested up to a few dozen levels, and about twice as fast on wide, flat ones. The gap narrows as nesting grows; the two meet somewhere around a hundred levels, past which `dclone()` is marginally ahead.

Deep data is also where the two differ in kind rather than degree: `dclone()` dies with *"Max. recursion depth with nested structures exceeded"* past `$Storable::recursion_limit` (512 levels by default), while Clone copies arbitrarily deep structures through the iterative fallback described under Limitations.

So reach for `dclone()` when you want what it uniquely offers — serialization, `freeze`/`thaw`, a form you can put on disk or on the wire — rather than for speed.

Those figures are one machine, one perl, one data shape. Benchmark your own case if it is performance-critical.

## Caveats

* **Cloned objects are deep copies**: Changes to the clone do not affect the original, and vice versa. This includes nested references and objects — but only for a full clone: a depth-capped one shares everything below the cap, see *The depth argument* under Limitations.

* **Object internals**: While Clone handles most blessed objects correctly, objects with XS components or complex internal state may not clone as expected. Test thoroughly with your specific object types.

* **Memory usage**: Cloning large data structures creates a complete copy in memory. Ensure you have sufficient memory available.

## Testing

Run the test suite:

```bash
    make test
```

Or with verbose output:

```bash
    prove -lv t/
```

## Contributing

Contributions are welcome! Please:

1. Fork the repository on [GitHub](https://github.com/garu/Clone)
2. Create a feature branch
3. Make your changes with tests
4. Submit a pull request

## See Also

[Storable](https://metacpan.org/pod/Storable)'s `dclone()` is a flexible solution for cloning
variables and the right tool when you also need serialization. For plain
in-memory copies it is generally slower than Clone, and it refuses structures
nested past `$Storable::recursion_limit` — see Performance above.

Other modules that may be of interest:

* [Clone::PP](https://metacpan.org/pod/Clone::PP) - Pure Perl implementation of Clone
* [Scalar::Util](https://metacpan.org/pod/Scalar::Util) - For `weaken()` and other scalar utilities
* [Data::Dumper](https://metacpan.org/pod/Data::Dumper) - For debugging and inspecting data structures

## Support

* **Bug Reports and Feature Requests**: Please report bugs on [GitHub Issues](https://github.com/garu/Clone/issues)
* **Source Code**: Available on [GitHub](https://github.com/garu/Clone)

COPYRIGHT
---------

Copyright 2001-2026 Ray Finch. All Rights Reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

## Author

Ray Finch `<rdf@cpan.org>`

Breno G. de Oliveira `<garu@cpan.org>`,
Nicolas Rochelemagne `<atoomic@cpan.org>` and
Florian Ragwitz `<rafl@debian.org>` perform routine maintenance
releases since 2012.
