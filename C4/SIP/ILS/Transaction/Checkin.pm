
# An object to handle checkin status
#

package C4::SIP::ILS::Transaction::Checkin;

use warnings;
use strict;

# use POSIX qw(strftime);

use C4::SIP::ILS::Transaction;

use C4::Circulation;
use C4::Debug;
use C4::Items qw( ModItemTransfer );
use C4::Reserves qw( ModReserveAffect );
use Koha::DateUtils qw( dt_from_string );
use Koha::Items;

use parent qw(C4::SIP::ILS::Transaction);

my %fields = (
    magnetic => 0,
    sort_bin => undef,
    collection_code  => undef,
    # 3M extensions:
    call_number      => undef,
    destination_loc  => undef,
    alert_type       => undef,  # 00,01,02,03,04 or 99
    hold_patron_id   => undef,
    hold_patron_name => "",
    hold             => undef,
);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new();                # start with an ILS::Transaction object

    foreach (keys %fields) {
        $self->{_permitted}->{$_} = $fields{$_};    # overlaying _permitted
    }

    @{$self}{keys %fields} = values %fields;        # copying defaults into object
    return bless $self, $class;
}

sub do_checkin {
    my $self = shift;
    my $branch = shift;
    my $return_date = shift;
    my $account = shift;

    my $checked_in_ok     = $account->{checked_in_ok};
    my $cv_triggers_alert = $account->{cv_triggers_alert};
    my $holds_block_checkin  = $account->{holds_block_checkin};

    if (!$branch) {
        $branch = 'SIP2';
    }
    my $barcode = $self->{item}->id;

    if ( $return_date ) {
        $return_date =   substr( $return_date, 0, 4 )
                       . '-'
                       . substr( $return_date, 4, 2 )
                       . '-'
                       . substr( $return_date, 6, 2 )
                       . q{ }
                       . substr( $return_date, 12, 2 )
                       . ':'
                       . substr( $return_date, 14, 2 )
                       . ':'
                       . substr( $return_date, 16, 2 );
        $return_date = dt_from_string($return_date);
    }

    my ( $return, $messages, $issue, $borrower );

    my $item = Koha::Items->find( { barcode => $barcode } );

    my $human_required = 0;
    if (   C4::Context->preference("CircConfirmItemParts")
        && defined($item)
        && $item->materials )
    {
        $human_required                   = 1;
        $messages->{additional_materials} = 1;
    }

    my $checkin_blocked_by_holds = $holds_block_checkin && $item->biblio->holds->count;

    $debug and warn "do_checkin() calling AddReturn($barcode, $branch)";
    ( $return, $messages, $issue, $borrower ) =
      AddReturn( $barcode, $branch, undef, $return_date )
      unless $human_required || $checkin_blocked_by_holds;

    if ( $checked_in_ok ) {
        delete $messages->{ItemLocationUpdated};
        delete $messages->{NotIssued};
        delete $messages->{LocalUse};
        $return = 1 unless keys %$messages;
    }

    # biblionumber, biblioitemnumber, itemnumber
    # borrowernumber, reservedate, branchcode
    # cancellationdate, found, reservenotes, priority, timestamp
    if ($messages->{additional_materials}) {
        $self->alert_type('99');
    }
    if( $messages->{DataCorrupted} ) {
        $self->alert_type('98');
    }
    if ($messages->{BadBarcode}) {
        $self->alert_type('99');
    }
    if ($messages->{withdrawn}) {
        $self->alert_type('99');
    }
    if ($messages->{WasLost}) {
        $self->alert_type('99') if C4::Context->preference("BlockReturnOfLostItems");
    }
    if ($messages->{Wrongbranch}) {
        $self->{item}->destination_loc($messages->{Wrongbranch}->{Rightbranch});
        $self->alert_type('04');            # send to other branch
    }
    if ($messages->{WrongTransfer}) {
        $self->{item}->destination_loc($messages->{WrongTransfer});
        $self->alert_type('04');            # send to other branch
    }
    if ($messages->{NeedsTransfer}) {
        $self->{item}->destination_loc($messages->{NeedsTransfer});
        $self->alert_type('04');            # send to other branch
    }
    if ($messages->{WasTransfered}) { # set into transit so tell unit
        $self->{item}->destination_loc($item->homebranch);
        $self->alert_type('04');            # send to other branch
    }
    if ($messages->{ResFound} || $checkin_blocked_by_holds ) {
        if ($checkin_blocked_by_holds) {
            $self->alert_type('99');
            $return = 0;
        } elsif ($branch eq $messages->{ResFound}->{branchcode}) {
            $self->hold($messages->{ResFound});
            $self->alert_type('01');
            ModReserveAffect( $messages->{ResFound}->{itemnumber},
                $messages->{ResFound}->{borrowernumber}, 0, $messages->{ResFound}->{reserve_id});

        } else {
            $self->hold($messages->{ResFound});
            $self->alert_type('02');
            ModReserveAffect( $item->itemnumber,
                $messages->{ResFound}->{borrowernumber}, 1, $messages->{ResFound}->{reserve_id});
            ModItemTransfer( $item->itemnumber,
                $branch,
                $messages->{ResFound}->{branchcode},
                'Reserve',
            );

        }
        $self->{item}->hold_patron_id( $messages->{ResFound}->{borrowernumber} );
        $self->{item}->destination_loc( $messages->{ResFound}->{branchcode} );
    }
    # ignoring messages: NotIssued, WasTransfered

    if ($cv_triggers_alert) {
        $self->alert( defined $self->alert_type ); # Overwrites existing alert value, should set to 0 if there is no alert type
    }
    else {
        $self->alert( !$return || defined $self->alert_type );
    }

    $self->ok($return);

    return { messages => $messages };
}

sub resensitize {
	my $self = shift;
	unless ($self->{item}) {
		warn "resensitize(): no item found in object to resensitize";
		return;
	}
	return !$self->{item}->magnetic_media;
}

sub patron_id {
	my $self = shift;
	unless ($self->{patron}) {
		warn "patron_id(): no patron found in object";
		return;
	}
	return $self->{patron}->id;
}

1;
