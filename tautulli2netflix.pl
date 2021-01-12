#!/usr/bin/perl

use strict;
use warnings;
use diagnostics;
use Data::Dumper;
use feature qw(say signatures);
no warnings "experimental::signatures";
use List::Util qw(min max);
use JSON;
use File::Slurp;

my %fake_netflix_ids;
sub get_fake_netflix_id
{
	my ($input) = @_;
	die if(!$input);
	my $netflix_id = $fake_netflix_ids{$input} // ((max(values %fake_netflix_ids) // 1) + 1);
	$fake_netflix_ids{$input} = $netflix_id;
	return $netflix_id;
}


my $in_fname = $ARGV[0];
my $data = from_json(read_file($in_fname));

my @watches;
foreach my $response ($data->{response}->{data}->{data}->@*)
{
	my %watch;
	$watch{date} = $response->{stopped} * 1000;
	$watch{title} = $response->{title};
	if($response->{grandparent_title})
	{
		# TV series
		$watch{seriesTitle} = $response->{grandparent_title};
		$watch{episodeTitle} = $watch{title};
		$watch{series} = get_fake_netflix_id($watch{seriesTitle});
	}
	else
	{
		# movie
	}
	# both TV and movie
	$watch{movieID} = get_fake_netflix_id($response->{full_title});
	push @watches, \%watch;
}
print to_json(\@watches, {pretty=>1});

