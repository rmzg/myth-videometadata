#!/usr/bin/perl

use strict;
use warnings;

require 5.11.2; #readdir!

use WebService::TVDB;
use JSON qw/decode_json/;
use DBI;
use Time::HiRes qw/sleep/;
$|++; #Turn off STDOUT buffering

#==================================================================
# Usage: tvscan.pl /tv/directory [/directory/2/ ...]
# Takes a list of directories containing tv series. Each top level directory should contain a number of directories
# that each contain a single tv series, with each folder named exactly for the tv series in question.
# Series folders can contain either a list of video files with names that match the season and episode numbers of the 
# series in question or these files can be contained in one level of subdirectories named S1,S2,etc for each
# season of the series.
# 
# Series directories may also contain a single file named '.tvmetainfo' that contains a json structure specifying
# options for how the series is to be parsed by this scanned. If this file doesn't exist it defaults to doing
# relatively sane things.
# 
# Available options are:
# series_id: a number representing the specific TVDB series id to be used to look up this tv series.
# 	Useful for overriding the default matching behaviour when the series name of the directory doesn't 
# 	find the correct series when searching the TVDB.
# series_order: 'dvd'; Specify this key and value in order to have the scanner look for episodes
# 	named after the 'dvd ordering' instead of the 'broadcast ordering'. Check the TVDB page for the series
# 	to see the difference in numbering/ordering this makes.
#
# example .tvmetainfo file: 
# {series_id:82230,series_order:'dvd'}
# which specifies that we should use the specific id '82230' instead of whichever one is matched first based on the
# name of the series directory and that we should attempt to match the episodes based on the order they were
# placed on the dvd, instead of broadcast, which is the default.
#
# Stores video files in tvscan_cache/$directory depending on which image is found.
# The image file names are stored in the database as part of the insert process but the actual image files
# are not moved into the mythtv image directories since we don't know where they are.
# So you need to manually copy the generated images into the right spots.

my $tvdb = WebService::TVDB->new( api_key => 'BA564A54BE1EA624', language => 'English', max_retries => '10' );

my $ua = LWP::UserAgent->new;
my $dbh = DBI->connect( "dbi:mysql:mythconverg","mythtv","mythtv" ) or die $!;

my @file_exts = qw/mkv avi mp4 mpg mpeg ts mov wmv divx flv rmvb mpe mpa mp2 m2a qt rm 3gp ogm bin dvr gom gvi h264 hdmov hdv hkm mp4v mpeg1 mpeg4 ogv ogx tivo wtv/;
	my $file_ext_regex = '(' . (join '|', @file_exts) . ')';

#TODO Option parsing

mkdir "tvscan_cache";
chdir "tvscan_cache" or die $!;

for my $top_dir ( @ARGV ) {
	$top_dir =~ s{/+$}{};

	opendir my $dh, $top_dir or do { warn "Failed to open dir [$top_dir]: $!\n"; next };

	while( defined( my $series_dir = readdir $dh ) ) {
		next if $series_dir =~ /^\./;

		print "Found [$series_dir]\n";

		my $cwd = "$top_dir/$series_dir";
		my $metadata = {}; #Blank means defaults!

		# Check for .tvmetainfo file {series_id:xxxx}
		my $metainfo = "$cwd/.tvmetainfo";
		if( -e $metainfo ) {
			open my $fh, "<", $metainfo or die "Failed to open [$metainfo]: $!\n";
			local $/;
			my $contents = <$fh>;
			$metadata = JSON->new->utf8->allow_singlequote->allow_barekey->decode($contents);
		}


		my $series;
		# Check if we should set $series from specified id or directory name
		if( $metadata->{series_id} ) {
			$series = $tvdb->get( $metadata->{series_id} );

			if( not $series ) {
				warn "Failed to find specific series [$metadata->{series_id}] for [$series_dir]\n";
				next;
			}
		}
		else {
			my $series_list = $tvdb->search( $series_dir );
			
			if( not @$series_list) {
				warn "Failed to find a match for [$series_dir]\n";
				next;
			}

			# Assume first one is the correct one!
			# If necessary scan through list or ask user..
			$series = $series_list->[0];
		}

		# Hopefully we've found a series by now..
		$series->fetch;

		print "Series: ", $series->SeriesName, " -- ", $series->seriesid, "\n";

		for my $episode ( @{ $series->episodes } ) {

			# Default to regular Season/Episode numbers
			my $sn = $episode->SeasonNumber;
			my $en = $episode->EpisodeNumber;

			# If we want dvd order..
			if( lc($metadata->{series_order} // "") eq 'dvd' ) {
				$sn = $episode->DVD_season;
				$en = $episode->DVD_episodenumber;
				next unless length($sn) and length($en); #Skip specials that don't get proper numbers..

				# DVD episodenumbers look like: 24.0, we want to ignore everything after the dot
				$en =~ s/\..+$//;
			}

			# We default to files in the 'root dir' for the season.
			my $sub_dir = "";
			# Check if files are stored in season directories named S1,S2,etc
			if( -d "$cwd/S$sn" ) {
				$sub_dir = "/S$sn";
			}
			# Lowercase dirs..
			elsif( -d "$cwd/s$sn" ) { 
				$sub_dir = "/s$sn";
			}

			# Attempt to locate the actual file matching the episode.
			my $file = find_file( "$cwd$sub_dir", $sn, $en );
			my $myth_relative_path = "tv/$series_dir$sub_dir/$file"; #TODO Fix hardcoding tv/

			# We silently ignore episodes that don't have files.
			next unless $file;

			print "\tEpisode: ", $episode->EpisodeName, " ${sn}x$en -- $file\n";
			print "\t\t Myth Path: [$myth_relative_path]\n";

			insert_show({
				title => $episode->EpisodeName,
				subtitle => $series->SeriesName,
				tagline => '',
				director => $episode->Director,
				studio => $series->Network,
				plot => $episode->Overview,
				rating => $series->ContentRating,
				inetref => $episode->id,
				collectionref => -1, #TODO How do collections apply to TV shows?
				year => $episode->year,
				releasedate => $episode->FirstAired,
				userrating => $episode->Rating,
				length => $series->Runtime,
				playcount => 0,
				season => $sn,
				episode => $en,
				filename => $myth_relative_path,

				homepage => '', # TV Shows never have homepages
				showlevel => 1, #TODO Why is this 1?
				hash => 1235, #1234 is movies, 1235 is tv. Hilarious!
				childid => -1, #TODO why is this -1?
				browse => 1,
				watched => 0,
				processed => 1,
				playcommand => undef,
				category => 0, #TODO Add categories!
				trailer => '', #TV Shows don't have trailers, right?
				host => 'mediabox', #TODO Figure out proper hostname!

				coverfile => 
				screenshot => 
				banner => 
				fanart => 

				contenttype => 'TELEVISION',
			});

		}

		sleep(0.5);
	}
}


sub find_file {
	my( $dir, $sn, $en ) = @_;

	#print "Checking $dir\n";

	opendir my $dh, $dir or die "Failed to open [$dir] for reading: $!\n";

	while( readdir $dh ) {
		next unless -f "$dir/$_";

		#print "--File $_: $sn,$en\n";

		if( 
			/\D0?$sn\D{1,3}0?$en(?=\D).*\.$file_ext_regex$/ 
			or /^\s*0?$en\s*\.$file_ext_regex$/ 
			or /^\s*[eE]?0?$en(?=\D).*\.$file_ext_regex$/ 
		) {
			return $_;
		}
	}

	return;
}

# This subroutine attempts to check if there are any files in the passed directory that aren't already
# stored in the metadata database.
# We need a $top_dir and the $season_dir because of how mythtv stores 'relative' paths in the metadata table..
sub check_for_new_files {
	my( $top_dir, $season_dir ) = @_;
	my $abs_path = "$top_dir/$season_dir";

	open my $dh, $abs_path or die "Failed to open [$abs_path] for reading: $!\n";
}


my( $insert_sth, $delete_sth );
sub insert_show {
	my( $info ) = @_;
	return;

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

my $show_check_sth;
sub show_in_db {
	my( $file ) = @_;

	$show_check_sth ||= $dbh->prepare( "SELECT title FROM videometadata WHERE filename = ?" );

	# Check if the file already exists in the database.
	my $ret = $show_check_sth->execute( $file );

	# Ret should either be 1 or 0E0, which are both true.
	# It should never be greater than 1 but we check for it just in case.
	# We return 0 explicitly since it is false unlike 0E0
	return $ret > 0 ? 1 : 0; 
	
}
