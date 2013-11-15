#!/usr/bin/perl

use strict;
use warnings;

require 5.11.2; #readdir!

use WWW::TheMovieDB;
use JSON qw/decode_json/;
use DBI;
use Time::HiRes qw/sleep/;
$|++; #Turn off STDOUT buffering

#==================================================================
# Usage: moviescan.pl /movie/directory [/directory/2/ ...]
# Takes a list of directories containing movies. Each passed directory should contain a list of directories
# named 'Movie Title (year)' each containing a single video file representing the movie named in the directory.
#
# Stores video files in moviescan_cache/$directory depending on which image is found.
# The image file names are stored in the database as part of the insert process but the actual image files
# are not moved into the mythtv image directories since we don't know where they are.
# So you need to manually copy the generated images into the right spots.


my $mdb = WWW::TheMovieDB->new({ 
	key => '9f78a7651a6a613062eb03f95b13160f',
	language => 'en',
	version => '3',
	type => 'json' 
});

my $ua = LWP::UserAgent->new;
my $dbh = DBI->connect( "dbi:mysql:mythconverg","mythtv","mythtv" ) or die $!;

my @file_exts = qw/mkv avi mp4 mpg mpeg ts mov wmv divx flv rmvb mpe mpa mp2 m2a qt rm 3gp ogm bin dvr gom gvi h264 hdmov hdv hkm mp4v mpeg1 mpeg4 ogv ogx tivo wtv/;
	my $file_ext_regex = join '|', @file_exts;

#TODO Sometimes the service returns 503 xml based error strings instead of actual data
# If this happens repeatedly we should script a way to deal with it.. sleep $x seconds and retry.
sub get_json;

my $configuration = get_json $mdb->Configuration::configuration();

#TODO Option parsing

mkdir "moviescan_cache";
chdir "moviescan_cache" or die $!;
# A list of directories containing directories containing files.
for my $top_dir ( @ARGV ) {
	$top_dir =~ s{/+$}{};

	opendir my $dh, $top_dir or do { warn "Failed to open dir [$top_dir]: $!\n"; next };

	while( defined( my $movie_dir = readdir $dh ) ) {
		next if $movie_dir =~ /^\./;

		my( $title, $year ) = $movie_dir =~ /^\s*(.+) \((\d+)\)\s*$/
			or do { warn "Failed to parse [$movie_dir] for title and year\n"; next };

		print "Found: $title - [$year]\n";

		my $movie_file = find_movie_file( "$top_dir/$movie_dir" )
			or do { warn "Failed to find movie file in [$movie_dir]\n"; next };

		print "\tFile: $movie_file\n";

		my $full_file_path = "movies/$movie_dir/$movie_file"; #TODO Fix the hardcoding of movies/
		#TODO Add option to skip this check
		if( movie_in_db( $full_file_path ) ) { 
			print "-- Skipping $movie_dir: Already in database\n";
			next;
		}

		my $search = get_json $mdb->Search::movie({ query => $title, language => 'en', year => $year, search_type => 'phrase' });
		if( $search->{total_results} < 1 ) {
			warn "Failed to find a match for [$title]!\n";
			next;
		}

		# Assume the first match is correct since we should be searching with very specific strings
		# If this isn't sufficient we can scan through results looking for titles that match or prompt the user.
		my $id = $search->{results}->[0]->{id};

		my $info =     get_json $mdb->Movies::info({ movie_id => $id });
		my $images =   get_json $mdb->Movies::images({ movie_id => $id });
		my $trailers = get_json $mdb->Movies::trailers({ movie_id => $id });
		my $credits  = get_json $mdb->Movies::casts({ movie_id => $id }); #Used mostly for Director so far..
		my $releases = get_json $mdb->Movies::releases({ movie_id => $id }); #Used for MPAA Content Rating!

		insert_movie({
			title => $info->{title},
			subtitle => '',
			tagline => $info->{tagline},
			director => get_director( $credits ),
			studio => $info->{production_companies}->[0]->{name},
			plot => $info->{overview},
			rating => get_release_rating( $releases ),
			inetref => $id,
			collectionref => -1, #TODO Check if it belongs to a collection
			homepage => $info->{homepage},
			year => $year,
			releasedate => $info->{release_date},
			userrating => $info->{vote_average},
			length => $info->{runtime},
			playcount => 0,
			season => 0,
			episode => 0,
			showlevel => 1,
			filename => $full_file_path,
			hash => '1234', #TODO What should we set here?
			contenttype => 'MOVIE', #TODO Always movies.. right?
			childid => -1,
			browse => 1,
			watched => 0,
			processed => 1, #TODO Uh.. what is this?
			playcommand => undef,
			category => 0, #TODO Assign a category
			host => 'mediabox', #TODO Oh god we have to find the hostname now?

			trailer => $trailers->{youtube}->[0]->{source},

			screenshot =>  '',
			banner => '',
			fanart => get_art( $images, 'fanart', 'backdrops' ),
			coverfile => get_art( $images, 'coverfile', 'posters' ),
		});

		sleep(0.5);
		print "\n";
	}
}



sub find_movie_file {
	my( $dir ) = @_;

	opendir my $dh, $dir or die "Failed to open movie dir [$dir]: $!\n";

	while( readdir $dh ) {
		if( /\.($file_ext_regex)$/ ) {
			return $_;
		}
	}
}

my( $insert_sth, $delete_sth );
sub insert_movie {
	my( $info ) = @_;

	# Prepare our statements once.
	# Do it inside the sub to make sure they're set when the sub is called...
	$insert_sth ||= $dbh->prepare( "INSERT INTO videometadata ( 
		title,
		subtitle,
		tagline,
		director,
		studio,
		plot,
		rating,
		inetref,
		collectionref,
		homepage,
		year,
		releasedate,
		userrating,
		length,
		playcount,
		season,
		episode,
		showlevel,
		filename,
		hash,
		coverfile,
		childid,
		browse,
		watched,
		processed,
		playcommand,
		category,
		trailer,
		host,
		screenshot,
		banner,
		fanart,
		insertdate,
		contenttype
	) VALUES ( ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NOW(),? )" );

	$delete_sth ||= $dbh->prepare( "DELETE FROM videometadata WHERE filename = ?" );

	# If we've been called we want to make sure we're not duplicating data in the database so we remove the existing filename record.
	$delete_sth->execute( $info->{filename} );

	$insert_sth->execute( 
		$info->{title},
		$info->{subtitle},
		$info->{tagline},
		$info->{director},
		$info->{studio},
		$info->{plot},
		$info->{rating},
		$info->{inetref},
		$info->{collectionref},
		$info->{homepage},
		$info->{year},
		$info->{releasedate},
		$info->{userrating},
		$info->{length},
		$info->{playcount},
		$info->{season},
		$info->{episode},
		$info->{showlevel},
		$info->{filename},
		$info->{hash},
		$info->{coverfile},
		$info->{childid},
		$info->{browse},
		$info->{watched},
		$info->{processed},
		$info->{playcommand},
		$info->{category},
		$info->{trailer},
		$info->{host},
		$info->{screenshot},
		$info->{banner},
		$info->{fanart},
		$info->{contenttype},
	);
}

my $movie_check_sth;
sub movie_in_db {
	my( $file ) = @_;

	$movie_check_sth ||= $dbh->prepare( "SELECT title FROM videometadata WHERE filename = ?" );

	# Check if the file already exists in the database.
	my $ret = $movie_check_sth->execute( $file );

	# Ret should either be 1 or 0E0, which are both true.
	# It should never be greater than 1 but we check for it just in case.
	# We return 0 explicitly since it is false unlike 0E0
	return $ret > 0 ? 1 : 0; 
	
}

sub get_director {
	my( $credits ) = @_;

	for( @{ $credits->{crew} } ) {
		if( lc $_->{job} eq 'director' ) {
			return $_->{name}
		}
	}

	return "";
}

sub get_release_rating {
	my( $releases ) = @_;
	
	#TODO Clean this code up. 
	# We need to loop over each item because we don't know where our preferred ones lie in the array..

	# Prefer US rating
	for( @{ $releases->{countries} } ) {
		if( $_->{'iso_3166_1'} eq 'US' ) {
			return "United States: $_->{certification}";
		}
	}

	# Secondary England
	for( @{ $releases->{countries} } ) {
		if( $_->{'iso_3166_1'} eq 'GB' ) {
			return "England: $_->{certification}";
		}
	}

	# Tertiary Germany
	for( @{ $releases->{countries} } ) {
		if( $_->{'iso_3166_1'} eq 'DE' ) {
			return "Germany: $_->{certification}";
		}
	}

	# If we've reached here we haven't found a preferred certification...
	if( my $r = shift @{ $releases->{countries} } ) {
		return "$r->{'iso_3166_1'}: $r->{certification}"; #Return the first one
	}

	return '';
}

sub get_art {
	my( $images, $mythtype, $mdbtype ) = @_;
	mkdir $mythtype;

	# Sort by highest vote average
	my @backdrops = sort { $b->{vote_average} <=> $a->{vote_average} } @{$images->{$mdbtype}};

	for( @backdrops ) {
		my $path = $_->{file_path};
		my $image_url = "$configuration->{images}->{base_url}original$_->{file_path}";
		$path =~ s{^/}{};

		my $fn = "$mythtype/$path";
		return $path if -f $fn;

		my $resp = $ua->get( $image_url );

		if( $resp->is_success ) {
			open my $fh, ">", $fn or die "Failed to open [$fn]: $!\n";
			print $fh $resp->content;
			return $path;
		}
	}

	return '';
}

sub get_json {
	my( $string ) = @_;

	my $ret = eval { decode_json $string; };

	if( $ret and ref $ret ) { return $ret; }
	else {
		die "Bad response: $string\n";
	}
}
