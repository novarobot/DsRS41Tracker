#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Encode qw(encode_utf8);
use Getopt::Long qw(GetOptions);
use HTTP::Tiny;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Select;
use JSON::PP qw(decode_json);
use POSIX qw(strftime);
use Time::HiRes qw(gettimeofday time);
use FindBin qw($Bin);
use File::Path qw(make_path);
use File::Spec;

binmode STDIN,  ':encoding(UTF-8)';
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

$| = 1;

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

					next if !defined $name || !defined $value;

					$name =~ s/^\s+|\s+$//g;
					$value =~ s/^\s+|\s+$//g;
					$value =~ s/^"(.*)"$/$1/;
					$value =~ s/^'(.*)'$/$1/;

					next if $name eq '';

					$CONFIG{uc($name)} = $value;
				}

				close $fh;
			}
		}
	}

	my $key = uc($field // '');
	return $CONFIG{$key}
		if exists $CONFIG{$key} && $CONFIG{$key} ne '';

	return $default;
}

sub config_boolean
{
	my ($field, $default) = @_;
	my $value = load_config($field, $default ? '1' : '0');

	return 1 if defined $value && $value =~ /^(?:1|true|yes|on|igen|be)$/i;
	return 0 if defined $value && $value =~ /^(?:0|false|no|off|nem|ki)$/i;
	return $default ? 1 : 0;
}

sub config_number
{
	my ($field, $default, $minimum) = @_;
	my $value = load_config($field, $default);

	return 0 + $default
		if !defined $value
		|| $value !~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/;

	my $number = 0 + $value;
	return 0 + $default if defined $minimum && $number < $minimum;
	return $number;
}

my %CFG =
(
	telemetry_api_url =>
		$ENV{SONDEHUB_API_URL}
		// load_config(
			'SONDEHUB_TELEMETRY_API_URL',
			'https://api.v2.sondehub.org/sondes/telemetry',
		),
	listener_api_url =>
		$ENV{SONDEHUB_LISTENER_API_URL}
		// load_config(
			'SONDEHUB_LISTENER_API_URL',
			'https://api.v2.sondehub.org/listeners',
		),
	software_name          => load_config('SONDEHUB_SOFTWARE_NAME', 'DsRS41Tracker'),
	software_version       => load_config('SONDEHUB_SOFTWARE_VERSION', '0.1.31'),
	uploader_callsign      => load_config('SONDEHUB_UPLOADER_CALLSIGN', 'SWL'),
	manufacturer           => load_config('SONDEHUB_MANUFACTURER', 'Vaisala'),
	type                   => load_config('SONDEHUB_TYPE', 'RS41'),
	subtype                => load_config('SONDEHUB_SUBTYPE', 'RS41-SGP'),
	receiver               => load_config('SONDEHUB_RECEIVER', 'UNDEFINED'),
	receiver_firmware      => load_config('SONDEHUB_RECEIVER_FIRMWARE', 'UNDEFINED'),
	antenna                => load_config('SONDEHUB_ANTENNA', 'UNDEFINED'),
	http_timeout_s         => config_number('SONDEHUB_HTTP_TIMEOUT_S', 15, 1),
	telemetry_interval_s   => config_number('SONDEHUB_TELEMETRY_INTERVAL_S', 30, 1),
	fixed_base_interval_s  => config_number('SONDEHUB_FIXED_BASE_INTERVAL_S', 21600, 30),
	mobile_base_interval_s => config_number('SONDEHUB_MOBILE_BASE_INTERVAL_S', 600, 30),
	base_min_interval_s    => config_number('SONDEHUB_BASE_MIN_INTERVAL_S', 30, 30),
	base_move_distance_m   => config_number('SONDEHUB_BASE_MOVE_DISTANCE_M', 100, 0),
	gzip_enabled           => config_boolean('SONDEHUB_GZIP_ENABLED', 0),
	log_directory          => load_config('LOG_DIRECTORY', './log'),
	default_base_lat       => config_number('BASE_LAT', 47.49786),
	default_base_lon       => config_number('BASE_LON', 19.04022),
	default_base_alt       => config_number('BASE_ALT', 110),
	default_frequency_mhz  => config_number('SONDEHUB_FREQUENCY_MHZ', 400.000, 100),
);

my $dev_mode = 0;
my $help = 0;
my $protocol_version = 0;

GetOptions
(
	'dev'              => \$dev_mode,
	'help'             => \$help,
	'protocol-version' => \$protocol_version,
)
	or usage(1);

if ($protocol_version)
{
	print "2\n";
	exit 0;
}

usage(0) if $help;

my $json = JSON::PP->new
	->utf8(0)
	->canonical(1)
	->allow_nonref(0);

my $http = HTTP::Tiny->new
(
	timeout    => $CFG{http_timeout_s},
	agent      => "$CFG{software_name}/$CFG{software_version}",
	verify_SSL => 1,
);

my $slog_path = create_slog_path();
my $slog_fh;

if (!open($slog_fh, '>>:encoding(UTF-8)', $slog_path))
{
	die "A SondeHUB napló nem nyitható meg: $slog_path: $!\n";
}

$slog_fh->autoflush(1);
print STDERR "SondeHUB payload napló: $slog_path\n";

my $selector = IO::Select->new(\*STDIN);
my $stdin_open = 1;
my @telemetry_queue;
my $pending_base;
my $last_telemetry_upload_epoch = time();
my $last_base_attempt_epoch;
my $last_base_success_epoch;
my $last_confirmed_base;

while ($stdin_open || @telemetry_queue || defined $pending_base)
{
	my $timeout = next_timeout_seconds();
	my @ready = $selector->can_read($timeout);

	if (@ready)
	{
		my $line = <STDIN>;

		if (defined $line)
		{
			$line =~ s/\r?\n\z//;
			process_line($line) if $line !~ /^\s*\z/;
		}
		else
		{
			$selector->remove(\*STDIN);
			$stdin_open = 0;
		}
	}

	flush_telemetry_if_due(!$stdin_open);
	upload_pending_base_if_due();
}

close $slog_fh;
exit 0;

sub create_slog_path
{
	my $requested = $CFG{log_directory};
	my $directory = File::Spec->rel2abs($requested, $Bin);

	if (!-d $directory)
	{
		eval
		{
			make_path($directory);
			1;
		};
	}

	if (!-d $directory)
	{
		$directory = File::Spec->rel2abs('.', $Bin);
		print STDERR "FIGYELEM: a megadott logmappa nem használható; naplózás ide: $directory\n";
	}

	my $filename = 'sondehub_' . strftime('%Y-%m-%d_%H-%M-%S', localtime()) . '.Slog';
	return File::Spec->catfile($directory, $filename);
}

sub next_timeout_seconds
{
	my @timeouts = (1.0);
	my $now = time();

	if (@telemetry_queue)
	{
		my $remaining = $last_telemetry_upload_epoch
			+ $CFG{telemetry_interval_s}
			- $now;
		push @timeouts, $remaining > 0 ? $remaining : 0;
	}

	if (defined $pending_base)
	{
		push @timeouts, seconds_until_base_due($pending_base);
	}

	my $minimum = $timeouts[0];
	for my $value (@timeouts)
	{
		$minimum = $value if $value < $minimum;
	}

	return $minimum < 0 ? 0 : $minimum;
}

sub process_line
{
	my ($line) = @_;
	my $input;

	eval
	{
		$input = decode_json($line);
		1;
	}
		or do
		{
			my $error = clean_text($@ || 'ismeretlen JSON feldolgozási hiba');
			print_status({}, "LOCAL JSON ERROR: $error", 'ERR');
			return;
		};

	if (ref($input) ne 'HASH')
	{
		print_status({}, 'LOCAL JSON ERROR: a bemenetnek JSON objektumnak kell lennie', 'ERR');
		return;
	}

	my $message_type = $input->{message_type};

	if (!defined $message_type || ref($message_type))
	{
		print_status({}, 'LOCAL VALIDATION ERROR: hiányzó vagy érvénytelen message_type', 'ERR');
		return;
	}

	if ($message_type eq 'sonde')
	{
		process_sonde_input($input);
		return;
	}

	if ($message_type eq 'base')
	{
		process_base_input($input);
		return;
	}

	print_status({}, "LOCAL VALIDATION ERROR: ismeretlen message_type: $message_type", 'ERR');
}

sub process_sonde_input
{
	my ($input) = @_;
	my ($valid, $error) = validate_sonde_input($input);

	if (!$valid)
	{
		print_status({}, "LOCAL VALIDATION ERROR: $error", 'ERR');
		return;
	}

	push @telemetry_queue, build_telemetry_payload($input);
	print_status(
		{},
		sprintf(
			'TELEMETRY QUEUED: %d csomag; következő köteg legfeljebb %.0f másodperc múlva',
			scalar(@telemetry_queue),
			$CFG{telemetry_interval_s},
		),
		'OK',
	);
}

sub process_base_input
{
	my ($input) = @_;
	my ($valid, $error) = validate_base_input($input);

	if (!$valid)
	{
		print_status({}, "LOCAL VALIDATION ERROR: $error", 'ERR');
		return;
	}

	$pending_base =
	{
		lat    => round_number($input->{lat}, 5),
		lon    => round_number($input->{lon}, 5),
		alt    => round_number($input->{alt}, 2),
		mobile => $input->{mobile} ? JSON::PP::true : JSON::PP::false,
	};

	upload_pending_base_if_due();
}

sub flush_telemetry_if_due
{
	my ($force) = @_;
	return if !@telemetry_queue;

	my $now = time();
	return
		if !$force
		&& $now - $last_telemetry_upload_epoch < $CFG{telemetry_interval_s};

	my @batch = @telemetry_queue;
	@telemetry_queue = ();
	$last_telemetry_upload_epoch = $now;

	log_payload($_) for @batch;

	if ($dev_mode)
	{
		print_status(
			{},
			sprintf('TELEMETRY DEV MODE: %d csomag feltöltése kihagyva', scalar(@batch)),
			'OK',
		);
		return;
	}

	my $response = put_json($CFG{telemetry_api_url}, \@batch);
	print_http_status('TELEMETRY', { batch_size => scalar(@batch) }, $response);
}

sub seconds_until_base_due
{
	my ($base) = @_;
	my $now = time();

	if (defined $last_base_attempt_epoch)
	{
		my $minimum_due = $last_base_attempt_epoch + $CFG{base_min_interval_s};
		return $minimum_due - $now if $minimum_due > $now;
	}

	return 0 if !defined $last_base_success_epoch || !defined $last_confirmed_base;

	my $normal_interval = $base->{mobile}
		? $CFG{mobile_base_interval_s}
		: $CFG{fixed_base_interval_s};

	my $normal_due = $last_base_success_epoch + $normal_interval;
	my $distance = base_distance_m($last_confirmed_base, $base);

	return 0 if $distance >= $CFG{base_move_distance_m};
	return $normal_due - $now if $normal_due > $now;
	return 0;
}

sub upload_pending_base_if_due
{
	return if !defined $pending_base;
	return if seconds_until_base_due($pending_base) > 0;

	my $base = $pending_base;
	$pending_base = undef;
	$last_base_attempt_epoch = time();

	my $payload = build_listener_payload($base);
	log_payload($payload);

	if ($dev_mode)
	{
		print_status($payload, 'LISTENER DEV MODE: feltöltés kihagyva', 'OK');
		return;
	}

	my $response = put_json($CFG{listener_api_url}, $payload);
	my $success = print_http_status('LISTENER', $payload, $response);

	if ($success)
	{
		$last_base_success_epoch = time();
		$last_confirmed_base =
		{
			lat    => $base->{lat},
			lon    => $base->{lon},
			alt    => $base->{alt},
			mobile => $base->{mobile},
		};
	}
	else
	{
		$pending_base = $base if !defined $pending_base;
	}
}

sub put_json
{
	my ($url, $payload) = @_;
	my $wire_json = $json->encode($payload);
	my $wire_bytes = encode_utf8($wire_json);
	my %headers =
	(
		'Accept'       => 'text/plain',
		'Content-Type' => 'application/json; charset=utf-8',
		'Date'         => http_date_utc(),
		'User-Agent'   => "$CFG{software_name}/$CFG{software_version}",
	);

	if ($CFG{gzip_enabled})
	{
		my $compressed = '';
		my $ok = gzip(\$wire_bytes => \$compressed);

		if (!$ok)
		{
			return
			{
				request_ok => 0,
				response   => undef,
				error      => "GZIP tömörítési hiba: $GzipError",
			};
		}

		$wire_bytes = $compressed;
		$headers{'Content-Encoding'} = 'gzip';
	}

	my $response;
	my $request_ok = eval
	{
		$response = $http->put
		(
			$url,
			{
				headers => \%headers,
				content => $wire_bytes,
			}
		);
		1;
	};

	return
	{
		request_ok => $request_ok ? 1 : 0,
		response   => $response,
		error      => $request_ok
			? ''
			: clean_text($@ || 'ismeretlen HTTP klienshiba'),
	};
}

sub print_http_status
{
	my ($kind, $payload, $result) = @_;

	if (!$result->{request_ok})
	{
		print_status($payload, "$kind LOCAL HTTP ERROR: $result->{error}", 'ERR');
		return 0;
	}

	my $response = $result->{response};
	my $http_text = sprintf
	(
		'%s %s%s',
		defined($response->{status}) ? $response->{status} : '599',
		defined($response->{reason}) ? $response->{reason} : 'HTTP hiba',
		defined($response->{content}) && length($response->{content})
			? ': ' . clean_text($response->{content})
			: '',
	);

	my $success = $response->{success} ? 1 : 0;
	print_status($payload, "$kind $http_text", $success ? 'OK' : 'ERR');
	return $success;
}

sub log_payload
{
	my ($payload) = @_;
	print {$slog_fh} $json->encode($payload) . "\n";
}

sub build_listener_payload
{
	my ($input) = @_;

	return
	{
		software_name     => $CFG{software_name},
		software_version  => $CFG{software_version},
		uploader_callsign => $CFG{uploader_callsign},
		uploader_position =>
		[
			round_number($input->{lat}, 5),
			round_number($input->{lon}, 5),
			round_number($input->{alt}, 2),
		],
		uploader_radio   => "$CFG{receiver}; firmware: $CFG{receiver_firmware}",
		uploader_antenna => $CFG{antenna},
		mobile           => $input->{mobile} ? JSON::PP::true : JSON::PP::false,
	};
}

sub build_telemetry_payload
{
	my ($input) = @_;

	my $payload =
	{
		software_name     => $CFG{software_name},
		software_version  => $CFG{software_version},
		uploader_callsign => $CFG{uploader_callsign},
		time_received     => iso8601_now_utc(),
		manufacturer      => $CFG{manufacturer},
		type              => $CFG{type},
		subtype           => $CFG{subtype},
		serial            => $input->{serial},
		frame             => int($input->{frame}),
		datetime          => $input->{datetime},
		lat               => round_number($input->{lat}, 5),
		lon               => round_number($input->{lon}, 5),
		alt               => round_number($input->{alt}, 2),
		frequency         => round_number(
			defined($input->{frequency})
				? $input->{frequency}
				: $CFG{default_frequency_mhz},
			3,
		),
		temp              => round_number($input->{temp}, 2),
		humidity          => round_number($input->{humidity}, 2),
		pressure          => round_number($input->{pressure}, 2),
		vel_h             => round_number($input->{vel_h}, 2),
		vel_v             => round_number($input->{vel_v}, 2),
		heading           => round_number($input->{heading}, 2),
		sats              => int($input->{sats}),
		batt              => round_number($input->{batt}, 2),
		uploader_antenna  => join
		(
			'; ',
			"vevő: $CFG{receiver}",
			"firmware: $CFG{receiver_firmware}",
			"antenna: $CFG{antenna}",
		),
	};

	if (exists($input->{uploader_position}))
	{
		$payload->{uploader_position} =
		[
			round_number($input->{uploader_position}[0], 5),
			round_number($input->{uploader_position}[1], 5),
			round_number($input->{uploader_position}[2], 2),
		];
	}

	if ($dev_mode)
	{
		$payload->{dev} = 'true';
	}

	return $payload;
}

sub round_number
{
	my ($value, $digits) = @_;
	my $factor = 10 ** $digits;
	my $number = 0 + $value;

	return int($number * $factor + ($number < 0 ? -0.5 : 0.5)) / $factor;
}

sub base_distance_m
{
	my ($first, $second) = @_;
	my $earth_radius = 6371008.8;
	my $pi = 4 * atan2(1, 1);

	my $lat1 = $first->{lat} * $pi / 180;
	my $lat2 = $second->{lat} * $pi / 180;
	my $dlat = ($second->{lat} - $first->{lat}) * $pi / 180;
	my $dlon = ($second->{lon} - $first->{lon}) * $pi / 180;

	my $a = sin($dlat / 2) ** 2
		+ cos($lat1) * cos($lat2) * sin($dlon / 2) ** 2;
	$a = 0 if $a < 0;
	$a = 1 if $a > 1;

	return $earth_radius * 2 * atan2(sqrt($a), sqrt(1 - $a));
}

sub validate_sonde_input
{
	my ($input) = @_;

	my @required = qw
	(
		message_type
		serial
		frame
		datetime
		lat
		lon
		alt
		temp
		humidity
		pressure
		vel_h
		vel_v
		heading
		sats
		batt
	);

	my %allowed = map { $_ => 1 } (@required, 'frequency', 'uploader_position');

	for my $key (sort keys %{$input})
	{
		return (0, "nem engedélyezett szonda mező: $key") if !$allowed{$key};
	}

	for my $key (@required)
	{
		return (0, "hiányzó mező: $key") if !exists($input->{$key});
		return (0, "null érték nem megengedett: $key") if !defined($input->{$key});
	}

	return (0, 'message_type értéke sonde kell legyen')
		if ref($input->{message_type}) || $input->{message_type} ne 'sonde';

	return (0, 'serial nem lehet üres')
		if ref($input->{serial}) || $input->{serial} !~ /\S/;

	return (0, 'datetime nem érvényes UTC ISO-8601 idő')
		if ref($input->{datetime})
		|| $input->{datetime} !~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

	for my $key (qw(frame lat lon alt temp humidity pressure vel_h vel_v heading sats batt))
	{
		return (0, "$key nem szám") if !is_finite_number($input->{$key});
	}

	if (exists($input->{frequency}) && defined($input->{frequency}))
	{
		return (0, 'frequency nem szám') if !is_finite_number($input->{frequency});
	}

	if (exists($input->{uploader_position}))
	{
		return (0, 'uploader_position csak háromelemű JSON tömb lehet')
			if ref($input->{uploader_position}) ne 'ARRAY'
			|| @{$input->{uploader_position}} != 3;

		for my $index (0 .. 2)
		{
			return (0, "uploader_position[$index] nem szám")
				if !is_finite_number($input->{uploader_position}[$index]);
		}

		return (0, 'uploader_position szélességi tartománya -90..90 fok')
			if $input->{uploader_position}[0] < -90
			|| $input->{uploader_position}[0] > 90;

		return (0, 'uploader_position hosszúsági tartománya -180..180 fok')
			if $input->{uploader_position}[1] < -180
			|| $input->{uploader_position}[1] > 180;
	}

	return (0, 'frame csak nemnegatív egész szám lehet')
		if $input->{frame} < 0 || int($input->{frame}) != $input->{frame};

	return (0, 'sats csak nemnegatív egész szám lehet')
		if $input->{sats} < 0 || int($input->{sats}) != $input->{sats};

	return (0, 'lat tartománya -90..90 fok')
		if $input->{lat} < -90 || $input->{lat} > 90;

	return (0, 'lon tartománya -180..180 fok')
		if $input->{lon} < -180 || $input->{lon} > 180;

	return (0, 'frequency MHz-ben adandó meg, ésszerű tartománya 100..2000 MHz')
		if exists($input->{frequency})
		&& defined($input->{frequency})
		&& ($input->{frequency} < 100 || $input->{frequency} > 2000);

	return (0, 'humidity tartománya 0..100 százalék')
		if $input->{humidity} < 0 || $input->{humidity} > 100;

	return (0, 'pressure nem lehet negatív')
		if $input->{pressure} < 0;

	return (0, 'heading tartománya 0..360 fok')
		if $input->{heading} < 0 || $input->{heading} > 360;

	return (0, 'batt nem lehet negatív')
		if $input->{batt} < 0;

	return (1, '');
}

sub validate_base_input
{
	my ($input) = @_;
	my @required = qw(message_type lat lon alt mobile);
	my %allowed = map { $_ => 1 } @required;

	for my $key (sort keys %{$input})
	{
		return (0, "nem engedélyezett bázis mező: $key") if !$allowed{$key};
	}

	for my $key (@required)
	{
		return (0, "hiányzó mező: $key") if !exists($input->{$key});
		return (0, "null érték nem megengedett: $key") if !defined($input->{$key});
	}

	return (0, 'message_type értéke base kell legyen')
		if ref($input->{message_type}) || $input->{message_type} ne 'base';

	for my $key (qw(lat lon alt))
	{
		return (0, "$key nem szám") if !is_finite_number($input->{$key});
	}

	return (0, 'lat tartománya -90..90 fok')
		if $input->{lat} < -90 || $input->{lat} > 90;

	return (0, 'lon tartománya -180..180 fok')
		if $input->{lon} < -180 || $input->{lon} > 180;

	return (0, 'mobile csak JSON boolean lehet')
		if !JSON::PP::is_bool($input->{mobile});

	return (1, '');
}

sub is_finite_number
{
	my ($value) = @_;
	return 0 if ref($value);
	return 0 if $value !~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/;

	my $number = 0 + $value;
	return 0 if $number != $number;
	return 0 if "$number" =~ /inf/i;
	return 1;
}

sub iso8601_now_utc
{
	my ($seconds, $microseconds) = gettimeofday();
	my $milliseconds = int($microseconds / 1000);

	return strftime('%Y-%m-%dT%H:%M:%S', gmtime($seconds))
		. sprintf('.%03dZ', $milliseconds);
}

sub http_date_utc
{
	return strftime('%a, %d %b %Y %H:%M:%S GMT', gmtime(time()));
}

sub clean_text
{
	my ($text) = @_;
	$text = '' if !defined($text);
	$text =~ s/[\r\n\t]+/ /g;
	$text =~ s/\s{2,}/ /g;
	$text =~ s/^\s+|\s+$//g;
	return $text;
}

sub print_status
{
	my ($payload, $http_response, $result) = @_;

	print $json->encode($payload)
		. "\t"
		. clean_text($http_response)
		. "\t"
		. $result
		. "\n";
}

sub usage
{
	my ($exit_code) = @_;

	print STDERR <<'USAGE';
Használat:
  ./sondehub_upload.pl [--dev]

A program soronként kétféle JSON objektumot olvas STDIN-ről.

Szonda telemetria:
  {"message_type":"sonde", ...}

Bázis/listener pozíció:
  {"message_type":"base","lat":47.49786,"lon":19.04022,"alt":110,"mobile":false}

A telemetria konfigurálható időközönként kötegelt JSON tömbként kerül feltöltésre.
A bázisfeltöltés időzítését a feltöltő kezeli a sikeresen visszaigazolt utolsó
pozíció, a fix/mobil időköz, a minimális időköz és a mozgási küszöb alapján.

  --dev               A hálózati feltöltéseket kihagyja, a payloadokat naplózza.
  --protocol-version  Kiírja a GUI-protokoll verzióját, majd kilép.
  --help              Súgó.
USAGE

	exit $exit_code;
}
