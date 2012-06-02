package Mojolicious::Command::deploy::heroku;
use Mojo::Base 'Mojo::Command';

use Data::Dumper;
use File::Slurp 'slurp';
use File::Spec;
use Getopt::Long qw/ GetOptions :config no_auto_abbrev no_ignore_case /;
use Git::Repository;
use IPC::Cmd 'can_run';
use Mojo::IOLoop;
use Mojo::UserAgent;
use Net::Heroku;

has tmpdir => sub { $ENV{MOJO_TMPDIR} || File::Spec->tmpdir };
has ua => sub { Mojo::UserAgent->new->ioloop(Mojo::IOLoop->singleton) };
has description      => "Deploy Mojolicious app to Heroku.\n";
has opt              => sub { {} };
has credentials_file => sub {"$ENV{HOME}/.heroku/credentials"};
has usage            => <<"EOF";


usage: $0 deploy heroku [OPTIONS]

  # Create new app with randomly selected name and deploy
  $0 deploy heroku -c

  # Deploy to specified app and deploy (creates app if it does not exist)
  $0 deploy heroku -n friggin-ponycorns

These options are available:
  -n, --appname <name>      Specify app name for deployment
  -a, --api-key <api_key>   Heroku API key (read from ~/.heroku/credentials by default).
  -c, --create              Create app with randomly selected name
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

  push @errors => 'git command not found' if !can_run('git');

  # Create or appname
  push @errors => '--create or --appname must be specified'
    if !defined $opt->{create} and !defined $opt->{name};

  # API Key
  push @errors => 'API key not specified, or not found in '
    . $self->credentials_file . "\n"
    . ' (Your API key can be found at https://api.heroku.com/account)'
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

  # Validate
  my @errors = $self->validate($opt);
  die "\n" . join("\n" => @errors) . "\n" . $self->usage if @errors;

  my $h = Net::Heroku->new(api_key => $opt->{api_key});

  # Create
  my $res = verify_app(
    $h,
    config_app(
      $h,
      create_or_get_app($h, $opt),
      {BUILDPACK_URL => 'http://github.com/tempire/perloku.git'}
    )
  );

  # Upload
  print "Uploading $name to $res->{name}...";
  push_repo(
    fill_repo(
      $self->create_repo($home_dir, $self->tmpdir),
      $self->app->home->list_files
    ),
    $res
  );

  print "done.\n";
}

sub api_key {
  my $self = shift;

  return if !-T $self->credentials_file;

  my $api_key = +(slurp $self->credentials_file)[-1];
  chomp $api_key;

  return $api_key;
}

sub create_repo {
  my ($self, $home_dir, $tmp_dir) = @_;

  my $git_dir = $tmp_dir . '/mojo_deploy_git_' . int rand 1000;

  Git::Repository->run(init => $git_dir);

  return Git::Repository->new(
    work_tree => $home_dir,
    git_dir   => $git_dir . '/.git'
  );
}

sub fill_repo {
  my ($r, $files) = @_;

  # Files matched by .gitignore
  my @ignore =
    git($r, 'ls-files' => '--others' => '-i' => '--exclude-standard');

  # Add files filtered by .gitignore
  git($r,
    add => grep { my $file = $_; $file if !grep $file =~ /$_\W*/ => @ignore }
      @$files);

  git($r, commit => '-m' => 'Initial Commit');

  return $r;
}

sub push_repo {
  my ($r, $res) = @_;

  git($r, remote => add       => heroku => $res->{git_url});
  git($r, push   => '--force' => heroku => 'master');

  return $r;
}

sub git {
  return shift->run(@_);
  #my $r = shift;
  #`git --work-tree $r->work_tree --git-dir $r->git_dir @_`;
  #warn('git --work-tree ' . $r->work_tree . ' --git-dir ' . $r->git_dir . " @_");
}

sub create_or_get_app {
  my ($h, $opt) = @_;

  # Attempt create
  my $res = {$h->create(name => $opt->{name})};
  my $error = $h->error;

  # Attempt retrieval
  $res = shift @{[grep $_->{name} eq $opt->{name} => $h->apps]}
    if $h->error and $h->error eq 'Name is already taken';

  print "Upload failed for $opt->{name}: " . $error . "\n" and exit if !$res;

  return $res;
}

sub config_app {
  my ($h, $res, $config) = @_;

  print "Configuration failed for app $res->{name}: " . $h->error . "\n"
    and exit
    if !$h->add_config(name => $res->{name}, %$config);

  return $res;
}

sub verify_app {
  my ($h, $res) = @_;

  # This is the way Heroku's official command-line client does it.

  for (0 .. 5) {
    last if $h->app_created(name => $res->{name});
    sleep 1;
    print ' . ';
  }

  return $res;
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
  $deployment     = $deployment->description(' Foo !');

Short description of this command, used for the command list.

=head2 C<usage>

  my $usage    = $deployment->usage;
  $deployment  = $deployment->usage(' Foo !');

Usage information for this command, used for the help screen.

=head1 METHODS

L<Mojolicious::Command::deploy::heroku> inherits all methods from L<Mojo::Command>
and implements the following new ones.

=head2 C<run>

  $deployment->run(@ARGV);

Run this command.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
