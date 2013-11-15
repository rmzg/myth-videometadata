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
# grab_metadata: 0|1
# 	If not defined or set to 1 then we attempt to get metadata from TVDB
# 	otherwise if its set to a false value we insert the plain files without metadata.
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
my $tvdb_base_image_url = "http://thetvdb.com/banners/"; # This is the root path for all image requests. It uses round-robin dns so we always use the same host.

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
		next unless -d "$top_dir/$series_dir";

		print "Found [$series_dir]\n";

		# Skip this series unless we found files inside it that aren't in the database
		#TODO Fix this!
		next unless check_for_new_files( $top_dir, $series_dir );

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

		# Check if we should attempt to gather metadata for this series directory
		# If it doesn't exist or is true we ask tvdb for metadata
		# otherwise if search is false then we skip metadata and insert plain files
		if( not exists $metadata->{grab_metadata} or $metadata->{grab_metadata} ) {

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

			# Add a folder image so mythtv displays something!
			store_folder_image( $cwd, $series );

			# Attempt to find files matching the episodes in the series.
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
					# TODO Apparently sometimes episode numbers contain multiple episodes that should be combined 
					# specified via 12.1 12.2 12.3; This makes zero sense and we're ignoring it!
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

				# We silently ignore episodes that don't have files.
				next unless $file;

				my $myth_relative_path = "tv/$series_dir$sub_dir/$file"; #TODO Fix hardcoding tv/

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

					coverfile => get_coverfile( $series, $sn ),
					screenshot => get_screenshot( $episode ),
					banner => get_banner( $series, $sn ),
					fanart => get_fanart( $series ),

					contenttype => 'TELEVISION',
				});

				sleep(0.7);
			}
		}
		# End of the series metadata scan

		# If we've reached here we want to skip metadata and insert plain files.
		else {
		#$cwd = "$top_dir/$series_dir";

			print "Raw Series: $series_dir\n";

			opendir my $dh, $cwd or die "Failed to open [$cwd] for reading: $!\n";

			# We assume there are no subdirs!
			#TODO handle season dirs, sigh.
			while( readdir $dh ) {
				next unless /\.$file_ext_regex$/ and -f "$cwd/$_";

				print "\tRaw Episode: $_\n";
				
				insert_show({
					title => $_,
					subtitle => $series_dir,
					tagline => '',
					director => '',
					studio => '',
					plot => '',
					rating => '',
					inetref => '',
					collectionref => -1, #TODO How do collections apply to TV shows?
					year => '',
					releasedate => '',
					userrating => 0,
					length => 0,
					playcount => 0,
					season => 0,
					episode => 0,
					filename => "tv/$series_dir/$_", #TODO Fix hardcoding tv/

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

					coverfile => '',
					screenshot => '',
					banner => '',
					fanart => '',

					contenttype => 'TELEVISION',
				});

			}
		}
	}
}


# Look for a file that matches our season number and episode number
#TODO Optimize this to avoid scanning the entire file system so many times?
#	Perhaps we can cache the entire list of video files for a given $dir..
sub find_file {
	my( $dir, $sn, $en ) = @_;

	opendir my $dh, $dir or die "Failed to open [$dir] for reading: $!\n";

	while( readdir $dh ) {

		# Check for a number of different $sn/$en patterns
		if( 
			/\D0?$sn\D{1,3}0?$en(?=\D).*\.$file_ext_regex$/ 
			or /^\s*0?$en\s*\.$file_ext_regex$/ 
			or /^\s*[eE]?0?$en(?=\D).*\.$file_ext_regex$/ 
		) {
			# Ensure its actually a file...
			if( -f "$dir/$_" ) {
				return $_;
			}
		}
	}

	return;
}

# This subroutine attempts to check if there are any files in the passed directory that aren't already
# stored in the metadata database.
# We need a $top_dir and the $series_dir because of how mythtv stores 'relative' paths in the metadata table..
# We return 1 if we found a file not in the db, theoretically triggering a rescan of the entire directory.
# We return 0 if there are no new files and we can skip this dir.
#TODO Fix hardcoding of tv/
sub check_for_new_files {
	my( $top_dir, $series_dir ) = @_;
	my $abs_path = "$top_dir/$series_dir";

	opendir my $dh, $abs_path or die "Failed to open [$abs_path] for reading: $!\n";

	# If there exists season sub dirs
	# We assume we'll always have a s1 if there are any seasons dirs...
	if( -d "$abs_path/S1" or -d "$abs_path/s1" ) {
		while( readdir $dh ) {

			# Check if we found a season sub-dir..
			if( /s\d/i  and -d "$abs_path/$_" ) {

				my $new_abs_path = "$abs_path/$_";
				my $sub_dir = $_;

				# Scan the sub dir for video files
				opendir my $sdh, $new_abs_path or die "Failed to open [$new_abs_path] for reading: $!\n";
				while( readdir $sdh ) {
					if( /\.$file_ext_regex$/ and -f "$new_abs_path/$_" ) {
						if( not show_in_db( "tv/$series_dir/$sub_dir/$_" ) ) {
							return 1;
						}
					}
				}

			}
		}
	}
	else {
		while( readdir $dh ) {
			if( /\.$file_ext_regex$/ and -f "$abs_path/$_" ) {
				if( not show_in_db( "tv/$series_dir/$_" ) ) {
					return 1;
				}
			}
		}
	}

	return 0;
}


my( $insert_sth, $delete_sth );
sub insert_show {
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

	unless( defined $info->{filename} and length $info->{filename} ) { 
		warn "TERRIBLE INSERT: [$info->{title}]! Missing filename!";
		return;
	}

	# If we've been called we want to make sure we're not duplicating data in the database so we remove the existing filename record.
	$delete_sth->execute( $info->{filename} );

	# Check for invalid undefs!
	for( keys %$info ) {

		next if $_ eq 'playcommand'; #Ugly hack to leave 'playcommand' as undef if its set that way.
		                             # I don't know if its just as happy with an empty string as undef, but this works..

		# The table is much happier with blank strings instead of undefs
		if( not defined $info->{$_} ) { $info->{$_} = '' } 
	}

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

sub _get_store_image {
	my( $rel_url, $sub_dir ) = @_;

	return "" unless $rel_url;
	die "Requires a \$sub_dir!" unless length $sub_dir;

	my( $local_path ) = $rel_url =~ m{/([^/]+)$}
		or return "";
	my $store_path = "$sub_dir/$local_path";

	return $local_path if -e $store_path; # Skip downloading if it already exists!

	my $abs_url = $tvdb_base_image_url . $rel_url;

	my $resp = $ua->get( $abs_url );

	if( $resp->is_success ) {
		_mkdir( $sub_dir );

		open my $fh, ">", $store_path or die "Failed to open [$store_path]: $!\n";
		print $fh $resp->content;
		return $local_path;

	}
	else {
		warn "Failed to fetch $abs_url: " . $resp->code . "\n";
	}

	return "";
}

sub _mkdir {
	my $ret = mkdir $_[0];
	if( $ret or ( $ret == 0 and $! eq "File exists" ) ) {
		return 1;
	}
	else {
		die "Failed to make directory [$_[0]]: $!\n";
	}
}

#-------------------------
# All of these image subs return paths relative to the directories they're supposed to be stored in
# e.g. screenshots/foo.jpg returns foo.jpg since mythtv knows to look in screenshots/

sub get_coverfile {
	my( $series, $sn ) = @_;


	my @season_files = grep { $_->BannerType eq 'season' } @{$series->banners};

	return "" unless @season_files;

	# Check for files that match our specific season
	my @files = grep { $_->Season == $sn } @season_files;
	# If we don't have any go back to using any file we can find.
	if( not @files ) { @files = @season_files }

	# Find the 'best' file by rating.
	my( $best_file ) = map { $_->BannerPath } sort { ( $b->Rating // 0 ) <=> ( $a->Rating // 0 ) } @files;

	return _get_store_image( $best_file, "coverart" );
}

sub get_screenshot {
	my( $episode ) = @_;

	return _get_store_image( $episode->filename, "screenshots" );
}

sub get_banner {
	my( $series ) = @_;

	                                            # Fix undef warnings with no ratings..
	my( $file ) = map { $_->BannerPath } sort { ( $b->Rating // 0 ) <=> ( $a->Rating // 0 ) } grep { $_->BannerType eq 'series' } @{$series->banners};

	return _get_store_image( $file, "banners" );
}

sub get_fanart {
	my( $series ) = @_;

	                                            # Fix undef warnings with no ratings..
	my( $file ) = map { $_->BannerPath } sort { ( $b->Rating // 0 ) <=> ( $a->Rating // 0 ) } grep { $_->BannerType eq 'fanart' } @{$series->banners};

	return _get_store_image( $file, "fanart" );
}
#-------------------------

sub store_folder_image {
	my( $abs_dir, $series ) = @_;

	my @banners = grep { $_->BannerType eq 'poster' } @{$series->banners};
	if( not @banners ) { @banners = @{$series->banners} } #TODO Prefer different banner types first.. heh

	my( $best_banner ) = map { $_->BannerPath } sort { ( $b->Rating // 0 ) <=> ( $a->Rating // 0 ) } @banners;
	
	my( $ext ) = $best_banner =~ /\.(\w{2,4})$/;


	my $abs_url = $tvdb_base_image_url . $best_banner;

	my $resp = $ua->get( $abs_url );

	if( $resp->is_success ) {
		my $out_path = "$abs_dir/folder.$ext";

		open my $fh, ">", $out_path or die "Failed to open [$out_path]: $!\n";
		print $fh $resp->content;
	}
	else {
		warn "Failed to fetch $abs_url: " . $resp->code . "\n";
	}

	return;
}
