#!/usr/bin/perl

# Copyright 2000-2002 Katipo Communications
# Copyright 2010 BibLibre
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.


=head1 moremember.pl

 script to do a borrower enquiry/bring up borrower details etc
 Displays all the details about a borrower
 written 20/12/99 by chris@katipo.co.nz
 last modified 21/1/2000 by chris@katipo.co.nz
 modified 31/1/2001 by chris@katipo.co.nz
   to not allow items on request to be renewed

 needs html removed and to use the C4::Output more, but its tricky

=cut

use Modern::Perl;
use CGI qw ( -utf8 );
use C4::Context;
use C4::Auth qw/:DEFAULT get_session/;
use C4::Output;
use C4::Members;
use C4::Koha;
use Koha::DateUtils;

#use Smart::Comments;
#use Data::Dumper;

use vars qw($debug);

BEGIN {
	$debug = $ENV{DEBUG} || 0;
}

my $input = CGI->new;
my $sessionID = $input->cookie("CGISESSID");
my $session = get_session($sessionID);

$debug or $debug = $input->param('debug') || 0;
my $print = $input->param('print');
my $error = $input->param('error');

# circ staff who process checkouts but can't edit
# patrons still need to be able to print receipts
my $flagsrequired = { circulate => "circulate_remaining_permissions" };

my ( $template, $loggedinuser, $cookie ) = get_template_and_user(
    {
        template_name   => "circ/printslip.tt",
        query           => $input,
        type            => "intranet",
        flagsrequired   => $flagsrequired,
        debug           => 1,
    }
);

my $borrowernumber = $input->param('borrowernumber');

my $logged_in_user = Koha::Patrons->find( $loggedinuser );
my $patron         = Koha::Patrons->find( $borrowernumber );
output_and_exit_if_error( $input, $cookie, $template, { module => 'members', logged_in_user => $logged_in_user, current_patron => $patron } );

my $branch=C4::Context->userenv->{'branch'};
my ($slip, $is_html);
if ( $print eq 'checkinslip' ) {
    my $checkinslip_branch = $session->param('branch') ? $session->param('branch') : $branch;

    # get today's checkins
    my @itemnumbers = $patron->old_checkouts->search( { branchcode => $checkinslip_branch } )
      ->filter_by_todays_checkins->get_column('itemnumber');

    my %loops = (
        old_issues => \@itemnumbers,
    );

    my $letter = C4::Letters::GetPreparedLetter(
        module      => 'circulation',
        letter_code => 'CHECKINSLIP',
        branchcode  => $checkinslip_branch,
        lang        => $patron->lang,
        tables      => {
            branches  => $checkinslip_branch,
            borrowers => $borrowernumber,
        },
        loops                  => \%loops,
        message_transport_type => 'print'
    );

    $slip    = $letter->{content};
    $is_html = $letter->{is_html};

} elsif (my $letter = IssueSlip ($session->param('branch') || $branch, $borrowernumber, $print eq "qslip")) {
    $slip = $letter->{content};
    $is_html = $letter->{is_html};
}

$template->param(
    slip => $slip,
    plain => !$is_html,
    borrowernumber => $borrowernumber,
    caller => 'members',
    stylesheet => C4::Context->preference("SlipCSS"),
    error           => $error,
);

$template->param( IntranetSlipPrinterJS => C4::Context->preference('IntranetSlipPrinterJS' ) );

output_html_with_http_headers $input, $cookie, $template->output;
