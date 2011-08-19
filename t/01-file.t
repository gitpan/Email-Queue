use strict;
use warnings;

use Test::More tests => 138;
use Test::Deep;

my $TIME;

BEGIN {
    $TIME = time;
    *CORE::GLOBAL::time = sub() { $TIME };
    *CORE::GLOBAL::sleep = sub(;$) {  
        my $seconds = shift || 1;
        note "Sleep $seconds";
        $TIME += $seconds;
    }
}

use File::Temp qw/tempdir/;
use Email::Queue;
use Email::Simple;

my $path = tempdir( DIR => '.', CLEANUP => 1 );

# Create object
#
isa_ok( my $fq = Email::Queue->new(), 'Email::Queue' );
my %attrs = (
    path       => '.',
    mkpath     => 0,
    ext        => 'eml',
    prefix     => 'msg',
    xlock      => 'X-Lock',
    timeout    => 3600,
    _locked    => [],
    grab_count => 50
);
for ( keys %attrs ) {
    is_deeply( $fq->$_, $attrs{$_}, "Attribute $_" );
}

# Make sure it creates the path
#
$fq = Email::Queue->new(
    path => "$path/emails",
    mkpath => 1
);
ok(-d "$path/emails", "Created path: $path/emails");


# Die if path is not writeable
#
eval { Email::Queue->new( path => "$path/something", mkpath => 0 ) };
ok( $@, 'Die when path is not writeable' );

# Try using a different attributes
#
%attrs = (
    prefix  => 'email',
    ext     => 'msg',
    path    => $path,
    xlock   => 'X-Locked',
    timeout => 120,
    grab_count => 0
);
$fq = Email::Queue->new( %attrs );
for ( keys %attrs ) {
    is_deeply( $fq->$_, $attrs{$_}, "Altered attribute $_" );
}


# Create an email message
#
my $email  = Email::Simple->new("From: a\nTo:b\nSubject:c\n\nmessage\n");

# Test store
#
my $m1 = $fq->store( $email );
ok( -e $fq->path . '/' . $m1, 'Store message 1: ' . $m1 );

my $m2 = $fq->store( $email );
ok( -e $fq->path . '/' . $m2, 'Store message 2: ' . $m2 );

isnt( $m1, $m2, 'Two different files' );
my $v1 = $fq->load($m1);
my $v2 = $fq->load($m2);
is($v1->as_string, $v2->as_string, 'But contents are the same');

$email->header_set(Something => 'else');
my $m3 = $fq->store( $email, $m2 );
ok( -e $fq->path . '/' . $m2, 'Store message 3: ' . $m3 );
is( $m3, $m2, 'Under the same name' );

my $v3 = $fq->load($m3);
isnt($v2->as_string, $v3->as_string, 'But different contents');

# Clean all
#
$fq->remove($m1, $m2);

is($fq->count, 0, 'All cleared');

# Schedule a few rounds of emails
#
my $emails = schedule(2, 5);

# Verify locking and unlocking
#
my $message_id = $emails->[0];
ok($fq->lock( $message_id ), 'Lock message');
my $message = $fq->load( $message_id );
ok( $message->header($fq->xlock), 'Locking works' );
$fq->unlock( $message );
ok( !$message->header($fq->xlock), 'Unlocking works' );

sleep 20;
ok( !$fq->lock( $message_id ), 'Can not lock a locked message' );

sleep 100;
ok( $fq->lock( $message_id ), 'Lock again after timeout' );

sleep 120;

# Get available emails and remove them
#
for ( my $i = 0 ; $i < @$emails ; $i++ ) {
    my $message = $fq->next;
    my $message_id = $emails->[$i];
    ok( !-e $fq->path . '/' . $message_id, "$message_id removed" );
    isa_ok( $message, 'Email::Simple' );
    ok( $message->as_string, "$message_id: has as_string" );
}

is( $fq->count, 0, 'Count is 0' );

$emails = schedule( 2, 2 );
$fq->grab_count(2);
for my $message_id ( @$emails ) {
    my $message = $fq->next;
    ok( scalar(@{$fq->_locked}) <= 2, "$message_id: locked count ok" );
}
is( $fq->count, 0, 'Count is 0' );

#####################################################

sub schedule {
    my ( $rounds, $files ) = @_;
    my @emails = ();
    my $ext    = $fq->ext;
    my $prefix = $fq->prefix;
    for my $j ( 0 .. $rounds - 1 ) {
        for my $i ( 0 .. $files - 1 ) {
            my $message_id = $fq->schedule($email);
            ok( $message_id, "Message ID: $message_id" );

            ok( -f $fq->path . '/' . $message_id, "File $message_id exists" );
            ok( $message_id =~ /^$prefix\-(\w+)\-(\w+)-(\w+)\.$ext$/,
                'File matches' );

            is( $1,      time, 'Time part ok' );
            is( $3, $i,   'Increment part ok ' . $i );

            push @emails, $message_id;
        }
        sleep 16;
    }
    is( $fq->count, $rounds * $files, 'Count accurate' );
    return \@emails;
}


