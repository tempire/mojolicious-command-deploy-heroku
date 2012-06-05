use Test::More;
use Mojolicious::Command::generate::heroku;

ok my $o = Mojolicious::Command::generate::heroku->new;
ok $o->can('run');

done_testing;
