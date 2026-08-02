#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

our $VERSION;

BEGIN
{
	$VERSION = '0.2.46';

	if (grep { $_ eq '--version' || $_ eq '-V' } @ARGV)
	{
		print "rs41_main.pl $VERSION\n";
		exit 0;
	}
}

use FindBin qw($Bin);
use lib $Bin;
use File::Spec;
use File::Temp qw(tempfile);
use POSIX qw(strftime WNOHANG);
use Math::Trig qw(deg2rad rad2deg);
use List::Util qw(min max);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Handle;
use IO::Select;
use IPC::Open2;
use Time::HiRes qw(time sleep);
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

use RS41IPC qw(json_codec configure_json_stdio send_json_message decode_json_line);
use Encode qw(decode_utf8);

configure_json_stdio();
my $json = json_codec();

my $configfile = File::Spec->catfile($Bin, 'config.txt');

my (%config, $processor_pid, $processor_out, $recorder_pid);
my $pipeline_generation = 0;

my %service_pipe;

my $selector = IO::Select->new();

my %buffers;
my $running = 1;
my $mode = 'idle';
my $stop_state;
my $shutdown_requested = 0;

my ($current_file, $current_rlog, $current_jlog, $description);
my ($current_session_kind, $current_session_path);

my %packet = (VALID   => 0, PARTIAL => 0, INVALID => 0);

my ($last_valid, $total_path, $previous, $peak_alt, $peak_time) = (undef, 0,
	undef, undef, '?');

my $last_receiver;
my $last_calculation_position =
{
	latitude_deg  => undef,
	longitude_deg => undef,
	altitude_m    => undef
};
my @track;
my $last_base_share = 0;

sub read_config
{
	return unless -f $configfile;

	open(my $handle, '<:encoding(UTF-8)', $configfile) or return;

	while (my $line = <$handle>)
	{
		$line =~ s/^\x{FEFF}//;
		$line =~ s/[\r\n]+$//;
		$line =~ s/^\s+|\s+$//g;

		next if $line =~ /^#/;
		next if !length($line);

		if ($line =~ /^([A-Za-z0-9_.-]+)\s*=\s*(.*)$/)
		{
			my ($key, $value) = (uc($1), $2);

			$value =~ s/^['"]|['"]$//g;
			$config{$key} = $value;
		}
	}

	close($handle);

	return;
}

sub cfg
{
	my ($key, $default) = @_;
	my $name = uc($key // '');

	# Prioritás: launcher által átadott ENV > config.txt > beépített érték.
	return $ENV{$name}
		if exists($ENV{$name});

	return $config{$name}
		if exists($config{$name})
		&& $config{$name} ne '';

	return $default;
}

sub cfg_boolean
{
	my ($key, $default) = @_;
	my $value = cfg($key, $default ? '1' : '0');

	return 1 if defined($value)
		&& $value =~ /^(?:1|true|yes|on|igen|be)$/i;
	return 0 if defined($value)
		&& $value =~ /^(?:0|false|no|off|nem|ki)$/i;

	return $default ? 1 : 0;
}

read_config();

my %settings = (work_dir => File::Spec->rel2abs(cfg('LOG_DIRECTORY', './log'
), $Bin),

	device => cfg('AUDIO_DEVICE', 'default'),

	sample_rate => cfg('AUDIO_SAMPLE_RATE', '48000'),

	lf => cfg('AUDIO_LF', '525'),

	hf => cfg('AUDIO_HF', '14000'),

	order => cfg('AUDIO_ORDER', '1'),

	peak => cfg('AUDIO_PEAK', '0.75'),

	delay => cfg('AUDIO_DELAY', '0.1'),

	invert => cfg('AUDIO_INVERT', '1') =~ /^(?:1|true|yes|on)$/i ? 1 : 0,

	frequency => cfg('SONDEHUB_FREQUENCY_MHZ', '400.000'),

	share  => cfg_boolean('SONDEHUB_SHARE', 0),

	mobile => cfg_boolean('SONDEHUB_MOBIL', 0),

	base =>
	{
		latitude => cfg('BASE_LAT', '47.49786'),

		longitude => cfg('BASE_LON', '19.04022'),

		altitude => cfg('BASE_ALT', '110'),

		angle => cfg('BASE_ANGLE', '0')
	});

if (!-d $settings{work_dir})
{
	$settings{work_dir} = File::Spec->rel2abs('.', $Bin);
}

my %html_config = (base_arrow_color => cfg('BASE_ARROW_COLOR', '#42c9ff'),

	sonde_arrow_color => cfg('SONDE_ARROW_COLOR', '#e3a52b'),

	track_color => cfg('TRACK_COLOR', '#e3a52b'),

	tile_server => cfg('TILE_SERVER',
			'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),

	map_start_lat => 0 + cfg('MAP_START_LAT', 47.49786),

	map_start_lon => 0 + cfg('MAP_START_LON', 19.04022),

	map_start_zoom => 0 + cfg('MAP_START_ZOOM', 9),

	track_width => 0 + cfg('TRACK_WIDTH', 4),

	track_opacity => 0 + cfg('TRACK_OPACITY', 0.9),

	track_point_radius => 0 + cfg('TRACK_POINT_RADIUS', 3));

my $decoder = File::Spec->catfile($Bin, 'rs41_raw_decode_fixed_fields.pl');

if (!-f $decoder)
{
	$decoder = File::Spec->catfile($Bin, 'rs41_raw_decode_fixed.pl');
}

if (!-f $decoder)
{
	$decoder = File::Spec->catfile($Bin, 'rs41_raw_decode.pl');
}

my $filter = File::Spec->catfile($Bin, 'rs41_filter_stream.py');

my $bt_bridge = File::Spec->catfile($Bin, 'gps_bridge_bt.pl');

my $pipe_connect = File::Spec->catfile($Bin, 'pipeConnect.pl');

my $sondehub = File::Spec->catfile($Bin, 'sondehub_upload_v9.pl');

if (!-f $sondehub)
{
	$sondehub = File::Spec->catfile($Bin, 'sondehub_upload.pl');
}


sub shell_quote
{
	my $value = $_[0] // '';

	$value =~ s/'/'"'"'/g;

	return "'$value'";
}

sub expand_command_template
{
	my ($template, $values) = @_;

	$template = '' if !defined($template);
	$values = {} if ref($values) ne 'HASH';

	$template =~ s/\{([A-Z0-9_]+)\}/
		exists($values->{$1})
			? $values->{$1}
			: die("Ismeretlen parancssablon-helyettesítő: {$1}\n")
	/ge;

	return $template;
}

sub default_pipeline_template
{
	my ($kind) = @_;

	if ($kind eq 'record')
	{
		return
			'arecord -D {AUDIO_DEVICE} -t wav -f S16_LE '
			. '-r {AUDIO_SAMPLE_RATE} -c 1 -q '
			. '| {FILTER_COMMAND} {FILTER_ARGS} '
			. '| {MOD_COMMAND} {MOD_ARGS} '
			. '| tee -a {RLOG_FILE} '
			. '| {DECODER} --json '
			. '| tee -a {JLOG_FILE}';
	}

	if ($kind eq 'wav')
	{
		return
			'sox -- {INPUT_FILE} -t wav -b 16 -e signed-integer '
			. '-c 1 -r {AUDIO_SAMPLE_RATE} - '
			. '| {FILTER_COMMAND} {FILTER_ARGS} '
			. '| {MOD_COMMAND} {MOD_ARGS} '
			. '| {DECODER} --json';
	}

	if ($kind eq 'raw')
	{
		return
			'cat -- {INPUT_FILE} '
			. '| {DECODER} --json '
			. '| {PIPE_DELAY}';
	}

	if ($kind eq 'json')
	{
		return
			'cat -- {INPUT_FILE} '
			. '| {PIPE_DELAY}';
	}

	die "Ismeretlen feldolgozási mód: $kind\n";
}

sub configured_pipeline_template
{
	my ($kind) = @_;
	my $key = 'PIPE_' . uc($kind);
	my $configured = cfg($key, '');

	return $configured
		if defined($configured) && $configured ne '';

	return default_pipeline_template($kind);
}

sub pipeline_command
{
	my ($kind, %extra) = @_;

	my %value =
	(
		AUDIO_DEVICE      => shell_quote($settings{device}),
		AUDIO_SAMPLE_RATE => shell_quote($settings{sample_rate}),
		AUDIO_LF          => shell_quote($settings{lf}),
		AUDIO_HF          => shell_quote($settings{hf}),
		AUDIO_ORDER       => shell_quote($settings{order}),
		AUDIO_PEAK        => shell_quote($settings{peak}),
		AUDIO_DELAY       => shell_quote($settings{delay}),
		AUDIO_INVERT_ARG  => $settings{invert} ? '-i' : '',
		FILTER            => shell_quote($filter),
		FILTER_COMMAND    => filter_command(),
		FILTER_ARGS       => filter_args(),
		RS41_MOD          => shell_quote(File::Spec->catfile($Bin, 'rs41_mod')),
		MOD_COMMAND       => mod_command(),
		MOD_ARGS          => mod_args(),
		DECODER           => shell_quote($decoder),
		PIPE_DELAY        => shell_quote(
			File::Spec->catfile($Bin, 'pipe_delay.pl')
		),
		INPUT_FILE        => shell_quote($extra{input_file} // ''),
		WAV_FILE          => shell_quote($extra{wav_file} // ''),
		RLOG_FILE         => shell_quote($extra{rlog_file} // ''),
		JLOG_FILE         => shell_quote($extra{jlog_file} // ''),
		PERL              => shell_quote($^X),
		PROJECT_DIR       => shell_quote($Bin)
	);

	return expand_command_template(
		configured_pipeline_template($kind),
		\%value
	);
}

sub record_monitor_command
{
	my ($wav_file) = @_;

	my $wav_log_enabled = cfg_boolean('WAV_LOG_ENABLED', 1);

	my $wav_log_pipe = $wav_log_enabled
		? '| tee -- ' . shell_quote($wav_file)
		: '';

	my $template = cfg(
		'RECORD_MONITOR_COMMAND',
		'arecord -D {AUDIO_DEVICE} -t wav -f S16_LE '
		. '-r {AUDIO_SAMPLE_RATE} -c 1 -q - '
		. '{WAV_LOG_PIPE} '
		. '| aplay -q'
	);

	return expand_command_template(
		$template,
		{
			AUDIO_DEVICE      => shell_quote($settings{device}),
			AUDIO_SAMPLE_RATE => shell_quote($settings{sample_rate}),
			WAV_FILE          => shell_quote($wav_file // ''),
			WAV_LOG_PIPE      => $wav_log_pipe,
			PROJECT_DIR       => shell_quote($Bin)
		}
	);
}

sub service_worker_command
{
	my ($service) = @_;
	my $worker = service_worker($service);
	my $key = $service eq 'bt'
		? 'BT_WORKER_COMMAND'
		: 'SONDEHUB_WORKER_COMMAND';

	my $default =
		'exec {PERL} {WORKER} 2>&1';

	my $template = cfg($key, $default);

	return expand_command_template(
		$template,
		{
			PERL             => shell_quote($^X),
			WORKER           => shell_quote($worker),
			BT_WORKER        => shell_quote($bt_bridge),
			SONDEHUB_WORKER  => shell_quote($sondehub),
			PIPE_CONNECT     => shell_quote($pipe_connect),
			PROJECT_DIR      => shell_quote($Bin)
		}
	);
}

sub spawn_posix_command
{
	my ($command) = @_;

	pipe(my $child_stdin, my $parent_stdin)
		or die "A gyermek STDIN pipe nem hozható létre: $!\n";

	pipe(my $parent_stdout, my $child_stdout)
		or do
		{
			close($child_stdin);
			close($parent_stdin);
			die "A gyermek STDOUT pipe nem hozható létre: $!\n";
		};

	my $pid = fork();

	if (!defined($pid))
	{
		close($child_stdin);
		close($parent_stdin);
		close($parent_stdout);
		close($child_stdout);
		die "A gyermekfolyamat nem indítható: $!\n";
	}

	if ($pid == 0)
	{
		close($parent_stdin);
		close($parent_stdout);

		POSIX::setsid();

		open(STDIN, '<&', $child_stdin)
			or POSIX::_exit(125);

		open(STDOUT, '>&', $child_stdout)
			or POSIX::_exit(125);

		open(STDERR, '>&', $child_stdout)
			or POSIX::_exit(125);

		close($child_stdin);
		close($child_stdout);

		exec('sh', '-c', $command)
			or POSIX::_exit(127);
	}

	close($child_stdin);
	close($child_stdout);

	$parent_stdin->autoflush(1);

	return ($pid, $parent_stdout, $parent_stdin);
}

sub terminate_process
{
	my ($pid, $grace_seconds) = @_;

	return if !defined($pid) || $pid <= 0;

	$grace_seconds = 0.5
		if !defined($grace_seconds) || $grace_seconds < 0;

	kill('TERM', $pid);

	my $deadline = time() + $grace_seconds;

	while (time() < $deadline)
	{
		my $result = waitpid($pid, WNOHANG);

		return if $result == $pid || $result == -1;
		sleep(0.05);
	}

	kill('KILL', $pid);
	waitpid($pid, 0);

	return;
}

sub nonblock
{
	my ($handle) = @_;

	my $flags = fcntl($handle, F_GETFL, 0);

	fcntl($handle, F_SETFL, $flags | O_NONBLOCK);

	return;
}

sub send_gui
{
	my ($message) = @_;

	send_json_message(\*STDOUT, $message);

	return;
}

sub terminal_message
{
	my ($level, $text) = @_;

	send_gui(
		{
			type  => 'terminal', level => uc($level // 'INFO'),
			text  => $text // ''
		});

	return;
}

sub log_gui
{
	my ($target, $text) = @_;

	send_gui(
		{
			type   => 'append_log', target => $target, text   => $text
		});

	return;
}

sub update_settings
{
	my ($new_settings) = @_;

	return unless ref($new_settings) eq 'HASH';

	for my $key (qw (work_dir device sample_rate lf hf order peak delay invert
			frequency share mobile))
	{
		if (exists($new_settings->{$key}))
		{
			$settings{$key} = $new_settings->{$key};
		}
	}

	if (ref($new_settings->{base}) eq 'HASH')
	{
		$settings{base} =
		{
			%{$settings{base}}, %{$new_settings->{base}}
		};
	}

	return;
}

sub send_settings_state
{
	send_gui(
		{
			type        => 'settings_state',
			settings    => \%settings,
			html_config => \%html_config
		}
	);

	return;
}

sub update_applied_settings
{
	my ($new_settings) = @_;

	return unless ref($new_settings) eq 'HASH';

	for my $key (qw(frequency share mobile))
	{
		$settings{$key} = $new_settings->{$key}
			if exists($new_settings->{$key});
	}

	if (ref($new_settings->{base}) eq 'HASH')
	{
		$settings{base} =
		{
			%{$settings{base}},
			%{$new_settings->{base}}
		};
	}

	return;
}

sub processing_session_is_running
{
	return 0 if $mode eq 'idle';
	return 0 if $mode eq 'stopping';
	return 0 if !defined($current_session_kind);

	return 1;
}

sub restart_current_session
{
	return 0 if !processing_session_is_running();

	log_gui(
		'prc',
		"A beállítások mentve; az aktív munkamenet leállítása "
		. "után kézzel indítható újra.\n"
	);

	stop_pipeline();

	return 1;
}

sub validate
{
	for my $key (qw (sample_rate lf hf order peak delay)
)
	{
		if ($settings{$key} !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/)
		{
			die("Érvénytelen numerikus mező: " . "$key=$settings{$key}\n");
		}
	}

	return;
}

sub reset_stats
{
	%packet = (VALID   => 0, PARTIAL => 0, INVALID => 0);

	($last_valid, $total_path, $previous, $peak_alt, $peak_time) = (undef, 0,
		undef, undef, '?');

	$last_receiver = undef;
	$last_calculation_position =
	{
		latitude_deg  => undef,
		longitude_deg => undef,
		altitude_m    => undef
	};
	@track = ();

	send_gui(
		{
			type => 'clear_logs'
		});

	send_stats();
	send_calc();

	return;
}

sub send_stats
{
	send_gui(
		{
			type => 'runtime_statistics',

			packet_count => \%packet,

			runtime =>
			{
				last_success_age_s => defined($last_valid)
						? int(time() - $last_valid) : undef,

				total_path_m => 0 + sprintf('%.1f', $total_path),

				peak_altitude_m => defined($peak_alt) ? 0 + sprintf('%.2f',
							$peak_alt) : undef,

				peak_altitude_time => $peak_time
			}
		});

	return;
}

sub great_circle
{
	my ($latitude_a, $longitude_a, $latitude_b, $longitude_b) = @_;

	my $earth_radius = 6371008.8;

	my ($lat_a, $lon_a, $lat_b, $lon_b) = map
		{
			deg2rad($_)
		}
		($latitude_a, $longitude_a, $latitude_b, $longitude_b);

	my $latitude_delta = $lat_b - $lat_a;

	my $longitude_delta = $lon_b - $lon_a;

	my $value = sin($latitude_delta / 2) ** 2 + cos($lat_a) * cos($lat_b) *
		sin($longitude_delta / 2) ** 2;

	$value = max(0, min(1, $value));

	my $distance = $earth_radius * 2 * atan2(sqrt($value), sqrt(1 - $value));

	my $y = sin($longitude_delta) * cos($lat_b);

	my $z = cos($lat_a) * sin($lat_b) - sin($lat_a) * cos($lat_b) *
		cos($longitude_delta);

	my $bearing = rad2deg(atan2($y, $z));

	if ($bearing < 0)
	{
		$bearing += 360;
	}

	return ($distance, $bearing);
}

sub valid_calculation_coordinate
{
	my ($value) = @_;

	return 0 if !defined($value);
	return 0 if ref($value);
	return 0 if $value !~
		/^-?(?:\d+(?:\.\d*)?|\.\d+)$/;

	return 1;
}

sub merge_calculation_position
{
	my ($data) = @_;

	return 0 if ref($data) ne 'HASH';
	return 0 if ref($data->{position}) ne 'HASH';

	my $position = $data->{position};
	my $changed = 0;

	for my $key (qw(latitude_deg longitude_deg altitude_m))
	{
		next if !valid_calculation_coordinate($position->{$key});

		my $value = 0 + $position->{$key};

		if (!defined($last_calculation_position->{$key})
			|| $last_calculation_position->{$key} != $value)
		{
			$last_calculation_position->{$key} = $value;
			$changed = 1;
		}
	}

	return $changed;
}

sub send_calc
{
	my ($distance, $bearing, $elevation) = ('?', '?', '?');
	my $position = $last_calculation_position;
	my $base = $settings{base};

	if (ref($position) eq 'HASH'
		&& defined($position->{latitude_deg})
		&& defined($position->{longitude_deg})
		&& defined($position->{altitude_m})
		&& ref($base) eq 'HASH'
		&& valid_calculation_coordinate($base->{latitude})
		&& valid_calculation_coordinate($base->{longitude})
		&& valid_calculation_coordinate($base->{altitude}))
	{
		my ($ground_distance, $calculated_bearing) = great_circle(
			0 + $base->{latitude},
			0 + $base->{longitude},
			0 + $position->{latitude_deg},
			0 + $position->{longitude_deg}
		);

		my $height =
			(0 + $position->{altitude_m})
			- (0 + $base->{altitude});

		$distance = sprintf(
			'%.1f m',
			sqrt(
				$ground_distance * $ground_distance
				+ $height * $height
			)
		);

		$bearing = sprintf('%.1f°', $calculated_bearing);

		$elevation = sprintf(
			'%.2f°',
			rad2deg(atan2($height, $ground_distance))
		);
	}

	send_gui(
		{
			type      => 'calculated_fields',
			distance  => $distance,
			bearing   => $bearing,
			elevation => $elevation
		}
	);

	return;
}

sub format_prc
{
	my ($receiver) = @_;

	my $position = ref($receiver->{position}) eq 'HASH' ? $receiver->{position}
			: {};

	my $ptu = ref($receiver->{ptu}) eq 'HASH' ? $receiver->{ptu}
			: {};

	return sprintf("[%s] frame=%s id=%s batt=%s V " .
		"lat=%s lon=%s alt=%s vH=%s D=%s " .
		"vV=%s sats=%s T=%sC RH=%s%% P=%shPa\n",

		map
		{
			defined($_) ? $_ : '?'
		}
		($receiver->{validity}, $receiver->{frame_number},
			$receiver->{sonde_id}, $receiver->{battery_v},
			$position->{latitude_deg}, $position->{longitude_deg},
			$position->{altitude_m}, $position->{velocity_h_ms},
			$position->{heading_deg}, $position->{velocity_v_ms},
			$position->{satellites}, $ptu->{temperature_c},
			$ptu->{relative_humidity_pct}, $ptu->{pressure_hpa}
));
}

sub process_data
{
	my ($data) = @_;

	my $validity = $data->{validity} // '';

	if (exists($packet{$validity}))
	{
		$packet{$validity}++;
	}

	if ($validity eq 'VALID')
	{
		$last_valid = time();
	}

	if (ref($data->{position}) eq 'HASH')
	{
		my $position = $data->{position};

		if (defined($position->{latitude_deg})
			&& defined($position->{longitude_deg}) &&
			defined($position->{altitude_m}))
		{
			if ($previous)
			{
				my ($ground_distance) = great_circle($previous->{lat},
						$previous->{lon}, $position->{latitude_deg},
						$position->{longitude_deg});

				my $height = $position->{altitude_m}
					- $previous->{alt};

				$total_path += sqrt($ground_distance * $ground_distance +
						$height * $height);
			}

			$previous =
			{
				lat => $position->{latitude_deg},

				lon => $position->{longitude_deg},

				alt => $position->{altitude_m}
			};

			if ($validity eq 'VALID'
				&& (!defined($peak_alt)
					|| $position->{altitude_m} > $peak_alt))
			{
				$peak_alt = $position->{altitude_m};

				$peak_time = ref($data->{gps_time}) eq 'HASH'
						? $data->{gps_time}{utc_uncorrected}
						: '?';
			}
		}
	}

	$last_receiver = $data;
	merge_calculation_position($data);

	send_gui(
		{
			type => 'receiver_update', data => $data
		});

	send_stats();
	send_calc();
	send_sondehub($data);

	return;
}

sub filter_command
{
	return shell_quote($filter);
}

sub filter_args
{
	return join(
		' ',
		'-LF', shell_quote($settings{lf}),
		'-HF', shell_quote($settings{hf}),
		'-O',  shell_quote($settings{order}),
		'-P',  shell_quote($settings{peak}),
		'-D',  shell_quote($settings{delay}),
		'-V'
	);
}

sub filter_cmd
{
	return join(' ', filter_command(), filter_args());
}

sub mod_command
{
	return shell_quote(File::Spec->catfile($Bin, 'rs41_mod'));
}

sub mod_args
{
	return join(
		' ',
		'-vv',
		'-r',
		($settings{invert} ? '-i' : ()),
		'/dev/stdin'
	);
}

sub mod_cmd
{
	return join(' ', mod_command(), mod_args());
}

sub detach_processor_output
{
	return if !defined($processor_out);

	my $id = fileno($processor_out);

	$selector->remove($processor_out);
	delete($buffers{$id}) if defined($id);
	close($processor_out);
	undef($processor_out);

	return;
}

sub process_is_alive
{
	my ($pid) = @_;

	return 0 if !defined($pid) || $pid <= 0;
	return kill(0, $pid) ? 1 : 0;
}

sub process_group_is_alive
{
	my ($pid) = @_;

	return 0 if !defined($pid) || $pid <= 0;

	return kill(0, -$pid) ? 1 : 0;
}

sub reap_process_leader
{
	my ($pid) = @_;

	return 1 if !defined($pid) || $pid <= 0;

	my $result = waitpid($pid, WNOHANG);

	return 1 if $result == $pid || $result == -1;
	return 0;
}

sub send_stopping_state
{
	my ($description) = @_;

	send_gui(
		{
			type        => 'running_state',
			running     => 1,
			description => $description
		}
	);

	return;
}

sub finalize_pipeline_stop
{
	my (%option) = @_;

	detach_processor_output();

	$processor_pid = undef;
	$recorder_pid = undef;
	$stop_state = undef;
	$mode = 'idle';

	send_gui(
		{
			type    => 'running_state',
			running => 0
		}
	);

	if (defined($option{message}) && $option{message} ne '')
	{
		log_gui('prc', $option{message} . "\n");
	}

	return;
}

sub force_pipeline_stop
{
	return if ref($stop_state) ne 'HASH';

	for my $pid (
		$stop_state->{processor_pid},
		$stop_state->{recorder_pid}
	)
	{
		next if !defined($pid) || $pid <= 0;
		kill('KILL', -$pid);
	}

	$stop_state->{phase} = 'kill';
	$stop_state->{deadline} = time() + 1.0;

	send_stopping_state('Kényszerített leállítás folyamatban...');

	return;
}

sub poll_pipeline_stop
{
	return if ref($stop_state) ne 'HASH';

	my $old_processor_pid = $stop_state->{processor_pid};
	my $old_recorder_pid = $stop_state->{recorder_pid};

	$stop_state->{processor_reaped} = reap_process_leader($old_processor_pid)
		if !$stop_state->{processor_reaped};

	$stop_state->{recorder_reaped} = reap_process_leader($old_recorder_pid)
		if !$stop_state->{recorder_reaped};

	my $processor_alive = process_group_is_alive($old_processor_pid);
	my $recorder_alive = process_group_is_alive($old_recorder_pid);

	if (!$processor_alive && !$recorder_alive)
	{
		finalize_pipeline_stop(
			message => $stop_state->{message}
		);
		return;
	}

	return if time() < $stop_state->{deadline};

	if ($stop_state->{phase} eq 'term')
	{
		force_pipeline_stop();
		return;
	}

	for my $pid ($old_processor_pid, $old_recorder_pid)
	{
		next if !defined($pid) || $pid <= 0;
		kill('KILL', -$pid);
	}

	$stop_state->{deadline} = time() + 1.0;

	terminal_message(
		'ERR',
		'A háttérfolyamat még SIGKILL után is fut; '
		. 'a MAIN továbbra is vár a tényleges leállásra.'
	);

	return;
}

sub begin_pipeline_stop
{
	my (%option) = @_;

	return 0 if $mode eq 'idle' && !$processor_pid && !$recorder_pid
		&& !defined($processor_out);

	if (ref($stop_state) eq 'HASH')
	{
		force_pipeline_stop();
		return 1;
	}

	$stop_state =
	{
		phase              => 'term',
		deadline           => time() + 2.0,
		processor_pid      => $processor_pid,
		recorder_pid       => $recorder_pid,
		processor_reaped   => 0,
		recorder_reaped    => 0,
		message            => $option{message}
	};

	$mode = 'stopping';

	detach_processor_output();

	for my $pid (
		$stop_state->{processor_pid},
		$stop_state->{recorder_pid}
	)
	{
		next if !defined($pid) || $pid <= 0;
		kill('TERM', -$pid);
	}

	send_stopping_state('Leállítás folyamatban...');

	poll_pipeline_stop();

	return 1;
}

sub terminate_process_group
{
	my ($pid, $grace_seconds) = @_;

	return if !defined($pid) || $pid <= 0;

	$grace_seconds = 2.0
		if !defined($grace_seconds) || $grace_seconds < 0;

	kill('TERM', -$pid);

	my $deadline = time() + $grace_seconds;

	while (time() < $deadline)
	{
		reap_process_leader($pid);
		return if !process_group_is_alive($pid);
		sleep(0.05);
	}

	kill('KILL', -$pid);

	$deadline = time() + 1.0;

	while (time() < $deadline)
	{
		reap_process_leader($pid);
		return if !process_group_is_alive($pid);
		sleep(0.05);
	}

	return;
}

sub finish_pipeline
{
	my (%option) = @_;

	return if $mode eq 'idle' && !$processor_pid && !$recorder_pid
		&& !defined($processor_out);

	begin_pipeline_stop(
		message => $option{message}
	);

	return;
}

sub start_processor
{
	my ($command, $generation) = @_;

	die "Belső hiba: elavult feldolgozási munkamenet.\n"
		if $generation != $pipeline_generation;

	my $processor_input;

	(
		$processor_pid,
		$processor_out,
		$processor_input
	) = spawn_posix_command('(' . $command . ')');

	close($processor_input);

	nonblock($processor_out);
	$selector->add($processor_out);
	$buffers{fileno($processor_out)} = '';

	$mode = $mode eq 'starting' ? 'running' : $mode;

	log_gui('json', "$description\nPARANCS: $command\n\n");

	send_gui(
		{
			type        => 'running_state',
			running     => 1,
			description => $description
		});

	return;
}

sub normalize_input_file_path
{
	my ($path) = @_;

	die "A bemeneti fájl útvonala hiányzik.\n"
		if !defined($path) || $path eq '';

	die "A bemeneti fájl útvonala érvénytelen.\n"
		if $path =~ /[\0\r\n]/;

	my $absolute_path = File::Spec->file_name_is_absolute($path)
		? File::Spec->canonpath($path)
		: File::Spec->rel2abs($path, $Bin);

	die "A bemeneti fájl nem található: $absolute_path\n"
		if !-f $absolute_path;

	die "A bemeneti fájl nem olvasható: $absolute_path\n"
		if !-r $absolute_path;

	return $absolute_path;
}

sub start_session
{
	my ($kind, $path) = @_;

	if ($mode ne 'idle' || $processor_pid || $recorder_pid
		|| defined($processor_out))
	{
		log_gui('prc',
			"Indítás elutasítva: egy feldolgozási munkamenet már fut vagy leállóban van.\n");
		return 0;
	}

	$path = normalize_input_file_path($path)
		if $kind ne 'record';

	validate();
	reset_stats();

	$pipeline_generation++;
	my $generation = $pipeline_generation;
	$mode = 'starting';

	my $ok = eval
	{
		if ($kind eq 'record')
		{
			my $base = 'rs41_' . strftime('%Y-%m-%d_%H-%M-%S', localtime());

			my $wav_log_enabled =
				cfg_boolean('WAV_LOG_ENABLED', 1);

			$current_file = $wav_log_enabled
				? File::Spec->catfile(
					$settings{work_dir},
					$base . '.wav'
				)
				: undef;

			$current_rlog = File::Spec->catfile(
				$settings{work_dir},
				$base . '.Rlog'
			);

			$current_jlog = File::Spec->catfile(
				$settings{work_dir},
				$base . '.Jlog'
			);

			$description = $wav_log_enabled
				? "Felvétel: $current_file"
				: 'Felvétel: WAV napló kikapcsolva';

			my $record_command =
				record_monitor_command($current_file);

			$recorder_pid = fork();
			die "A felvételi folyamat nem indítható: $!\n"
				if !defined($recorder_pid);

			if ($recorder_pid == 0)
			{
				POSIX::setsid();
				exec('sh', '-c', $record_command) or POSIX::_exit(127);
			}

			my $processor_command = pipeline_command(
				'record',
				wav_file  => $current_file,
				rlog_file => $current_rlog,
				jlog_file => $current_jlog
			);

			start_processor($processor_command, $generation);
		}
		elsif ($kind eq 'wav')
		{
			$description = "Lejátszás: $path";
			start_processor(
				pipeline_command(
					'wav',
					input_file => $path
				),
				$generation
			);
		}
		elsif ($kind eq 'raw')
		{
			$description = "RAW feldolgozás: $path";
			start_processor(
				pipeline_command(
					'raw',
					input_file => $path
				),
				$generation
			);
		}
		else
		{
			$description = "JSON beolvasás: $path";
			start_processor(
				pipeline_command(
					'json',
					input_file => $path
				),
				$generation
			);
		}

		1;
	};

	if (!$ok)
	{
		my $error = $@ || 'ismeretlen indítási hiba';
		finish_pipeline(terminate => 1);
		die $error;
	}

	$current_session_kind = $kind;
	$current_session_path = $kind eq 'record' ? undef : $path;

	return 1;
}

sub stop_pipeline
{
	return if $mode eq 'idle' && !$processor_pid && !$recorder_pid
		&& !defined($processor_out);

	if ($mode eq 'stopping')
	{
		force_pipeline_stop();
		return;
	}

	finish_pipeline(
		terminate => 1,
		message   => 'A feldolgozási folyamatok szabályosan leálltak.'
	);

	return;
}

sub service_title
{
	my ($service) = @_;

	return $service eq 'bt'
		? 'Bluetooth GPS Bridge'
		: 'SondeHub feltöltő';
}

sub service_worker
{
	my ($service) = @_;

	return $service eq 'bt' ? $bt_bridge : $sondehub;
}

sub service_state_message
{
	my ($service, $active) = @_;

	send_gui(
		{
			type   => $service eq 'bt' ? 'bt_state' : 'sondehub_state',
			active => $active ? 1 : 0
		});

	return;
}

sub close_service_handle
{
	my ($handle) = @_;
	return if !defined($handle);
	$selector->remove($handle);
	my $id = fileno($handle);
	delete($buffers{$id}) if defined($id);
	close($handle);
	return;
}

sub valid_pipeconnect_id
{
	my ($id) = @_;

	return 0 if !defined($id) || $id eq '';
	return 0 if $id =~ /[\0\r\n]/;
	return 0 if length($id) > 240;

	return 1;
}

sub open_pipeconnect_reader
{
	my ($service) = @_;

	die "A pipeConnect.pl nem található vagy nem futtatható: $pipe_connect\n"
		if !-x $pipe_connect;

	my ($reader_output, $reader_input);
	my $reader_pid = open2(
		$reader_output,
		$reader_input,
		$^X,
		$pipe_connect,
		'-R'
	);

	close($reader_input);

	my $id_line = <$reader_output>;

	if (!defined($id_line))
	{
		terminate_process($reader_pid, 0.5);
		die service_title($service)
			. ": a pipeConnect -R nem adott ID-t.\n";
	}

	$id_line =~ s/[\r\n]+\z//;

	if (!valid_pipeconnect_id($id_line))
	{
		terminate_process($reader_pid, 0.5);
		die service_title($service)
			. ": érvénytelen pipeConnect fogadó ID.\n";
	}

	nonblock($reader_output);
	$selector->add($reader_output);
	$buffers{fileno($reader_output)} = '';

	return ($reader_pid, $reader_output, $id_line);
}

sub open_pipeconnect_writer
{
	my ($service, $receive_id) = @_;

	die service_title($service) . ": érvénytelen UI fogadó ID.\n"
		if !valid_pipeconnect_id($receive_id);

	my ($writer_output, $writer_input);
	my $writer_pid = open2(
		$writer_output,
		$writer_input,
		$^X,
		$pipe_connect,
		'-W',
		$receive_id
	);

	close($writer_output);
	$writer_input->autoflush(1);
	nonblock($writer_input);

	return ($writer_pid, $writer_input);
}

sub flush_service_worker_input
{
	my ($service) = @_;
	my $state = $service_pipe{$service};

	return if ref($state) ne 'HASH';
	return if !$state->{worker_input};
	return if ($state->{to_worker} // '') eq '';

	while (length($state->{to_worker}))
	{
		my $written = syswrite(
			$state->{worker_input},
			$state->{to_worker}
		);

		if (defined($written) && $written > 0)
		{
			substr($state->{to_worker}, 0, $written, '');
			next;
		}

		last if !defined($written)
			&& ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR);

		if ($state->{restarting})
		{
			$state->{to_worker} = '';
			last;
		}

		stop_service_pipe($service);
		last;
	}

	return;
}

sub queue_service_worker_input
{
	my ($service, $data) = @_;
	my $state = $service_pipe{$service};

	return 0 if ref($state) ne 'HASH';
	return 0 if !$state->{worker_input};

	$state->{to_worker} .= $data // '';
	flush_service_worker_input($service);

	return 1;
}

sub flush_service_ui_output
{
	my ($service) = @_;
	my $state = $service_pipe{$service};

	return if ref($state) ne 'HASH';
	return if !$state->{ui_writer_input};
	return if ($state->{to_ui} // '') eq '';

	while (length($state->{to_ui}))
	{
		my $written = syswrite(
			$state->{ui_writer_input},
			$state->{to_ui}
		);

		if (defined($written) && $written > 0)
		{
			substr($state->{to_ui}, 0, $written, '');
			next;
		}

		last if !defined($written)
			&& ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR);

		stop_service_pipe($service);
		last;
	}

	return;
}

sub queue_service_ui_output
{
	my ($service, $data) = @_;
	my $state = $service_pipe{$service};

	return 0 if ref($state) ne 'HASH';
	return 0 if !$state->{ui_writer_input};

	$state->{to_ui} .= $data // '';
	flush_service_ui_output($service);

	return 1;
}

sub stop_service_worker
{
	my ($service) = @_;
	my $state = $service_pipe{$service};

	return 0 if ref($state) ne 'HASH';

	$state->{restarting} = 1;
	$state->{ready} = 0;

	# Csak a worker stdout-ja kerül ki az IO::Select-ből.
	# A MAIN pipeConnect -R fogadója és a UI felé vezető
	# pipeConnect -W írója változatlanul megmarad.
	if ($state->{worker_output})
	{
		close_service_handle($state->{worker_output});
		$state->{worker_output} = undef;
	}

	if ($state->{worker_input})
	{
		close($state->{worker_input});
		$state->{worker_input} = undef;
	}

	if ($state->{worker_pid})
	{
		terminate_process_group($state->{worker_pid}, 2.0);
		$state->{worker_pid} = undef;
	}

	$state->{worker_line_buffer} = '';

	# A régi workernek szánt, de még ki nem írt adatot nem szabad az új
	# konfigurációval induló workernek átadni.
	$state->{to_worker} = '';

	# A UI felé már várakozó kimenetet viszont megtartjuk, mert az a tartós
	# MAIN -> UI pipeConnect csatornához tartozik.
	flush_service_ui_output($service);

	return 1;
}

sub restart_service_worker
{
	my ($service) = @_;
	my $state = $service_pipe{$service};

	return 0 if ref($state) ne 'HASH';
	return 0 if !$state->{channels_ready};

	terminal_message(
		'INFO',
		service_title($service)
		. ' worker újraindítása; a pipeConnect csatornák megmaradnak.'
	);

	stop_service_worker($service);

	# A stop_service_worker nem törölte a service state-et, a fogadó és író
	# pipeConnect folyamatokat, valamint az UI kapcsolatot.
	start_service_worker($service);

	$state = $service_pipe{$service};

	if (
		ref($state) eq 'HASH'
		&& $state->{ready}
	)
	{
		$state->{restarting} = 0;

		terminal_message(
			'INFO',
			service_title($service)
			. ' workere sikeresen újraindult ugyanabban a csatornában.'
		);

		return 1;
	}

	if (ref($state) eq 'HASH')
	{
		$state->{restarting} = 0;
	}

	log_gui(
		'prc',
		service_title($service)
		. ": a worker újraindítása sikertelen.\n"
	);

	return 0;
}

sub start_service_worker
{
	my ($service) = @_;
	my $state = $service_pipe{$service};

	return if ref($state) ne 'HASH';
	return if $state->{worker_pid};
	return if !$state->{channels_ready};

	my $worker = service_worker($service);

	if (!-f $worker)
	{
		log_gui(
			'prc',
			service_title($service)
			. ": a worker nem található: $worker\n"
		);
		stop_service_pipe($service);
		return;
	}

	my ($pid, $worker_output, $worker_input);
	my $worker_command;

	my $ok = eval
	{
		$worker_command = service_worker_command($service);

		(
			$pid,
			$worker_output,
			$worker_input
		) = spawn_posix_command($worker_command);

		1;
	};

	if (!$ok)
	{
		log_gui(
			'prc',
			service_title($service)
			. ': a worker nem indítható: '
			. ($@ || $!)
			. "\n"
		);
		stop_service_pipe($service);
		return;
	}

	nonblock($worker_input);
	nonblock($worker_output);
	$selector->add($worker_output);
	$buffers{fileno($worker_output)} = '';

	$state->{worker_pid} = $pid;
	$state->{worker_input} = $worker_input;
	$state->{worker_output} = $worker_output;
	$state->{worker_line_buffer} = '';
	$state->{ready} = 1;

	service_state_message($service, 1);

	terminal_message(
		'INFO',
		service_title($service)
		. ' POSIX pipe workere elindult a pipeConnect csatornában.'
	);

	log_gui(
		'prc',
		service_title($service)
		. " worker parancs: $worker_command\n"
	);

	send_sondehub_base() if $service eq 'sondehub';

	return;
}

sub start_service_pipe
{
	my ($service, $ui_receive_id) = @_;

	return if ref($service_pipe{$service}) eq 'HASH';

	if (!valid_pipeconnect_id($ui_receive_id))
	{
		log_gui(
			'prc',
			service_title($service)
			. ": hiányzó vagy érvénytelen UI fogadó ID.\n"
		);
		service_state_message($service, 0);
		return;
	}

	my (
		$main_reader_pid,
		$main_reader_output,
		$main_receive_id,
		$ui_writer_pid,
		$ui_writer_input
	);

	my $ok = eval
	{
		(
			$main_reader_pid,
			$main_reader_output,
			$main_receive_id
		) = open_pipeconnect_reader($service);

		(
			$ui_writer_pid,
			$ui_writer_input
		) = open_pipeconnect_writer($service, $ui_receive_id);

		1;
	};

	if (!$ok)
	{
		my $error = $@ || 'ismeretlen pipeConnect indítási hiba';

		close_service_handle($main_reader_output)
			if $main_reader_output;

		close($ui_writer_input)
			if $ui_writer_input;

		terminate_process($main_reader_pid, 0.5)
			if $main_reader_pid;

		terminate_process($ui_writer_pid, 0.5)
			if $ui_writer_pid;

		log_gui(
			'prc',
			service_title($service)
			. ": $error"
		);

		service_state_message($service, 0);
		return;
	}

	$service_pipe{$service} =
	{
		ui_receive_id      => $ui_receive_id,
		main_receive_id    => $main_receive_id,
		main_reader_pid    => $main_reader_pid,
		main_reader_output => $main_reader_output,
		ui_writer_pid      => $ui_writer_pid,
		ui_writer_input    => $ui_writer_input,
		channels_ready     => 1,
		worker_pid         => undef,
		worker_input       => undef,
		worker_output      => undef,
		worker_line_buffer => '',
		to_worker          => '',
		to_ui              => '',
		restarting         => 0,
		ready              => 0
	};

	start_service_worker($service);

	if (
		ref($service_pipe{$service}) eq 'HASH'
		&& $service_pipe{$service}{ready}
	)
	{
		send_gui(
			{
				type       => 'service_opened',
				service    => $service,
				receive_id => $main_receive_id,
				title      => service_title($service)
			}
		);
	}

	return;
}

sub stop_service_pipe
{
	my ($service) = @_;
	my $state = delete($service_pipe{$service});

	if (ref($state) eq 'HASH')
	{
		close_service_handle($state->{worker_output})
			if $state->{worker_output};

		close($state->{worker_input})
			if $state->{worker_input};

		terminate_process_group($state->{worker_pid}, 2.0)
			if $state->{worker_pid};

		close_service_handle($state->{main_reader_output})
			if $state->{main_reader_output};

		close($state->{ui_writer_input})
			if $state->{ui_writer_input};

		terminate_process($state->{main_reader_pid}, 0.5)
			if $state->{main_reader_pid};

		terminate_process($state->{ui_writer_pid}, 0.5)
			if $state->{ui_writer_pid};
	}

	service_state_message($service, 0);

	return;
}

sub start_bt
{
	my ($ui_receive_id) = @_;
	start_service_pipe('bt', $ui_receive_id);
	return;
}

sub stop_bt
{
	stop_service_pipe('bt');
	return;
}

sub start_sondehub
{
	my ($ui_receive_id) = @_;
	start_service_pipe('sondehub', $ui_receive_id);
	return;
}

sub stop_sondehub
{
	stop_service_pipe('sondehub');
	return;
}

sub read_service_ui
{
	my ($service) = @_;
	my $state = $service_pipe{$service};

	return if ref($state) ne 'HASH';
	return if !$state->{main_reader_output};

	my $chunk = '';
	my $count = sysread(
		$state->{main_reader_output},
		$chunk,
		65536
	);

	if (defined($count) && $count > 0)
	{
		queue_service_worker_input($service, $chunk);
		return;
	}

	if (defined($count) && $count == 0)
	{
		stop_service_pipe($service);
		return;
	}

	return if !defined($count)
		&& ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR);

	stop_service_pipe($service);
	return;
}

sub process_service_worker_line
{
	my ($service, $line) = @_;
	$line =~ s/[\r\n]+\z//;

	if ($service eq 'bt')
	{
		my $data = eval { $json->decode($line) };
		if (ref($data) eq 'HASH')
		{
			my $angle = defined($data->{heading_true})
				? $data->{heading_true}
				: defined($data->{heading_mag}) ? $data->{heading_mag} : $data->{course};
			if (defined($data->{lat}) && defined($data->{lon})
				&& defined($data->{alt}) && defined($angle))
			{
				$settings{base} =
				{
					latitude  => 0 + $data->{lat},
					longitude => 0 + $data->{lon},
					altitude  => 0 + $data->{alt},
					angle     => 0 + $angle
				};
				send_gui({type => 'base_position_update', base => $settings{base}});
				send_calc();
				send_sondehub_base() if ref($service_pipe{sondehub}) eq 'HASH';
			}
		}
	}
	return;
}

sub read_service_worker
{
	my ($service) = @_;
	my $state = $service_pipe{$service};
	return if ref($state) ne 'HASH' || !$state->{worker_output};

	my $chunk = '';
	my $count = sysread($state->{worker_output}, $chunk, 65536);
	if (defined($count) && $count > 0)
	{
		queue_service_ui_output($service, $chunk);
		$state->{worker_line_buffer} .= $chunk;
		while ($state->{worker_line_buffer} =~ s/^(.*?\n)//s)
		{
			process_service_worker_line($service, decode_utf8($1));
		}
		return;
	}
	if (defined($count) && $count == 0)
	{
		if ($state->{restarting})
		{
			close_service_handle($state->{worker_output})
				if $state->{worker_output};

			$state->{worker_output} = undef;
			return;
		}

		stop_service_pipe($service);
	}
	return;
}

sub send_sondehub_base
{
	return unless ref($service_pipe{sondehub}) eq 'HASH';
	return unless $service_pipe{sondehub}{ready};
	return unless $settings{share};

	my %payload =
	(
		message_type => 'base',
		lat          => 0 + $settings{base}{latitude},
		lon          => 0 + $settings{base}{longitude},
		alt          => 0 + $settings{base}{altitude},
		mobile       => $settings{mobile} ? JSON::PP::true : JSON::PP::false,
		share        => JSON::PP::true
	);

	queue_service_worker_input('sondehub', $json->encode(\%payload) . "\n");
	return;
}

sub send_sondehub
{
	my ($data) = @_;

	return unless ref($service_pipe{sondehub}) eq 'HASH';
	return unless $service_pipe{sondehub}{ready};

	# A $mode a pipeline életciklusát jelzi. Az élő feldolgozás
	# típusát a current_session_kind tartalmazza.
	return unless defined($current_session_kind)
		&& $current_session_kind eq 'record';
	return unless ($data->{validity} // '') eq 'VALID';

	# Telemetria csak mind az 51 RS41 kalibrációs részkeret
	# összegyűjtése után küldhető.
	my $calibration = $data->{calibration};

	return unless ref($calibration) eq 'HASH';
	return unless $calibration->{complete};
	return unless defined($calibration->{seen_count})
		&& $calibration->{seen_count} >= 51;

	my $position = $data->{position};

	my $ptu = $data->{ptu};

	return unless ref($position) eq 'HASH';
	return unless ref($ptu) eq 'HASH';

	my %payload = (message_type => 'sonde',

		serial => $data->{sonde_id},

		frame => $data->{frame_number},

		datetime => $data->{gps_time}{utc_uncorrected},

		lat => $position->{latitude_deg},

		lon => $position->{longitude_deg},

		alt => $position->{altitude_m},

		frequency => 0 + $settings{frequency},

		temp => $ptu->{temperature_c},

		humidity => $ptu->{relative_humidity_pct},

		pressure => $ptu->{pressure_hpa},

		vel_h => $position->{velocity_h_ms},

		vel_v => $position->{velocity_v_ms},

		heading => $position->{heading_deg},

		sats => $position->{satellites},

		batt => $data->{battery_v},

		share => $settings{share} ? JSON::PP::true : JSON::PP::false,

		mobile => $settings{mobile} ? JSON::PP::true : JSON::PP::false
	);

	if ($settings{share})
	{
		$payload{uploader_position} =
		[
			0 + $settings{base}{latitude},
			0 + $settings{base}{longitude},
			0 + $settings{base}{altitude}
		];
	}

	queue_service_worker_input('sondehub', $json->encode(\%payload) . "\n");

	return;
}

sub handle_gui
{
	my ($message) = @_;

	my $type = $message->{type} // '';

	if ($type eq 'frontend_ready' || $type eq 'gui_ready' || $type eq 'tui_ready')
	{
		send_gui(
			{
				type        => 'initialize', settings    => \%settings,
				html_config => \%html_config
			});
	}
	elsif ($type eq 'settings_apply_requested')
	{
		my $incoming = $message->{settings};
		my $sondehub_mode_changed = 0;

		if (ref($incoming) eq 'HASH')
		{
			$sondehub_mode_changed = 1
				if exists($incoming->{share})
				&& (($incoming->{share} ? 1 : 0)
					!= ($settings{share} ? 1 : 0));

			$sondehub_mode_changed = 1
				if exists($incoming->{mobile})
				&& (($incoming->{mobile} ? 1 : 0)
					!= ($settings{mobile} ? 1 : 0));
		}

		update_applied_settings($incoming);

		if (
			$sondehub_mode_changed
			&& ref($service_pipe{sondehub}) eq 'HASH'
			&& $service_pipe{sondehub}{ready}
		)
		{
			restart_service_worker('sondehub');
		}

		send_calc();
		send_sondehub_base()
			if ref($service_pipe{sondehub}) eq 'HASH';
		send_settings_state();
	}
	elsif (
		$type eq 'settings_save_requested'
		|| $type eq 'settings_changed'
		|| $type eq 'processing_settings_changed'
	)
	{
		my $restart = processing_session_is_running();
		my $incoming = $message->{settings};
		my $sondehub_mode_changed = 0;

		if (ref($incoming) eq 'HASH')
		{
			$sondehub_mode_changed = 1
				if exists($incoming->{share})
				&& (($incoming->{share} ? 1 : 0)
					!= ($settings{share} ? 1 : 0));

			$sondehub_mode_changed = 1
				if exists($incoming->{mobile})
				&& (($incoming->{mobile} ? 1 : 0)
					!= ($settings{mobile} ? 1 : 0));
		}

		update_settings($incoming);

		if (
			$sondehub_mode_changed
			&& ref($service_pipe{sondehub}) eq 'HASH'
			&& $service_pipe{sondehub}{ready}
		)
		{
			restart_service_worker('sondehub');
		}

		if ($restart)
		{
			eval
			{
				restart_current_session();
				1;
			}
				or do
				{
					my $error =
						$@ || 'ismeretlen pipeline-újraindítási hiba';

					log_gui(
						'prc',
						"HIBA: a feldolgozás újraindítása sikertelen: "
						. $error
					);
				};
		}

		send_calc();
		send_sondehub_base()
			if ref($service_pipe{sondehub}) eq 'HASH';
		send_settings_state();
	}
	elsif ($type eq 'start_recording_requested')
	{
		update_settings($message->{settings});

		eval
		{
			start_session('record');
		};

		if ($@)
		{
			log_gui('prc', "HIBA: $@");
		}
	}
	elsif ($type eq 'play_wav_requested')
	{
		update_settings($message->{settings});

		eval
		{
			start_session('wav', $message->{path});
		};

		if ($@)
		{
			log_gui('prc', "HIBA: $@");
		}
	}
	elsif ($type eq 'play_raw_requested')
	{
		update_settings($message->{settings});

		eval
		{
			start_session('raw', $message->{path});
		};

		if ($@)
		{
			log_gui('prc', "HIBA: $@");
		}
	}
	elsif ($type eq 'play_json_requested')
	{
		update_settings($message->{settings});

		eval
		{
			start_session('json', $message->{path});
		};

		if ($@)
		{
			log_gui('prc', "HIBA: $@");
		}
	}
	elsif ($type eq 'stop_requested')
	{
		stop_pipeline();
	}
	elsif ($type eq 'bt_start_requested')
	{
		start_bt($message->{receive_id});
	}
	elsif ($type eq 'bt_stop_requested')
	{
		stop_bt();
	}
	elsif ($type eq 'sondehub_start_requested')
	{
		update_settings($message->{settings});

		start_sondehub($message->{receive_id});
	}
	elsif ($type eq 'sondehub_stop_requested')
	{
		stop_sondehub();
	}
	elsif ($type eq 'window_close_requested')
	{
		terminal_message('INFO', 'A frontend bezárást kért.');

		shutdown_all();
	}

	return;
}

sub lines_from
{
	my ($handle, $kind) = @_;

	my $id = fileno($handle);

	my $chunk = '';

	my $read_count = sysread($handle, $chunk, 65536);

	if (defined($read_count)
		&& $read_count > 0)
	{
		$buffers{$id} .= $chunk;

		while ($buffers{$id} =~ s/^(.*?\n)//s)
		{
			my $raw_line = $1;
			my $line = decode_utf8($raw_line);

			$line =~ s/[\r\n]+$//;

			if ($kind eq 'frontend')
			{
				my $message = decode_json_line($raw_line);

				if (ref($message) eq 'HASH')
				{
					handle_gui($message);
				}
			}
			elsif ($kind eq 'processor')
			{
				log_gui('json', $line . "\n");

				my $data = eval { $json->decode($line) };

				if (ref($data) eq 'HASH' && ($data->{type} // '') eq 'RS41')
				{
					log_gui('prc', format_prc($data));
					process_data($data);
				}
			}
		}

		return;
	}

	if (defined($read_count) && $read_count == 0)
	{
		$selector->remove($handle);

		close($handle);

		if ($kind eq 'processor')
		{
			# Csak az aktuÃ¡lis processor handle kerÃ¼lhet ide. A handle-t mÃ¡r
			# eltÃ¡volÃ­tottuk a selectorbÃ³l Ã©s bezÃ¡rtuk, ezÃ©rt a globÃ¡lis
			# hivatkozÃ¡st is megszÃ¼ntetjÃ¼k, majd az esetleges kÃ¼lÃ¶n recorder
			# folyamatot is leÃ¡llÃ­tjuk.
			undef($processor_out);
			finish_pipeline(
				terminate => 0,
				message   => 'A feldolgozÃ¡si munkamenet befejezÅdÃ¶tt.'
			);
		}
		elsif ($kind eq 'frontend')
		{
			$running = 0;
		}
	}

	return;
}

sub shutdown_all
{
	$shutdown_requested = 1;

	stop_pipeline();
	stop_bt();
	stop_sondehub();

	if ($mode eq 'idle')
	{
		send_gui(
			{
				type => 'shutdown'
			}
		);

		$running = 0;
	}

	return;
}

$SIG{INT} = sub
	{
		shutdown_all();
	};

$SIG{TERM} = sub
	{
		shutdown_all();
	};

nonblock(\*STDIN);

$selector->add(\*STDIN);

$buffers{fileno(STDIN)} = '';

terminal_message(
	'INFO',
	'A főfolyamat elindult (v0.2.46), várakozás a frontend kapcsolatra.');

while ($running)
{
	for my $handle ($selector->can_read(0.25)
)
	{
		if (fileno($handle)
			== fileno(STDIN))
		{
			lines_from($handle, 'frontend');
		}
		elsif (defined($processor_out)
			&& $handle == $processor_out)
		{
			lines_from($handle, 'processor');
		}
		else
		{
			my $handled = 0;
			for my $service (qw(bt sondehub))
			{
				my $state = $service_pipe{$service};
				next if ref($state) ne 'HASH';
				if (
					$state->{main_reader_output}
					&& $handle == $state->{main_reader_output}
				)
				{
					read_service_ui($service);
					$handled = 1;
					last;
				}
				if ($state->{worker_output} && $handle == $state->{worker_output})
				{
					read_service_worker($service);
					$handled = 1;
					last;
				}
			}
		}
	}

	poll_pipeline_stop();

	if ($shutdown_requested && $mode eq 'idle')
	{
		send_gui(
			{
				type => 'shutdown'
			}
		);

		$running = 0;
		next;
	}

	if ($mode ne 'idle')
	{
		send_stats();
	}

	for my $service (qw(bt sondehub))
	{
		flush_service_worker_input($service);
		flush_service_ui_output($service);
		my $state = $service_pipe{$service};
		if (ref($state) eq 'HASH' && $state->{worker_pid}
			&& waitpid($state->{worker_pid}, WNOHANG) == $state->{worker_pid})
		{
			stop_service_pipe($service);
		}
	}

	if ($mode ne 'stopping'
		&& $processor_pid
		&& waitpid($processor_pid, WNOHANG) == $processor_pid)
	{
		finish_pipeline(
			terminate => 0,
			message   => 'A feldolgozÃ¡si munkamenet folyamata kilÃ©pett.'
		);
	}

	if ($mode ne 'stopping'
		&& $recorder_pid
		&& waitpid($recorder_pid, WNOHANG) == $recorder_pid)
	{
		$recorder_pid = undef;
	}

}

terminal_message('INFO', 'A főfolyamat leáll.');

exit(0);
