package Mojolicious::Command::deploy::heroku;
use Mojo::Base 'Mojolicious::Command';

use IO::Prompter;
use File::Spec;
use Mojo::File;
use IPC::Cmd 'can_run';
use Net::Netrc;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Mojolicious::Command::generate::heroku;
use Mojolicious::Command::generate::makefile;
use Net::Heroku;

our $VERSION = 0.23;

has tmpdir           => sub { $ENV{MOJO_TMPDIR} || File::Spec->tmpdir };
has ua               => sub { Mojo::UserAgent->new->ioloop(Mojo::IOLoop->singleton) };
has description      => "Deploy Mojolicious app to Heroku\n";
has opt              => sub { {} };
has credentials_file => sub { "$ENV{HOME}/.netrc" };
has makefile         => 'Makefile.PL';
has usage            => sub { shift->extract_usage };


sub opt_spec {
  my $self = shift;
  my $opt  = {};

  Mojo::Util::getopt(
    'name|n=s'    => \$opt->{name},
    'api-key|a=s' => \$opt->{api_key},
    'create|c:s'  => sub { $opt->{create} = $_[1] ? ($opt->{name} = $_[1]) : 1 },
    #'verbose|v'   => \$opt->{verbose},
  );

  return $opt;
}

sub validate {
  my $self = shift;
  my $opt  = shift;

  my @errors = map {
    $_ . ' command not found'
  } grep {
    !can_run($_)
  } qw/ git ssh ssh-keygen /;

  # Create or appname
  push @errors => '--create or --appname must be specified'
    if !defined $opt->{create} && !defined $opt->{name};

  return @errors;
}

sub run {
  my $self = shift;

  # App home dir
  $self->ua->server->app($self->app);
  my $home_dir = $self->ua->server->app->home->to_string;

  # Command-line Options
  my $opt = $self->opt_spec(@_);

  # Validate
  my @errors = $self->validate($opt);
  die "\n" . join("\n" => @errors) . "\n" . $self->usage if @errors;

  # Net::Heroku
  my $h = $self->heroku_object($opt->{api_key} || $self->local_api_key);

  # Prepare
  $self->generate_makefile;
  $self->generate_herokufile;

  # SSH key permissions
  if (!remote_key_match($h)) {
    print "\nHeroku does not have any matching SSH keys stored for you.";
    my ($file, $key) = create_or_get_key();

    print "\nUploading SSH public key $file\n";
    $h->add_key(key => $key);
  }

  # Create
  my $res = verify_app(
    $h,
    config_app(
      $h,
      create_or_get_app($h, $opt),
      { BUILDPACK_URL => 'http://github.com/rage311/perloku.git' }
    )
  );

  print "Collecting all files in "
    . $self->app->home . " ..."
    . " (Ctrl-C to cancel)\n";

  # Upload
  push_repo(
    fill_repo(
      $self->create_repo($home_dir, $self->tmpdir),
      $self->app->home->list
    ),
    $res
  );
}

sub promptopt {
  my ($message, @options) = @_;

  print "\n$message\n";

  for (my $i = 0; $i < @options; $i++) {
    printf "\n%d) %s" => $i + 1, $options[$i];
  }

  print "\n\n> ";

  my $response = <STDIN>;
  chomp $response;

  return ($response
      && $response =~ /^\d+$/
      && $response > 0
      && $response < @options + 1)
    ? $options[$response - 1]
    : promptopt($message, @options);
}

sub choose_key {
  return promptopt
    "Which of the following keys would you like to use with Heroku?",
    ssh_keys();
}

sub generate_key {
  print "\nGenerating an SSH public key...\n";

  # Generate RSA key
  my $path = Mojo::File->new($ENV{HOME}, '.ssh')
    ->make_path({mode => 0700 })
    ->child('id_rsa_test');

  my $exit = system('ssh-keygen', '-t', 'rsa', '-N', '', '-f', $path);

  return $path . '.pub';
}

sub ssh_keys {
  return Mojo::File->new($ENV{HOME}, '.ssh')->list->grep(qr/\.pub$/)->each;
}


sub create_or_get_key {
  my $file = Mojo::File->new(ssh_keys() ? choose_key : generate_key);
  return $file, $file->slurp;
}

sub generate_makefile {
  my $self = shift;

  my $command = Mojolicious::Command::generate::makefile->new;
  my $file    = $self->app->home->rel_file($self->makefile);

  if (!file_exists($file)) {
    print "$file not found.  Generating...\n";
    return $command->run;
  }

  die "$file does not compile. Cannot continue."
    unless (qx/$^X -c $file 2>&1/ =~ /syntax OK/);
}

sub generate_herokufile {
  my $self = shift;

  my $command = Mojolicious::Command::generate::heroku->new(app => $self->app);

  if (!file_exists($command->file)) {
    print $command->file . " not found.  Generating...\n";
    return $command->run;
  }
}

sub file_exists {
  return -e shift;
}

sub heroku_object {
  my ($self, $api_key) = @_;

  my $h;

  if (defined $api_key) {
    $h = Net::Heroku->new(api_key => $api_key);
  }
  else {
    my @credentials;

    while (!$h || $h->error) {
      @credentials = prompt_user_pass();
      $h           = Net::Heroku->new(@credentials);
    }

    $self->save_local_api_key($credentials[1], $h->ua->api_key);
  }

  return $h;
}

sub save_local_api_key {
  my ($self, $email, $api_key) = @_;

  my $path = Mojo::File->new($self->credentials_file);
  my $exists = file_exists $path;

  $path->spurt(
    -T $path ? $path->slurp : '',
    "machine api.heroku.com\n",
    "  password $api_key\n",
    "  login $email\n",
    "machine git.heroku.com\n",
    "  password $api_key\n",
    "  login $email\n",
  );

  chmod 0600, $path if !$exists;

  return $path;
}

sub local_api_key {
  my $self = shift;

  return if ! -T $self->credentials_file;

  my $api_key = Net::Netrc->lookup('api.heroku.com')->password;

  return $api_key;
}

sub prompt_user_pass {
  print "\nPlease enter your Heroku credentials";
  print "\n  (Sign up for free at https://api.heroku.com/signup)";

  print "\n\n";
  my $email = prompt('Email:', -stdio);
  chomp $email;

  my $password = prompt('Password:', -echo => '*', -stdio);
  chomp $password;

  return (email => $email, password => $password);
}

sub create_repo {
  my ($self, $home_dir, $tmp_dir) = @_;

  print "\nCreating git repo\n";
  my $git_dir =
    Mojo::File::tempdir($tmp_dir . '/mojo_deploy_git_XXXXXXXX')->make_path;
  print "$git_dir\n\n";

  my $r = {
    work_tree => $home_dir,
    git_dir   => $git_dir,
  };

  git($r, 'init');

  return $r;
}

sub fill_repo {
  my ($r, $all_files) = @_;

  # .gitignore'd files
  my @ignore =
    git($r, 'ls-files' => '--others' => '-i' => '--exclude-standard');

  my @files = grep {
    my $file = $_;
    $file if !grep {
      $file =~ /$_\W*/
    } @ignore
  } @$all_files;

  # Add files filtered by .gitignore
  print "Adding file $_\n" for @files;
  git($r, add => @files);

  git($r, commit => '-m' => '"Initial commit"');
  print int(@files) . " files added\n\n";

  return $r;
}

sub push_repo {
  my ($r, $res) = @_;

  print "Pushing git repo\n";
  git($r, remote => add       => heroku => $res->{git_url});
  git($r, push   => '--force' => heroku => 'master');

  return $r;
}

sub git {
  my $r = shift;
  my $cmd =
    'git -c core.autocrlf=false '
    . "--work-tree=\"$r->{work_tree}\" "
    . "--git-dir=\"$r->{git_dir}\" "
    . join ' ' => @_;

  return system($cmd);
}

sub create_or_get_app {
  my ($h, $opt) = @_;

  # Attempt create
  my %params = defined $opt->{name} ? (name => $opt->{name}) : ();
  my $res    = { $h->create(%params) };
  my $error  = $h->error;

  # Attempt retrieval
  $res = shift @{[ grep { $_->{name} eq $opt->{name} } $h->apps ]}
    if $h->error and $h->error eq 'Name is already taken';

  print "Upload failed for $opt->{name}: " . $error . "\n" and exit if !$res;

  return $res;
}

sub remote_key_match {
  my $h = pop;

  my %remote_keys = map { $_->{public_key} => $_->{email} } $h->keys;

  my @local_keys = map {
    substr(Mojo::File->new($_)->slurp, 0, -1)
  } ssh_keys();

  return grep { defined $remote_keys{$_} } @local_keys;
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

  script/my_app deploy heroku [OPTIONS]

    # Create new app with randomly selected name and deploy
    script/my_app deploy heroku --create

    # Create new app with randomly selected name and specified api key
    script/my_app deploy heroku --create --api-key 123412341234...

    # Deploy app (new or existing) with specified name
    script/my_app deploy heroku --name happy-cloud-1234

  These options are available:
    -n, --name <name>         Specify app for deployment
    -a, --api-key <api_key>   Heroku API key (read from ~/.netrc by default)
    -c, --create [name]       Create a new Heroku app with an optional name
    -h, --help                This message

=head1 DESCRIPTION

L<Mojolicious::Command::deploy::heroku> deploys a Mojolicious app to Heroku.

*NOTE* The deploy command itself works on Windows, but the Heroku service does not reliably accept deployments from Windows.  Your mileage may vary.

*NOTE* This release works with Mojolicious versions 7.20 and above.  For older Mojolicious versions, please use 0.13 or before.

=head1 WORKFLOW

=over 4

=item 1) B<Heroku Service>

L<https://signup.heroku.com>

=item 2) B<Generate Mojolicious app>

  mojo generate lite_app hello

=item 3) B<Deploy>

  hello deploy heroku --create [optional-name]

The deploy command creates a git repository of the B<current directory's contents> in /tmp, and then pushes it to a remote heroku repository.

=back

=head1 SEE ALSO

L<https://github.com/tempire/mojolicious-command-deploy-heroku>

L<https://github.com/tempire/perloku>

L<http://heroku.com/>

L<https://mojolicious.org>

=head1 SOURCE

L<http://github.com/tempire/mojolicious-command-deploy-heroku>

=head1 VERSION

0.23

=head1 AUTHOR

Glen Hinkle C<tempire@cpan.org>

=head1 CONTRIBUTORS

MattOates

briandfoy

rage311

=cut
