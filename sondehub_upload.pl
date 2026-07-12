#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Encode qw(encode_utf8);
use Getopt::Long qw(GetOptions);
use HTTP::Tiny;
use IO::Select;
use JSON::PP qw(decode_json);
use POSIX qw(strftime);
use Time::HiRes qw(gettimeofday time);
use Time::Local qw(timegm);
use FindBin qw($Bin);
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

# -----------------------------------------------------------------------------
# ÁLLOMÁS- ÉS PROGRAMKONFIGURÁCIÓ
# -----------------------------------------------------------------------------

my %CFG =
	(
		telemetry_api_url =>$ENV{SONDEHUB_API_URL}// load_config('SONDEHUB_TELEMETRY_API_URL','https://api.v2.sondehub.org/sondes/telemetry',),
		listener_api_url =>$ENV{SONDEHUB_LISTENER_API_URL}// load_config('SONDEHUB_LISTENER_API_URL','https://api.v2.sondehub.org/listeners',),
		software_name => load_config('SONDEHUB_SOFTWARE_NAME','DsRS41Tracker',),
		software_version => load_config('SONDEHUB_SOFTWARE_VERSION','0.1.28',),
		uploader_callsign => load_config('SONDEHUB_UPLOADER_CALLSIGN','SWL',),
		manufacturer => load_config('SONDEHUB_MANUFACTURER','Vaisala',),
		type => load_config('SONDEHUB_TYPE','RS41',),
		subtype => load_config('SONDEHUB_SUBTYPE','RS41-SGP',),
		receiver => load_config('SONDEHUB_RECEIVER','UNDEFINED',),
		receiver_firmware => load_config('SONDEHUB_RECEIVER_FIRMWARE','UNDEFINED',),
		antenna => load_config('SONDEHUB_ANTENNA','UNDEFINED',),
		http_timeout_s => 0 + load_config('SONDEHUB_HTTP_TIMEOUT_S','15',),
		gps_utc_offset_s => 0 + load_config('SONDEHUB_GPS_UTC_OFFSET_S','18',),
		listener_min_interval_s => 0 + load_config('SONDEHUB_LISTENER_MIN_INTERVAL_S','10',),
	);

# -----------------------------------------------------------------------------

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

my $selector = IO::Select->new(\*STDIN);
my $stdin_open = 1;
my $pending_base;
my $last_listener_attempt_epoch;

while ($stdin_open || defined $pending_base)
{
	my $timeout;
	if (defined $pending_base)
	{
		$timeout = seconds_until_listener_due();
	}

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

	upload_pending_base_if_due();
}

exit 0;

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

	my $payload = build_telemetry_payload($input);
	my $response = put_json($CFG{telemetry_api_url}, [$payload]);
	print_http_status('TELEMETRY', $payload, $response);
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
		lat    => 0 + $input->{lat},
		lon    => 0 + $input->{lon},
		alt    => 0 + $input->{alt},
		mobile => $input->{mobile} ? JSON::PP::true : JSON::PP::false,
	};

	upload_pending_base_if_due();
}

sub seconds_until_listener_due
{
	return 0 if !defined $last_listener_attempt_epoch;

	my $due = $last_listener_attempt_epoch + $CFG{listener_min_interval_s};
	my $remaining = $due - time();
	return $remaining > 0 ? $remaining : 0;
}

sub upload_pending_base_if_due
{
	return if !defined $pending_base;
	return if seconds_until_listener_due() > 0;

	my $base = $pending_base;
	$pending_base = undef;
	$last_listener_attempt_epoch = time();

	my $payload = build_listener_payload($base);
	if ($dev_mode)
	{
		print_status($payload, 'LISTENER DEV MODE: feltöltés kihagyva', 'OK');
		return;
	}

	my $response = put_json($CFG{listener_api_url}, $payload);
	print_http_status('LISTENER', $payload, $response);
}

sub put_json
{
	my ($url, $payload) = @_;
	my $wire_json = $json->encode($payload);
	my $wire_bytes = encode_utf8($wire_json);
	my $response;

	my $request_ok = eval
	{
		$response = $http->put
		(
			$url,
			{
				headers =>
				{
					'Accept'       => 'text/plain',
					'Content-Type' => 'application/json; charset=utf-8',
					'Date'         => http_date_utc(),
					'User-Agent'   => "$CFG{software_name}/$CFG{software_version}",
				},
				content => $wire_bytes,
			}
		);
		1;
	};

	return
	{
		request_ok => $request_ok ? 1 : 0,
		response   => $response,
		error      => $request_ok ? '' : clean_text($@ || 'ismeretlen HTTP klienshiba'),
	};
}

sub print_http_status
{
	my ($kind, $payload, $result) = @_;

	if (!$result->{request_ok})
	{
		print_status($payload, "$kind LOCAL HTTP ERROR: $result->{error}", 'ERR');
		return;
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

	my $status = $response->{success} ? 'OK' : 'ERR';
	print_status($payload, "$kind $http_text", $status);
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
			0 + $input->{lat},
			0 + $input->{lon},
			0 + $input->{alt},
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
		frame             => 0 + $input->{frame},
		datetime          => gps_datetime_to_utc($input->{datetime}),
		lat               => 0 + $input->{lat},
		lon               => 0 + $input->{lon},
		alt               => 0 + $input->{alt},
		frequency         => 0 + $input->{frequency},
		temp              => 0 + $input->{temp},
		humidity          => 0 + $input->{humidity},
		pressure          => 0 + $input->{pressure},
		vel_h             => 0 + $input->{vel_h},
		vel_v             => 0 + $input->{vel_v},
		heading           => 0 + $input->{heading},
		sats              => 0 + $input->{sats},
		batt              => 0 + $input->{batt},
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
			0 + $input->{uploader_position}[0],
			0 + $input->{uploader_position}[1],
			0 + $input->{uploader_position}[2],
		];
	}

	if ($dev_mode)
	{
		$payload->{dev} = 'true';
	}

	return $payload;
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
		frequency
		temp
		humidity
		pressure
		vel_h
		vel_v
		heading
		sats
		batt
	);

	my %allowed = map { $_ => 1 } (@required, 'uploader_position');
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

	for my $key (qw(frame lat lon alt frequency temp humidity pressure vel_h vel_v heading sats batt))
	{
		return (0, "$key nem szám") if !is_finite_number($input->{$key});
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
		if $input->{frequency} < 100 || $input->{frequency} > 2000;

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

sub gps_datetime_to_utc
{
	my ($value) = @_;
	return $value
		if $value !~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?Z$/;

	my ($year, $month, $day, $hour, $minute, $second, $fraction) =
		($1, $2, $3, $4, $5, $6, defined($7) ? $7 : '');

	my $epoch = timegm($second, $minute, $hour, $day, $month - 1, $year);
	$epoch -= $CFG{gps_utc_offset_s};

	return strftime('%Y-%m-%dT%H:%M:%S', gmtime($epoch)) . $fraction . 'Z';
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
  {"message_type":"base","lat":47.5,"lon":19.1,"alt":200,"mobile":false}

A szonda JSON kizárólag a /sondes/telemetry végpontra kerül.
A bázis JSON kizárólag a /listeners végpontra kerül.

A bázisfeltöltések között legalább listener_min_interval_s másodperc telik el.
Ha közben több bázis JSON érkezik, csak a legutolsó érvényes marad sorban.

  --dev               A szondacsomagot dev módban küldi; a bázisfeltöltést kihagyja.
  --protocol-version  Kiírja a GUI-protokoll verzióját, majd kilép.
  --help              Súgó.
USAGE

	exit $exit_code;
}
