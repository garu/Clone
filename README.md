Clone - recursively copy Perl datatypes
=======================================

This module provides a clone() method which makes recursive
copies of nested hash, array, scalar and reference types,
including tied variables and objects.

```perl
    use Clone;

    my $data = {
       set => [ 1 .. 50 ],
       foo => {
           answer => 42,
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

    package main;

    my $obj = Foo->new;
    my $copy = $obj->clone;
```

```clone()``` takes a scalar argument and duplicates it. To duplicate lists,
arrays or hashes, pass them in by reference. e.g.

```perl
    my $copy = clone (\@array);

    # or

    my %copy = %{ clone (\%hash) };
```


See Also
--------

(Storable)[https://metacpan.org/pod/Storable]'s ```dclone()``` is a flexible solution for cloning variables,
albeit slower for average-sized data structures. Simple
and naive benchmarks show that Clone is faster for data structures
with 3 or less levels, while ```dclone()``` can be faster for structures
4 or more levels deep.


COPYRIGHT
---------

Copyright 2001-2014 Ray Finch. All Rights Reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.


