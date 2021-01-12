#!/usr/bin/perl -I.

use strict;
use warnings;
use diagnostics;
use feature 'say';
use utf8;
use Data::Dumper;
use LWP::UserAgent;
use JSON;
use URI::Escape;
use File::Slurp;
use Fuzzy 'token_set_ratio';
use IPC::Run 'run';
use Date::Parse;
use POSIX 'strftime';
use List::Util qw(min max sum shuffle);
use Getopt::Long qw(GetOptions);
$|=1;
$Data::Dumper::Indent = 1;
binmode STDOUT, ':utf8';

my $client_id = 'f50d9e27e9567c96c9117b6f2811c51431de588096bf543bd64aa2727540dfd1';
my $client_secret = 'b2861b4f8cecc3b1ad76e6b0f7752f6eec5ca14df6802ac921e2d72a815ff62e';
my $access_token;
use constant API=>'https://api.trakt.tv';

my $ua = LWP::UserAgent->new;
my $res;

sub json_req($$;@)
{
	my $method = shift;
	my $url = shift;
	my $req = HTTP::Request->new($method => API.$url);
	$req->content_type('application/json');
	$req->header('trakt-api-key' => $client_id);
	$req->header('trakt-api-version' => 2);
	$req->header(Authorization => "Bearer $access_token") if($access_token);
	$req->content(to_json({@_}));
	my $resp = $ua->request($req);
	if($resp->decoded_content)
	{
		#print "\n";
		#say $url;
		#say $resp;
		#say $resp->decoded_content;
		return from_json($resp->decoded_content);
	}
	#print Dumper($resp);
	return undef;
}
sub json_post($;@)
{
	my $url = shift;
	return json_req('POST', $url, @_);
}
sub json_get($;@)
{
	my $url = shift;
	return json_req('GET', $url, @_);
}

sub get_summary_status_char($)
{
	my ($episode_or_movie) = @_;
	my $status = ' ';
	if(scalar($episode_or_movie->{trakt_watches}->@*) > 1)
	{
		$status = 'D';
	}
	elsif(($episode_or_movie->{trakt_watches}->[0]->{watched_at} // '') ne ($episode_or_movie->{netflix_watch_time_str} // ''))
	{
		if($episode_or_movie->{trakt_watches}->[0]->{watched_at} && $episode_or_movie->{netflix_watch_time_str} // '')
		{
			my $trakt_watch_time = str2time($episode_or_movie->{trakt_watches}->[0]->{watched_at});
			my $netflix_watch_time = int($episode_or_movie->{netflix_watch_time} / 1000);
			my $time_diff = abs($trakt_watch_time - $netflix_watch_time);
			if($time_diff < 60*5)
			{
				$status = 'C';
			}
			elsif($time_diff < 60*60*25)
			{
				$status = 'c';
			}

		}
	}
	elsif($episode_or_movie->{netflix_watch_time_str})
	{
		$status = '✓';
	}
	return $status;
}

sub print_summary_row($)
{
	my ($episode_or_movie) = @_;
	my $status = get_summary_status_char($episode_or_movie);
	my $episode_label = '';
	if(defined($episode_or_movie->{season}) && defined($episode_or_movie->{number}))
	{
		$episode_label = sprintf('%dx%02d ', $episode_or_movie->{season}, $episode_or_movie->{number});
	}
	printf "%s %25s %25s %s%s",
		$status,
		$episode_or_movie->{trakt_watches}->[0]->{watched_at} // '',
		$episode_or_movie->{netflix_watch_time_str} // '',
		$episode_label,
		$episode_or_movie->{title} // '[undef]';
	print " (netflix: $episode_or_movie->{netflix_title})" if ($episode_or_movie->{netflix_title} && $episode_or_movie->{title} ne $episode_or_movie->{netflix_title});
	print " (no netflix match)" if (not defined($episode_or_movie->{netflix_title}));
	say "";
}

sub print_series_summary($$)
{
	my ($series_data, $trakt_series_id) = @_;
	my $trakt_series_data = $series_data->{trakt}->{serieses}->{$trakt_series_id};

	say sprintf "  %25s %25s %s", "trakt    ", "netflix    ", "title";
	#print Dumper($trakt_series_data);
	if($series_data->{is_tv})
	{
		foreach my $episode ($trakt_series_data->{episodes}->@*)
		{
			print_summary_row($episode);
		}
		foreach my $netflix_episode_title ($series_data->{netflix}->{episode_titles}->@*)
		{
			if (!grep { defined($_->{netflix_title}) && $netflix_episode_title eq $_->{netflix_title} } $trakt_series_data->{episodes}->@*)
			{
				printf "- %25s %25s      %s\n",
					" - unmatched - ",
					strftime("%FT%X.000Z", gmtime($series_data->{netflix}->{title_to_watch_time}->{$netflix_episode_title} / 1000)),
					$netflix_episode_title;
			}
		#		say sprintf "N %25s %25s %s", "????", strftime("%FT%X.000Z", gmtime($netflix_title_to_watch_time{$episode} / 1000)), $episode // '';
		}
	}
	else
	{
		print_summary_row($trakt_series_data);
	}
}

sub match_tv_netflix_to_trakt($$)
{
	my ($series_data, $trakt_series_id) = @_;
	my $trakt_series_data = $series_data->{trakt}->{serieses}->{$trakt_series_id};
	printf "https://trakt.tv/shows/%-30s %s\n", $trakt_series_data->{show_data}->{ids}->{slug}, "Start of match_tv_netflix_to_trakt ID: $trakt_series_id";
	#say "trakt series id: $trakt_series_id";
	#print_series_summary($series_data, $trakt_series_id);

	my @multiple_trakt_watches = grep { scalar($_->{trakt_watches}->@*) > 1 } $trakt_series_data->{episodes}->@*;
	if(@multiple_trakt_watches)
	{
		printf "https://trakt.tv/shows/%-30s %s\n", $trakt_series_data->{show_data}->{ids}->{slug}, "SKIPPING! Multiple Trakt watches!! (" . join(", ", map { $_->{title} } @multiple_trakt_watches) . ")";
		return undef;
	}

	my %unmatched_trakt_episodes_by_title;
	foreach my $i (0 .. $trakt_series_data->{episodes}->$#*)
	{
		#print Dumper($trakt_series_data->{episodes}->[$i]);
		my $trakt_episode_title = $series_data->{use_season_in_name} ?
			sprintf "Season %d: \"%s\"", $trakt_series_data->{episodes}->[$i]->{season}, $trakt_series_data->{episodes}->[$i]->{title}
			: $trakt_series_data->{episodes}->[$i]->{title};

		next if(!$trakt_episode_title);

		if (defined($unmatched_trakt_episodes_by_title{$trakt_episode_title}))
		{
			printf "https://trakt.tv/shows/%-30s %s\n", $trakt_series_data->{show_data}->{ids}->{slug}, "SKIPPING! Duplicated Trakt title!! ($trakt_episode_title)";
			#say Dumper($trakt_series_data);
			return undef;
		}
		if($trakt_episode_title)
		{
			$unmatched_trakt_episodes_by_title{$trakt_episode_title} = $i;
		}
	}
	if(!%unmatched_trakt_episodes_by_title)
	{
		printf "https://trakt.tv/shows/%-30s %s\n", $trakt_series_data->{show_data}->{ids}->{slug}, "SKIPPING! No Trakt episodes!!";
		#say Dumper($trakt_series_data);
		return undef;
	}

	my @unmatched_netflix_titles = ( $series_data->{netflix}->{episode_titles}->@* );
	my $series_match_score = 0;

	# ================================
	# match up netflix watches to trakt episodes
	# first exact title matches
	foreach my $i (0 .. $#unmatched_netflix_titles)
	{
		my $netflix_title = $unmatched_netflix_titles[$i];
		my $trakt_ep_i = $unmatched_trakt_episodes_by_title{$netflix_title};
		if(defined($trakt_ep_i))
		{
			my $watch_time = $series_data->{netflix}->{title_to_watch_time}->{$netflix_title};
			$trakt_series_data->{episodes}->[$trakt_ep_i]->{netflix_watch_time} = $watch_time;
			$trakt_series_data->{episodes}->[$trakt_ep_i]->{netflix_watch_time_str} = strftime("%FT%X.000Z", gmtime($watch_time / 1000));
			$trakt_series_data->{episodes}->[$trakt_ep_i]->{netflix_title} = $netflix_title;
			undef $unmatched_netflix_titles[$i];
			delete $unmatched_trakt_episodes_by_title{$netflix_title};
			$series_match_score += 100;
		}
	}
	@unmatched_netflix_titles = grep { defined } @unmatched_netflix_titles;

	# then closest title matches
	foreach my $i (0 .. $#unmatched_netflix_titles)
	{
		my $netflix_title = $unmatched_netflix_titles[$i];
		if (%unmatched_trakt_episodes_by_title)
		{
			my @sorted = sort {token_set_ratio($netflix_title, $b) <=> token_set_ratio($netflix_title, $a)} grep { $_ } keys %unmatched_trakt_episodes_by_title;
			my $best_trakt_episode_title = $sorted[0];
			#say "$netflix_title <=> $_ ".token_set_ratio($netflix_title,$_) foreach(@sorted);
			#say "MATCH?? '$netflix_title' and '$best_trakt_episode_title'";
			my $trakt_ep_i = $unmatched_trakt_episodes_by_title{$best_trakt_episode_title};
			if(defined($trakt_ep_i))
			{
				my $watch_time = $series_data->{netflix}->{title_to_watch_time}->{$netflix_title};
				$trakt_series_data->{episodes}->[$trakt_ep_i]->{netflix_watch_time} = $watch_time;
				$trakt_series_data->{episodes}->[$trakt_ep_i]->{netflix_watch_time_str} = strftime("%FT%X.000Z", gmtime($watch_time / 1000));
				$trakt_series_data->{episodes}->[$trakt_ep_i]->{netflix_title} = $netflix_title;
				undef $unmatched_netflix_titles[$i];
				delete $unmatched_trakt_episodes_by_title{$best_trakt_episode_title};
				$series_match_score += token_set_ratio($netflix_title, $best_trakt_episode_title);
			}
		}
	}
	@unmatched_netflix_titles = grep { defined } @unmatched_netflix_titles;

	#say "trakt_data:";
	#print Dumper($trakt_series_data);
	#print_series_summary($series_data, $trakt_series_id);
	#say "Score: $series_match_score";

	#if(@unmatched_netflix_titles)
	#{
	#	say "SKIPPING: Netflix episodes unmatched";
	#	say Dumper(\@unmatched_netflix_titles);
	#	return undef;
	#}

	$series_match_score += sum(map { scalar($_->{trakt_watches}->@*) } $trakt_series_data->{episodes}->@*);

	$trakt_series_data->{series_match_score} = $series_match_score;
	printf "https://trakt.tv/shows/%-30s %s\n", $trakt_series_data->{show_data}->{ids}->{slug}, "Score: $series_match_score";
	return $series_match_score;
}

sub match_movie_netflix_to_trakt($$)
{
	my ($series_data, $trakt_series_id) = @_;
	my $trakt_series_data = $series_data->{trakt}->{serieses}->{$trakt_series_id};
	printf "https://trakt.tv/movies/%-30s %s\n", $trakt_series_data->{movie_data}->{ids}->{slug}, "Start of match_movie_netflix_to_trakt ID: $trakt_series_id";
	#say "trakt series id: $trakt_series_id";
	#print_series_summary($series_data, $trakt_series_id);

	if(scalar($trakt_series_data->{trakt_watches}->@*) > 1)
	{
		printf "https://trakt.tv/movies/%-30s %s\n", $trakt_series_data->{movie_data}->{ids}->{slug}, "SKIPPING! Multiple Trakt watches!!";
		return undef;
	}

	my $series_match_score = 0;

	$trakt_series_data->{title} = $trakt_series_data->{movie_data}->{title};

	my $watch_time = $series_data->{netflix}->{watches}->[0]->{date};
	$trakt_series_data->{netflix_watch_time} = $watch_time;
	$trakt_series_data->{netflix_watch_time_str} = strftime("%FT%X.000Z", gmtime($watch_time / 1000));
	$trakt_series_data->{netflix_title} = $series_data->{netflix}->{watches}->[0]->{title};

	$series_match_score = token_set_ratio($series_data->{netflix}->{title}, $trakt_series_data->{movie_data}->{title});
	$series_match_score += scalar(grep {$_} values $trakt_series_data->{movie_data}->{ids}->%*);
	$series_match_score += 100 * int($trakt_series_data->{movie_data}->{rating});
	$series_match_score += int($trakt_series_data->{movie_data}->{votes});
	$series_match_score += 500 if($trakt_series_data->{trakt_watches}->@*);
	$trakt_series_data->{series_match_score} = $series_match_score;
	printf "https://trakt.tv/movies/%-30s %s\n", $trakt_series_data->{movie_data}->{ids}->{slug}, "Score: $series_match_score";
	return $series_match_score;
}


sub interact($$)
{
	my ($series_data, $trakt_series_id) = @_;
	my $trakt_series_data = $series_data->{trakt}->{serieses}->{$trakt_series_id};
	my $needs_sync;

	say "";
	say "Netflix: $series_data->{netflix}->{title}";
	if($series_data->{is_tv})
	{
		say "Trakt: $trakt_series_data->{show_data}->{title}  ( https://trakt.tv/shows/$trakt_series_data->{show_data}->{ids}->{slug} )";
		$needs_sync = grep {
			scalar($_->{trakt_watches}->@*) <= 1 &&
			$_->{netflix_watch_time_str} &&
			($_->{trakt_watches}->[0]->{watched_at} // '') ne ($_->{netflix_watch_time_str} // '')
		} $trakt_series_data->{episodes}->@*;
	}
	else
	{
		say "Trakt: $trakt_series_data->{movie_data}->{title}  ( https://trakt.tv/movies/$trakt_series_data->{movie_data}->{ids}->{slug} )";
		$needs_sync = scalar($trakt_series_data->{trakt_watches}->@*) <= 1 &&
			$trakt_series_data->{netflix_watch_time_str} &&
			($trakt_series_data->{trakt_watches}->[0]->{watched_at} // '') ne ($trakt_series_data->{netflix_watch_time_str} // '');
	}
	say "";
	print_series_summary($series_data, $trakt_series_id);


	if(!$needs_sync)
	{
		say "Already in sync!";
		return;
	}
	say "Sync now? (y/n/q/e/c)";
	while(<>)
	{
		chomp;
		last if($_ eq 'n');
		exit if($_ eq 'q');
		if($_ eq 'y')
		{
			print "Syncing";
			if($series_data->{is_tv})
			{
				foreach my $episode ($trakt_series_data->{episodes}->@*)
				{
					if($episode->{netflix_watch_time_str} && ($episode->{trakt_watches}->[0]->{watched_at} // '') ne ($episode->{netflix_watch_time_str} // ''))
					{
						if($episode->{trakt_watches}->@*)
						{
							# existing watch don't match up
							# remove it
							json_post('/sync/history/remove', ids => [$episode->{trakt_watches}->[0]->{id}]);
							sleep 1.5;
						}
						my $resp = json_post('/sync/history', episodes => [{
								watched_at => $episode->{netflix_watch_time_str},
								ids => {
									trakt => $episode->{ids}->{trakt},
								}
						}]);
						sleep 1.5;
						#print Dumper($resp);

						print '.';
					}
				}
			}
			else
			{
				if($trakt_series_data->{trakt_watches}->@*)
				{
					# existing watch don't match up
					# remove it
					json_post('/sync/history/remove', ids => [$trakt_series_data->{trakt_watches}->[0]->{id}]);
					sleep 1.5;
				}
				my $resp = json_post('/sync/history', movies => [{
						watched_at => $trakt_series_data->{netflix_watch_time_str},
						ids => {
							trakt => $trakt_series_data->{movie_data}->{ids}->{trakt},
						}
				}]);
				sleep 1.5;

				print '.';
			}
			print "\n";
			last;
		}
		if($_ eq 'e')
		{
			say "Trakt title: ";
			my $trakt_title = <>;
			chomp $trakt_title;
			say "Netflix title: ";
			my $netflix_title = <>;
			chomp $netflix_title;

			my $trakt_episode_data = (grep { $_->{title} eq $trakt_title } $trakt_series_data->{episodes}->@*)[0];
			if ($trakt_episode_data)
			{
				delete $trakt_episode_data->{netflix_title};
				delete $trakt_episode_data->{netflix_watch_time};
				delete $trakt_episode_data->{netflix_watch_time_str};

				if (defined($series_data->{netflix}->{title_to_watch_time}->{$netflix_title}))
				{
					my $other_trakt_episode_data = (grep { defined($_->{netflix_title}) && $_->{netflix_title} eq $netflix_title } $trakt_series_data->{episodes}->@*)[0];
					if ($other_trakt_episode_data)
					{
						delete $other_trakt_episode_data->{netflix_title};
						delete $other_trakt_episode_data->{netflix_watch_time};
						delete $other_trakt_episode_data->{netflix_watch_time_str};
					}

					my $watch_time = $series_data->{netflix}->{title_to_watch_time}->{$netflix_title};
					$trakt_episode_data->{netflix_title} = $netflix_title;
					$trakt_episode_data->{netflix_watch_time} = $watch_time;
					$trakt_episode_data->{netflix_watch_time_str} = strftime("%FT%X.000Z", gmtime($watch_time / 1000));
				}
			}
			else
			{
				# Trakt title doesn't match. If Netflix does, it'll unmatch it
				my $other_trakt_episode_data = (grep { defined($_->{netflix_title}) && $_->{netflix_title} eq $netflix_title } $trakt_series_data->{episodes}->@*)[0];
				if($other_trakt_episode_data)
				{
					delete $other_trakt_episode_data->{netflix_title};
					delete $other_trakt_episode_data->{netflix_watch_time};
					delete $other_trakt_episode_data->{netflix_watch_time_str};
				}
			}
			print_series_summary($series_data, $trakt_series_id);

		}
		if($_ eq 'c')
		{
			say "Change. ID: ";
			my $new_id = <>;
			chomp $new_id;
			return $new_id if($new_id);
		}
		print "y/n/q/e/c? ";
	}
}


# =====================================================

if(-e '.trakt_access_token')
{
	$access_token = read_file('.trakt_access_token');
	chomp $access_token;
}
else
{
	$res = json_post('/oauth/device/code', client_id => $client_id);
	my %device_auth_data = %{$res};
# {"device_code":"88addf6773eae9f13dec7d98cfb8f32899fae0480dc32fff4e3a7c2e21b3691a","user_code":"394D9EAD","verification_url":"https://trakt.tv/activate","expires_in":600,"interval":5}

	say "Visit $device_auth_data{verification_url} and enter code: $device_auth_data{user_code}";

	my %device_access_data;

	print "Waiting.";
	my $start_time = time;
	while(1)
	{
		$res = json_post('/oauth/device/token',
			code => $device_auth_data{device_code},
			client_id => $client_id,
			client_secret => $client_secret,
		);

		if($res)
		{
			# {"access_token":"5f5af8303c29cc4b282cc7ad69e47c78d9a341556068adf2408fc9744bca0f6e","token_type":"bearer","expires_in":7776000,"refresh_token":"20f2929560dbfabd416f7f30eea8e0b1943f1dfef785e003e99430bd46c5234e","scope":"public","created_at":1496518029}
			%device_access_data = %{$res};
			print "\n";
			last;
		}
		if(time - $start_time > $device_auth_data{expires_in})
		{
			print "\n";
			say "Did not authorize in time.";
			exit;
		}
		print ".";
		sleep $device_auth_data{interval};
	}
	say "Authorized!";
	$access_token = $device_access_data{access_token};
	write_file('.trakt_access_token', $access_token);
}

my $series_filter;
my $skip_until;
my $debug;
my $input_file;
my $order_reverse;
my $order_random;

GetOptions(
	'skip-until=s' => \$skip_until,
	'filter=s' => \$series_filter,
	'input-file=s' => \$input_file,
	'reverse' => \$order_reverse,
	'random' => \$order_random,
	'debug' => \$debug,
) or die "Usage: $0 [--skip-until name] [--filter name] [--input-file name] [--reverse] [--random] --debug\n";

if(!$input_file)
{
	$input_file = (glob "netflix-streaming-history*.json")[-1];
}
my $netflix_data = from_json(read_file($input_file));

my %series_data_by_netflixid;

foreach my $netflix_watch (@$netflix_data)
{
	my $netflixid;
	my $netflix_series_title;

	my $is_tv = defined($netflix_watch->{series});
	if($is_tv)
	{
		$netflixid = $netflix_watch->{series};
		$netflix_series_title = $netflix_watch->{seriesTitle};
		next if(!defined($netflix_series_title));
	}
	else
	{
		$netflixid = $netflix_watch->{movieID};
		$netflix_series_title = $netflix_watch->{title};
	}
	if($skip_until)
	{
		if(index($netflix_series_title, $skip_until) >= 0)
		{
			undef $skip_until;
		}
		else
		{
			next;
		}
	}
	next if($series_filter && index($netflix_series_title, $series_filter) < 0);
	push @{$series_data_by_netflixid{$netflixid}->{netflix}->{watches}}, $netflix_watch;
	$series_data_by_netflixid{$netflixid}->{is_tv} = $is_tv;
	$series_data_by_netflixid{$netflixid}->{netflix}->{title} = $netflix_series_title;
	$series_data_by_netflixid{$netflixid}->{latest_watch} = max($series_data_by_netflixid{$netflixid}->{latest_watch} // 0, $netflix_watch->{date});
}

my @series_ids;
if($order_random)
{
	@series_ids = shuffle keys %series_data_by_netflixid;
}
else
{
	@series_ids = sort { $series_data_by_netflixid{$b}->{latest_watch} <=> $series_data_by_netflixid{$a}->{latest_watch} } keys %series_data_by_netflixid;
}
if($order_reverse)
{
	@series_ids = reverse @series_ids;
}
foreach my $netflix_series_id (@series_ids)
{
	my @netflix_watches = grep { $_->{series} && $_->{series} == $netflix_series_id } @$netflix_data;
	$series_data_by_netflixid{$netflix_series_id}->{use_season_in_name} = 0;

	my %netflix_title_to_ids;
	foreach my $netflix_watch (@netflix_watches)
	{
		$netflix_title_to_ids{$netflix_watch->{episodeTitle}}->{$netflix_watch->{movieID}} = 1;
	}
	if (grep { scalar keys %{$netflix_title_to_ids{$_}} > 1 && $_ =~ /^episode \d+$/i } keys %netflix_title_to_ids)
	{
		print Dumper(\%netflix_title_to_ids);
		say "Using \"title\" field from Netflix instead of \"episodeTitle\"";
		$series_data_by_netflixid{$netflix_series_id}->{use_season_in_name} = 1;
		%netflix_title_to_ids = ();
		foreach my $netflix_watch (@netflix_watches)
		{
			$netflix_watch->{episodeTitle} = $netflix_watch->{title};
			$netflix_title_to_ids{$netflix_watch->{episodeTitle}}->{$netflix_watch->{movieID}} = 1;
		}
	}
	my %duplicate_netflix_titles = map { $_ => 1 } grep { scalar keys $netflix_title_to_ids{$_}->%* > 1 } keys %netflix_title_to_ids;
	if(%duplicate_netflix_titles)
	{
		say "Duplicate title in Netflix! (".join(", ", keys %duplicate_netflix_titles).")";
		say "Trying hack of adding season info.";
		%netflix_title_to_ids = ();
		foreach my $netflix_watch (@netflix_watches)
		{
			$netflix_watch->{episodeTitle} = defined($duplicate_netflix_titles{$netflix_watch->{episodeTitle}}) && $netflix_watch->{seasonDescriptor} ? "$netflix_watch->{episodeTitle} ($netflix_watch->{seasonDescriptor})" : $netflix_watch->{episodeTitle};
			$netflix_title_to_ids{$netflix_watch->{episodeTitle}}->{$netflix_watch->{movieID}} = 1;
		}
	}
	%duplicate_netflix_titles = map { $_ => 1 } grep { scalar keys $netflix_title_to_ids{$_}->%* > 1 } keys %netflix_title_to_ids;
	if(%duplicate_netflix_titles)
	{
		say "Duplicate title in Netflix! (".join(", ", keys %duplicate_netflix_titles).")";
		say "Giving up. Skipping!";
		next;
	}

	my %netflix_title_to_watch_time;
	foreach my $netflix_watch (@netflix_watches)
	{
		my $netflix_title = $netflix_watch->{episodeTitle};
		if(defined($netflix_title_to_watch_time{$netflix_title}))
		{
			say "Duplicate Netflix watch: $netflix_title";
		}
		$netflix_title_to_watch_time{$netflix_title} = int($netflix_watch->{date}) if(!defined($netflix_title_to_watch_time{$netflix_title}) || int($netflix_watch->{date}) < $netflix_title_to_watch_time{$netflix_title});
	}
	$series_data_by_netflixid{$netflix_series_id}->{netflix}->{title_to_watch_time} = \%netflix_title_to_watch_time;
	$series_data_by_netflixid{$netflix_series_id}->{netflix}->{episode_titles} = [ sort { $netflix_title_to_watch_time{$a} <=> $netflix_title_to_watch_time{$b} } keys %netflix_title_to_watch_time ];

	# ======================

	my $netflix_series_title = $series_data_by_netflixid{$netflix_series_id}->{netflix}->{title};
	say "Looking in Trakt for \"$netflix_series_title\"";
	my @search_data;
	if($series_data_by_netflixid{$netflix_series_id}->{is_tv})
	{
		@search_data = @{json_get('/search/show?fields=title,aliases&query='.uri_escape($netflix_series_title))};
	}
	else
	{
		@search_data = @{json_get('/search/movie?fields=title,aliases&query='.uri_escape($netflix_series_title))};
	}
	if(!@search_data)
	{
		say "Series NOT FOUND in Trakt! \"$netflix_series_title\"";
		$series_data_by_netflixid{$netflix_series_id}->{trakt} = -1;
	}
	else
	{
		if($series_data_by_netflixid{$netflix_series_id}->{is_tv})
		{
			foreach my $trakt_show (@search_data)
			{
				my $trakt_id = $trakt_show->{show}->{ids}->{trakt};
				my $show_data = json_get("/shows/$trakt_id");

				my $episodes_data = json_get("/shows/$trakt_id/seasons?extended=episodes");
				my $series_trakt_data = {
					show_data => $show_data,
					episodes => [ map { $_->{episodes}->@* } grep { defined $_->{episodes} } $episodes_data->@* ],
				};
				foreach my $episode ($series_trakt_data->{episodes}->@*)
				{
					$episode->{trakt_watches} = [];
				}

				my $watch_history = json_get("/sync/history/shows/$trakt_id?limit=10000");
				foreach my $watch ($watch_history->@*)
				{
					if($watch->{type} eq 'episode' and ($watch->{action} eq 'watch' || $watch->{action} eq 'scrobble'))
					{
						my ($episode) = grep { $_->{ids}->{trakt} == $watch->{episode}->{ids}->{trakt} } $series_trakt_data->{episodes}->@*;
						push @{$episode->{trakt_watches}}, {
							watched_at => $watch->{watched_at},
							id => $watch->{id},
						};
					}
				}
				$series_data_by_netflixid{$netflix_series_id}->{trakt}->{serieses}->{$trakt_id} = $series_trakt_data;

				# only fetch 4 search results from Trakt to limit API usage
				if(scalar(keys $series_data_by_netflixid{$netflix_series_id}->{trakt}->{serieses}->%*) >= 4)
				{
					last;
				}
			}
		}
		else
		{
			foreach my $trakt_movie (@search_data)
			{
				my $trakt_id = $trakt_movie->{movie}->{ids}->{trakt};
				my $movie_data = json_get("/movies/$trakt_id?extended=full");
				my $series_trakt_data = {
					movie_data => $movie_data,
					trakt_watches => [],
				};
				my $watch_history = json_get("/sync/history/movies/$trakt_id?limit=10000");
				foreach my $watch ($watch_history->@*)
				{
					if($watch->{type} eq 'movie' and ($watch->{action} eq 'watch' || $watch->{action} eq 'scrobble'))
					{
						push @{$series_trakt_data->{trakt_watches}}, {
							watched_at => $watch->{watched_at},
							id => $watch->{id},
						};
					}
				}
				$series_data_by_netflixid{$netflix_series_id}->{trakt}->{serieses}->{$trakt_id} = $series_trakt_data;

				# only fetch 4 search results from Trakt to limit API usage
				if(scalar(keys $series_data_by_netflixid{$netflix_series_id}->{trakt}->{serieses}->%*) >= 4)
				{
					last;
				}
			}
		}
	}

#say "======";
#
#say "Looking for accidental duplicate trakt watches...";
#foreach my $trakt_series (values %series_netflix_to_trakt)
#{
#	next if(ref($trakt_series) ne 'HASH');
#	#say $trakt_series->{show_data}->{title};
#	foreach my $episode ($trakt_series->{episodes}->@*)
#	{
#		#say "  " . ($episode->{title} // "(no title)");
#		if (scalar($episode->{trakt_watches}->@*) > 1)
#		{
#			my @watches = sort { str2time($a->{watched_at}) <=> str2time($b->{watched_at}) } $episode->{trakt_watches}->@*;
#			my $time_diff = str2time($watches[-1]->{watched_at}) - str2time($watches[0]->{watched_at});
#			if ($time_diff < 60 * 60)
#			{
#				say $trakt_series->{show_data}->{title};
#				say "  " . ($episode->{title} // "(no title)");
#				say "CONSOLIDATE!";
#				my @removing_ids = map { $_->{id} } @watches[ 1 .. $#watches ];
#				print Dumper(\@watches);
#				print Dumper(\@removing_ids);
#
#				json_post('/sync/history/remove', ids => \@removing_ids);
#				$episode->{trakt_watches} = [ $watches[0] ];
#			}
#		}
#	}
#}

	# ==============================

	my $series_data = $series_data_by_netflixid{$netflix_series_id};
	my $trakt_data = $series_data->{trakt};
	if(!ref($trakt_data))
	{
		say "Trakt data not found! Skipping.";
		next;
	}
	foreach my $trakt_series_id (keys %{$trakt_data->{serieses}})
	{
		if($series_data->{is_tv})
		{
			match_tv_netflix_to_trakt($series_data, $trakt_series_id);
		}
		else
		{
			match_movie_netflix_to_trakt($series_data, $trakt_series_id);
		}
	}

	my $best_trakt_series_id = (sort { $trakt_data->{serieses}->{$b}->{series_match_score} <=> $trakt_data->{serieses}->{$a}->{series_match_score} } grep { defined($trakt_data->{serieses}->{$_}->{series_match_score}) } keys %{$trakt_data->{serieses}})[0];
	while(1)
	{
		say "ID: $best_trakt_series_id";
		my $new_id = interact($series_data, $best_trakt_series_id);
		last if(!defined($new_id));
		$best_trakt_series_id = $new_id;
	}
}
continue
{
	say "======";
}
