package Mojolicious::Command::generate::heroku;
use Mojo::Base 'Mojo::Command';

has description => qq/Generate "Heroku configuration".\n/;
has usage       => "usage: $0 generate heroku\n";

# "If we don't go back there and make that event happen,
#  the entire universe will be destroyed...
#  And as an environmentalist, I'm against that."
sub run {
  my $self        = shift;
  my $class       = $ENV{MOJO_APP} || 'MyApp';
  my $script_name = 'script/' . $self->class_to_file($class);
  $self->render_to_rel_file(perloku => Perloku => $script_name);
  $self->chmod_file('Perloku' => 0744);
}

1;
__DATA__

@@ perloku
#!/bin/sh
<%= shift %> daemon --listen http://*:$PORT

__END__
=head1 NAME

Mojolicious::Command::generate::heroku - Heroku configuration generator command

=head1 SYNOPSIS

  use Mojolicious::Command::generate::heroku;

  my $heroku = Mojolicious::Command::generate::heroku->new;
  $heroku->run(@ARGV);

=head1 DESCRIPTION

L<Mojolicious::Command::generate::heroku> is a heroku configuration generator.

=head1 ATTRIBUTES

L<Mojolicious::Command::generate::heroku> inherits all attributes from
L<Mojo::Command> and implements the following new ones.

=head2 C<description>

  my $description = $heroku->description;
  $heroku       = $heroku->description('Foo!');

Short description of this command, used for the command list.

=head2 C<usage>

  my $usage = $heroku->usage;
  $heroku = $heroku->usage('Foo!');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Mojolicious::Command::generate::heroku> inherits all methods from
L<Mojo::Command> and implements the following new ones.

=head2 C<run>

  $heroku->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
