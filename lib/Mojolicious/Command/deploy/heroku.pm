package Mojolicious::Command::deploy::heroku;
use Mojo::Base 'Mojo::Command';

# Developer's note:
#   Experiment using concatenative style.
#   Type signatures provided, and may make sense in light of:
#   http://evincarofautumn.blogspot.com/2012/02/why-concatenative-programming-matters.html

use Getopt::Long qw/GetOptions :config no_auto_abbrev no_ignore_case/;
use Net::Heroku;
use Git::Repository;
use Mojo::UserAgent;
use Mojo::IOLoop;
use File::Spec;
use File::Slurp 'slurp';
use Data::Dumper;

$|++;

has tmpdir => sub { $ENV{MOJO_TMPDIR} || File::Spec->tmpdir };
has ua => sub { Mojo::UserAgent->new->ioloop(Mojo::IOLoop->singleton) };
has description      => "Deploy Mojolicious app.\n";
has opt              => sub { {} };
has credentials_file => sub {"$ENV{HOME}/.heroku/credentials"};
has usage            => <<"EOF";

usage: $0 deploy heroku [OPTIONS]

  # Create new app with randomly selected name and deploy
  $0 deploy heroku -c

  # Create new app with specified name and deploy
  $0 deploy heroku -c -n happy-cloud-1234

  # Deploy to existing app
  $0 deploy heroku -n happy-cloud-1234

These options are available:
  -n, --appname <name>      Specify app for deployment
  -a, --api-key <api_key>   Heroku API key (read from ~/.heroku/credentials by default).
  -c, --create              Create a new Heroku app
  -v, --verbose             Verbose output (heroku response, git output)
  -h, --help                This message
EOF

sub opt_spec {
  my $self = shift;
  my $opt  = {};

  return $opt
    if GetOptions(
    "appname|n=s" => sub { $opt->{name}    = pop },
    "api-key|a=s" => sub { $opt->{api_key} = pop },
    "create|c"    => sub { $opt->{create}  = pop },
    );
}

sub validate {
  my $self = shift;
  my $opt  = shift;

  my @errors;

  # Create or appname
  push @errors => '--create or --appname must be specified'
    if !defined $opt->{create} and !defined $opt->{name};

  # API Key
  push @errors => 'API key not specified, and not found in '
    . $self->credentials_file
    if !defined $opt->{api_key};

  return @errors;
}

sub run {
  my $self = shift;
  my $class = $ENV{MOJO_APP} || 'MyApp';
  my $name =
    ref $class eq 'Mojolicious::Lite' ? +($0 =~ /^\W*(.+)$/)[0] : $class;

  # App home dir
  $self->ua->app($class);
  my $home_dir = $self->ua->app->home->to_string;

  # Options
  my $opt = $self->opt_spec(@_);

  $opt->{api_key} //= $self->api_key;

  # Validate, exit if errors
  my @errors = $self->validate($opt);
  die "\n" . join("\n" => @errors) . "\n" . $self->usage if @errors;

  my $h = Net::Heroku->new(api_key => $opt->{api_key});

  my ($res) = verify_app(
    config_app(
      create_or_get_app(
        {BUILDPACK_URL => 'http://github.com/tempire/perloku.git'},
        $opt, $h
      )
    )
  );

  # Upload
  print "Uploading $name to $res->{name}...";
  push_repo(
    fill_repo(
      create_repo(
        $res, $self->app->home->list_files,
        $home_dir, $self->tmpdir
      )
    )
  );
  say 'done.';
}

sub api_key {
  my $self = shift;

  return if !-T $self->credentials_file;

  my $api_key = +(slurp $self->credentials_file)[-1];
  chomp $api_key;

  return $api_key;
}

# T :: (A, $home_dir, $tmp_dir) -> (A, $r)
sub create_repo {
  my ($tmp_dir, $home_dir) = map {pop} 1 .. 2;

  my $git_dir = $tmp_dir . '/mojo_deploy_git_' . int rand 1000;

  Git::Repository->run(init => $git_dir);

  return @_,
    Git::Repository->new(
    work_tree => $home_dir,
    git_dir   => $git_dir . '/.git'
    );
}

# T :: (A, $files, $r) -> (A, $r)
sub fill_repo {
  my ($r, $files) = map {pop} 1 .. 2;

  # Files matched by .gitignore
  my @ignore =
    git($r, 'ls-files' => '--others' => '-i' => '--exclude-standard');

  # Add files filtered by .gitignore
  git($r,
    add => grep { my $file = $_; $file if !grep $file =~ /$_\W*/ => @ignore }
      @$files);

  git($r, commit => '-m' => 'Initial Commit');

  return @_, $r;
}

# T :: (A, $name, $res, $r) -> (A, $r)
sub push_repo {
  my ($r, $res, $name) = map {pop} 1 .. 3;

  git($r, remote => add       => heroku => $res->{git_url});
  git($r, push   => '--force' => heroku => 'master');

  return @_, $r;
}

sub git {
  return shift->run(@_);
}

# T :: (A, $opt, $h) -> (A, $res)
sub create_or_get_app {
  my ($h, $opt) = map {pop} 1 .. 2;

  # Attempt create
  my $res = {$h->create(name => $opt->{name})};
  my $error = $h->error;

  # Attempt retrieval
  $res = shift @{[grep $_->{name} eq $opt->{name} => $h->apps]}
    if $h->error and $h->error eq 'Name is already taken';

  say "Upload failed for $opt->{name}: " . $error and exit if !$res;

  return @_, $h, $res;
}

# T :: (A, $config, $h, $res) -> (A, $h, $res)
sub config_app {
  my ($res, $h, $config) = map {pop} 1 .. 3;

  say "Configuration failed for app $res->{name}: " . $h->error and exit
    if !$h->add_config(name => $res->{name}, %$config);

  return @_, $h, $res;
}

# T :: (A, $h, $res) -> (A, $res)
sub verify_app {
  my ($res, $h) = map {pop} 1 .. 2;

  for (0 .. 5) {
    last if $h->app_created(name => $res->{name});
    sleep 1;
    print ' . ';
  }

  return @_, $res;
}


1;

=head1 NAME

Mojolicious::Command::deploy::heroku - Deploy to Heroku

=head1 SYNOPSIS

  use Mojolicious::Command::deploy::heroku

  my $deployment = Mojolicious::Command::deploy::heroku->new;
  $deployment->run(@ARGV);

=head1 DESCRIPTION

L<Mojolicious::Command::deployment> deploys a Mojolicious app to Heroku.

=head1 ATTRIBUTES

L<Mojolicious::Command::deploy::heroku> inherits all attributes from
L<Mojo::Command> and implements the following new ones.

=head2 C<description>

  my $description = $deployment->description;
  $cpanify        = $deployment->description(' Foo !');

Short description of this command, used for the command list.

=head2 C<usage>

  my $usage = $deployment->usage;
  $deployment  = $deployment->usage(' Foo !');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Mojolicious::Command::deploy::heroku> inherits all methods from L<Mojo::Command>
and implements the following new ones.

=head2 C<run>

  $delpoyment->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
