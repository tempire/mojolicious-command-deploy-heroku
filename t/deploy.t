use Test::More;
use Mojolicious::Command::deploy::heroku;

ok my $o = Mojolicious::Command::deploy::heroku->new;

ok $o->can($_) for qw/
    choose_key
    config_app
    create_or_get_app
    create_or_get_key
    create_repo
    file_exists
    fill_repo
    generate_herokufile
    generate_key
    generate_makefile
    git
    heroku_object
    local_api_key
    opt_spec
    prompt
    prompt_user_pass
    push_repo
    remote_key_match
    run
    save_local_api_key
    ssh_keys
    upload_keys
    validate
    verify_app
  /;

done_testing;
