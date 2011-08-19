
use Test::More tests => 1;

BEGIN {
    use_ok( 'Email::Queue' ) || print "Bail out!\n";
}

diag( "Testing Email::Queue $Email::Queue::VERSION, Perl $], $^X" );
