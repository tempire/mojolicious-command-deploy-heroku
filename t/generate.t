use Test::More;
use Mojolicious::Command::Author::generate::heroku;

ok my $o = Mojolicious::Command::Author::generate::heroku->new;
ok $o->can('run');

done_testing;
