#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use IO::Handle;
use POSIX qw(mkfifo WNOHANG);
use Time::HiRes qw(sleep);
use FindBin qw($Bin);
use File::Spec;

binmode(STDIN,  ':encoding(UTF-8)');
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $configfile = File::Spec->catfile($Bin, 'config.txt');

my %CONFIG;
my $CONFIG_LOADED = 0;

sub load_config
{
	my ($field, $default) = @_;

	if (!$CONFIG_LOADED)
	{
		$CONFIG_LOADED = 1;

		if (defined $configfile && -f $configfile)
		{
			my $fh;

			if (open($fh, '<:encoding(UTF-8)', $configfile))
			{
				while (my $line = <$fh>)
				{
					$line =~ s/^\x{FEFF}//;
					$line =~ s/\r?\n$//;

					next if $line =~ /^\s*$/;
					next if $line =~ /^\s*#/;

					my ($name, $value) = split(/=/, $line, 2);

					next if !defined $name;
					next if !defined $value;

					$name =~ s/^\s+//;
					$name =~ s/\s+$//;

					$value =~ s/^\s+//;
					$value =~ s/\s+$//;

					next if $name eq '';

					$CONFIG{$name} = $value;
				}

				close $fh;
			}
		}
	}

	return $CONFIG{$field}
		if exists $CONFIG{$field};

	return $default;
}

my $RFCOMM_DEVICE_NUMBER = 0 + load_config( 'RFCOMM_DEVICE_NUMBER','0', );
my $RFCOMM_DEVICE_PATH = load_config('RFCOMM_DEVICE_PATH', 	'/dev/rfcomm0', );
my $GPS_SERVICE_NAME = load_config( 'GPS_SERVICE_NAME', 'GPS Bridge', );
my $SCAN_TIME_SECONDS = 0 + load_config( 'SCAN_TIME_SECONDS', '15', );
my $PREFERRED_DEVICE_MAC = load_config( 'PREFERRED_DEVICE_MAC', '', );

my $is_worker = 0;
my $fifo_handle;
my $rfcomm_handle;
my $rfcomm_pid;
my $cleanup_started = 0;

sub command_exists
{
	my ($command) = @_;

	for my $directory (split(/:/, $ENV{PATH} // ''))
	{
		my $path = "$directory/$command";

		if (-x $path)
		{
			return $path;
		}
	}

	return undef;
}

sub run_command
{
	my (@command) = @_;

	system(@command);

	if ($? == -1)
	{
		return 127;
	}

	if ($? & 127)
	{
		return 128 + ($? & 127);
	}

	return $? >> 8;
}

sub capture_command
{
	my (@command) = @_;

	my $pid = open(
		my $handle,
		'-|',
		@command
	);

	if (!defined($pid))
	{
		return '';
	}

	my $output = '';

	while (my $line = <$handle>)
	{
		$output .= $line;
	}

	close($handle);

	return $output;
}

sub capture_command_silent
{
	my (@command) = @_;

	my $pid = open(
		my $handle,
		'-|',
		@command
	);

	if (!defined($pid))
	{
		return '';
	}

	my $output = '';

	while (my $line = <$handle>)
	{
		$output .= $line;
	}

	close($handle);

	return $output;
}

sub terminal_message
{
	my ($message) = @_;

	print "$message\n";
}

sub send_json_to_parent
{
	my ($json_line) = @_;

	return if !defined($fifo_handle);

	print {$fifo_handle} $json_line;
	$fifo_handle->flush();
}

sub cleanup_worker
{
	return if !$is_worker;
	return if $cleanup_started;

	$cleanup_started = 1;

	print "\nBluetooth kapcsolat lezárása...\n";

	if (defined($rfcomm_handle))
	{
		close($rfcomm_handle);
		undef($rfcomm_handle);
	}

	if (defined($rfcomm_pid))
	{
		kill('TERM', $rfcomm_pid);

		for (1 .. 20)
		{
			my $result = waitpid($rfcomm_pid, WNOHANG);

			last if $result == $rfcomm_pid;

			sleep(0.1);
		}

		kill('KILL', $rfcomm_pid);
		waitpid($rfcomm_pid, WNOHANG);

		undef($rfcomm_pid);
	}

	run_command(
		'sudo',
		'-n',
		'rfcomm',
		'release',
		$RFCOMM_DEVICE_NUMBER
	);

	run_command(
		'bluetoothctl',
		'scan',
		'off'
	);

	run_command(
		'bluetoothctl',
		'discoverable',
		'off'
	);

	run_command(
		'bluetoothctl',
		'pairable',
		'off'
	);

	run_command(
		'bluetoothctl',
		'power',
		'off'
	);

	print "RFCOMM kapcsolat lezárva.\n";
	print "A laptop Bluetooth-adaptere kikapcsolva.\n";

	if (defined($fifo_handle))
	{
		close($fifo_handle);
		undef($fifo_handle);
	}
}

sub install_signal_handlers
{
	$SIG{INT} = sub
	{
		cleanup_worker();
		exit(0);
	};

	$SIG{TERM} = sub
	{
		cleanup_worker();
		exit(0);
	};

	$SIG{HUP} = sub
	{
		cleanup_worker();
		exit(0);
	};

	$SIG{QUIT} = sub
	{
		cleanup_worker();
		exit(0);
	};

	$SIG{PIPE} = sub
	{
		cleanup_worker();
		exit(0);
	};
}

sub launch_terminal
{
	my ($script_path, $fifo) = @_;

	if (command_exists('gnome-terminal'))
	{
		return run_command(
			'gnome-terminal',
			'--title=GPS Bridge Bluetooth',
			'--',
			$^X,
			$script_path,
			'--worker',
			$fifo
		);
	}

	if (command_exists('mate-terminal'))
	{
		return run_command(
			'mate-terminal',
			'--title=GPS Bridge Bluetooth',
			'--',
			$^X,
			$script_path,
			'--worker',
			$fifo
		);
	}

	if (command_exists('xfce4-terminal'))
	{
		return run_command(
			'xfce4-terminal',
			'--title=GPS Bridge Bluetooth',
			'--command',
			join(
				' ',
				map
				{
					my $value = $_;
					$value =~ s/'/'"'"'/g;
					"'$value'"
				}
				(
					$^X,
					$script_path,
					'--worker',
					$fifo
				)
			)
		);
	}

	if (command_exists('konsole'))
	{
		return run_command(
			'konsole',
			'--title',
			'GPS Bridge Bluetooth',
			'-e',
			$^X,
			$script_path,
			'--worker',
			$fifo
		);
	}

	if (command_exists('xterm'))
	{
		return run_command(
			'xterm',
			'-T',
			'GPS Bridge Bluetooth',
			'-e',
			$^X,
			$script_path,
			'--worker',
			$fifo
		);
	}

	die(
		"Nem található támogatott terminál.\n" .
		"Telepítsd például a gnome-terminal vagy xterm csomagot.\n"
	);
}

sub parent_main
{
	my $script_path = abs_path($0);

	if (!defined($script_path))
	{
		die "Nem határozható meg a script teljes elérési útja.\n";
	}

	my $temporary_directory =
		tempdir(
			'gps-bridge-bt-XXXXXX',
			TMPDIR  => 1,
			CLEANUP => 0
		);

	my $fifo = "$temporary_directory/json.fifo";

	if (!mkfifo($fifo, 0600))
	{
		die "Nem hozható létre a FIFO: $fifo: $!\n";
	}

	my $terminal_result =
		launch_terminal(
			$script_path,
			$fifo
		);

	if ($terminal_result != 0)
	{
		unlink($fifo);
		rmdir($temporary_directory);

		die "Nem sikerült elindítani az új terminált.\n";
	}

	open(
		my $reader,
		'<:encoding(UTF-8)',
		$fifo
	) or die "Nem nyitható meg a FIFO: $fifo: $!\n";

	while (my $line = <$reader>)
	{
		print STDOUT $line;
	}

	close($reader);

	unlink($fifo);
	rmdir($temporary_directory);

	return 0;
}

sub ensure_required_commands
{
	my @commands =
	(
		'bluetoothctl',
		'rfcomm',
		'sdptool',
		'systemctl',
		'sudo'
	);

	my @missing;

	for my $command (@commands)
	{
		if (!command_exists($command))
		{
			push(@missing, $command);
		}
	}

	if (@missing)
	{
		die(
			"Hiányzó parancsok: " .
			join(', ', @missing) .
			"\n\nDebian alatt telepítsd:\n" .
			"sudo apt install bluez rfkill\n"
		);
	}
}

sub start_bluetooth
{
	terminal_message('Bluetooth szolgáltatás indítása...');

	my $result =
		run_command(
			'sudo',
			'systemctl',
			'start',
			'bluetooth'
		);

	if ($result != 0)
	{
		die "Nem sikerült elindítani a bluetooth szolgáltatást.\n";
	}

	if (command_exists('rfkill'))
	{
		run_command(
			'sudo',
			'rfkill',
			'unblock',
			'bluetooth'
		);
	}

	$result =
		run_command(
			'bluetoothctl',
			'power',
			'on'
		);

	if ($result != 0)
	{
		die "Nem sikerült bekapcsolni a Bluetooth-adaptert.\n";
	}

	run_command(
		'bluetoothctl',
		'pairable',
		'on'
	);

	run_command(
		'bluetoothctl',
		'discoverable',
		'on'
	);

	terminal_message('Bluetooth bekapcsolva.');
}

sub get_device_name
{
	my ($mac) = @_;

	my $info =
		capture_command(
			'bluetoothctl',
			'info',
			$mac
		);

	if ($info =~ /^\s*Name:\s*(.+?)\s*$/m)
	{
		return $1;
	}

	if ($info =~ /^\s*Alias:\s*(.+?)\s*$/m)
	{
		return $1;
	}

	return 'Ismeretlen eszköz';
}

sub device_is_paired
{
	my ($mac) = @_;

	my $info =
		capture_command(
			'bluetoothctl',
			'info',
			$mac
		);

	return $info =~ /^\s*Paired:\s*yes\s*$/mi ? 1 : 0;
}

sub scan_devices
{
	terminal_message('');
	terminal_message(
		"Bluetooth-eszközök keresése " .
		"$SCAN_TIME_SECONDS másodpercig..."
	);

	my %found;
	my %known_names;

	my $scan_output =
		capture_command(
			'bluetoothctl',
			'--timeout',
			$SCAN_TIME_SECONDS,
			'scan',
			'on'
		);

	run_command(
		'sh',
		'-c',
		'bluetoothctl scan off >/dev/null 2>&1 || true'
	);

	for my $line (split(/\n/, $scan_output))
	{
		if (
			$line =~
			/(?:Device|\[NEW\]\s+Device|\[CHG\]\s+Device)\s+
			([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})
			(?:\s+(.+))?/x
		)
		{
			my $mac = uc($1);
			my $name = defined($2) ? $2 : '';

			$name =~ s/^\s+//;
			$name =~ s/\s+$//;

			$found{$mac} = 1;

			if ($name ne '')
			{
				$known_names{$mac} = $name;
			}
		}
	}

	my $known_devices =
		capture_command(
			'bluetoothctl',
			'devices'
		);

	for my $line (split(/\n/, $known_devices))
	{
		if (
			$line =~
			/^Device\s+
			([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})
			(?:\s+(.+))?$/x
		)
		{
			my $mac = uc($1);
			my $name = defined($2) ? $2 : '';

			$name =~ s/^\s+//;
			$name =~ s/\s+$//;

			$found{$mac} = 1;

			if ($name ne '')
			{
				$known_names{$mac} = $name;
			}
		}
	}

	my $paired_devices =
		capture_command(
			'bluetoothctl',
			'paired-devices'
		);

	for my $line (split(/\n/, $paired_devices))
	{
		if (
			$line =~
			/^Device\s+
			([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})
			(?:\s+(.+))?$/x
		)
		{
			my $mac = uc($1);
			my $name = defined($2) ? $2 : '';

			$name =~ s/^\s+//;
			$name =~ s/\s+$//;

			$found{$mac} = 1;

			if ($name ne '')
			{
				$known_names{$mac} = $name;
			}
		}
	}

	my @devices;

	for my $mac (sort(keys(%found)))
	{
		my $name = $known_names{$mac};

		if (!defined($name) || $name eq '')
		{
			$name = get_device_name($mac);
		}

		if (!defined($name) || $name eq '')
		{
			$name = 'Ismeretlen eszköz';
		}

		my $paired =
			device_is_paired($mac)
			? 1
			: 0;

		push(
			@devices,
			{
				mac    => $mac,
				name   => $name,
				paired => $paired
			}
		);
	}

	return @devices;
}

sub normalize_mac
{
	my ($mac) = @_;

	$mac = '' if !defined($mac);
	$mac =~ s/^\s+//;
	$mac =~ s/\s+$//;
	$mac = uc($mac);

	return $mac;
}

sub find_preferred_device
{
	my (@devices) = @_;

	my $preferred_mac =
		normalize_mac(
			$PREFERRED_DEVICE_MAC
		);

	return undef if $preferred_mac eq '';

	for my $device (@devices)
	{
		if (
			normalize_mac($device->{mac}) eq
			$preferred_mac
		)
		{
			return $device;
		}
	}

	return undef;
}

sub select_device
{
	my (@devices) = @_;

	terminal_message('');
	terminal_message('Talált Bluetooth-eszközök:');
	terminal_message('');

	if (!@devices)
	{
		terminal_message('  Nem található Bluetooth-eszköz.');
	}
	else
	{
		for my $index (0 .. $#devices)
		{
			my $number = $index + 1;

			my $paired =
				$devices[$index]->{paired}
				? 'párosítva'
				: 'nincs párosítva';

			printf(
				"  %d. %-30s %s  [%s]\n",
				$number,
				$devices[$index]->{name},
				$devices[$index]->{mac},
				$paired
			);
		}
	}

	terminal_message('');
	terminal_message('  *. Keresés megismétlése');
	terminal_message('');

	while (1)
	{
		print 'Válassz eszközt a sorszámával vagy *-gal: ';

		my $answer = <STDIN>;

		if (!defined($answer))
		{
			die "A terminál bemenete bezárult.\n";
		}

		chomp($answer);
		$answer =~ s/^\s+//;
		$answer =~ s/\s+$//;

		if ($answer eq '*')
		{
			return undef;
		}

		if (
			$answer =~ /^\d+$/ &&
			$answer >= 1 &&
			$answer <= scalar(@devices)
		)
		{
			return $devices[$answer - 1];
		}

		terminal_message('Érvénytelen választás.');
	}
}

sub choose_device
{
	while (1)
	{
		my @devices = scan_devices();

		my $preferred_device =
			find_preferred_device(
				@devices
			);

		if (defined($preferred_device))
		{
			terminal_message('');
			terminal_message(
				"Az előre beállított MAC-cím megtalálható, " .
				"automatikus kiválasztás:"
			);

			terminal_message(
				"  $preferred_device->{name} " .
				"[$preferred_device->{mac}]"
			);

			return $preferred_device;
		}

		my $preferred_mac =
			normalize_mac(
				$PREFERRED_DEVICE_MAC
			);

		if ($preferred_mac ne '')
		{
			terminal_message('');
			terminal_message(
				"Az előre beállított MAC-cím nem szerepel " .
				"a találati listában: $preferred_mac"
			);
		}

		my $device =
			select_device(
				@devices
			);

		if (defined($device))
		{
			return $device;
		}

		terminal_message('');
		terminal_message('Új Bluetooth-keresés indul...');
	}
}

sub pair_device
{
	my ($device) = @_;

	if ($device->{paired})
	{
		terminal_message(
			"Az eszköz már párosítva van: " .
			"$device->{name}"
		);

		run_command(
			'bluetoothctl',
			'trust',
			$device->{mac}
		);

		return;
	}

	terminal_message('');
	terminal_message(
		"Párosítás indítása: " .
		"$device->{name} [$device->{mac}]"
	);

	terminal_message(
		'A telefonon fogadd el a megjelenő párosítási kérést.'
	);

	my $result =
		run_command(
			'bluetoothctl',
			'--timeout',
			60,
			'pair',
			$device->{mac}
		);

	if (
		$result != 0 ||
		!device_is_paired($device->{mac})
	)
	{
		terminal_message('');
		terminal_message(
			'Az automatikus párosítás nem sikerült.'
		);

		terminal_message(
			'Elindul az interaktív bluetoothctl.'
		);

		terminal_message(
			"A megnyíló promptban add ki:\n" .
			"  agent KeyboardDisplay\n" .
			"  default-agent\n" .
			"  pair $device->{mac}\n" .
			"  trust $device->{mac}\n" .
			"  quit"
		);

		run_command('bluetoothctl');
	}

	if (!device_is_paired($device->{mac}))
	{
		die "Az eszköz párosítása nem sikerült.\n";
	}

	run_command(
		'bluetoothctl',
		'trust',
		$device->{mac}
	);

	terminal_message('A párosítás sikeres.');
}

sub find_gps_bridge_channel
{
	my ($mac) = @_;

	terminal_message('');
	terminal_message(
		"A(z) \"$GPS_SERVICE_NAME\" RFCOMM szolgáltatás keresése..."
	);

	for my $attempt (1 .. 15)
	{
		my $sdp =
			capture_command(
				'sdptool',
				'browse',
				$mac
			);

		if (
			$sdp =~
			/Service\s+Name:\s*\Q$GPS_SERVICE_NAME\E
			.*?
			RFCOMM.*?
			Channel:\s*(\d+)/six
		)
		{
			my $channel = int($1);

			terminal_message(
				"GPS Bridge RFCOMM csatorna: $channel"
			);

			return $channel;
		}

		terminal_message(
			"Szolgáltatás még nem látható " .
			"($attempt/15)..."
		);

		sleep(1);
	}

	die(
		"Nem található a \"$GPS_SERVICE_NAME\" szolgáltatás.\n\n" .
		"A telefonon:\n" .
		"  1. indítsd el a GPS Bridge alkalmazást;\n" .
		"  2. nyomd meg az Indítás gombot;\n" .
		"  3. várd meg az RFCOMM szerver aktív állapotot.\n"
	);
}

sub start_rfcomm_connection
{
	my ($mac, $channel) = @_;

	run_command(
		'sudo',
		'-n',
		'rfcomm',
		'release',
		$RFCOMM_DEVICE_NUMBER
	);

	terminal_message('');
	terminal_message(
		"RFCOMM kapcsolat létrehozása:\n" .
		"  Telefon:  $mac\n" .
		"  Csatorna: $channel\n" .
		"  Eszköz:   $RFCOMM_DEVICE_PATH"
	);

	$rfcomm_pid = fork();

	if (!defined($rfcomm_pid))
	{
		die "Nem indítható az rfcomm folyamat: $!\n";
	}

	if ($rfcomm_pid == 0)
	{
		exec(
			'sudo',
			'rfcomm',
			'connect',
			$RFCOMM_DEVICE_NUMBER,
			$mac,
			$channel
		);

		die "Nem indítható az rfcomm parancs: $!\n";
	}

	for my $attempt (1 .. 200)
	{
		if (-e $RFCOMM_DEVICE_PATH)
		{
			terminal_message('RFCOMM kapcsolat létrejött.');
			return;
		}

		my $result = waitpid($rfcomm_pid, WNOHANG);

		if ($result == $rfcomm_pid)
		{
			$rfcomm_pid = undef;

			die(
				"Az rfcomm folyamat a kapcsolat " .
				"létrejötte előtt leállt.\n"
			);
		}

		sleep(0.1);
	}

	die(
		"Nem jött létre a $RFCOMM_DEVICE_PATH eszköz.\n"
	);
}

sub stream_json
{
	terminal_message('');
	terminal_message(
		'JSON-adatok fogadása. A terminál bezárása bontja a kapcsolatot.'
	);

	terminal_message(
		'----------------------------------------------------------------'
	);

	open(
		$rfcomm_handle,
		'<:encoding(UTF-8)',
		$RFCOMM_DEVICE_PATH
	) or die(
		"Nem nyitható meg a $RFCOMM_DEVICE_PATH: $!\n"
	);

	while (my $line = <$rfcomm_handle>)
	{
		next if $line !~ /\S/;

		print $line;
		send_json_to_parent($line);
	}

	die "Az RFCOMM adatkapcsolat megszakadt.\n";
}

sub worker_main
{
	my ($fifo) = @_;

	$is_worker = 1;

	install_signal_handlers();
	ensure_required_commands();

	open(
		$fifo_handle,
		'>:encoding(UTF-8)',
		$fifo
	) or die "Nem nyitható meg a FIFO írásra: $fifo: $!\n";

	$fifo_handle->autoflush(1);

	terminal_message('GPS Bridge Bluetooth kliens');
	terminal_message('================================');

	start_bluetooth();

	my $device = choose_device();

	terminal_message('');
	terminal_message(
		"Kiválasztva: $device->{name} [$device->{mac}]"
	);

	pair_device($device);

	my $channel =
		find_gps_bridge_channel(
			$device->{mac}
		);

	start_rfcomm_connection(
		$device->{mac},
		$channel
	);

	stream_json();

	return 0;
}

END
{
	cleanup_worker();
}

if (
	@ARGV >= 2 &&
	$ARGV[0] eq '--worker'
)
{
	exit(
		worker_main(
			$ARGV[1]
		)
	);
}

exit(parent_main());
