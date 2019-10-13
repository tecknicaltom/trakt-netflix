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
use List::Util qw(min max);
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

##$res = json_get('/search/show?fields=title,aliases&query='.uri_escape('Law & Order: Special Victims Unit'));
##print $res->as_string;
##my @search_data = @{from_json($res->decoded_content)};
##my $id = $search_data[0]->{show}->{ids}->{trakt};
##
###$res = json_get('/sync/history/shows/'.$id.'?limit=1000');
##$res = json_get('/sync/history/shows/?limit=10000');
##print $res->as_string;

my %series_netflix_to_trakt;

my $dump_file = (glob "netflix-streaming-history*.json")[-1];
my $netflix_data = from_json(read_file($dump_file));
my $series_filter = @ARGV ? shift : '';
foreach my $netflix_watch (@$netflix_data)
{
	if(defined($netflix_watch->{series}))
	{
		my $netflix_series_id = $netflix_watch->{series};
		my $netflix_series_title = $netflix_watch->{seriesTitle};
		next if($series_filter && index($netflix_series_title, $series_filter) < 0);
#next unless($netflix_series_title =~ /House Hunters/);
		if(not defined($series_netflix_to_trakt{$netflix_series_id}))
		{
			say $netflix_series_title;
			my @search_data = @{json_get('/search/show?fields=title,aliases&query='.uri_escape($netflix_series_title))};
			if(!@search_data)
			{
				say "Series NOT FOUND in Trakt! \"$netflix_series_title\"";
				$series_netflix_to_trakt{$netflix_series_id} = -1;
			}
			else
			{
				my $trakt_id = $search_data[0]->{show}->{ids}->{trakt};
				my $show_data = json_get("/shows/$trakt_id");
				my $episodes_data = json_get("/shows/$trakt_id/seasons?extended=episodes");
				#print Dumper($episodes_data);
				my $watch_history = json_get("/sync/history/shows/$trakt_id?limit=10000");
				#print "watches:\n";
				#print Dumper($watch_history);
				$series_netflix_to_trakt{$netflix_series_id} = {
					show_data => $show_data,
					episodes => [ map { $_->{episodes}->@* } grep { defined $_->{episodes} } $episodes_data->@* ],
				};
				foreach my $episode ($series_netflix_to_trakt{$netflix_series_id}->{episodes}->@*)
				{
					$episode->{trakt_watches} = [];
				}
				foreach my $watch ($watch_history->@*)
				{
					if($watch->{type} eq 'episode' and ($watch->{action} eq 'watch' || $watch->{action} eq 'scrobble'))
					{
						my ($episode) = grep { $_->{ids}->{trakt} == $watch->{episode}->{ids}->{trakt} } $series_netflix_to_trakt{$netflix_series_id}->{episodes}->@*;
						push @{$episode->{trakt_watches}}, {
							watched_at => $watch->{watched_at},
							id => $watch->{id},
						};
					}
				}
				#print Dumper($series_netflix_to_trakt{$netflix_series_id});
last if(scalar keys %series_netflix_to_trakt > 40);
			}
		}
	}
}

say "======";

say "Looking for accidental duplicate watches...";
foreach my $trakt_series (values %series_netflix_to_trakt)
{
	next if(ref($trakt_series) ne 'HASH');
	#say $trakt_series->{show_data}->{title};
	foreach my $episode ($trakt_series->{episodes}->@*)
	{
		#say "  " . ($episode->{title} // "(no title)");
		if (scalar($episode->{trakt_watches}->@*) > 1)
		{
			my @watches = sort { str2time($a->{watched_at}) <=> str2time($b->{watched_at}) } $episode->{trakt_watches}->@*;
			my $time_diff = str2time($watches[-1]->{watched_at}) - str2time($watches[0]->{watched_at});
			if ($time_diff < 60 * 60)
			{
				say $trakt_series->{show_data}->{title};
				say "  " . ($episode->{title} // "(no title)");
				say "CONSOLIDATE!";
				my @removing_ids = map { $_->{id} } @watches[ 1 .. $#watches ];
				print Dumper(\@watches);
				print Dumper(\@removing_ids);

				json_post('/sync/history/remove', ids => \@removing_ids);
				$episode->{trakt_watches} = [ $watches[0] ];
			}
		}
	}
}

say "======";

foreach my $netflix_series_id (keys %series_netflix_to_trakt)
{
	my $trakt_data = $series_netflix_to_trakt{$netflix_series_id};
	next if (ref($trakt_data) ne 'HASH');

	my @netflix_watches = grep { $_->{series} && $_->{series} == $netflix_series_id } @$netflix_data;
	my %netflix_title_to_watch_time;
	my $netflix_multiple_episodes_same_name;
	my $use_season_in_name = 0;
	foreach my $netflix_watch (@netflix_watches)
	{
		my @watches_same_title = grep {$_->{episodeTitle} eq $netflix_watch->{episodeTitle}} @netflix_watches;
		if(grep {$_->{movieID} ne $netflix_watch->{movieID}} @watches_same_title)
		{
			say "Netflix episode title used on multiple episides: $netflix_watch->{episodeTitle}";
			$netflix_multiple_episodes_same_name = 1;
			if($netflix_watch->{episodeTitle} =~ /^episode \d+$/i)
			{
				say "Using \"title\" field from Netflix instead of \"episodeTitle\"";
				$use_season_in_name = 1;
			}
		}
		elsif(defined($netflix_title_to_watch_time{$netflix_watch->{episodeTitle}}))
		{
			say "Duplicate Netflix watch: $netflix_watch->{episodeTitle}";
		}
		my $netflix_episode_title = $use_season_in_name ? $netflix_watch->{title} : $netflix_watch->{episodeTitle};
		$netflix_title_to_watch_time{$netflix_episode_title} = int($netflix_watch->{date}) if(!defined($netflix_title_to_watch_time{$netflix_episode_title}) || int($netflix_watch->{date}) < $netflix_title_to_watch_time{$netflix_episode_title});
	}
	my %trakt_episodes_by_title;
	foreach my $i (0 .. $trakt_data->{episodes}->$#*)
	{
		my $trakt_episode_title;
		if ($use_season_in_name)
		{
			$trakt_episode_title = sprintf "Season %d: \"%s\"", $trakt_data->{episodes}->[$i]->{season}, $trakt_data->{episodes}->[$i]->{title};
			say $trakt_episode_title;
		}
		else
		{
			$trakt_episode_title = $trakt_data->{episodes}->[$i]->{title};
		}
		if ($trakt_episode_title)
		{
			push @{$trakt_episodes_by_title{$trakt_episode_title}}, $i;
		}
	}

	say "Trakt:   " . $trakt_data->{show_data}->{title};
	say "Netflix: " . $netflix_watches[0]->{seriesTitle};
	say "https://trakt.tv/shows/" . $trakt_data->{show_data}->{ids}->{slug};
	print "\n";

	if(grep {scalar($_->@*) > 1} values %trakt_episodes_by_title)
	{
		say "SKIPPING! Duplicated Trakt title!!";
		say Dumper(\%trakt_episodes_by_title);
		#say Dumper($trakt_data);
		say "======";
		next;
	}
	if(!%trakt_episodes_by_title)
	{
		say "SKIPPING! No Trakt episodes!!";
		#say Dumper(\%trakt_episodes_by_title);
		#say Dumper($trakt_data);
		say "======";
		next;
	}


	#print Dumper($trakt_data);
	#say "Trakt Episodes:";
	#say join "\n", map { ($_->{title}//'?') . ($_->{watched_at} ? " (".join(", ", $_->{watched_at}->@*).")" : '') } $trakt_data->{episodes}->@*;
	#print "\n";

	#print Dumper(\@netflix_watches);
	#say "Netflix Watches:";
	#say join "\n", reverse map { $_->{episodeTitle} } @netflix_watches;

	#print Dumper(\%netflix_title_to_watch_time);
	#print Dumper(\%trakt_episodes_by_title);

	my @netflix_titles = sort {$netflix_title_to_watch_time{$a} <=> $netflix_title_to_watch_time{$b}} keys %netflix_title_to_watch_time;

	# ================================
	# match up metflix watches to trakt episodes
	# first exact title matches
	foreach my $i (0 .. $#netflix_titles)
	{
		my $netflix_title = $netflix_titles[$i];
		if($trakt_episodes_by_title{$netflix_title} && scalar($trakt_episodes_by_title{$netflix_title}->@*) == 1)
		{
			my $ep_i = $trakt_episodes_by_title{$netflix_title}->[0];
			$trakt_data->{episodes}->[$ep_i]->{netflix_watch_time} = $netflix_title_to_watch_time{$netflix_title};
			$trakt_data->{episodes}->[$ep_i]->{netflix_watch_time_str} = strftime("%FT%X.000Z", gmtime($netflix_title_to_watch_time{$netflix_title} / 1000));
			$trakt_data->{episodes}->[$ep_i]->{netflix_title} = $netflix_title;
			undef $netflix_titles[$i];
		}
	}

	# then closest title matches
	@netflix_titles = grep { defined } @netflix_titles;
	foreach my $i (0 .. $#netflix_titles)
	{
		my $netflix_title = $netflix_titles[$i];
		my @available_trakt_titles = grep { scalar($trakt_episodes_by_title{$_}->@*) == 1 && not defined($trakt_data->{episodes}->[$trakt_episodes_by_title{$_}->[0]]->{netflix_watch_time}) } keys %trakt_episodes_by_title;
		my $best_trakt_episode_title = (sort {token_set_ratio($netflix_title, $b) <=> token_set_ratio($netflix_title, $a)} @available_trakt_titles)[0];
		#say "MATCH?? '$netflix_title' and '$best_trakt_episode_title'";
		my $ep_i = $trakt_episodes_by_title{$best_trakt_episode_title}->[0];
		$trakt_data->{episodes}->[$ep_i]->{netflix_watch_time} = $netflix_title_to_watch_time{$netflix_title};
		$trakt_data->{episodes}->[$ep_i]->{netflix_watch_time_str} = strftime("%FT%X.000Z", gmtime($netflix_title_to_watch_time{$netflix_title} / 1000));
		$trakt_data->{episodes}->[$ep_i]->{netflix_title} = $netflix_title;
		undef $netflix_titles[$i];
	}

	@netflix_titles = grep { defined } @netflix_titles;

	sub print_episodes($)
	{
		my ($trakt_data) = @_;
		say sprintf "  %25s %25s %s", "trakt", "netflix", "title";
		#print Dumper($trakt_data);
		foreach my $episode ($trakt_data->{episodes}->@*)
		{
			my $status = ' ';
			if(scalar($episode->{trakt_watches}->@*) > 1)
			{
				$status = 'D';
			}
			elsif(($episode->{trakt_watches}->[0]->{watched_at} // '') ne ($episode->{netflix_watch_time_str} // ''))
			{
				if($episode->{trakt_watches}->[0]->{watched_at} && $episode->{netflix_watch_time_str} // '')
				{
					my $trakt_watch_time = str2time($episode->{trakt_watches}->[0]->{watched_at});
					my $netflix_watch_time = int($episode->{netflix_watch_time} / 1000);
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
			elsif($episode->{netflix_watch_time_str})
			{
				$status = '✓';
			}
			say sprintf "%s %25s %25s %dx%02d %s%s",
				$status,
				$episode->{trakt_watches}->[0]->{watched_at} // '',
				$episode->{netflix_watch_time_str} // '',
				$episode->{season},
				$episode->{number},
				$episode->{title} // '[undef]',
				$episode->{netflix_title} && $episode->{title} ne $episode->{netflix_title} ? " (netflix: $episode->{netflix_title})" : '';
		}
		foreach my $episode (@netflix_titles)
		{
			say sprintf "N %25s %25s %s", "????", strftime("%FT%X.000Z", gmtime($netflix_title_to_watch_time{$episode} / 1000)), $episode // '';
		}
		#print Dumper(\%trakt_episodes_by_title);
	}

	print_episodes($trakt_data);
	my $needs_sync = grep {
		scalar($_->{trakt_watches}->@*) <= 1 &&
		$_->{netflix_watch_time_str} &&
		($_->{trakt_watches}->[0]->{watched_at} // '') ne ($_->{netflix_watch_time_str} // '')
	} $trakt_data->{episodes}->@*;

	if(@netflix_titles)
	{
		say "skipping: netflix episodes unmatched";
		say Dumper(\@netflix_titles);
		say "======";
		next;
	}
	if(grep { scalar($_->{trakt_watches}->@*) > 1 } $trakt_data->{episodes}->@*)
	{
		say "skipping: episodes with multiple Trakt watches";
		say Dumper(grep { scalar($_->{trakt_watches}->@*) > 1 } $trakt_data->{episodes}->@*);
		say "======";
		next;
	}
	if(!$needs_sync)
	{
		say "Already in sync!";
		next;
	}
	say "Sync now?";
	while(<>)
	{
		chomp;
		last if($_ eq 'n');
		exit if($_ eq 'q');
		if($_ eq 'y')
		{
			print "Syncing";
			foreach my $episode ($trakt_data->{episodes}->@*)
			{
				if($episode->{netflix_watch_time_str} && ($episode->{trakt_watches}->[0]->{watched_at} // '') ne ($episode->{netflix_watch_time_str} // ''))
				{
					if($episode->{trakt_watches}->@*)
					{
						# existing watch don't match up
						# remove it
						json_post('/sync/history/remove', ids => [$episode->{trakt_watches}->[0]->{id}]);
					}
					json_post('/sync/history', episodes => [{
							watched_at => $episode->{netflix_watch_time_str},
							ids => {
								trakt => $episode->{ids}->{trakt},
							}
					}]);

					print '.';
				}
			}
			print "\n";
			last;
		}
		print "y/n? ";
	}
}
continue
{
	say "======";
}
