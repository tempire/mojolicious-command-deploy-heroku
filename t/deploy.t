use Test::More;
use Mojolicious::Command::deploy::heroku;

ok my $o = Mojolicious::Command::deploy::heroku->new;

ok $o->can($_) for qw/
  api_key
  config_app
  create_or_get_app
  create_repo
  fill_repo
  generate_herokufile
  generate_makefile
  git
  opt_spec
  push_repo
  run
  validate
  verify_app
  ssh_keys
  /;

$o->generate_ssh_keys;

done_testing;
