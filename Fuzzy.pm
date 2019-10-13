#!/usr/bin/perl

use strict;
use warnings;
use diagnostics;
use feature qw(say signatures);
no warnings "experimental::signatures";

package Fuzzy;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(ratio token_set_ratio);

use Text::LevenshteinXS qw(distance);
use Data::Dumper;
use List::Util qw(max);

sub ratio($s1, $s2)
{
	my $l = length($s1) + length($s2);
	return int(100.0 * ($l - distance($s1, $s2)) / $l);
}

sub preprocess($s)
{
	$s =~ s/\b1\b/one/g;
	$s =~ s/\b2\b/two/g;
	$s =~ s/\b3\b/three/g;
	$s =~ s/\b4\b/four/g;
	$s = lc $s;
	return $s;
}

sub token_set_ratio($s1, $s2)
{
	$s1 = preprocess($s1);
	$s2 = preprocess($s2);
	my %tokens1 = map {$_ => 1} split /\s+/, $s1;
	my %tokens2 = map {$_ => 1} split /\s+/, $s2;
	my %intersection = map {$_ => 1} grep {$tokens2{$_}} keys %tokens1;
	my %diff1to2 = map {$_ => 1} grep {not $tokens2{$_}} keys %tokens1;
	my %diff2to1 = map {$_ => 1} grep {not $tokens1{$_}} keys %tokens2;

	my $sorted_sect = join(" ", sort keys %intersection);
	my $sorted_1to2 = join(" ", sort keys %diff1to2);
	my $sorted_2to1 = join(" ", sort keys %diff2to1);

	my $combined_1to2 = $sorted_sect . ' ' . $sorted_1to2;
	my $combined_2to1 = $sorted_sect . ' ' . $sorted_2to1;

	chomp $sorted_sect;
	chomp $combined_1to2;
	chomp $combined_2to1;

	my @pairwise = (
		ratio($sorted_sect, $combined_1to2),
		ratio($sorted_sect, $combined_2to1),
		ratio($combined_1to2, $combined_2to1),
	);
	return max(@pairwise);
}

1;
