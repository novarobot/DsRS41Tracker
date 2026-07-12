#!/usr/bin/env perl

##arecord       -D default      -t wav  -f S16_LE       -r 48000        -c 1    -q | ./rs41_filter_stream.py    -LF 1000        -HF 4000        -O 1    -P 0.75         -D 0.5  -V | rs41mod    -vv       -r /dev/stdin | ./rs41_raw_decode.pl

=pod
OUT="rs41_$(date '+%Y-%m-%d_%H-%M-%S').wav"

arecord \
	-D default \
	-t wav \
	-f S16_LE \
	-r 48000 \
	-c 1 \
	-q \
| tee "$OUT" \
| ./rs41_filter_stream.py \
	-LF 1000 \
	-HF 4000 \
	-O 1 \
	-P 0.75 \
	-D 0.5 \
	-V \
| rs41mod \
	-vv \
	-r \
	/dev/stdin \
| ./rs41_raw_decode.pl
=cut

use strict;
use warnings;
use feature qw(say);
use Getopt::Long qw(GetOptions);
use JSON::PP;
use POSIX qw(atan2 sqrt strftime);
use Time::Local qw(timegm);

$| = 1;

my $json_output = 0;
my $show_raw = 1;
my $show_cal = 0;
my $only_valid = 0;
my $help = 0;

GetOptions(
	'json!'       => \$json_output,
	'raw!'        => \$show_raw,
	'calibration' => \$show_cal,
	'only-valid'  => \$only_valid,
	'help'        => \$help,
) or usage(1);

usage(0) if $help;

my %sondes;
my $json = JSON::PP->new->canonical(1)->allow_nonref(1);

while (my $line = <STDIN>)
{
	chomp $line;

	my ($hex, $upstream_state, $upstream_info) = parse_input_line($line);
	next if !defined $hex;

	my @frame = unpack('C*', pack('H*', $hex));
	my $result = decode_frame(\@frame, $upstream_state, $upstream_info, \%sondes);
	next if !defined $result;
	next if $only_valid && $result->{validity} ne 'VALID';

	if ($json_output)
	{
		say $json->encode($result);
	}
	else
	{
		print_text($result, $show_raw, $show_cal);
	}
}

sub usage
{
	my ($exit_code) = @_;

	print <<'USAGE';
Használat:
  rs41mod -r -i -vv /dev/stdin | ./rs41_raw_decode.pl
  ./rs41_raw_decode.pl < rs41_raw.txt

Kapcsolók:
  --json           Egy JSON objektum keretenként
  --no-raw         Ne írja ki a 12 darab nyers PTU mérést
  --calibration    Kalibrációs részkeret és gyűjtési állapot kiírása
  --only-valid     Csak teljesen CRC-helyes keretek
  --help           Súgó

A bemenet az rs41mod -r sorformátuma: 640 vagy több hexadecimális karakter,
majd opcionálisan [OK]/[NO] és további állapotjelzés.
USAGE

	exit $exit_code;
}

sub parse_input_line
{
	my ($line) = @_;

	return if $line !~ /^\s*([0-9A-Fa-f]{640,1036})(?:\s+\[(OK|NO)\])?(?:\s+(.*))?\s*$/;

	my $hex = lc $1;
	my $state = defined $2 ? $2 : 'UNKNOWN';
	my $info = defined $3 ? $3 : '';

	return ($hex, $state, $info);
}

sub decode_frame
{
	my ($f, $upstream_state, $upstream_info, $sondes) = @_;

	return if @$f < 320;

	my $header_ok = join('', map { sprintf('%02x', $_) } @$f[0 .. 7]) eq '8635f44093df1a60';
	my %packets = (
		frame => check_packet($f, 0x039, 0x79),
		ptu   => check_packet($f, 0x065, 0x7A),
		gps1  => check_packet($f, 0x093, 0x7C),
		gps2  => check_packet($f, 0x0B5, 0x7D),
		gps3  => check_packet($f, 0x112, 0x7B),
		end   => check_packet($f, 0x12B, undef),
	);

	my $valid_count = scalar grep { $_->{crc_ok} } values %packets;
	my $present_count = scalar grep { $_->{present} } values %packets;

	my $validity;
	if ($header_ok && $valid_count == scalar(keys %packets))
	{
		$validity = 'VALID';
	}
	elsif ($header_ok && $valid_count > 0)
	{
		$validity = 'PARTIAL';
	}
	else
	{
		$validity = 'INVALID';
	}

	my $frame_number;
	my $sonde_id;
	my $battery;
	my $cal_index;
	my $cal_payload;

	if ($packets{frame}{crc_ok})
	{
		$frame_number = u16le($f, 0x03B);
		$sonde_id = ascii_field($f, 0x03D, 8);
		$battery = $f->[0x045] / 10.0;
		$cal_index = $f->[0x052];
		$cal_payload = [ @$f[0x053 .. 0x062] ];
	}
	else
	{
		my $guessed_id = guess_sonde_id($f);
		$sonde_id = $guessed_id if defined $guessed_id && exists $sondes->{$guessed_id};
	}

	my $state;
	if (defined $sonde_id && $sonde_id =~ /^[[:print:]]{8}$/)
	{
		$state = ($sondes->{$sonde_id} //= new_sonde_state($sonde_id));
	}

	if (defined $state && defined $cal_index && $cal_index <= 0x32)
	{
		$state->{calibration}[$cal_index] = $cal_payload;
		$state->{cal_seen}{$cal_index} = 1;
	}

	my $gps_time = $packets{gps1}{crc_ok} ? decode_gps_time($f) : undef;
	my $position = $packets{gps3}{crc_ok} ? decode_gps3($f) : undef;
	my $ptu = $packets{ptu}{crc_ok} ? decode_ptu($f, $state, $position) : undef;

	my $cal_status = defined $state ? calibration_status($state) : undef;
	my $config = defined $state ? decode_configuration($state) : undef;

	return {
		type              => 'RS41',
		validity          => $validity,
		header_ok         => bool($header_ok),
		valid_packets     => $valid_count,
		present_packets   => $present_count,
		upstream_state    => $upstream_state,
		upstream_info     => $upstream_info,
		frame_length      => scalar(@$f),
		frame_number      => $frame_number,
		sonde_id          => $sonde_id,
		battery_v         => $battery,
		packet_status     => { map { $_ => packet_public($packets{$_}) } sort keys %packets },
		gps_time          => $gps_time,
		position          => $position,
		ptu               => $ptu,
		configuration     => $config,
		calibration       => $cal_status,
		calibration_frame => defined $cal_index ? {
			index => $cal_index,
			hex   => join('', map { sprintf('%02x', $_) } @$cal_payload),
		} : undef,
	};
}

sub new_sonde_state
{
	my ($id) = @_;

	return {
		id          => $id,
		calibration => [],
		cal_seen    => {},
	};
}

sub check_packet
{
	my ($f, $pos, $expected_type) = @_;

	return {
		present => bool(0),
		crc_ok  => bool(0),
		reason  => 'outside-frame',
	} if $pos + 4 > @$f;

	my $type = $f->[$pos];
	my $len = $f->[$pos + 1];

	return {
		present => bool(0),
		crc_ok  => bool(0),
		type    => sprintf('0x%02X', $type),
		length  => $len,
		reason  => 'unexpected-type',
	} if defined $expected_type && $type != $expected_type;

	return {
		present => bool(0),
		crc_ok  => bool(0),
		type    => sprintf('0x%02X', $type),
		length  => $len,
		reason  => 'invalid-length',
	} if $pos + $len + 4 > @$f;

	my @data = @$f[$pos + 2 .. $pos + 1 + $len];
	my $stored = u16le($f, $pos + 2 + $len);
	my $calculated = crc16(\@data);

	return {
		present        => bool(1),
		crc_ok         => bool($stored == $calculated),
		type           => sprintf('0x%02X', $type),
		length         => $len,
		stored_crc     => sprintf('0x%04X', $stored),
		calculated_crc => sprintf('0x%04X', $calculated),
		reason         => $stored == $calculated ? 'ok' : 'crc-error',
	};
}

sub packet_public
{
	my ($p) = @_;
	return { %$p };
}

sub crc16
{
	my ($data) = @_;
	my $rem = 0xFFFF;

	for my $byte (@$data)
	{
		$rem ^= $byte << 8;

		for (1 .. 8)
		{
			if ($rem & 0x8000)
			{
				$rem = (($rem << 1) ^ 0x1021) & 0xFFFF;
			}
			else
			{
				$rem = ($rem << 1) & 0xFFFF;
			}
		}
	}

	return $rem;
}

sub decode_gps_time
{
	my ($f) = @_;

	my $week = u16le($f, 0x095);
	my $tow_ms = u32le($f, 0x097);
	my $gps_epoch = timegm(0, 0, 0, 6, 0, 1980);
	my $unix = $gps_epoch + $week * 7 * 86400 + int($tow_ms / 1000);
	my $millisecond = $tow_ms % 1000;

	return {
		gps_week       => $week,
		tow_ms         => $tow_ms,
		utc_uncorrected => strftime('%Y-%m-%dT%H:%M:%S', gmtime($unix)) . sprintf('.%03dZ', $millisecond),
		note           => 'Az rs41mod algoritmusához igazodva GPS-UTC szökőmásodperc-korrekció nélkül.',
	};
}

sub decode_gps3
{
	my ($f) = @_;

	my $x = i32le($f, 0x114) / 100.0;
	my $y = i32le($f, 0x118) / 100.0;
	my $z = i32le($f, 0x11C) / 100.0;
	my $vx = i16le($f, 0x120) / 100.0;
	my $vy = i16le($f, 0x122) / 100.0;
	my $vz = i16le($f, 0x124) / 100.0;

	my ($lat, $lon, $alt) = ecef_to_geodetic($x, $y, $z);
	my ($north, $east, $up) = ecef_velocity_to_enu($vx, $vy, $vz, $lat, $lon);
	my $vh = sqrt($north * $north + $east * $east);
	my $heading = atan2($east, $north) * 180.0 / pi();
	$heading += 360.0 if $heading < 0.0;

	return {
		latitude_deg  => $lat,
		longitude_deg => $lon,
		altitude_m    => $alt,
		velocity_h_ms => $vh,
		heading_deg   => $heading,
		velocity_v_ms => $up,
		satellites    => $f->[0x126],
		sacc          => $f->[0x127],
		pdop          => $f->[0x128] / 10.0,
		ecef          => {
			x_m  => $x,
			y_m  => $y,
			z_m  => $z,
			vx_ms => $vx,
			vy_ms => $vy,
			vz_ms => $vz,
		},
	};
}

sub decode_ptu
{
	my ($f, $state, $position) = @_;

	my @meas;
	for my $i (0 .. 11)
	{
		push @meas, u24le($f, 0x067 + 3 * $i);
	}
	my $pressure_sensor_temperature_raw = i16le($f, 0x067 + 38);

	my $result = {
		raw_measurements => {
			temperature       => [ @meas[0 .. 2] ],
			humidity          => [ @meas[3 .. 5] ],
			humidity_temp     => [ @meas[6 .. 8] ],
			pressure          => [ @meas[9 .. 11] ],
			pressure_temp_raw => $pressure_sensor_temperature_raw,
		},
	};

	return $result if !defined $state;

	my $cal = calibration_values($state);
	$result->{calibration_ready} = $cal->{ready};
	$result->{missing_calibration_frames} = $cal->{missing};

	if ($cal->{temperature_ready})
	{
		$result->{temperature_c} = get_temperature(
			$meas[0], $meas[1], $meas[2],
			$cal->{rf1}, $cal->{rf2}, $cal->{co1}, $cal->{cal_t1},
		);
	}

	if ($cal->{humidity_temperature_ready})
	{
		$result->{humidity_sensor_temperature_c} = get_temperature(
			$meas[6], $meas[7], $meas[8],
			$cal->{rf1}, $cal->{rf2}, $cal->{co2}, $cal->{cal_t2},
		);
	}

	if ($cal->{humidity_basic_ready} && defined $result->{temperature_c})
	{
		$result->{relative_humidity_empirical_pct} = get_rh_empirical(
			$meas[3], $meas[4], $meas[5],
			$result->{temperature_c}, $cal->{cal_h},
		);
	}

	if ($cal->{pressure_ready})
	{
		$result->{pressure_hpa} = get_pressure(
			$meas[9], $meas[10], $meas[11],
			$pressure_sensor_temperature_raw,
			$cal->{cal_p},
		);
	}

	my $pressure_for_rh;
	if (defined $result->{pressure_hpa})
	{
		$pressure_for_rh = $result->{pressure_hpa};
	}
	elsif (defined $position)
	{
		$pressure_for_rh = pressure_from_altitude($position->{altitude_m});
		$result->{pressure_estimated_hpa} = $pressure_for_rh;
	}

	if (
		$cal->{humidity_advanced_ready}
		&& defined $result->{temperature_c}
		&& defined $result->{humidity_sensor_temperature_c}
	)
	{
		$result->{relative_humidity_pct} = get_rh_advanced(
			$meas[3], $meas[4], $meas[5],
			$result->{temperature_c},
			$result->{humidity_sensor_temperature_c},
			$pressure_for_rh,
			$cal,
		);
	}

	return $result;
}

sub calibration_values
{
	my ($state) = @_;
	my @bytes = calibration_bytes($state);
	my %seen = %{ $state->{cal_seen} };

	my @need_temperature = (0x03, 0x04, 0x05, 0x06);
	my @need_humidity_temp = (0x03, 0x04, 0x12, 0x13);
	my @need_humidity_basic = (0x07);
	my @need_humidity_adv = (0x07 .. 0x13, 0x2A .. 0x2E);
	my @need_pressure = (0x21, 0x25 .. 0x2A);

	my @all_required = unique(@need_temperature, @need_humidity_temp, @need_humidity_adv, @need_pressure);
	my @missing = grep { !$seen{$_} } @all_required;

	my $cal = {
		ready                       => bool(@missing == 0),
		missing                     => [ map { sprintf('0x%02X', $_) } @missing ],
		temperature_ready           => bool(all_seen(\%seen, @need_temperature)),
		humidity_temperature_ready  => bool(all_seen(\%seen, @need_humidity_temp)),
		humidity_basic_ready        => bool(all_seen(\%seen, @need_humidity_basic)),
		humidity_advanced_ready     => bool(all_seen(\%seen, @need_humidity_adv)),
		pressure_ready              => bool(all_seen(\%seen, @need_pressure) && byte_at(\@bytes, 0x21F) == ord('P')),
	};

	if ($cal->{temperature_ready} || $cal->{humidity_temperature_ready})
	{
		$cal->{rf1} = float_le(\@bytes, 61);
		$cal->{rf2} = float_le(\@bytes, 65);
	}

	if ($cal->{temperature_ready})
	{
		$cal->{co1} = [ map { float_le(\@bytes, $_) } (77, 81, 85) ];
		$cal->{cal_t1} = [ map { float_le(\@bytes, $_) } (89, 93, 97) ];
	}

	if ($cal->{humidity_basic_ready})
	{
		$cal->{cal_h} = [ map { float_le(\@bytes, $_) } (117, 121) ];
	}

	if ($cal->{humidity_temperature_ready})
	{
		$cal->{co2} = [ map { float_le(\@bytes, $_) } (293, 297, 301) ];
		$cal->{cal_t2} = [ map { float_le(\@bytes, $_) } (305, 309, 313) ];
	}

	if ($cal->{humidity_advanced_ready})
	{
		$cal->{cf1} = float_le(\@bytes, 69);
		$cal->{cf2} = float_le(\@bytes, 73);
		$cal->{mtx_h} = [ map { float_le(\@bytes, 125 + 4 * $_) } 0 .. 41 ];
		$cal->{cor_hp} = [ map { float_le(\@bytes, 678 + 4 * $_) } 0 .. 2 ];
		$cal->{cor_ht} = [ map { float_le(\@bytes, 698 + 4 * $_) } 0 .. 11 ];
	}

	if ($cal->{pressure_ready})
	{
		my @p = (0.0) x 25;
		for my $i (0 .. 6)
		{
			$p[4 * $i] = float_le(\@bytes, 606 + 4 * $i);
		}
		for my $i (0 .. 3)
		{
			$p[1 + 4 * $i] = float_le(\@bytes, 634 + 4 * $i);
		}
		for my $i (0 .. 3)
		{
			$p[2 + 4 * $i] = float_le(\@bytes, 650 + 4 * $i);
		}
		for my $i (0 .. 2)
		{
			$p[3 + 4 * $i] = float_le(\@bytes, 666 + 4 * $i);
		}
		$cal->{cal_p} = \@p;
	}

	return $cal;
}

sub calibration_bytes
{
	my ($state) = @_;
	my @bytes = (0) x (51 * 16);

	for my $index (0 .. 50)
	{
		next if !defined $state->{calibration}[$index];
		my $payload = $state->{calibration}[$index];
		for my $i (0 .. 15)
		{
			$bytes[$index * 16 + $i] = $payload->[$i];
		}
	}

	return @bytes;
}

sub calibration_status
{
	my ($state) = @_;
	my @seen = sort { $a <=> $b } keys %{ $state->{cal_seen} };
	my @missing = grep { !$state->{cal_seen}{$_} } 0 .. 0x32;
	my @bytes = calibration_bytes($state);
	my $complete_crc_ok = bool(0);

	if (@missing == 0)
	{
		my $stored = $bytes[0] | ($bytes[1] << 8);
		my @crc_data = @bytes[2 .. 50 * 16 - 1];
		$complete_crc_ok = bool($stored == crc16(\@crc_data));
	}

	return {
		seen_count      => scalar(@seen),
		seen_frames     => [ map { sprintf('0x%02X', $_) } @seen ],
		missing_frames  => [ map { sprintf('0x%02X', $_) } @missing ],
		complete        => bool(@missing == 0),
		complete_crc_ok => $complete_crc_ok,
	};
}

sub decode_configuration
{
	my ($state) = @_;
	my @bytes = calibration_bytes($state);
	my %seen = %{ $state->{cal_seen} };
	my %cfg;

	if ($seen{0x00})
	{
		my $raw = u16le(\@bytes, 0x005);
		$cfg{frequency_khz} = 400000 + 10 * $raw;
	}
	if ($seen{0x01})
	{
		$cfg{firmware} = sprintf('0x%04X', u16le(\@bytes, 0x015));
	}
	if ($seen{0x21} && $seen{0x22})
	{
		$cfg{model} = ascii_field(\@bytes, 0x21B, 10);
		$cfg{rsm} = ascii_field(\@bytes, 0x225, 6);
	}
	if ($seen{0x31})
	{
		$cfg{burst_timer_min} = u16le(\@bytes, 0x316) / 60.0;
	}

	return \%cfg;
}

sub get_temperature
{
	my ($f, $f1, $f2, $rf1, $rf2, $p, $c) = @_;
	return undef if !defined $rf1 || !defined $rf2 || $f2 == $f1 || $rf2 == $rf1;

	my $g = ($f2 - $f1) / ($rf2 - $rf1);
	my $rb = ($f1 * $rf2 - $f2 * $rf1) / ($f2 - $f1);
	my $rc = $f / $g - $rb;
	my $r = $rc * $c->[0];
	return ($p->[0] + $p->[1] * $r + $p->[2] * $r * $r + $c->[1]) * (1.0 + $c->[2]);
}

sub get_rh_empirical
{
	my ($f, $f1, $f2, $temperature, $cal_h) = @_;
	return undef if $f2 == $f1 || !$cal_h->[0];

	my $a0 = 7.5;
	my $a1 = 350.0 / $cal_h->[0];
	my $fh = ($f - $f1) / ($f2 - $f1);
	my $rh = 100.0 * ($a1 * $fh - $a0);
	$rh -= $temperature / 5.5;
	$rh *= 1.0 + (-20.0 - $temperature) / 100.0 if $temperature < -20.0;
	$rh *= 1.0 + (-40.0 - $temperature) / 120.0 if $temperature < -40.0;
	$rh = 0.0 if $rh < 0.0;
	$rh = 100.0 if $rh > 100.0;
	return $rh;
}

sub get_rh_advanced
{
	my ($f, $f1, $f2, $t, $th, $pressure, $cal) = @_;
	return undef if $f2 == $f1 || !$cal->{cal_h}[0];

	my $cfh = ($f - $f1) / ($f2 - $f1);
	my $cap = $cal->{cf1} + ($cal->{cf2} - $cal->{cf1}) * $cfh;
	my $cp = ($cap / $cal->{cal_h}[0] - 1.0) * $cal->{cal_h}[1];
	my $trh = ($th - 20.0) / 180.0;
	my @b;
	my $bk = 1.0;
	for my $k (0 .. 5)
	{
		$b[$k] = $bk;
		$bk *= $trh;
	}

	if (defined $pressure && $pressure > 0.0)
	{
		my $pbar = $pressure / 1000.0;
		my @bp;
		my $cpj = 1.0;
		for my $j (0 .. 2)
		{
			my $h = $cal->{cor_hp}[$j];
			$bp[$j] = $h * ($pbar / (1.0 + $h * $pbar) - $cpj / (1.0 + $h));
			$cpj *= $cp;
		}
		my $corr = 0.0;
		for my $j (0 .. 2)
		{
			my $bt = 0.0;
			for my $k (0 .. 3)
			{
				$bt += $cal->{cor_ht}[4 * $j + $k] * $b[$k];
			}
			$corr += $bp[$j] * $bt;
		}
		$cp -= $corr;
	}

	my $rh0 = 0.0;
	my $aj = 1.0;
	for my $j (0 .. 6)
	{
		for my $k (0 .. 5)
		{
			$rh0 += $aj * $b[$k] * $cal->{mtx_h}[6 * $j + $k];
		}
		$aj *= $cp;
	}

	$rh0 += ($t + 40.0) / 12.0 if (!defined $pressure || $pressure <= 0.0) && $t < -40.0;
	my $rh = $rh0 * vapor_saturation_pressure($th) / vapor_saturation_pressure($t);
	$rh = 0.0 if $rh < 0.0;
	$rh = 100.0 if $rh > 100.0;
	return $rh;
}

sub get_pressure
{
	my ($f, $f1, $f2, $fx, $cal_p) = @_;
	return undef if $f1 == $f2 || $f1 == $f;

	my $a0 = $cal_p->[24] / (($f - $f1) / ($f2 - $f1));
	my $a1 = $fx * 0.01;
	my $p = 0.0;
	my $a0j = 1.0;

	for my $j (0 .. 5)
	{
		my $a1k = 1.0;
		for my $k (0 .. 3)
		{
			$p += $a0j * $a1k * $cal_p->[$j * 4 + $k];
			$a1k *= $a1;
		}
		$a0j *= $a0;
	}

	return $p;
}

sub vapor_saturation_pressure
{
	my ($tc) = @_;
	my $t = $tc + 273.15;
	return exp(
		-5800.2206 / $t
		+ 1.3914993
		+ 6.5459673 * log($t)
		- 4.8640239e-2 * $t
		+ 4.1764768e-5 * $t * $t
		- 1.4452093e-8 * $t * $t * $t
	);
}

sub pressure_from_altitude
{
	my ($h) = @_;
	my ($pb, $tb, $lb, $hb);
	my $gmr = 9.80665 * 0.0289644 / 8.31446;

	if ($h > 32000.0)
	{
		($pb, $tb, $lb, $hb) = (8.6802, 228.65, 0.0028, 32000.0);
	}
	elsif ($h > 20000.0)
	{
		($pb, $tb, $lb, $hb) = (54.7489, 216.65, 0.001, 20000.0);
	}
	elsif ($h > 11000.0)
	{
		($pb, $tb, $lb, $hb) = (226.321, 216.65, 0.0, 11000.0);
	}
	else
	{
		($pb, $tb, $lb, $hb) = (1013.25, 288.15, -0.0065, 0.0);
	}

	return $lb == 0.0
		? $pb * exp(-$gmr * ($h - $hb) / $tb)
		: $pb * (1.0 + $lb * ($h - $hb) / $tb) ** (-$gmr / $lb);
}

sub ecef_to_geodetic
{
	my ($x, $y, $z) = @_;
	my $a = 6378137.0;
	my $e2 = 6.69437999014e-3;
	my $lon = atan2($y, $x);
	my $p = sqrt($x * $x + $y * $y);
	my $lat = atan2($z, $p * (1.0 - $e2));
	my $alt = 0.0;

	for (1 .. 12)
	{
		my $sin_lat = sin($lat);
		my $n = $a / sqrt(1.0 - $e2 * $sin_lat * $sin_lat);
		$alt = $p / cos($lat) - $n;
		my $next = atan2($z, $p * (1.0 - $e2 * $n / ($n + $alt)));
		last if abs($next - $lat) < 1e-12;
		$lat = $next;
	}

	return ($lat * 180.0 / pi(), $lon * 180.0 / pi(), $alt);
}

sub ecef_velocity_to_enu
{
	my ($vx, $vy, $vz, $lat_deg, $lon_deg) = @_;
	my $lat = $lat_deg * pi() / 180.0;
	my $lon = $lon_deg * pi() / 180.0;
	my $east = -sin($lon) * $vx + cos($lon) * $vy;
	my $north = -sin($lat) * cos($lon) * $vx - sin($lat) * sin($lon) * $vy + cos($lat) * $vz;
	my $up = cos($lat) * cos($lon) * $vx + cos($lat) * sin($lon) * $vy + sin($lat) * $vz;
	return ($north, $east, $up);
}

sub print_text
{
	my ($r, $show_raw, $show_cal) = @_;
	my $id = text_value($r->{sonde_id}, '????????');
	my $frame = text_value($r->{frame_number}, '?');
	my $battery = number_text($r->{battery_v}, '%.1f', '?');
	my $time = defined $r->{gps_time}
		? text_value($r->{gps_time}{utc_uncorrected}, '?')
		: '?';
	my $position = $r->{position} // {};
	my $ptu = $r->{ptu} // {};

	printf '[%s] frame=%s id=%s batt=%s V time=%s packets=%d/%d upstream=%s',
		$r->{validity}, $frame, $id, $battery, $time,
		$r->{valid_packets}, scalar(keys %{ $r->{packet_status} }), $r->{upstream_state};

	printf ' lat=%s lon=%s alt=%s vH=%s D=%s vV=%s sats=%s',
		number_text($position->{latitude_deg}, '%.5f', '?'),
		number_text($position->{longitude_deg}, '%.5f', '?'),
		number_text($position->{altitude_m}, '%.2f', '?'),
		number_text($position->{velocity_h_ms}, '%.1f', '?'),
		number_text($position->{heading_deg}, '%.1f', '?'),
		number_text($position->{velocity_v_ms}, '%.1f', '?'),
		text_value($position->{satellites}, '?');

	printf ' T=%sC TH=%sC RH=%s%% RHemp=%s%% P=%shPa Pest=%shPa cal=%s',
		number_text($ptu->{temperature_c}, '%.2f', '?'),
		number_text($ptu->{humidity_sensor_temperature_c}, '%.2f', '?'),
		number_text($ptu->{relative_humidity_pct}, '%.1f', '?'),
		number_text($ptu->{relative_humidity_empirical_pct}, '%.1f', '?'),
		number_text($ptu->{pressure_hpa}, '%.2f', '?'),
		number_text($ptu->{pressure_estimated_hpa}, '%.2f', '?'),
		defined $ptu->{calibration_ready}
			? ($ptu->{calibration_ready} ? 'READY' : 'WAIT')
			: '?';
	print "\n";

	my @bad = grep { !$r->{packet_status}{$_}{crc_ok} } sort keys %{ $r->{packet_status} };
	if (@bad)
	{
		print '  Hibás/hiányzó blokkok: ';
		print join(', ', map { $_ . '=' . $r->{packet_status}{$_}{reason} } @bad);
		print "\n";
	}

	if ($show_raw)
	{
		my $m = defined $r->{ptu} ? $r->{ptu}{raw_measurements} : undef;
		printf "  PTU RAW: T=%s H=%s TH=%s P=%s Ptemp=%s\n",
			raw_triplet_text($m, 'temperature'),
			raw_triplet_text($m, 'humidity'),
			raw_triplet_text($m, 'humidity_temp'),
			raw_triplet_text($m, 'pressure'),
			defined $m && defined $m->{pressure_temp_raw} ? $m->{pressure_temp_raw} : '?';
	}

	if ($show_cal)
	{
		my $cal = $r->{calibration} // {};
		printf "  Kalibráció: %s/51 részkeret, teljes=%s, teljes-CRC=%s\n",
			text_value($cal->{seen_count}, '?'),
			defined $cal->{complete} ? ($cal->{complete} ? 'igen' : 'nem') : '?',
			defined $cal->{complete_crc_ok} ? ($cal->{complete_crc_ok} ? 'OK' : 'nem/hiányos') : '?';
		if (defined $r->{calibration_frame})
		{
			printf "  Aktuális kalibrációs részkeret: 0x%02X %s\n",
				$r->{calibration_frame}{index}, $r->{calibration_frame}{hex};
		}
		else
		{
			print "  Aktuális kalibrációs részkeret: ? ?\n";
		}
	}
}

sub text_value
{
	my ($value, $fallback) = @_;
	return defined $value && $value ne '' ? $value : $fallback;
}

sub number_text
{
	my ($value, $format, $fallback) = @_;
	return $fallback if !defined $value;
	return sprintf($format, $value);
}

sub raw_triplet_text
{
	my ($measurements, $name) = @_;
	return '?/?/?' if !defined $measurements;
	return '?/?/?' if !defined $measurements->{$name};
	return join('/', map { defined $_ ? $_ : '?' } @{ $measurements->{$name} });
}

sub guess_sonde_id
{
	my ($f) = @_;
	return if @$f < 0x45;
	my $id = ascii_field($f, 0x03D, 8);
	return $id if $id =~ /^[A-Z0-9]{8}$/;
	return undef;
}

sub ascii_field
{
	my ($f, $pos, $len) = @_;
	return '' if $pos + $len > @$f;
	my $s = pack('C*', @$f[$pos .. $pos + $len - 1]);
	$s =~ s/\x00.*$//s;
	$s =~ s/[^[:print:]]//g;
	return $s;
}

sub float_le
{
	my ($f, $pos) = @_;
	return undef if $pos + 4 > @$f;
	return unpack('f<', pack('C4', @$f[$pos .. $pos + 3]));
}

sub byte_at
{
	my ($f, $pos) = @_;
	return 0 if $pos >= @$f;
	return $f->[$pos];
}

sub u16le
{
	my ($f, $pos) = @_;
	return $f->[$pos] | ($f->[$pos + 1] << 8);
}

sub i16le
{
	my ($f, $pos) = @_;
	my $v = u16le($f, $pos);
	return $v & 0x8000 ? $v - 0x10000 : $v;
}

sub u24le
{
	my ($f, $pos) = @_;
	return $f->[$pos] | ($f->[$pos + 1] << 8) | ($f->[$pos + 2] << 16);
}

sub u32le
{
	my ($f, $pos) = @_;
	return unpack('V', pack('C4', @$f[$pos .. $pos + 3]));
}

sub i32le
{
	my ($f, $pos) = @_;
	return unpack('l<', pack('C4', @$f[$pos .. $pos + 3]));
}

sub all_seen
{
	my ($seen, @indices) = @_;
	for my $index (@indices)
	{
		return 0 if !$seen->{$index};
	}
	return 1;
}

sub unique
{
	my %seen;
	return grep { !$seen{$_}++ } @_;
}

sub bool
{
	my ($v) = @_;
	return $v ? JSON::PP::true : JSON::PP::false;
}

sub pi
{
	return 4.0 * atan2(1.0, 1.0);
}
