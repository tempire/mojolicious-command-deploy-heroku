package Mojolicious::Command::Author::generate::heroku;
use Mojo::Base 'Mojolicious::Command';
use Mojo::Util 'class_to_file';

has description => qq/Generate Heroku configuration.\n/;
has usage       => "usage: $0 generate heroku\n";
has file        => 'Perloku';

sub run {
  my $self  = shift;
  my $class = ref $self->app;

  my $script_name =
      $class eq 'Mojolicious::Lite'
    ? $0
    : 'script/' . class_to_file($class);

  $self->render_to_rel_file(
    perloku => $self->file => { script_name => $script_name }
  );
  $self->chmod_file($self->file => 0744);
}

1;
__DATA__

@@ perloku
web: ./<%= +($script_name =~ qr|[\./]*(.+)|)[0] %> daemon --listen http://*:$PORT --mode production

__END__
=head1 NAME

Mojolicious::Command::Author::generate::heroku - Heroku configuration generator command

=head1 SYNOPSIS

  use Mojolicious::Command::Author::generate::heroku;

  my $heroku = Mojolicious::Command::Author::generate::heroku->new;
  $heroku->run(@ARGV);

=head1 DESCRIPTION

L<Mojolicious::Command::Author::generate::heroku> is a heroku configuration generator.

=head1 ATTRIBUTES

L<Mojolicious::Command::Author::generate::heroku> inherits all attributes from
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

L<Mojolicious::Command::Author::generate::heroku> inherits all methods from
L<Mojo::Command> and implements the following new ones.

=head2 C<run>

  $heroku->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
