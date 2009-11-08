#!/usr/bin/perl
use 5.010;
use strict;
use warnings;
no warnings qw( once qw );

use Plack::Request;
use Try::Tiny;
use XML::Builder;
use File::MimeInfo::Magic qw( mimetype globs );

sub git { open my $rh, '-|', git => @_ or die $!; local $/; binmode $rh; <$rh> }

sub get_type { my $_ = git 'cat-file' => -t => "HEAD:$_[0]"; s!\s+\z!!; $_ }

sub get_file { git 'cat-file' => blob => "HEAD:$_[0]" }

sub get_dir {
	my ( $path ) = @_;

	$path =~ s!/*\z!/!;

	my $prefix;
	$prefix = qr(\A\Q$path) if $path ne '/';

	my @entry
		= sort {
			( ( $b =~ m!/\z! ) <=> ( $a =~ m!/\z! ) )  # dirs first
			|| ( lc $a cmp lc $b )
		}
		map {
			my ( $mode, $type, $sha1, $name ) = /\A (\S+) [ ] (\S+) [ ] (\S+) \t (.*) \z/sx;
			$name =~ s!$prefix!! if $prefix;
			$name .= '/' if $type eq 'tree';
			$name;
		}
		split /\0/,
		git 'ls-tree' => -z => HEAD => ( $prefix ? $path : () );

	unshift @entry, '..' if $prefix;

	my $x = XML::Builder->new;
	my $h = $x->register_ns( 'http://www.w3.org/1999/xhtml', '' );

	return $x->root(
		$h->html(
			$h->head(
				$h->title( $path ),
				$h->style( { type => 'text/css' },
					"\nul, li { margin: 0; padding: 0 }",
					"\nli { list-style-type: none }",
					"\n",
				)
			),
			$h->body( $h->ul( $h->li->foreach(
				map { $h->a( { href => $_, class => ( m!(\A\.\.|/)\z! ? 'd' : 'f' ) }, $_ ) } @entry
			) ) ),
		),
	);
}

sub get_mimetype {
	my ( $filename, $fh ) = @_;
	my $type = mimetype $fh;
	$type = ( globs $filename ) // $type
		if $type eq 'application/octet-stream'
		or $type eq 'text/plain';
	$type;
}

sub {
	my $req = Plack::Request->new( shift );

	my $res = $req->new_response( 200 );

	my $path = $req->path // '';
	$path =~ s!\A/!!;

	try {
		given ( get_type $path ) {
			when ( 'blob' ) {
				open my $fh, '<', \get_file $path;
				$res->content_type( get_mimetype $path, $fh );
				seek $fh, 0, 0;
				$res->body( $fh );
			}
			when ( 'tree' ) {
				$res->body( get_dir $path );
				$res->content_type( 'application/xhtml+xml' );
			}
			default {
				my $x = XML::Builder->new;
				my $h = $x->register_ns( 'http://www.w3.org/1999/xhtml', '' );

				$res->status( 404 );
				$res->content_type( 'application/xhtml+xml' );
				$res->body( $x->root( $h->html(
					$h->head( $h->title( $path ) ),
					$h->body( $h->h1( '404 Not Found' ) ),
				) ) );
			}
		}
	}
	catch {
		my $x = XML::Builder->new;
		my $h = $x->register_ns( 'http://www.w3.org/1999/xhtml', '' );

		$res->status( 500 );
		$res->content_type( 'application/xhtml+xml' );
		$res->body( $x->root( $h->html(
			$h->head( $h->title( 'Internal Server Error' ) ),
			$h->body( $h->pre( $_ ) ),
		) ) );
	};

	$res->finalize;
}
