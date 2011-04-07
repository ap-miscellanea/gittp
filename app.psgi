#!/usr/bin/perl
use 5.010;
use strict;
use warnings;
no warnings qw( once qw );

use Plack::Request;
use Try::Tiny;
use XML::Builder;
use File::MimeInfo::Magic qw( mimetype globs );
use constant DIR_STYLE => "\n".<<'';
ul, li { margin: 0; padding: 0 }
li { list-style-type: none }

sub git { open my $rh, '-|', git => @_ or die $!; local $/; binmode $rh; $rh }

sub type_of { open my $fh, '>&STDERR'; close STDERR; my $_ = readline git 'cat-file' => -t => "HEAD:$_[0]"; open STDERR, '>&='.fileno($fh); s!\s+\z!! if defined; $_ }

sub cat_file { git 'cat-file' => blob => "HEAD:$_[0]" }

sub render_dir {
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
		readline git 'ls-tree' => -z => HEAD => ( $prefix ? $path : () );

	unshift @entry, '..' if $prefix;

	my $x = XML::Builder->new;
	my $h = $x->register_ns( 'http://www.w3.org/1999/xhtml', '' );

	return $x->root( $h->html(
		$h->head(
			$h->title( $path ),
			$h->style( { type => 'text/css' }, DIR_STYLE )
		),
		$h->body( $h->ul( "\n", map {; $_, "\n" } $h->li->foreach(
			map {
				my $class = m!(\A\.\.|/)\z! ? 'd' : 'f';
				$h->a( { href => $_, class => $class }, $_ );
			} @entry
		) ) ),
	) );
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
	$path =~ s!/\z!!;

	try {
		given ( type_of $path ) {
			when ( 'blob' ) {
				$res->content_type( get_mimetype $path, cat_file $path );
				$res->body( cat_file $path ); # will only work in streaming servers...
			}
			when ( 'tree' ) {
				if ( $req->path !~ m!/\z! ) {
					my $uri = $req->uri->clone;
					$uri->path( $uri->path . '/' );
					$res->redirect( $uri, 301 );
					return; # from `try` block
				}
				$res->body( render_dir $path );
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
