#!/usr/bin/perl

# This file is part of Koha
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

use Test::More tests => 5;

use Koha::Report;
use Koha::Reports;
use Koha::Database;

use t::lib::TestBuilder;

my $schema = Koha::Database->new->schema;
$schema->storage->txn_begin;

my $builder = t::lib::TestBuilder->new;
my $nb_of_reports = Koha::Reports->search->count;
my $new_report_1 = Koha::Report->new({
    report_name => 'report_name_for_test_1',
    savedsql => 'SELECT "I wrote a report"',
})->store;
my $new_report_2 = Koha::Report->new({
    report_name => 'report_name_for_test_1',
    savedsql => 'SELECT "Oops, I did it again"',
})->store;

like( $new_report_1->id, qr|^\d+$|, 'Adding a new report should have set the id');
is( Koha::Reports->search->count, $nb_of_reports + 2, 'The 2 reports should have been added' );

my $retrieved_report_1 = Koha::Reports->find( $new_report_1->id );
is( $retrieved_report_1->report_name, $new_report_1->report_name, 'Find a report by id should return the correct report' );

$retrieved_report_1->delete;
is( Koha::Reports->search->count, $nb_of_reports + 1, 'Delete should have deleted the report' );

subtest 'prep_report' => sub {
    plan tests => 3;

    my $report = Koha::Report->new({
        report_name => 'report_name_for_test_1',
        savedsql => 'SELECT * FROM items WHERE itemnumber IN <<Test|list>>',
    })->store;

    my ($sql, undef) = $report->prep_report( ['Test|list'],["1\n12\n\r243"] );
    is( $sql, q{SELECT * FROM items WHERE itemnumber IN ('1','12','243')},'Expected sql generated correctly with single param and name');

    $report->savedsql('SELECT * FROM items WHERE itemnumber IN <<Test|list>> AND <<Another>> AND <<Test|list>>')->store;

    ($sql, undef) = $report->prep_report( ['Test|list','Another'],["1\n12\n\r243",'the other'] );
    is( $sql, q{SELECT * FROM items WHERE itemnumber IN ('1','12','243') AND 'the other' AND ('1','12','243')},'Expected sql generated correctly with multiple params and names');

    ($sql, undef) = $report->prep_report( [],["1\n12\n\r243",'the other',"42\n32\n22\n12"] );
    is( $sql, q{SELECT * FROM items WHERE itemnumber IN ('1','12','243') AND 'the other' AND ('42','32','22','12')},'Expected sql generated correctly with multiple params and no names');

};

$schema->storage->txn_rollback;
