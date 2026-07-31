#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Getopt::Long qw(GetOptions);
use IPC::Open2;
use IO::Select;
use IO::Handle;
use POSIX qw(:termios_h WNOHANG);
use FindBin qw($Bin);
use File::Spec;
use JSON::PP;
use Errno qw(EINTR EAGAIN EWOULDBLOCK);

my ($service, $control_id);

GetOptions
(
	'service=s'    => \$service,
	'control-id=s' => \$control_id
)
	or die "Használat: $0 --service bt|sondehub --control-id ID\n";

die "Érvénytelen szolgáltatás.\n"
	if !defined($service) || $service !~ /^(?:bt|sondehub)$/;

die "A GUI kontroll fogadó ID hiányzik.\n"
	if !defined($control_id) || $control_id eq '';

my $pipe_connect = File::Spec->catfile($Bin, 'pipeConnect.pl');
die "A pipeConnect.pl nem futtatható.\n" if !-x $pipe_connect;

binmode(STDIN,  ':raw');
binmode(STDOUT, ':raw');
binmode(STDERR, ':encoding(UTF-8)');
STDOUT->autoflush(1);
STDERR->autoflush(1);

my $json = JSON::PP->new->utf8(0)->canonical(1);

sub open_reader
{
	my ($output, $input);
	my $pid = open2(
		$output,
		$input,
		$^X,
		$pipe_connect,
		'-R'
	);

	close($input);

	my $id = <$output>;
	die "A pipeConnect -R nem adott ID-t.\n" if !defined($id);

	$id =~ s/[\r\n]+\z//;
	return ($pid, $output, $id);
}

sub open_writer
{
	my ($id) = @_;
	my ($output, $input);
	my $pid = open2(
		$output,
		$input,
		$^X,
		$pipe_connect,
		'-W',
		$id
	);

	close($output);
	$input->autoflush(1);

	return ($pid, $input);
}

my ($data_reader_pid, $data_reader, $data_receive_id) = open_reader();
my ($control_reader_pid, $control_reader, $control_receive_id) = open_reader();
my ($gui_writer_pid, $gui_writer) = open_writer($control_id);

print {$gui_writer} $json->encode(
	{
		type               => 'terminal_ready',
		service            => $service,
		receive_id         => $data_receive_id,
		control_receive_id => $control_receive_id
	}
) . "\n";

my $control_buffer = '';
my $main_receive_id;

while (!defined($main_receive_id))
{
	my $chunk = '';
	my $count = sysread($control_reader, $chunk, 65536);

	if (defined($count) && $count > 0)
	{
		$control_buffer .= $chunk;

		while ($control_buffer =~ s/^(.*?\n)//s)
		{
			my $message = eval
			{
				$json->decode($1)
			};

			if (
				ref($message) eq 'HASH'
				&& ($message->{type} // '') eq 'main_receive_id'
			)
			{
				$main_receive_id = $message->{receive_id};
				last;
			}
		}

		next;
	}

	die "A GUI kontrollcsatorna bezárult.\n"
		if defined($count) && $count == 0;

	next if !defined($count) && $! == EINTR;
	die "A GUI kontrollcsatorna olvasási hibája: $!\n";
}

my ($data_writer_pid, $data_writer) = open_writer($main_receive_id);

my $terminal;
my $terminal_active = 0;

if (-t STDIN)
{
	$terminal = POSIX::Termios->new();
	$terminal->getattr(fileno(STDIN));

	my $local = $terminal->getlflag();
	$terminal->setlflag(
		$local & ~(ECHO | ICANON | ISIG | IEXTEN)
	);

	my $input = $terminal->getiflag();
	$terminal->setiflag(
		$input & ~(IXON | ICRNL)
	);

	$terminal->setcc(VMIN, 1);
	$terminal->setcc(VTIME, 0);
	$terminal->setattr(fileno(STDIN), TCSANOW);
	$terminal_active = 1;
}

my $restore = sub
{
	system('stty', 'sane') if $terminal_active;
};

$SIG{INT} = sub { $restore->(); exit(0); };
$SIG{TERM} = sub { $restore->(); exit(0); };
$SIG{HUP} = sub { $restore->(); exit(0); };

my $selector = IO::Select->new(
	\*STDIN,
	$data_reader
);

my $running = 1;

while ($running)
{
	for my $handle ($selector->can_read(0.25))
	{
		my $chunk = '';
		my $count = sysread($handle, $chunk, 65536);

		if (defined($count) && $count > 0)
		{
			my $target =
				fileno($handle) == fileno(STDIN)
				? $data_writer
				: \*STDOUT;

			my $offset = 0;

			while ($offset < length($chunk))
			{
				my $written = syswrite(
					$target,
					$chunk,
					length($chunk) - $offset,
					$offset
				);

				if (defined($written) && $written > 0)
				{
					$offset += $written;
					next;
				}

				next if !defined($written) && $! == EINTR;
				$running = 0;
				last;
			}
		}
		elsif (defined($count) && $count == 0)
		{
			$running = 0;
		}
		elsif (
			!defined($count)
			&& $! != EAGAIN
			&& $! != EWOULDBLOCK
			&& $! != EINTR
		)
		{
			$running = 0;
		}
	}
}

$restore->();

close($data_writer);
close($data_reader);
close($gui_writer);
close($control_reader);

for my $pid
(
	$data_writer_pid,
	$data_reader_pid,
	$gui_writer_pid,
	$control_reader_pid
)
{
	next if !$pid;
	kill('TERM', $pid);
	waitpid($pid, WNOHANG);
}

exit(0);
