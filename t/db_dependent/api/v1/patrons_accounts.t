#!/usr/bin/perl

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

use Modern::Perl;

use Test::More tests => 2;

use Test::Mojo;

use t::lib::TestBuilder;
use t::lib::Mocks;

use Koha::Account::Lines;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

t::lib::Mocks::mock_preference( 'RESTBasicAuth', 1 );

my $t = Test::Mojo->new('Koha::REST::V1');

subtest 'get_balance() tests' => sub {

    plan tests => 15;

    $schema->storage->txn_begin;

    my $patron = $builder->build_object({
        class => 'Koha::Patrons',
        value => { flags => 1 }
    });
    my $password = 'thePassword123';
    $patron->set_password({ password => $password, skip_validation => 1 });
    my $userid = $patron->userid;

    my $library   = $builder->build_object({ class => 'Koha::Libraries' });
    my $patron_id = $patron->id;
    my $account   = $patron->account;

    $t->get_ok("//$userid:$password@/api/v1/patrons/$patron_id/account")
      ->status_is(200)
      ->json_is(
        {   balance             => 0.00,
            outstanding_debits  => { total => 0, lines => [] },
            outstanding_credits => { total => 0, lines => [] }
        }
    );

    my $account_line_1 = Koha::Account::Line->new(
        {
            borrowernumber    => $patron->borrowernumber,
            date              => \'NOW()',
            amount            => 50,
            description       => "A description",
            debit_type_code   => "NEW_CARD", # New card
            amountoutstanding => 50,
            manager_id        => $patron->borrowernumber,
            branchcode        => $library->id,
            interface         => 'test',
        }
    )->store();
    $account_line_1->discard_changes;

    my $account_line_2 = Koha::Account::Line->new(
        {
            borrowernumber    => $patron->borrowernumber,
            date              => \'NOW()',
            amount            => 50.01,
            description       => "A description",
            debit_type_code   => "NEW_CARD", # New card
            amountoutstanding => 50.01,
            manager_id        => $patron->borrowernumber,
            branchcode        => $library->id,
            interface         => 'test',
        }
    )->store();
    $account_line_2->discard_changes;

    $t->get_ok("//$userid:$password@/api/v1/patrons/$patron_id/account")
      ->status_is(200)
      ->json_is(
        {   balance            => 100.01,
            outstanding_debits => {
                total => 100.01,
                lines => [
                    $account_line_1->to_api,
                    $account_line_2->to_api
                ]
            },
            outstanding_credits => {
                total => 0,
                lines => []
            }
        }
    );

    $account->pay(
        {   amount       => 100.01,
            note         => 'He paid!',
            description  => 'Finally!',
            library_id   => $patron->branchcode,
            account_type => 'PAYMENT',
            offset_type  => 'Payment'
        }
    );

    $t->get_ok("//$userid:$password@/api/v1/patrons/$patron_id/account")
      ->status_is(200)
      ->json_is(
        {   balance             => 0,
            outstanding_debits  => { total => 0, lines => [] },
            outstanding_credits => { total => 0, lines => [] }
        }
    );

    # add a credit
    my $credit_line = $account->add_credit(
        { amount => 10, user_id => $patron->id, library_id => $library->id, interface => 'test' } );
    # re-read from the DB
    $credit_line->discard_changes;

    $t->get_ok("//$userid:$password@/api/v1/patrons/$patron_id/account")
      ->status_is(200)
      ->json_is(
        {   balance            => -10,
            outstanding_debits => {
                total => 0,
                lines => []
            },
            outstanding_credits => {
                total => -10,
                lines => [ $credit_line->to_api ]
            }
        }
    );

    # Accountline without manager_id (happens with fines.pl cron for example)
    my $account_line_3 = Koha::Account::Line->new(
        {
            borrowernumber    => $patron->borrowernumber,
            date              => \'NOW()',
            amount            => 50,
            description       => "A description",
            debit_type_code   => "NEW_CARD", # New card
            amountoutstanding => 50,
            manager_id        => undef,
            branchcode        => $library->id,
            interface         => 'test',
        }
    )->store();
    $account_line_3->discard_changes;

    $t->get_ok("//$userid:$password@/api/v1/patrons/$patron_id/account")
      ->status_is(200)
      ->json_is(
        {   balance            => 40.00,
            outstanding_debits => {
                total => 50.00,
                lines => [
                    $account_line_3->to_api
                ]
            },
            outstanding_credits => {
                total => -10,
                lines => [ $credit_line->to_api ]
            }
        }
    );

    $schema->storage->txn_rollback;
};

subtest 'add_credit() tests' => sub {

    plan tests => 18;

    $schema->storage->txn_begin;

    my $patron = $builder->build_object({
        class => 'Koha::Patrons',
        value => { flags => 1 }
    });
    my $password = 'thePassword123';
    $patron->set_password({ password => $password, skip_validation => 1 });
    my $userid = $patron->userid;

    my $library   = $builder->build_object({ class => 'Koha::Libraries' });
    my $patron_id = $patron->id;
    my $account   = $patron->account;

    is( $account->outstanding_debits->count,  0, 'No outstanding debits for patron' );
    is( $account->outstanding_credits->count, 0, 'No outstanding credits for patron' );

    my $credit = { amount => 100 };

    $t->post_ok("//$userid:$password@/api/v1/patrons/$patron_id/account/credits" => json => $credit)
      ->status_is(200)
      ->json_has('/account_line_id');

    my $outstanding_credits = $account->outstanding_credits;
    is( $outstanding_credits->count,             1 );
    is( $outstanding_credits->total_outstanding, -100 );

    my $debit_1 = Koha::Account::Line->new(
        {   borrowernumber    => $patron->borrowernumber,
            date              => \'NOW()',
            amount            => 10,
            description       => "A description",
            debit_type_code   => "NEW_CARD",                       # New card
            amountoutstanding => 10,
            manager_id        => $patron->borrowernumber,
            interface         => 'test',
        }
    )->store();
    my $debit_2 = Koha::Account::Line->new(
        {   borrowernumber    => $patron->borrowernumber,
            date              => \'NOW()',
            amount            => 15,
            description       => "A description",
            debit_type_code   => "NEW_CARD",                       # New card
            amountoutstanding => 15,
            manager_id        => $patron->borrowernumber,
            interface         => 'test',
        }
    )->store();

    is( $account->outstanding_debits->total_outstanding, 25 );
    $credit->{library_id} = $library->id;

    $t->post_ok("//$userid:$password@/api/v1/patrons/$patron_id/account/credits" => json => $credit)
      ->status_is(200)
      ->json_has('/account_line_id');

    my $account_line_id = $t->tx->res->json->{account_line_id};
    is( Koha::Account::Lines->find($account_line_id)->branchcode,
        $library->id, 'Library id is sored correctly' );

    is( $account->outstanding_debits->total_outstanding,
        0, "Debits have been cancelled automatically" );

    my $debit_3 = Koha::Account::Line->new(
        {   borrowernumber    => $patron->borrowernumber,
            date              => \'NOW()',
            amount            => 100,
            description       => "A description",
            debit_type_code   => "NEW_CARD",                       # New card
            amountoutstanding => 100,
            manager_id        => $patron->borrowernumber,
            interface         => 'test',
        }
    )->store();

    $credit = {
        amount            => 35,
        account_lines_ids => [ $debit_1->id, $debit_2->id, $debit_3->id ]
    };

    $t->post_ok("//$userid:$password@/api/v1/patrons/$patron_id/account/credits" => json => $credit)
      ->status_is(200)
      ->json_has('/account_line_id');

    my $outstanding_debits = $account->outstanding_debits;
    is( $outstanding_debits->total_outstanding, 65 );
    is( $outstanding_debits->count,             1 );

    $schema->storage->txn_rollback;
};
