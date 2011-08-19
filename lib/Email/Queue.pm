package Email::Queue;

use strict;
use warnings;

use Carp;
use File::Path 'make_path';
use File::Copy;
use Email::Simple;

our $VERSION = 0.01;

our $AUTOLOAD;

sub new {
    my $class = shift;
    my %args  = @_ == 1 ? %{ $_[0] } : @_;
    my $self  = bless \%args, $class;

    # Internals
    $args{_locked} = [];
    $args{grab_count} = 50 unless defined $args{grab_count};

    $self->build_args( \%args );
    return $self;
}

sub build_args {
    my ( $self, $args ) = @_;

    # Defaults
    $args->{path}   ||= '.';
    $args->{mkpath} ||= 0;
    $args->{ext}    ||= 'eml';
    $args->{prefix} ||= 'msg';
    $args->{xlock}  ||= 'X-Lock';
    $args->{timeout}||= 3600;

    # Create dir
    if ( $args->{mkpath} and !-d $args->{path} ) {
        make_path( $args->{path} ) || croak "$args->{path}: $!";
    }

    if ( !-d $args->{path} ) {
        croak "$args->{path}: no such directory";
    }

    if ( !-w $args->{path} ) {
        croak "$args->{path}: write access denied";
    }
}

sub DESTROY {}

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    croak "Can't access method $name" unless exists $self->{$name};
    $self->{$name} = shift if @_;
    return $self->{$name};
}

sub schedule {
    my ( $self, $message ) = @_;
    croak('Message must be an Email::Simple object')
      unless ref($message) eq 'Email::Simple';
    $self->store($message);
}


sub load_dir {
    my $self = shift;
    my $ext = $self->ext;
    my $prefix = $self->prefix;
    opendir( my $dh, $self->path );
    my @emails = sort grep( /^$prefix.+\.$ext$/, readdir($dh) );
    closedir($dh);
    return \@emails;
}

sub _uniq_name {
    my $self = shift;
    my $idx  = 0;
    my $name;
    do {
        $name = join( '-', $self->prefix, time, $$, $idx++ ) . '.' . $self->ext;
    } while ( -e $self->path . '/' . $name );
    return $name;
}

sub store {
    my ( $self, $message, $name ) = @_;
    $name ||= $self->_uniq_name;
    my $filepath = $self->path . '/' . $name;

    # Write the message
    open( my $fh, '>', $filepath ) || croak "$filepath: $!";
    print $fh $message->as_string;
    close($fh);

    # Return the file name as message ID
    return $name;
}

sub remove {
    my ( $self, @ids ) = @_;
    unlink($self->path . '/' . $_) for @ids;
}

sub count {
    my $self = shift;
    my $all = $self->load_dir;
    return scalar @$all;
}

sub load {
    my ( $self, $message_id ) = @_;
    open( my $fh, '<', $self->path . '/' . $message_id )
      or croak( $self->path . '/' . $message_id . ": $!" );
    my $message = join( '', <$fh> );
    close($fh);
    return Email::Simple->new($message);
}

sub lock {
    my ( $self, $message_id ) = @_;

    my $message = $self->load( $message_id );

    # Check if message is locked
    my $lock = $message->header($self->xlock);
    return undef if $lock && time - $lock < $self->timeout;

    # Temporarily rename the file when locking
    my $source = $self->path . '/' . $message_id;
    my $target = $source . '~';
    move( $source, $target ) or return undef;

    # Delete the tilda file
    unlink( $target );

    # Set the header lock
    $message->header_set( $self->xlock, time );
    return $self->store( $message, $message_id );
}

sub unlock {
    my ( $self, $message ) = @_;
    $message->header_set( $self->xlock );
}

sub next {
    my $self = shift;

    if ( !@{$self->_locked} ) {
        my $emails = $self->load_dir;
        my @locked = ();
        for my $message_id ( @$emails ) {
            if ( $self->lock( $message_id ) ) {
                push @locked, $message_id;
            }

            # Exit loop if $count is defined and reached
            if ( $self->grab_count > 0 ) {
                last if scalar(@locked) >= $self->grab_count;
            }
        }
        $self->_locked( \@locked );
    }

    my $message_id = shift(@{$self->_locked}) || return undef;
    my $message = $self->load( $message_id );
    $self->remove( $message_id );

    $self->unlock( $message );
    return $message;
}

1;

__END__

=head1 NAME

Email::Queue - schedule email messages to be sent one by one at a later time.

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

    use File::Queue;

    my $fq = File::Queue->new(
        path   => '/tmp/emails',
        mkpath => 1
    );

    # Create a message
    my $message = Email::Simple->create(...);

    # Schedule the message 50 times (for the sake of the example)
    $fq->schedule($message) for ( 0 .. 49 );

    # ... much later ... from another script ....

    # Process the scheduled messages
    while ( my $message = $fq->next ) {

        # sendmail is an imaginery sub that sends RFC2822 formatted emails.
        sendmail( $message->as_string );
    }

=head1 DESCRIPTION

This module schedules email messages to be sent one by one at a later time.

Your web application sends a lot of emails to your users for notifications, verification, 
updates or anything. Whether you use C<sendmail> or C<SMTP>, your emails are sent slower 
and they become the bottleneck of your application. 

One possible solution is to use this module to write your emails to files and send them
later one by one, perhaps from another script with lower process priority. You could even
process the email queue using several concurrently working scripts and it will be OK because 
this module handles all file locking and queue management.

This module does not provide the actual email sending functionality. It is up to the user of
this module to decide what to use for sending emails.

=head1 EMAIL FORMATS

All emails must be a L<Email::Simple> object. Please see the documentation for Email::Simple,
to understand how to create emails.

When an email is I<scheduled>, it is dumped to a file in the specified L</path> as plain
text RFC2822 email message.

When an email is loaded from a file it is converted back to an L<Email::Simple> object.

=head1 ATTRIBUTES

The following attributes are available during object construction

=head2 path

Specifies the path where email files will be stores. The default is the current path.
If the path is not writeable it will croak.

=head2 mkpath 

If set to 1 it will try to create a the C<path> unless the path already exists.

=head2 ext

Set the extension for the email files. The default value for this attribute is C<.eml>

=head2 prefix

Set the prefix for the email files. The default value for this attribute is C<msg>

=head2 xlock

Set the name of the email header which marks an email file as locked. The default value
is C<X-Lock>.

=head2 timeout

Timeout in seconds to hold email files locked. If a mailer process locks an email file 
and does not send it within the specified time, the file will be unlocked and available 
for other mailer processes. The default value is 3600.

=head2 grab_count

Sets the number of messages that L</next> will lock when called the very first time.
The default value is 50. If set to 0, then C<next> will lock B<all> messages in the queue.

  # Only lock 2 messages at a time
  $fq->grab_count(2);

  $fq->next;        # Lock 2 messages and return the first
  $fq->next;        # Return the second locked message

  $fq->next;        # Lock another 2 messages and return the first

=head1 METHODS

The following methods are available:

=head2 schedule( $message )

Schedule a message. C<$message> must be an L<Email::Simple> instance. Returns the ID of
the message, which is the filename used to save it.

  my $message = Email::Simple->new( ... );
  my $message_id = $fq->schedule( $message );

=head2 count

Returns the count of all scheduled messages.

  my $all_emails = $fq->count;

=head2 next

Returns the next scheduled message as an Email::Simple instance and immediately removes
that message from the queue. Returns undef is there are no more messages in the queue.

  print "Processing " . $fq->count . " messages\n";
  while ( my $message = $fq->next ) {
      # Do something with $message, 
      # for example send $message->as_string via sendmail
  }
  print "All mail sent\n";


=head1 SEE ALSO

L<Email::Simple>

=head1 AUTHOR

minimalist, C<< <minimalist at lavabit.com> >>

=head1 BUGS

Bug reports and patches are welcome. Reports which include a failing 
Test::More style test are helpful and will receive priority.

=head1 DEVELOPMENT

The source code of this module is available on GitHub:
L<https://github.com/naturalist/Email--Queue>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 minimalist.

This program is free software; you can redistribute it and/or modify 
it under the terms as perl itself.

=cut
