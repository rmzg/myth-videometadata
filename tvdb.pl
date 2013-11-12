#!/usr/bin/perl

use strict;
use warnings;

use WebService::TVDB;

my $tvdb = WebService::TVDB->new( api_key => 'BA564A54BE1EA624', language => 'English', max_retries => '10' );

my $series = $tvdb->search('archer');

my $s = $series->[2];

$s->fetch;

#use Data::Dumper;
#print Dumper $s->banners;

use Data::Dumper;
print Dumper $s;

