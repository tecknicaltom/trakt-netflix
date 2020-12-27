#!/usr/bin/perl -I.

use strict;
use warnings;
use diagnostics;
use Data::Dumper;
use feature qw(say signatures);
no warnings "experimental::signatures";
use List::Util qw(min max);
use Fuzzy 'token_set_ratio';

say(token_set_ratio("Edward Mordrake: Part 2", "Return to Murder House"));
say(token_set_ratio("Edward Mordrake: Part 2", "Edward Mordrake (2)"));
say(token_set_ratio("Return To Murder House", "Return to Murder House"));
say(token_set_ratio("Return To Murder House", "Murder House"));

