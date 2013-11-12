#!/usr/bin/perl

use strict;
use warnings;

use DBI;

my $dbh = DBI->connect("dbi:mysql:mythconverg","mythtv","mythtv") or die $!;

my %hash;
while(<DATA>){
	chomp;
	s/^\s+//;
	s/\s+$//;
	my( $k, $v ) = split /\s*:\s*/,$_,2;
	$v = undef if lc($v) eq 'null';
	$hash{$k} = $v;
}

my $cols = join ",", keys %hash;
my $placeholders = join ",", map "?", keys %hash;
my @vals = values %hash;

$dbh->do( "INSERT INTO videometadata ($cols) VALUES ($placeholders)", undef, @vals );
use Data::Dumper;
print Dumper \%hash;

#videometadatacast -> videocast
#videometadatagenre -> videogenre;

__DATA__
        intid: 28
        title: Blazing Saddles
     subtitle:
      tagline: Never give a saga an even break!
     director: Mel Brooks
       studio: Warner Bros. Pictures
         plot: The Ultimate Western Spoof. A town where everyone seems to be named Johnson is in the way of the railroad. In order to grab their land, Hedley Lemar, a politically connected nasty person, sends in his henchmen to make the town unlivable. After the sheriff is killed, the town demands a new sheriff from the Governor. Hedley convinces him to send the town the first Black sheriff in the west.
       rating: R
      inetref: 11072
collectionref: -1
     homepage:
         year: 1974
  releasedate: 1974-02-07
   userrating: 6.5
       length: 93
    playcount: 0
       season: 0
      episode: 0
    showlevel: 1
     filename: movies/Blazing Saddles (1974)/Blazing Saddles.mkv
         hash: db5c528f5836907
  contenttype: MOVIE
      childid: -1
       browse: 1
      watched: 0
    processed: 1
  playcommand: NULL
     category: 0
         host: mediabox
   screenshot:
       banner:
      trailer:
       fanart: 11072_fanart.jpg
    coverfile: 11072_coverart.jpg
   insertdate: 2013-11-09 07:06:28
