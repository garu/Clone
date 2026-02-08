package Clone;

use strict;

require Exporter;
use XSLoader ();

our @ISA       = qw(Exporter);
our @EXPORT;
our @EXPORT_OK = qw( clone );

our $VERSION = '0.48_01';

XSLoader::load('Clone', $VERSION);

1;
__END__

=head1 NAME

Clone - recursively copy Perl datatypes

=for html
<a href="https://github.com/garu/Clone/actions/workflows/test.yml"><img src="https://github.com/garu/Clone/actions/workflows/test.yml/badge.svg" alt="Build Status"></a>
<a href="https://metacpan.org/pod/Clone"><img src="https://badge.fury.io/pl/Clone.svg" alt="CPAN version"></a>

=head1 SYNOPSIS

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

You can also add it to your class:

    package Foo;
    use parent 'Clone';
    sub new { bless {}, shift }

    package main;

    my $obj = Foo->new;
    my $copy = $obj->clone;

=head1 DESCRIPTION

This module provides a C<clone()> method which makes recursive
copies of nested hash, array, scalar and reference types,
including tied variables and objects.

C<clone()> takes a scalar argument and duplicates it. To duplicate lists,
arrays or hashes, pass them in by reference, e.g.

    my $copy = clone (\@array);

    # or

    my %copy = %{ clone (\%hash) };

=head1 SEE ALSO

L<Storable>'s C<dclone()> is a flexible solution for cloning variables,
albeit slower for average-sized data structures. Simple
and naive benchmarks show that Clone is faster for data structures
with 3 or fewer levels, while C<dclone()> can be faster for structures
4 or more levels deep.

=head1 COPYRIGHT

Copyright 2001-2025 Ray Finch. All Rights Reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=head1 AUTHOR

Ray Finch C<< <rdf@cpan.org> >>

Breno G. de Oliveira C<< <garu@cpan.org> >>,
Nicolas Rochelemagne C<< <atoomic@cpan.org> >>
and
Florian Ragwitz C<< <rafl@debian.org> >> perform routine maintenance
releases since 2012.

=cut
