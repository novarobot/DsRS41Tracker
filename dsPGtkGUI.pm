package dsPGtkGUI;

use strict;
use warnings;
use utf8;
use Gtk3;

sub gtk_init
{
	Gtk3->init();

	return;
}

sub _read_utf8_file
{
	my ($f) = @_;

	open my $h, '<:encoding(UTF-8)', $f
		or die "A fájl nem nyitható meg: $f: $!\n";

	local $/;
	my $c = <$h>;
	close $h;

	return $c;
}

sub _xml_decode
{
	my ($v) = @_;

	$v =~ s/&lt;/</g;
	$v =~ s/&gt;/>/g;
	$v =~ s/&quot;/"/g;
	$v =~ s/&apos;/'/g;
	$v =~ s/&amp;/&/g;

	return $v;
}

sub _attr
{
	my ($t, $n) = @_;

	return _xml_decode($2)
		if $t =~ /\b\Q$n\E\s*=\s*(["'])(.*?)\1/s;

	return undef;
}

sub _ids
{
	my ($x) = @_;
	my (@r, %s);

	while (
		$x =~ m{
			<(?:object|template)\b
			[^>]*?
			\bid\s*=\s*(["'])([^"']+)\1
			[^>]*?>
		}gsx
	)
	{
		push @r, $2
			unless $s{$2}++;
	}

	return @r;
}

sub _signals
{
	my ($x) = @_;
	my (@st, @r);

	while ($x =~ m{<object\b[^>]*>|</object\s*>|<signal\b[^>]*/>}gs)
	{
		my $t = $&;

		if ($t =~ /^<object/)
		{
			push @st,
			{
				id => _attr($t, 'id'),
			};
		}
		elsif ($t =~ /^<\/object/)
		{
			pop @st;
		}
		else
		{
			my $o = $st[-1]
				or die "Glade signal objektumon kívül.\n";

			push @r,
			{
				object_id => $o->{id},
				name      => _attr($t, 'name'),
				handler   => _attr($t, 'handler'),
				after     => _attr($t, 'after'),
			};
		}
	}

	return @r;
}

sub LoadGLADEstring
{
	my ($class, $xml, %o) = @_;
	my $pkg = $o{caller_package} // caller;
	my $src = $o{source} // '<string>';
	my @s = _signals($xml);

	(my $bx = $xml) =~ s{<signal\b[^>]*/>}{}gs;

	my $b = Gtk3::Builder->new();

	eval
	{
		$b->add_from_string($bx);
		1;
	}
		or die "A Glade XML nem tölthető be: $src\n$@";

	my %g;

	for my $id (_ids($xml))
	{
		my $ob = $b->get_object($id);

		die "A Glade objektum nem érhető el: $id\n"
			unless $ob;

		$g{$id} = $ob;
	}

	for my $s (@s)
	{
		my $full = $s->{handler} =~ /::/
			? $s->{handler}
			: "${pkg}::$s->{handler}";

		no strict 'refs';
		my $h = defined &{$full}
			? \&{$full}
			: undef;
		use strict 'refs';

		die "A Glade signal kezelőfüggvénye nem található: $full\n"
			unless $h;

		$g{$s->{object_id}}->signal_connect($s->{name}, $h);
	}

	return
	{
		GTK     => \%g,
		Builder => $b,
		Source  => $src,
	};
}

sub LoadGLADE
{
	my ($class, $f) = @_;
	my $pkg = caller;

	die "A Glade XML fájl nem található: $f\n"
		unless -f $f;

	return $class->LoadGLADEstring(
		_read_utf8_file($f),
		source         => $f,
		caller_package => $pkg,
	);
}

sub run_main_loop
{
	Gtk3->main();
	return;
}

sub quit_main_loop
{
	Gtk3->main_quit();
	return;
}

1;
