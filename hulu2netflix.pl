#!/usr/bin/perl

use strict;
use warnings;
use diagnostics;
use Data::Dumper;
use feature qw(say signatures);
no warnings "experimental::signatures";
use List::Util qw(min max);
use Text::CSV;
use JSON;
use Date::Parse;
binmode STDOUT, ':utf8';

my $csv_fname = $ARGV[0];

 my $csv = Text::CSV->new ( { binary => 1 } )  # should set binary attribute.
				 or die "Cannot use CSV: ".Text::CSV->error_diag ();
open my $fh, "<:encoding(utf8)", $csv_fname or die "$!";

my $fields = $csv->getline($fh);

my @data;

while(my $row = $csv->getline($fh))
{
	my %row_data;
	foreach my $i (0 .. $fields->$#*)
	{
		$row_data{$fields->[$i]} = $row->[$i];
	}
	push @data, \%row_data;
}

my %fake_netflix_ids;

sub get_fake_netflix_id
{
	my ($input) = @_;
	my $netflix_id = $fake_netflix_ids{$input} // ((max(values %fake_netflix_ids) // 1) + 1);
	$fake_netflix_ids{$input} = $netflix_id;
	return $netflix_id;
}

foreach my $watch (@data)
{
	my $date = $watch->{"Last Played At"};
	$watch->{date} = $date ? 1000 * str2time($date) : 0;
	$watch->{title} = $watch->{"Episode Name"};

	my $netflix_id_field;
	my $netflix_id_input;
	if($watch->{"Series Name"} ne 'N/A')
	{
		# TV series
		$watch->{seriesTitle} = $watch->{"Series Name"};
		$watch->{episodeTitle} = $watch->{"Episode Name"};
		$watch->{series} = get_fake_netflix_id($watch->{"Series Name"});
	}
	else
	{
		# Movie
	}
	# both TV and Movie
	$watch->{movieID} = get_fake_netflix_id($watch->{"Episode Name"});
}

print to_json(\@data, {pretty=>1});
