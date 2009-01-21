use strict;
use warnings;

package Net::Trac::Ticket;

=head1 NAME

Net::Trac::Ticket - Create, read, and update tickets on a remote Trac instance

=head1 SYNOPSIS

    my $ticket = Net::Trac::Ticket->new( connection => $trac );
    $ticket->load( 1 );
    
    print $ticket->summary, "\n";

=head1 DESCRIPTION

This class represents a ticket on a remote Trac instance.  It provides methods
for creating, reading, and updating tickets and their history as well as adding
comments and getting attachments.

=cut

use Moose;
use Params::Validate qw(:all);
use Lingua::EN::Inflect qw();
use DateTime::Format::ISO8601;

use Net::Trac::TicketSearch;
use Net::Trac::TicketHistory;
use Net::Trac::TicketAttachment;

has connection => (
    isa => 'Net::Trac::Connection',
    is  => 'ro'
);

has state => (
    isa => 'HashRef',
    is  => 'rw'
);

has _attachments            => ( isa => 'ArrayRef', is => 'rw' );
has _loaded_new_metadata    => ( isa => 'Bool',     is => 'rw' );
has _loaded_update_metadata => ( isa => 'Bool',     is => 'rw' );

has valid_milestones  => ( isa => 'ArrayRef', is => 'rw', default => sub {[]} );
has valid_types       => ( isa => 'ArrayRef', is => 'rw', default => sub {[]} );
has valid_components  => ( isa => 'ArrayRef', is => 'rw', default => sub {[]} );
has valid_priorities  => ( isa => 'ArrayRef', is => 'rw', default => sub {[]} );
has valid_resolutions => ( isa => 'ArrayRef', is => 'rw', default => sub {[]} );
has valid_severities  => ( isa => 'ArrayRef', is => 'rw', default => sub {[]} );

sub basic_statuses {
    qw( new accepted assigned reopened closed )
}

sub valid_props {
    qw( id summary type status priority severity resolution owner reporter cc
        description keywords component milestone version time changetime )
}

sub valid_create_props { grep { !/^(?:resolution|time|changetime)$/i } $_[0]->valid_props }
sub valid_update_props { grep { !/^(?:time|changetime)$/i } $_[0]->valid_props }

for my $prop ( __PACKAGE__->valid_props ) {
    no strict 'refs';
    *{ "Net::Trac::Ticket::" . $prop } = sub { shift->state->{$prop} };
}

sub created       { shift->_time_to_datetime('time') }
sub last_modified { shift->_time_to_datetime('changetime') }

sub _time_to_datetime {
    my ($self, $prop) = @_;
    my $time = $self->$prop;
    $time =~ s/ /T/;
    return DateTime::Format::ISO8601->parse_datetime( $time );
}

sub BUILD {
    my $self = shift;
    $self->_fetch_new_ticket_metadata;
}

=head1 METHODS

=head2 new HASH

Takes a key C<connection> with a value of a L<Net::Trac::Connection>.  Returns
an empty ticket object.

=head2 load ID

Loads up the ticket with the specified ID.  Returns the ticket ID loaded on success
and undef on failure.

=cut

sub load {
    my $self = shift;
    my ($id) = validate_pos( @_, { type => SCALAR } );

    my $search = Net::Trac::TicketSearch->new( connection => $self->connection );
    $search->limit(1);
    $search->query( id => $id, _no_objects => 1 );

    return unless @{ $search->results };

    my $tid = $self->load_from_hashref( $search->results->[0] );
    return $tid;
}

=head2 load_from_hashref HASHREF [SKIP]

You should never need to use this method yourself.  Loads a ticket from a hashref
of data, optionally skipping metadata loading (values of C<valid_*> accessors).

=cut

sub load_from_hashref {
    my $self = shift;
    my ($hash, $skip_metadata) = validate_pos(
        @_,
        { type => HASHREF },
        { type => BOOLEAN, default => undef }
    );

    return undef unless $hash and $hash->{'id'};

    $self->state( $hash );
    $self->_fetch_update_ticket_metadata unless $skip_metadata;
    return $hash->{'id'};
}

sub _get_new_ticket_form {
    my $self = shift;
    $self->connection->ensure_logged_in;
    $self->connection->_fetch("/newticket") or return;
    my $i = 1; # form number
    for my $form ( $self->connection->mech->forms() ) {
        return ($form,$i) if $form->find_input('field_reporter');
        $i++;
    }
    return undef;
}

sub _get_update_ticket_form {
    my $self = shift;
    $self->connection->ensure_logged_in;
    $self->connection->_fetch("/ticket/".$self->id) or return;
    my $i = 1; # form number;
    for my $form ( $self->connection->mech->forms() ) {
        return ($form,$i) if $form->find_input('field_reporter');
        $i++;
    }
    return undef;
}

sub _fetch_new_ticket_metadata {
    my $self = shift;

    return 1 if $self->_loaded_new_metadata;

    my ($form, $form_num) = $self->_get_new_ticket_form;
    return undef unless $form;

    $self->valid_milestones([ $form->find_input("field_milestone")->possible_values ]);
    $self->valid_types     ([ $form->find_input("field_type")->possible_values ]);
    $self->valid_components([ $form->find_input("field_component")->possible_values ]);
    $self->valid_priorities([ $form->find_input("field_priority")->possible_values ]);

    my $severity = $form->find_input("field_severity");
    $self->valid_severities([ $severity->possible_values ]) if $severity;
    
#    my @inputs = $form->inputs;
#
#    for my $in (@inputs) {
#        my @values = $in->possible_values;
#    }

    $self->_loaded_new_metadata( 1 );
    return 1;
}

sub _fetch_update_ticket_metadata {
    my $self = shift;

    return 1 if $self->_loaded_update_metadata;

    my ($form, $form_num) = $self->_get_update_ticket_form;
    return undef unless $form;

    my $resolutions = $form->find_input("action_resolve_resolve_resolution");
    $self->valid_resolutions( [$resolutions->possible_values] ) if $resolutions;
    
    $self->_loaded_update_metadata( 1 );
    return 1;
}

sub _metadata_validation_rules {
    my $self = shift;
    my $type = lc shift;

    # Ensure that we've loaded up metadata
    $self->_fetch_new_ticket_metadata;
    $self->_fetch_update_ticket_metadata if $type eq 'update';

    my %rules;
    for my $prop ( @_ ) {
        my $method = "valid_" . Lingua::EN::Inflect::PL($prop);
        if ( $self->can($method) ) {
            # XXX TODO: escape the values for the regex?
            my $values = join '|', grep { defined and length } @{$self->$method};
            if ( length $values ) {
                my $check = qr{^(?:$values)$}i;
                $rules{$prop} = { type => SCALAR, regex => $check, optional => 1 };
            } else {
                $rules{$prop} = 0;
            }
        }
        else {
            $rules{$prop} = 0; # optional
        }
    }
    return \%rules;
}

=head2 create HASH

Creates and loads a new ticket with the values specified.
Returns undef on failure and the new ticket ID on success.

=cut

sub create {
    my $self = shift;
    my %args = validate(
        @_,
        $self->_metadata_validation_rules( 'create' => $self->valid_create_props )
    );

    my ($form,$form_num)  = $self->_get_new_ticket_form();

    my %form = map { 'field_' . $_ => $args{$_} } keys %args;

    $self->connection->mech->submit_form(
        form_number => $form_num,
        fields => { %form, submit => 1 }
    );

    my $reply = $self->connection->mech->response;
    $self->connection->_warn_on_error( $reply->base->as_string ) and return;

    if ($reply->title =~ /^#(\d+)/) {
        my $id = $1;
        $self->load($id);
        return $id;
    } else {
        return undef;
    }
}

=head2 update HASH

Updates the current ticket with the specified values.  This method will
attempt to emulate Trac's default workflow by auto-updating the status
based on changes to other fields.  To avoid this auto-updating, specify
a true value as the value for the key C<no_auto_status>.

Returns undef on failure, and the ID of the current ticket on success.

=cut

sub update {
    my $self = shift;
    my %args = validate(
        @_,
        {
            comment         => 0,
            no_auto_status  => { default => 0 },
            %{$self->_metadata_validation_rules( 'update' => $self->valid_update_props )}
        }
    );

    # Automatically set the status for default trac workflows unless
    # we're asked not to
    unless ( $args{'no_auto_status'} ) {
        $args{'status'} = 'closed'
            if $args{'resolution'} and not $args{'status'};
        
        $args{'status'} = 'assigned'
            if $args{'owner'} and not $args{'status'};
        
        $args{'status'} = 'accepted'
            if $args{'owner'} and $args{'owner'} eq $self->connection->user
               and not $args{'status'};
    }

    my ($form,$form_num)= $self->_get_update_ticket_form();

    # Copy over the values we'll be using
    my %form = map  { "field_".$_ => $args{$_} }
               grep { !/comment|no_auto_status/ } keys %args;

    # Copy over comment too -- it's a pseudo-prop
    $form{'comment'} = $args{'comment'};

    $self->connection->mech->submit_form(
        form_number => $form_num,
        fields => { %form, submit => 1 }
    );

    my $reply = $self->connection->mech->response;
    if ( $reply->is_success ) {
        return $self->load($self->id);
    }
    else {
        return undef;
    }
}

=head2 comment TEXT

Adds a comment to the current ticket.  Returns undef on failure, true on success.

=cut

sub comment {
    my $self = shift;
    my ($comment) = validate_pos( @_, { type => SCALAR });
    $self->update( comment => $comment );
}

=head2 history

Returns a L<Net::Trac::TicketHistory> object for this ticket.

=cut

sub history {
    my $self = shift;
    my $hist = Net::Trac::TicketHistory->new({ connection => $self->connection });
    $hist->load( $self->id );
    return $hist;
}

=head2 comments

Returns an array or arrayref (depending on context) of history entries which
have comments included.  This will include history entries representing
attachments if they have descriptions.

=cut

sub comments {
    my $self = shift;
    my $hist = $self->history;

    my @comments;
    for ( @{$hist->entries} ) {
        push @comments, $_ if $_->content =~ /\S/;
    }
    return wantarray ? @comments : \@comments;
}

sub _get_add_attachment_form {
    my $self = shift;
    $self->connection->ensure_logged_in;
    $self->connection->_fetch("/attachment/ticket/".$self->id."/?action=new") or return;
    my $i = 1; # form number;
    for my $form ( $self->connection->mech->forms() ) {
        return ($form,$i) if $form->find_input('attachment');
        $i++;
    }
    return undef;
}

=head2 attach PARAMHASH

Attaches the specified C<file> with an optional C<description>.
Returns undef on failure and the new L<Net::Trac::TicketAttachment> object
on success.

=cut

sub attach {
    my $self = shift;
    my %args = validate( @_, { file => 1, description => 0 } );

    my ($form, $form_num)  = $self->_get_add_attachment_form();

    $self->connection->mech->submit_form(
        form_number => $form_num,
        fields => {
            attachment  => $args{'file'},
            description => $args{'description'},
            replace     => 0
        }
    );

    my $reply = $self->connection->mech->response;
    $self->connection->_warn_on_error( $reply->base->as_string ) and return;

    return $self->attachments->[-1];
}

sub _update_attachments {
    my $self = shift;
    $self->connection->ensure_logged_in;
    my $content = $self->connection->_fetch("/attachment/ticket/".$self->id."/")
        or return;
    
    if ( $content =~ m{<dl class="attachments">(.+?)</dl>}is ) {
        my $html = $1 . '<dt>'; # adding a <dt> here is a hack that lets us
                                # reliably parse this with one regex

        my @attachments;
        while ( $html =~ m{<dt>(.+?)(?=<dt>)}gis ) {
            my $fragment = $1;
            my $attachment = Net::Trac::TicketAttachment->new({
                connection => $self->connection,
                ticket     => $self->id
            });
            $attachment->_parse_html_chunk( $fragment );
            push @attachments, $attachment;
        }
        $self->_attachments( \@attachments );
    }
}

=head2 attachments

Returns an array or arrayref (depending on context) of all the
L<Net::Trac::TicketAttachment> objects for this ticket.

=cut

sub attachments {
    my $self = shift;
    $self->_update_attachments;
    return wantarray ? @{$self->_attachments} : $self->_attachments;
}

=head1 ACCESSORS

=head2 connection

=head2 id

=head2 summary

=head2 type

=head2 status

=head2 priority

=head2 severity

=head2 resolution

=head2 owner

=head2 reporter

=head2 cc

=head2 description

=head2 keywords

=head2 component

=head2 milestone

=head2 version

=head2 created

Returns a L<DateTime> object

=head2 last_modified

Returns a L<DateTime> object

=head2 basic_statuses

Returns a list of the basic statuses available for a ticket.  Others
may be defined by the remote Trac instance, but we have no way of easily
getting them.

=head2 valid_props

Returns a list of the valid properties of a ticket.

=head2 valid_create_props

Returns a list of the valid properties specifiable when creating a ticket.

=head2 valid_update_props

Returns a list of the valid updatable properties.

=head2 Valid property values

These accessors are loaded from the remote Trac instance with the valid
values for the properties upon instantiation of a ticket object.

=over

=item valid_milestones

=item valid_types

=item valid_components

=item valid_priorities

=item valid_resolutions - Only loaded when a ticket is loaded.

=item valid_severities - May not be provided by the Trac instance.

=back

=head1 LICENSE

Copyright 2008-2009 Best Practical Solutions.

This package is licensed under the same terms as Perl 5.8.8.

=cut

__PACKAGE__->meta->make_immutable;
no Moose;

1;
