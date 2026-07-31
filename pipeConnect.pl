#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Getopt::Long qw(GetOptions);
use Socket qw(AF_UNIX SOCK_STREAM sockaddr_un);
use IO::Select;
use IO::Handle;
use Time::HiRes qw(time sleep);
use Errno qw(EINTR EAGAIN EWOULDBLOCK);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

binmode(STDIN,  ':raw');
binmode(STDOUT, ':raw');
binmode(STDERR, ':encoding(UTF-8)');

STDOUT->autoflush(1);
STDERR->autoflush(1);

my ($read_mode, $write_mode, $help);

GetOptions
(
	'R|read'  => \$read_mode,
	'W|write' => \$write_mode,
	'help'    => \$help
)
	or usage(2);

usage(0) if $help;

die "Pontosan egy mód szükséges: -R vagy -W.\n"
	if ($read_mode ? 1 : 0) + ($write_mode ? 1 : 0) != 1;

sub usage
{
	my ($code) = @_;

	print STDERR <<'USAGE';
Használat:
  pipeConnect.pl -R
  pipeConnect.pl -W ID

-R:
  Véletlen Linux absztrakt UNIX socketet hoz létre.
  Az stdout első sora az ID, utána a fogadott RAW bájtfolyam következik.

-W ID:
  Kapcsolódik a megadott ID-hez, majd a stdin RAW bájtfolyamát továbbítja.
USAGE

	exit($code);
}

sub random_id
{
	my $random = join(
		'',
		map
		{
			sprintf('%08x', int(rand(0xffffffff)))
		}
		1 .. 4
	);

	return join(
		'-',
		'pipeConnect',
		$<,
		$$,
		int(time() * 1000000),
		$random
	);
}

sub write_all
{
	my ($handle, $data) = @_;
	my $offset = 0;

	while ($offset < length($data))
	{
		my $written = syswrite(
			$handle,
			$data,
			length($data) - $offset,
			$offset
		);

		if (defined($written) && $written > 0)
		{
			$offset += $written;
			next;
		}

		next if !defined($written) && $! == EINTR;
		return 0;
	}

	return 1;
}

sub run_reader
{
	my $id = random_id();
	my $listener;

	socket($listener, AF_UNIX, SOCK_STREAM, 0)
		or die "A fogadó socket nem hozható létre: $!\n";

	bind($listener, sockaddr_un("\0" . $id))
		or die "A fogadó socket nem köthető: $!\n";

	listen($listener, 1)
		or die "A fogadó socket nem állítható figyelő módba: $!\n";

	print STDOUT $id . "\n";

	my $client;
	accept($client, $listener)
		or die "A fogadó kapcsolat nem fogadható: $!\n";

	close($listener);

	while (1)
	{
		my $chunk = '';
		my $count = sysread($client, $chunk, 65536);

		if (defined($count) && $count > 0)
		{
			last if !write_all(\*STDOUT, $chunk);
			next;
		}

		last if defined($count) && $count == 0;
		next if !defined($count) && $! == EINTR;
		last;
	}

	close($client);
	return;
}

sub run_writer
{
	my ($id) = @_;

	die "A -W módhoz egy fogadó ID szükséges.\n"
		if !defined($id) || $id eq '';

	die "Érvénytelen fogadó ID.\n"
		if $id =~ /[\0\r\n]/;

	my $socket;
	my $deadline = time() + 15.0;
	my $connected = 0;

	while (time() < $deadline)
	{
		socket($socket, AF_UNIX, SOCK_STREAM, 0)
			or die "Az író socket nem hozható létre: $!\n";

		if (connect($socket, sockaddr_un("\0" . $id)))
		{
			$connected = 1;
			last;
		}

		close($socket);
		undef($socket);
		sleep(0.05);
	}

	die "A fogadó ID nem érhető el: $id\n"
		if !$connected;

	while (1)
	{
		my $chunk = '';
		my $count = sysread(\*STDIN, $chunk, 65536);

		if (defined($count) && $count > 0)
		{
			last if !write_all($socket, $chunk);
			next;
		}

		last if defined($count) && $count == 0;
		next if !defined($count) && $! == EINTR;
		last;
	}

	close($socket);
	return;
}

if ($read_mode)
{
	die "A -R mód nem fogad ID paramétert.\n" if @ARGV;
	run_reader();
	exit(0);
}

die "A -W mód pontosan egy ID paramétert vár.\n" if @ARGV != 1;
run_writer($ARGV[0]);
exit(0);
