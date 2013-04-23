package Mojolicious::Command::deploy::heroku;
use Mojo::Base 'Mojolicious::Command';

#use IO::All 'io';
use File::Path 'make_path';
use File::Slurp qw/ slurp write_file /;
use File::Spec;
use Getopt::Long qw/ GetOptions :config no_auto_abbrev no_ignore_case /;
use IPC::Cmd 'can_run';
use Mojo::IOLoop;
use Mojo::UserAgent;
use Mojolicious::Command::generate::heroku;
use Mojolicious::Command::generate::makefile;
use Net::Heroku;

our $VERSION = 0.10;

has tmpdir => sub { $ENV{MOJO_TMPDIR} || File::Spec->tmpdir };
has ua => sub { Mojo::UserAgent->new->ioloop(Mojo::IOLoop->singleton) };
has description      => "Deploy Mojolicious app to Heroku.\n";
has opt              => sub { {} };
has credentials_file => sub {"$ENV{HOME}/.heroku/credentials"};
has makefile         => 'Makefile.PL';
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

  my @errors =
    map $_ . ' command not found' =>
    grep !can_run($_) => qw/ git ssh ssh-keygen /;

  # Create or appname
  push @errors => '--create or --appname must be specified'
    if !defined $opt->{create} and !defined $opt->{name};

  return @errors;
}

sub run {
  my $self = shift;

  # App home dir
  $self->ua->app($self->app);
  my $home_dir = $self->ua->app->home->to_string;

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
    print "\nHeroku does not have any SSH keys stored for you.";
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
      {BUILDPACK_URL => 'http://github.com/tempire/perloku.git'}
    )
  );

  print "Collecting all files in "
    . $self->app->home . " ..."
    . " (Ctrl-C to cancel)\n";

  # Upload
  push_repo(
    fill_repo(
      $self->create_repo($home_dir, $self->tmpdir),
      $self->app->home->list_files
    ),
    $res
  );
}

sub prompt {
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
    : prompt($message, @options);
}

sub choose_key {
  return prompt
    "Which of the following keys would you like to use with Heroku?",
    ssh_keys();
}

sub generate_key {
  print "\nGenerating an SSH public key...\n";

  my $file = "id_rsa";

  # Get/create dir
  #my $dir = io->dir("$ENV{HOME}/.ssh")->perms(0700)->mkdir;
  my $dir = File::Spec->catfile($ENV{HOME}, '.ssh');
  make_path($dir, {mode => 0700});

  # Generate RSA key
  my $path = File::Spec->catfile($dir, $file);
  `ssh-keygen -t rsa -N "" -f "$path" 2>&1`;

  return "$path.pub";
}

sub ssh_keys {

  #return grep /\.pub$/ => io->dir("$ENV{HOME}/.ssh/")->all;
  opendir(my $dir => File::Spec->catfile($ENV{HOME}, '.ssh')) or return;
  return
    map File::Spec->catfile($ENV{HOME}, '.ssh', $_) =>
    grep /\.pub$/ => readdir($dir);
}


sub create_or_get_key {

  #return io->file(ssh_keys() ? choose_key : generate_key)->slurp;
  my $file = ssh_keys() ? choose_key : generate_key;
  return $file, slurp $file;
}

sub generate_makefile {
  my $self = shift;

  my $command = Mojolicious::Command::generate::makefile->new;
  my $file    = $self->app->home->rel_file($self->makefile);

  if (!file_exists($file)) {
    print "$file not found...generating\n";
    return $command->run;
  }

  unless ( `$^X -c $file` =~ /syntax OK/ ) {
    die "$file does not compile. Cannot continue.\n";
  }
}

sub generate_herokufile {
  my $self = shift;

  my $command = Mojolicious::Command::generate::heroku->new;

  if (!file_exists($command->file)) {
    print $command->file . " not found...generating\n";
    return $command->run;
  }
}

sub file_exists {

  #return io(shift)->exists;
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

  #my $dir = io->dir("$ENV{HOME}/.heroku")->perms(0700)->mkdir;
  my $dir = "$ENV{HOME}/.heroku";
  make_path($dir, {mode => 0700});

  #return io("$dir/credentials")->print($email, "\n", $api_key, "\n");
  return write_file "$dir/credentials", $email, "\n", $api_key, "\n";
}

sub local_api_key {
  my $self = shift;

  return if !-T $self->credentials_file;

  #my $api_key = +(io->file($self->credentials_file)->slurp)[-1];
  my $api_key = +(slurp $self->credentials_file)[-1];
  chomp $api_key;

  return $api_key;
}

sub prompt_user_pass {
  print "\nPlease enter your Heroku credentials";
  print "\n  (Sign up for free at https://api.heroku.com/signup)";

  print "\n\nEmail: ";
  my $email = <STDIN>;
  chomp $email;

  print "Password: ";
  my $password = <STDIN>;
  chomp $password;

  return (email => $email, password => $password);
}

sub create_repo {
  my ($self, $home_dir, $tmp_dir) = @_;

  print "Creating git repo\n";
  my $git_dir =
    File::Spec->catfile($tmp_dir, 'mojo_deploy_git', int rand 1000);
  make_path($git_dir);

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

  my @files =
    grep { my $file = $_; $file if !grep $file =~ /$_\W*/ => @ignore }
    @$all_files;

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
    "git -c core.autocrlf=false --work-tree=\"$r->{work_tree}\" --git-dir=\"$r->{git_dir}\" "
    . join " " => @_;
  return `$cmd`;
}

sub create_or_get_app {
  my ($h, $opt) = @_;

  # Attempt create
  my %params = defined $opt->{name} ? (name => $opt->{name}) : ();
  my $res    = {$h->create(%params)};
  my $error  = $h->error;

  # Attempt retrieval
  $res = shift @{[grep $_->{name} eq $opt->{name} => $h->apps]}
    if $h->error and $h->error eq 'Name is already taken';

  print "Upload failed for $opt->{name}: " . $error . "\n" and exit if !$res;

  return $res;
}

sub remote_key_match {
  my $h = pop;

  my %remote_keys = map { $_->{contents} => $_->{email} } $h->keys;
  my @local_keys = map substr(slurp($_), 0, -1) => ssh_keys();

  #my @local_keys = map substr($_->all, 0, -1) => ssh_keys();

  return grep defined $remote_keys{$_} => @local_keys;
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

=head1 USAGE

  script/my_app deploy heroku [OPTIONS]

    # Create new app with randomly selected name and deploy
    script/my_app deploy heroku --create

    # Create new app with randomly selected name and specified api key
    script/my_app deploy heroku --create --api-key 123412341234...

    # Deploy app (new or existing) with specified name
    script/my_app deploy heroku --name happy-cloud-1234

  These options are available:
    -n, --appname <name>      Specify app for deployment
    -a, --api-key <api_key>   Heroku API key (read from ~/.heroku/credentials by default).
    -c, --create              Create a new Heroku app
    -v, --verbose             Verbose output (heroku response, git output)
    -h, --help                This message

=head1 DESCRIPTION

L<Mojolicious::Command::deploy::heroku> deploys a Mojolicious app to Heroku.

*NOTE* The deploy command itself works on Windows, but the Heroku service does not reliably accept deployments from Windows.  Your mileage may vary.

*NOTE* This release works with Mojolicious versions 3.0 and above.  For older Mojolicious versions, please use 0.05 or before.

=head1 WORKFLOW

=over 4

=item 1) B<Heroku Service>

L<https://api.heroku.com/signup>

=item 2) B<Generate Mojolicious app>

  mojo generate lite_app hello

=item 3) B<Deploy>

  hello deploy heroku --create

The deploy command creates a git repository of the B<current directory's contents> in /tmp, and then pushes it to a remote heroku repository.

=back

=head1 SEE ALSO

L<https://github.com/tempire/mojolicious-command-deploy-heroku>,
L<https://github.com/tempire/perloku>,
L<http://heroku.com/>,
L<http://mojolicio.us>

=head1 SOURCE

L<http://github.com/tempire/mojolicious-command-deploy-heroku>

=head1 VERSION

0.10

=head1 AUTHOR

Glen Hinkle C<tempire@cpan.org>

