#!/usr/bin/perl
use 5.014;
use strict;
use warnings;

use Git::Raw ();
use File::MimeInfo::Magic ();
use Plack::Request ();
use HTML::Escape 'escape_html';
use Scalar::Util 'blessed';
use List::Util 'reduce';
use constant DIR_STYLE => "\n".<<'';
ul, li { margin: 0; padding: 0 }
li { list-style-type: none }

my $git = Git::Raw::Repository->open( $ENV{'GIT_DIR'} // '.' );

sub unindent { ( map s!\A\n*(\h*)!!r =~ s!^\Q$1!!mgr =~ s!\s+\z!\n!r, @_ )[ 0 .. $#_ ] }

sub mimetype {
	my ( $name, $content_r ) = @_;
	open my $fh, '<', $content_r or die '!?';
	my $type = File::MimeInfo::Magic::mimetype( $fh );
	$type = File::MimeInfo::Magic::globs( $name ) // $type
		if $type eq 'application/octet-stream'
		or $type eq 'text/plain';
	$type;
}

sub render_dir {
	my ( $path, $tree ) = @_;

	my $index_sha1;

	my @entry =
		map { $_->[0] }
		sort { ( $a->[1] cmp $b->[1] ) || ( $a->[2] cmp $b->[2] ) }
		map {
			my $object = $_->object;
			my $name   = $_->name;
			return $object if 'index.html' eq $name;
			my $class = $object->isa( 'Git::Raw::Tree' ) ? 'd' : 'f';
			$name .= '/' if 'd' eq $class;
			my $href = escape_html $name;
			my $link = qq(\n<li><a href="$href" class="$class">$href</a><li>);
			[ $link, $class eq 'f', lc $name ];
		}
		@{ $tree->entries };

	unshift @entry, '<li><a href=".." class="d">..</a></li>' if $path;

	return unindent qq(
		<!DOCTYPE html>
		<html>
		<head>
		<title>gittp: ${\escape_html $path || '[root]'}</title>
		<style>${\DIR_STYLE}</style>
		</head>
		<body>
		<ul>${\join "\n", @entry}
		</ul>
		</body>
		</html>
	);
}

sub {
	my $req = Plack::Request->new( shift );

	my $res = $req->new_response( 200 );

	my $path = $req->path // '';
	$path =~ s!\A/!!;

	my $object = eval {
		reduce { $a->entry_byname( $b )->object }
		$git->head->target->tree,
		split '/', $path
	};

	if ( blessed $object and $object->isa( 'Git::Raw::Tree' ) ) {
		if ( $req->path !~ m{ (?<!/) / \z }x ) { # ends in exactly one slash?
			my $uri = $req->uri->clone;
			my $path = $uri->path;
			$path =~ s!/*\z!/!; # ensure there is exactly one slash
			$uri->path( $path );
			$res->redirect( $uri, 301 );
			return $res->finalize;
		}

		my $content = render_dir $path, $object;

		if ( not ref $content ) {
			$res->content_type( 'text/html' );
			$res->content_length( length $content );
			$res->body( $content );
			return $res->finalize;
		}

		$object = $content;
	}

	if ( blessed $object and $object->isa( 'Git::Raw::Blob' ) ) {
		my $content = $object->content;
		my $mime = mimetype $path, \$content;
		$mime .= ';charset=utf-8' if 'text/plain' eq $mime;
		$res->content_type( $mime );
		$res->content_length( $object->size );
		$res->body( $content );
		return $res->finalize;
	}

	$res->status( 404 );
	$res->content_type( 'text/html' );
	$res->body( unindent qq(
		<!DOCTYPE html>
		<html>
		<head><title>${\escape_html $path}</title></head>
		<body><h1>404 Not Found</h1></body>
		</html>
	) );
	$res->finalize;
}
