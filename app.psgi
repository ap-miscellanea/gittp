#!/usr/bin/perl
use 5.014;
use strict;
use warnings;
no warnings qw( once qw );

BEGIN {
	package Git::Repository::Plugin::LoadObject;
	use parent 'Git::Repository::Plugin';
	sub _keywords { 'load_object' }
	sub load_object { GitObject->new( @_ ) }
	$INC{'Git/Repository/Plugin/LoadObject.pm'} = 1;

	package GitObject;
	use Plack::Util::Accessor qw( git type path );
	use File::MimeInfo::Magic ();

	sub new {
		my $class = shift;
		my ( $git, $path ) = @_;
		my $type = eval { scalar $git->run( 'cat-file' => -t => "HEAD:$path" ) } // '';
		bless { git => $git, path => $path, type => $type }, $class;
	}

	sub entries {
		my $self = shift;
		die if 'tree' ne $self->type;
		local $/ = "\0";
		(
			#          mode      type      sha1     name
			map [ m!\A (\S+) [ ] (\S+) [ ] (\S+) \t (.*) \0 \z!x ],
			readline $self->git->command( 'ls-tree' => -z => HEAD => $self->path )->stdout
		);
	}

	sub content_fh {
		my $self = shift;
		die if 'blob' ne $self->type;
		$self->git->command( 'cat-file' => blob => 'HEAD:' . $self->path )->stdout;
	}

	sub mimetype {
		my $self = shift;
		my $type = File::MimeInfo::Magic::mimetype( $self->content_fh );
		$type = File::MimeInfo::Magic::globs( $self->path ) // $type
			if $type eq 'application/octet-stream'
			or $type eq 'text/plain';
		$type;
	}
}

use Git::Repository qw( LoadObject );
use Plack::Request;
use Try::Tiny;
use HTML::Escape 'escape_html';
use constant DIR_STYLE => "\n".<<'';
ul, li { margin: 0; padding: 0 }
li { list-style-type: none }

my $git = Git::Repository->new( $ENV{'GIT_DIR'} ? ( git_dir => $ENV{'GIT_DIR'} ) : ( work_tree => '.' ) );

sub unindent { map s!\A\n*(\h*)!!r =~ s!^\Q$1!!mgr =~ s!\s+\z!\n!r, @_ }

sub render_dir {
	my ( $obj ) = @_;

	my $path = $obj->path;

	my $prefix;
	$prefix = qr(\A\Q$path) if length $path;

	my @entry
		= sort {
			( ( $b =~ m!/\z! ) <=> ( $a =~ m!/\z! ) )  # dirs first
			|| ( lc $a cmp lc $b )
		}
		map {
			my ( $mode, $type, $sha1, $name ) = @$_;
			$name =~ s!$prefix!! if $prefix;
			$name .= '/' if $type eq 'tree';
			$name;
		}
		$obj->entries;

	unshift @entry, '..' if $prefix;

	my $title = $obj->path ? $obj->path : '[root]';

	my $list = join '', map {
		my $class = m!(\A\.\.|/)\z! ? 'd' : 'f';
		my $href = escape_html $_;
		qq(\n<li><a href="$_" class="$class">$_</a><li>);
	} @entry;

	return unindent qq(
		<!DOCTYPE html>
		<html>
		<head>
		<title>gittp: ${\escape_html $title}</title>
		<style>${\DIR_STYLE}</style>
		</head>
		<body>
		<ul>$list
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

	try {
		my $obj = $git->load_object( $path );
		given ( $obj->type ) {
			when ( 'blob' ) {
				my $mime = $obj->mimetype;
				$mime .= ';charset=utf-8' if 'text/plain' eq $mime;
				$res->content_type( $mime );
				$res->body( $obj->content_fh ); # looks like only works w/ streaming servers?
			}
			when ( 'tree' ) {
				if ( $req->path !~ m{ (?<!/) / \z }x ) { # ends in exactly one slash?
					my $uri = $req->uri->clone;
					my $path = $uri->path;
					$path =~ s!/*\z!/!; # ensure there is exactly one slash
					$uri->path( $path );
					$res->redirect( $uri, 301 );
				}
				else {
					$res->body( render_dir $obj );
					$res->content_type( 'text/html' );
				}
			}
			default {
				$res->status( 404 );
				$res->content_type( 'text/html' );
				$res->body( unindent qq(
					<!DOCTYPE html>
					<html>
					<head><title>${\escape_html $path}</title></head>
					<body><h1>404 Not Found</h1></body>
					</html>
				) );
			}
		}
	}
	catch {
		$res->status( 500 );
		$res->content_type( 'text/html' );
		$res->body( unindent qq(
			<!DOCTYPE html>
			<html>
			<head><title>Internal Server Error</title></head>
			<body><pre>${\escape_html $_}</pre></body>
			</html>
		) );
	};

	$res->finalize;
}
