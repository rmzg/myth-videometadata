#!/usr/bin/perl

use strict;
use warnings;

use Mojo::JSON;

use WWW::TheMovieDB;

my $mdb = WWW::TheMovieDB->new({ 
	key => '9f78a7651a6a613062eb03f95b13160f',
	language => 'en',
	version => '3',
	type => 'json' 
});

use Data::Dumper;

#print Dumper( Mojo::JSON->new()->decode( $mdb->Search::movie({ query => "$ARGV[0]", search_type => "phrase" }) ) ) ;
#print "\n\n";

my $j=Mojo::JSON->new;

print Dumper $j->decode( $mdb->Configuration::configuration() );

#print Dumper $j->decode( $mdb->Movies::info({movie_id=>11072}));
#print Dumper $j->decode( $mdb->Movies::images({movie_id=>11072}));
#print Dumper $j->decode( $mdb->Movies::trailers({movie_id=>11072}));
#print Dumper $j->decode( $mdb->Movies::reviews({movie_id=>11072}));

