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
		print "rs41_tui.pl $VERSION\n";
		exit 0;
	}
}

use Curses;
use POSIX qw(setlocale LC_ALL WNOHANG);
use FindBin qw($Bin);
use lib $Bin;
use File::Spec;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Handle;
use IO::Select;
use IPC::Open2;
use Time::HiRes qw(time sleep);
use RS41IPC qw(
	json_codec
	send_json_message
	extract_json_messages
	is_frontend_event_request
);
use RS41FrontendData qw(new_frontend_state reset_frontend_state apply_receiver_update apply_runtime_statistics apply_calculated_fields packet_ratio_text frontend_table_values);

setlocale(LC_ALL, '');

binmode(STDERR, ':encoding(UTF-8)');
STDERR->autoflush(1);

my $MIN_WIDTH  = 132;
my $MIN_HEIGHT = 45;

my $running = 1;
my $selected_menu = 0;
my $last_message = 'A TUI elindult.';
my $operation_status = 'Áll';
my $operation_failure = '';
my @diagnostics;
my $frontend_state = new_frontend_state();
# A két mező külön, közvetlen TUI-állapota. Ezeket kizárólag ténylegesen
# megkapott érték írhatja felül; PARTIAL/INVALID null mező nem törli.
my $display_frame_number;
my $display_satellites;

my %service_ui =
(
	bt =>
	{
		desired       => 0,
		pending       => 0,
		connected     => 0,
		dialog_visible => 0,
		request_time  => 0,
		endpoint      => '',
		token        => '',
		reader_pid    => undef,
		writer_pid    => undef,
		input         => undef,
		output        => undef,
		error         => undef,
		output_buffer => '',
		error_buffer  => '',
		lines         => [],
		status        => ''
	},
	sondehub =>
	{
		desired       => 0,
		pending       => 0,
		connected     => 0,
		dialog_visible => 0,
		request_time  => 0,
		endpoint      => '',
		token        => '',
		reader_pid    => undef,
		writer_pid    => undef,
		input         => undef,
		output        => undef,
		error         => undef,
		output_buffer => '',
		error_buffer  => '',
		lines         => [],
		status        => ''
	}
);

my $service_dialog;
my $SERVICE_START_TIMEOUT = 10.0;
my $main_input;
my $main_output;
my $main_buffer = '';
my $json = json_codec();
my $pipe_connect = File::Spec->catfile($Bin, 'pipeConnect.pl');

my %config_defaults =
(
	BASE_LAT               => '47.49786',
	BASE_LON               => '19.04022',
	BASE_ALT               => '110',
	BASE_ANGLE             => '0',
	SONDEHUB_FREQUENCY_MHZ => '403.700',
	SONDEHUB_SHARE         => '0',
	SONDEHUB_MOBIL         => '0',
	AUDIO_DEVICE           => 'default',
	AUDIO_SAMPLE_RATE      => '48000',
	AUDIO_LF               => '525',
	AUDIO_HF               => '14000',
	AUDIO_ORDER            => '1',
	AUDIO_PEAK             => '0.75',
	AUDIO_DELAY            => '0.1',
	AUDIO_INVERT           => '1',
	LOG_DIRECTORY          => './log'
);

my %config = %config_defaults;
my %settings_draft = %config_defaults;
my $settings_state_pending = 0;
my $force_full_redraw = 0;

sub request_full_redraw
{
	$force_full_redraw = 1;
	return;
}

sub config_boolean_value
{
	my ($name, $source) = @_;
	$source = \%config if ref($source) ne 'HASH';

	my $value = $source->{$name};

	return 1 if defined($value)
		&& $value =~ /^(?:1|true|yes|on|igen|be)$/i;

	return 0;
}

sub config_toggle_text
{
	my ($name, $source) = @_;

	return config_boolean_value($name, $source) ? '[#]' : '[_]';
}

my $ui_mode = 'MAIN';
my $selected_setting = 0;
my $settings_scroll = 0;
my $settings_editing = 0;
my $settings_edit_buffer = '';
my $settings_edit_cursor = 0;

my $file_dialog_kind;
my @file_dialog_files;
my $file_dialog_selected = 0;
my $file_dialog_scroll = 0;
my $file_dialog_error = '';

my @mouse_regions;
my $mouse_enabled = 0;

my @settings_items =
(
	{
		label      => 'Bázis / Szélesség',
		config_key => 'BASE_LAT',
		type       => 'number'
	},
	{
		label      => 'Bázis / Hosszúság',
		config_key => 'BASE_LON',
		type       => 'number'
	},
	{
		label      => 'Bázis / Magasság',
		config_key => 'BASE_ALT',
		type       => 'number'
	},
	{
		label      => 'Bázis / Szög',
		config_key => 'BASE_ANGLE',
		type       => 'number'
	},
	{
		label      => 'Vétel / Frekvencia MHz',
		config_key => 'SONDEHUB_FREQUENCY_MHZ',
		type       => 'number'
	},
	{
		label      => 'SondeHub / Pozíció megosztása',
		config_key => 'SONDEHUB_SHARE',
		type       => 'boolean'
	},
	{
		label      => 'SondeHub / Mobil bázis',
		config_key => 'SONDEHUB_MOBIL',
		type       => 'boolean'
	},
	{
		label      => 'Audio / Eszköz',
		config_key => 'AUDIO_DEVICE',
		type       => 'string'
	},
	{
		label      => 'Audio / Hz',
		config_key => 'AUDIO_SAMPLE_RATE',
		type       => 'number'
	},
	{
		label      => 'Szűrő / LF',
		config_key => 'AUDIO_LF',
		type       => 'number'
	},
	{
		label      => 'Szűrő / HF',
		config_key => 'AUDIO_HF',
		type       => 'number'
	},
	{
		label      => 'Szűrő / O',
		config_key => 'AUDIO_ORDER',
		type       => 'number'
	},
	{
		label      => 'Szűrő / P',
		config_key => 'AUDIO_PEAK',
		type       => 'number'
	},
	{
		label      => 'Szűrő / D',
		config_key => 'AUDIO_DELAY',
		type       => 'number'
	},
	{
		label      => 'Szűrő / Inverz',
		config_key => 'AUDIO_INVERT',
		type       => 'boolean'
	},
	{
		label      => 'Rendszer / LOG mappa',
		config_key => 'LOG_DIRECTORY',
		type       => 'directory'
	}
);

my @menu_items =
(
	{
		key    => '1',
		label  => 'FELV',
		group  => 'run',
		active => 0
	},
	{
		key    => '2',
		label  => 'WAV',
		group  => 'run',
		active => 0
	},
	{
		key    => '3',
		label  => 'RAW',
		group  => 'run',
		active => 0
	},
	{
		key    => '4',
		label  => 'JSON',
		group  => 'run',
		active => 0
	},
	{
		key    => '5',
		label  => 'ÁLLJ',
		group  => 'run',
		active => 1
	},
	{
		key    => '6',
		label  => 'BT',
		group  => 'toggle',
		active => 0
	},
	{
		key    => '7',
		label  => 'SHUB',
		group  => 'toggle',
		active => 0
	},
	{
		key    => '8',
		label  => 'BEÁLL.',
		group  => 'action',
		active => 0
	},
	{
		key    => 'q',
		label  => 'KILÉP',
		group  => 'action',
		active => 0
	}
);

my @left_fields =
(
	'ÉRVÉNYESSÉG',
	'KERET',
	'SZONDA ID',
	'AKKUMULÁTOR',
	'SZÉLESSÉG',
	'HOSSZÚSÁG',
	'MAGASSÁG',
	'VÍZSZINTES SEB.',
	'IRÁNY',
	'FÜGGŐLEGES SEB.',
	'HŐMÉRSÉKLET',
	'PÁRASZENZOR HŐM.',
	'PÁRATARTALOM',
	'EMPIRIKUS RH'
);

my @right_fields =
(
	'GPS IDŐ',
	'UTOLSÓ SIKERES VÉTEL',
	'MEGTETT ÖSSZÚT',
	'MŰHOLDAK',
	'NYOMÁS',
	'BECSÜLT NYOMÁS',
	'CSÚCSMAGASSÁG',
	'KALIBRÁCIÓ',
	'KAL. KERETEK',
	'RAW T',
	'RAW H',
	'RAW TH',
	'RAW P',
	'CSÚCSMAGASSÁG IDEJE'
);

sub append_diagnostic
{
	my ($text) = @_;

	return if !defined($text);

	for my $line (split(/\r?\n/, $text))
	{
		push @diagnostics, $line;
	}

	shift @diagnostics while @diagnostics > 1000;

	return;
}

sub current_settings
{
	my ($source) = @_;
	$source = \%config if ref($source) ne 'HASH';

	return
	{
		work_dir   => $source->{LOG_DIRECTORY},
		device     => $source->{AUDIO_DEVICE},
		sample_rate => $source->{AUDIO_SAMPLE_RATE},
		lf         => $source->{AUDIO_LF},
		hf         => $source->{AUDIO_HF},
		order      => $source->{AUDIO_ORDER},
		peak       => $source->{AUDIO_PEAK},
		delay      => $source->{AUDIO_DELAY},
		invert     => config_boolean_value('AUDIO_INVERT', $source),
		frequency  => $source->{SONDEHUB_FREQUENCY_MHZ},
		share      => config_boolean_value('SONDEHUB_SHARE', $source),
		mobile     => config_boolean_value('SONDEHUB_MOBIL', $source),
		base       =>
		{
			latitude  => $source->{BASE_LAT},
			longitude => $source->{BASE_LON},
			altitude  => $source->{BASE_ALT},
			angle     => $source->{BASE_ANGLE}
		}
	};
}

sub send_main
{
	my ($message) = @_;

	return if !defined($main_output);

	send_json_message($main_output, $message);

	return;
}

sub display_work_directory
{
	my ($path) = @_;

	return './log'
		if !defined($path) || $path eq '';

	return $path
		if !File::Spec->file_name_is_absolute($path);

	my $relative = File::Spec->abs2rel($path, $Bin);

	return $path
		if $relative eq '..'
		|| $relative =~ m{^\.\.(?:/|\\)};

	return '.'
		if $relative eq '.';

	return './' . $relative;
}

sub apply_initialize
{
	my ($settings) = @_;

	return if ref($settings) ne 'HASH';

	$config{LOG_DIRECTORY} = display_work_directory($settings->{work_dir})
		if exists($settings->{work_dir});
	$config{AUDIO_DEVICE} = $settings->{device}
		if exists($settings->{device});
	$config{AUDIO_SAMPLE_RATE} = $settings->{sample_rate}
		if exists($settings->{sample_rate});
	$config{AUDIO_LF} = $settings->{lf}
		if exists($settings->{lf});
	$config{AUDIO_HF} = $settings->{hf}
		if exists($settings->{hf});
	$config{AUDIO_ORDER} = $settings->{order}
		if exists($settings->{order});
	$config{AUDIO_PEAK} = $settings->{peak}
		if exists($settings->{peak});
	$config{AUDIO_DELAY} = $settings->{delay}
		if exists($settings->{delay});
	$config{AUDIO_INVERT} = $settings->{invert} ? 1 : 0
		if exists($settings->{invert});
	$config{SONDEHUB_FREQUENCY_MHZ} = $settings->{frequency}
		if exists($settings->{frequency});
	$config{SONDEHUB_SHARE} = $settings->{share} ? 1 : 0
		if exists($settings->{share});
	$config{SONDEHUB_MOBIL} = $settings->{mobile} ? 1 : 0
		if exists($settings->{mobile});

	if (ref($settings->{base}) eq 'HASH')
	{
		$config{BASE_LAT} = $settings->{base}{latitude}
			if exists($settings->{base}{latitude});
		$config{BASE_LON} = $settings->{base}{longitude}
			if exists($settings->{base}{longitude});
		$config{BASE_ALT} = $settings->{base}{altitude}
			if exists($settings->{base}{altitude});
		$config{BASE_ANGLE} = $settings->{base}{angle}
			if exists($settings->{base}{angle});
	}

	if ($ui_mode ne 'SETTINGS')
	{
		%settings_draft = %config;
	}

	$settings_state_pending = 0;

	return;
}

sub apply_requested_setting
{
	my ($name, $value) = @_;

	return 0 if !defined($name) || $name eq '';

	my %aliases =
	(
		work_dir   => 'LOG_DIRECTORY',
		device     => 'AUDIO_DEVICE',
		sample_rate => 'AUDIO_SAMPLE_RATE',
		lf         => 'AUDIO_LF',
		hf         => 'AUDIO_HF',
		order      => 'AUDIO_ORDER',
		peak       => 'AUDIO_PEAK',
		delay      => 'AUDIO_DELAY',
		invert     => 'AUDIO_INVERT',
		frequency  => 'SONDEHUB_FREQUENCY_MHZ',
		share      => 'SONDEHUB_SHARE',
		mobile     => 'SONDEHUB_MOBIL',
		base_latitude  => 'BASE_LAT',
		base_longitude => 'BASE_LON',
		base_altitude  => 'BASE_ALT',
		base_angle     => 'BASE_ANGLE'
	);

	my $key = $aliases{$name} // $name;

	return 0 if !exists($config{$key});

	$config{$key} = $value;
	%settings_draft = %config;

	send_main(
		{
			type     => 'settings_save_requested',
			settings => current_settings(),
			source   => 'tui_launcher_setting'
		}
	);

	$settings_state_pending = 1;
	$last_message =
		"Beállítási esemény elküldve a mainnek: $key=$value";
	append_diagnostic($last_message);

	return 1;
}

sub file_kind_label
{
	my ($kind) = @_;

	return 'WAV' if ($kind // '') eq 'wav';
	return 'RAW' if ($kind // '') eq 'raw';
	return 'JSON' if ($kind // '') eq 'json';

	return 'FÁJL';
}

sub resolved_log_directory
{
	my $directory = $config{LOG_DIRECTORY} // './log';

	return File::Spec->file_name_is_absolute($directory)
		? File::Spec->canonpath($directory)
		: File::Spec->rel2abs($directory, $Bin);
}

sub file_matches_kind
{
	my ($kind, $name) = @_;

	return 0 if !defined($name);

	return $name =~ /\.wav\z/i
		if $kind eq 'wav';

	return $name =~ /\.(?:rlog|raw)\z/i
		if $kind eq 'raw';

	return $name =~ /\.(?:jlog|json)\z/i
		if $kind eq 'json';

	return 0;
}

sub load_file_dialog_files
{
	my ($kind) = @_;
	my $directory = resolved_log_directory();

	@file_dialog_files = ();
	$file_dialog_error = '';

	my $directory_handle;

	if (!opendir($directory_handle, $directory))
	{
		$file_dialog_error =
			'A LOG mappa nem nyitható meg: ' . $directory;
		$operation_failure = $file_dialog_error;
		$operation_status = 'Hiba: a LOG mappa nem nyitható meg';
		return 0;
	}

	while (my $name = readdir($directory_handle))
	{
		next if $name eq '.' || $name eq '..';
		next if !file_matches_kind($kind, $name);

		my $path = File::Spec->catfile($directory, $name);
		next if !-f $path;

		push(
			@file_dialog_files,
			{
				name => $name,
				path => $path
			}
		);
	}

	closedir($directory_handle);

	@file_dialog_files = sort
	{
		lc($a->{name}) cmp lc($b->{name})
			|| $a->{name} cmp $b->{name}
	}
	@file_dialog_files;

	if (!@file_dialog_files)
	{
		$file_dialog_error =
			'Nincs választható '
			. file_kind_label($kind)
			. ' fájl az aktuális LOG mappában.';
	}

	return 1;
}

sub open_file_dialog
{
	my ($kind) = @_;

	$file_dialog_kind = $kind;
	$file_dialog_selected = 0;
	$file_dialog_scroll = 0;

	load_file_dialog_files($kind);

	$last_message =
		file_kind_label($kind)
		. ' fájlválasztó megnyitva.';

	return;
}

sub close_file_dialog
{
	$file_dialog_kind = undef;
	@file_dialog_files = ();
	$file_dialog_selected = 0;
	$file_dialog_scroll = 0;
	$file_dialog_error = '';

	request_full_redraw();
	return;
}

sub detect_file_start_failure
{
	my ($text) = @_;

	return if !defined($text) || $text eq '';
	return if !defined($file_dialog_kind) && $operation_failure ne '';

	my @patterns =
	(
		qr/\bsox\s+FAIL\b/i,
		qr/\bNo such file or directory\b/i,
		qr/\bPermission denied\b/i,
		qr/\bcan't open\b/i,
		qr/\bcannot open\b/i,
		qr/\bfailed to open\b/i,
		qr/^cat:\s/im
	);

	for my $pattern (@patterns)
	{
		if ($text =~ /($pattern[^\r\n]*)/)
		{
			my $detail = $1;
			$detail =~ s/^\s+//;
			$detail =~ s/\s+$//;
			$detail = substr($detail, 0, 72)
				if length($detail) > 72;

			$operation_failure = $detail;
			$operation_status = 'Hiba: ' . $detail;
			$last_message = $operation_status;
			return;
		}
	}

	return;
}

sub normalize_selected_file_path
{
	my ($path) = @_;

	return if !defined($path) || $path eq '';
	return if $path =~ /[\0\r\n]/;

	my $absolute_path = File::Spec->file_name_is_absolute($path)
		? File::Spec->canonpath($path)
		: File::Spec->rel2abs($path, $Bin);

	return if !-f $absolute_path || !-r $absolute_path;

	return $absolute_path;
}

sub request_file_path
{
	my ($kind, $path, $source) = @_;

	$path = normalize_selected_file_path($path);

	my %definition =
	(
		wav  => {index => 1, type => 'play_wav_requested',  label => 'WAV'},
		raw  => {index => 2, type => 'play_raw_requested',  label => 'RAW'},
		json => {index => 3, type => 'play_json_requested', label => 'JSON'}
	);

	my $item = $definition{lc($kind // '')};
	return 0 if ref($item) ne 'HASH';

	if (!defined($path) || $path eq '')
	{
		$operation_failure = $item->{label} . ' útvonal üres.';
		$operation_status = 'Hiba: ' . $operation_failure;
		$last_message = $operation_status;
		return 0;
	}

	if (!-f $path)
	{
		$operation_failure =
			$item->{label} . ' fájl nem található.';
		$operation_status = 'Hiba: ' . $operation_failure;
		$last_message = $operation_status;
		return 0;
	}

	if (!-r $path)
	{
		$operation_failure =
			$item->{label} . ' fájl nem olvasható.';
		$operation_status = 'Hiba: ' . $operation_failure;
		$last_message = $operation_status;
		return 0;
	}

	my $current_run = active_run_index();

	if ($current_run >= 0 && $current_run <= 3)
	{
		$last_message =
			'Feldolgozás már fut. Előbb az ÁLLJ menüt kell aktiválni.';
		return 0;
	}

	$selected_menu = $item->{index};
	set_run_mode($item->{index});
	$operation_failure = '';
	$operation_status =
		$item->{label} . ' indítása folyamatban...';

	send_main
	(
		{
			type => $item->{type},
			path => $path,
			settings => current_settings(),
			source => $source // 'tui'
		}
	);

	$last_message = $item->{label} . ' megnyitási kérés elküldve: ' . $path;
	append_diagnostic($last_message);

	return 1;
}

sub request_wav_path
{
	return request_file_path('wav', @_);
}

sub request_raw_path
{
	return request_file_path('raw', @_);
}

sub request_json_path
{
	return request_file_path('json', @_);
}

sub request_recording
{
	my ($source) = @_;
	my $current_run = active_run_index();

	return 0 if $current_run >= 0 && $current_run <= 3;

	reset_sticky_receiver_fields();
	$selected_menu = 0;
	set_run_mode(0);
	$operation_failure = '';
	$operation_status = 'Felvétel indítása folyamatban...';
	send_main({type => 'start_recording_requested', settings => current_settings(), source => $source // 'tui'});
	$last_message = 'Felvétel indítási kérés elküldve.';
	append_diagnostic($last_message);
	return 1;
}

sub service_label
{
	my ($service) = @_;

	return $service eq 'bt'
		? 'Bluetooth GPS Bridge'
		: 'SondeHub feltöltő';
}

sub service_menu_index
{
	my ($service) = @_;
	return $service eq 'bt' ? 5 : 6;
}

sub valid_pipeconnect_id
{
	my ($id) = @_;

	return 0 if !defined($id) || $id eq '';
	return 0 if $id =~ /[\0\r\n]/;
	return 0 if length($id) > 240;

	return 1;
}

sub open_tui_pipeconnect_reader
{
	my ($service) = @_;

	return 0 if !-x $pipe_connect;

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
	if (!defined($id))
	{
		kill('TERM', $pid);
		waitpid($pid, WNOHANG);
		return 0;
	}

	$id =~ s/[\r\n]+\z//;

	if (!valid_pipeconnect_id($id))
	{
		kill('TERM', $pid);
		waitpid($pid, WNOHANG);
		return 0;
	}

	my $flags = fcntl($output, F_GETFL, 0);
	fcntl($output, F_SETFL, $flags | O_NONBLOCK)
		if defined($flags);

	my $state = $service_ui{$service};
	$state->{reader_pid} = $pid;
	$state->{output} = $output;
	$state->{receive_id} = $id;
	$state->{output_buffer} = '';

	return 1;
}

sub open_tui_pipeconnect_writer
{
	my ($service, $receive_id) = @_;

	return 0 if !valid_pipeconnect_id($receive_id);

	my ($output, $input);
	my $pid = open2(
		$output,
		$input,
		$^X,
		$pipe_connect,
		'-W',
		$receive_id
	);

	close($output);
	$input->autoflush(1);

	my $flags = fcntl($input, F_GETFL, 0);
	fcntl($input, F_SETFL, $flags | O_NONBLOCK)
		if defined($flags);

	my $state = $service_ui{$service};
	$state->{writer_pid} = $pid;
	$state->{input} = $input;

	return 1;
}

sub request_service_start
{
	my ($service, $source) = @_;
	my $state = $service_ui{$service};

	return 0 if ref($state) ne 'HASH';

	$selected_menu = service_menu_index($service);
	$service_dialog = $service;
	$state->{dialog_visible} = 1;

	if ($state->{connected})
	{
		$state->{status} = 'A kapcsolat már aktív.';
		return 1;
	}

	if ($state->{pending})
	{
		$state->{status} = 'Az indítási válaszra várakozik...';
		return 1;
	}

	if (!open_tui_pipeconnect_reader($service))
	{
		$state->{status} =
			'Hiba: a pipeConnect.pl -R nem indítható.';
		$state->{desired} = 0;
		$state->{pending} = 0;
		return 0;
	}

	$state->{desired} = 1;
	$state->{pending} = 1;
	$state->{request_time} = time();
	$state->{status} =
		'UI fogadó csatorna elkészült; várakozás a main válaszára...';

	send_main(
		{
			type => $service eq 'bt'
				? 'bt_start_requested'
				: 'sondehub_start_requested',
			receive_id => $state->{receive_id},
			settings => $service eq 'sondehub'
				? current_settings()
				: undef,
			source => $source // 'tui'
		}
	);

	return 1;
}

sub request_toggle_service
{
	my ($service, $active, $source) = @_;

	if ($active)
	{
		return request_service_start($service, $source);
	}

	return disconnect_service($service, 1);
}

sub close_service_handles
{
	my ($service) = @_;
	my $state = $service_ui{$service};

	return if ref($state) ne 'HASH';

	close($state->{input}) if $state->{input};
	close($state->{output}) if $state->{output};

	for my $pid_key (qw(reader_pid writer_pid))
	{
		my $pid = $state->{$pid_key};

		if ($pid)
		{
			kill('TERM', $pid);
			waitpid($pid, WNOHANG);
		}
	}

	$state->{reader_pid} = undef;
	$state->{writer_pid} = undef;
	$state->{input} = undef;
	$state->{output} = undef;
	$state->{error} = undef;
	$state->{connected} = 0;
	$state->{receive_id} = '';
	$state->{endpoint} = '';
	$state->{token} = '';
	$state->{output_buffer} = '';
	$state->{error_buffer} = '';

	$menu_items[service_menu_index($service)]->{active} = 0;

	return;
}

sub disconnect_service
{
	my ($service, $notify_main) = @_;
	my $state = $service_ui{$service};

	return 0 if ref($state) ne 'HASH';

	$state->{desired} = 0;
	$state->{pending} = 0;
	$state->{dialog_visible} = 0;
	$state->{status} = 'A kapcsolat megszakítva.';
	close_service_handles($service);

	if ($notify_main)
	{
		send_main(
			{
				type => $service eq 'bt'
					? 'bt_stop_requested'
					: 'sondehub_stop_requested'
			}
		);
	}

	$service_dialog = undef
		if defined($service_dialog) && $service_dialog eq $service;

	request_full_redraw();
	return 1;
}

sub connect_service_pipe
{
	my ($message) = @_;
	my $service = $message->{service} // '';
	my $state = $service_ui{$service};
	my $receive_id = $message->{receive_id} // '';

	return 0 if ref($state) ne 'HASH';

	if (!$state->{desired})
	{
		send_main(
			{
				type => $service eq 'bt'
					? 'bt_stop_requested'
					: 'sondehub_stop_requested'
			}
		);
		return 0;
	}

	if (!open_tui_pipeconnect_writer($service, $receive_id))
	{
		$state->{pending} = 0;
		$state->{desired} = 0;
		$state->{status} =
			'Hiba: a main pipeConnect fogadó ID-je nem nyitható meg.';
		close_service_handles($service);
		return 0;
	}

	$state->{pending} = 0;
	$state->{connected} = 1;
	$state->{status} =
		'A kétirányú pipeConnect szolgáltatáskapcsolat aktív.';

	$menu_items[service_menu_index($service)]->{active} = 1;

	append_diagnostic(
		service_label($service)
		. ' pipeConnect csatornája csatlakozott.'
	);

	return 1;
}

sub poll_service_connections
{
	for my $service (qw(bt sondehub))
	{
		my $state = $service_ui{$service};

		if ($state->{pending}
			&& time() - $state->{request_time} >= $SERVICE_START_TIMEOUT)
		{
			$state->{pending} = 0;
			$state->{desired} = 0;
			$state->{status} = 'Időtúllépés: a main nem adott szolgáltatásvégpontot.';
			$menu_items[service_menu_index($service)]->{active} = 0;
			append_diagnostic(service_label($service)
				. ': indítási időtúllépés.');
			send_main(
				{
					type => $service eq 'bt'
						? 'bt_stop_requested'
						: 'sondehub_stop_requested'
				}
			);
		}

		next if !$state->{connected};

		for my $entry
		(
			[$state->{output}, 0, 'output_buffer']
		)
		{
			my ($handle, $is_error, $buffer_key) = @{$entry};
			next if !$handle;

			while (1)
			{
				my $chunk = '';
				my $count = sysread($handle, $chunk, 65536);

				if (defined($count) && $count > 0)
				{
					$state->{$buffer_key} .= $chunk;

					while ($state->{$buffer_key} =~ s/^(.*?\n)//s)
					{
						my $line = $1;
						$line =~ s/[\r\n]+$//;
						if ($line ne '')
						{
							push(@{$state->{lines}},
								($is_error ? 'ERR: ' : '') . $line);
							shift(@{$state->{lines}}) while @{$state->{lines}} > 1000;

							# A BT/SondeHub adatforgalom kizárólag a saját
							# szolgáltatásablakban jelenik meg. A közös
							# DIAGNOSZTIKA panelt nem terheljük vele.
						}
					}
					next;
				}

				if (defined($count) && $count == 0)
				{
					$state->{status} = 'A közvetlen szolgáltatáskapcsolat bezárult.';
					close_service_handles($service);
					last;
				}

				last;
			}
		}
	}
}

sub reset_sticky_receiver_fields
{
	$display_frame_number = undef;
	$display_satellites = undef;

	return;
}

sub valid_sticky_integer
{
	my ($value) = @_;

	return 0 if !defined($value);
	return 0 if ref($value);
	return 0 if $value eq '';
	return 0 if $value eq '?';
	return 0 if $value !~ /^\d+$/;

	return 1;
}

sub capture_sticky_receiver_fields
{
	my ($data) = @_;

	return if ref($data) ne 'HASH';

	if (valid_sticky_integer($data->{frame_number}))
	{
		$display_frame_number = q{} . $data->{frame_number};
	}

	my $position = ref($data->{position}) eq 'HASH'
		? $data->{position}
		: {};

	if (valid_sticky_integer($position->{satellites}))
	{
		$display_satellites = q{} . $position->{satellites};
	}
}

sub dispatch_main

{
	my ($message) = @_;

	return if ref($message) ne 'HASH';

	my $type = $message->{type} // '';

	if (is_frontend_event_request($message))
	{
		my $event = $message->{event} // '';

		if ($event eq 'open_wav')
		{
			request_wav_path($message->{path}, $message->{source} // 'launcher');
		}
		elsif ($event eq 'open_raw')
		{
			request_raw_path($message->{path}, $message->{source} // 'launcher');
		}
		elsif ($event eq 'open_json')
		{
			request_json_path($message->{path}, $message->{source} // 'launcher');
		}
		elsif ($event eq 'start_recording')
		{
			request_recording($message->{source} // 'launcher');
		}
		elsif ($event eq 'set_bt')
		{
			request_toggle_service('bt', $message->{active}, $message->{source} // 'launcher');
		}
		elsif ($event eq 'set_sondehub')
		{
			request_toggle_service('sondehub', $message->{active}, $message->{source} // 'launcher');
		}
		elsif ($event eq 'activate_menu')
		{
			my $key = $message->{menu_key} // '';
			select_menu_by_key($key) if $key ne '';
		}
		elsif ($event eq 'setting_change')
		{
			apply_requested_setting($message->{name}, $message->{value});
		}
		else
		{
			append_diagnostic('Ismeretlen frontend eseménykérés: ' . $event);
		}

		return;
	}

	if ($type eq 'initialize')
	{
		apply_initialize($message->{settings});
		$last_message = 'A main inicializálta a TUI-t.';
	}
	elsif ($type eq 'settings_state')
	{
		apply_initialize($message->{settings});
		$last_message =
			'A main által használt beállítások újratöltve.';
	}
	elsif ($type eq 'append_log')
	{
		my $text = $message->{text} // '';

		detect_file_start_failure($text);

		# A main a szolgáltatási csatornák forgalmát BT:, illetve
		# SondeHub: előtaggal tükrözi vissza. Ezek már láthatók a
		# saját szolgáltatásablakban, ezért a közös diagnosztikából
		# soronként kiszűrjük őket.
		for my $line (split(/(?<=\n)/, $text))
		{
			my $check = $line;
			$check =~ s/[\r\n]+$//;

			next if $check =~ /^BT:\s/;
			next if $check =~ /^SondeHub:\s/;

			append_diagnostic($line);
		}
	}
	elsif ($type eq 'terminal')
	{
		append_diagnostic(
			($message->{level} // 'INFO') . ': '
			. ($message->{text} // '')
		);
	}
	elsif ($type eq 'clear_logs')
	{
		@diagnostics = ();
		reset_frontend_state($frontend_state);
	}
	elsif ($type eq 'running_state')
	{
		if ($message->{running})
		{
			my $description = $message->{description} // '';
			my $index = $description =~ /Felvétel/i ? 0
				: $description =~ /Lejátszás/i ? 1
				: $description =~ /RAW/i ? 2
				: $description =~ /JSON/i ? 3 : 0;
			set_run_mode($index);
			$operation_failure = '';
			$operation_status =
				'Fut: ' . ($description || 'feldolgozás');
			$last_message = 'Állapot: ' . ($description || 'fut');
		}
		else
		{
			set_run_mode(4);

			if ($operation_failure ne '')
			{
				$operation_status = 'Hiba: ' . $operation_failure;
				$last_message = $operation_status;
			}
			else
			{
				$operation_status = 'Áll';
				$last_message = 'Állapot: áll';
			}

			# A feldolgozási pipe megszűnésekor a terminál fizikai
			# képernyőképe eltérhet az ncurses belső állapotától.
			# Teljes újrarajzolást kérünk, így a menüsor és minden
			# panel azonnal helyreáll.
			request_full_redraw();
		}
	}
	elsif ($type eq 'receiver_update')
	{
		my $data =
			ref($message->{data}) eq 'HASH'
			? $message->{data}
			: {};

		capture_sticky_receiver_fields($data);
		apply_receiver_update($frontend_state, $data);
	}

	elsif ($type eq 'runtime_statistics')
	{
		apply_runtime_statistics($frontend_state, $message);
	}
	elsif ($type eq 'calculated_fields')
	{
		apply_calculated_fields($frontend_state, $message);
	}
	elsif ($type eq 'base_position_update')
	{
		apply_initialize({base => $message->{base}});
	}
	elsif ($type eq 'service_opened')
	{
		connect_service_pipe($message);
	}
	elsif ($type eq 'bt_state')
	{
		if (!$message->{active})
		{
			close_service_handles('bt');
			$service_ui{bt}{desired} = 0;
			$service_ui{bt}{pending} = 0;
			$service_ui{bt}{status} = 'A Bluetooth kapcsolat leállt.';
		}
	}
	elsif ($type eq 'sondehub_state')
	{
		if (!$message->{active})
		{
			close_service_handles('sondehub');
			$service_ui{sondehub}{desired} = 0;
			$service_ui{sondehub}{pending} = 0;
			$service_ui{sondehub}{status} = 'A SondeHub kapcsolat leállt.';
		}
	}
	elsif ($type eq 'shutdown')
	{
		$running = 0;
	}

	return;
}

sub read_main_messages
{
	return if !defined($main_input);

	my $chunk = '';
	my $count = sysread($main_input, $chunk, 65536);

	if (defined($count) && $count > 0)
	{
		for my $message (extract_json_messages(\$main_buffer, $chunk))
		{
			dispatch_main($message);
		}
	}
	elsif (defined($count) && $count == 0)
	{
		$last_message = 'A main kapcsolat bezárult.';
		$running = 0;
	}

	return;
}

sub key_is_code
{
	my ($key, $code) = @_;

	return 0 if !defined $key;
	return 0 if $key !~ /\A-?\d+\z/;

	return int($key) == $code;
}

sub safe_addstr
{
	my ($window, $y, $x, $text, $max_width) = @_;

	return if !defined $text;

	# A JSON-számokat is valódi Perl szöveggé alakítjuk. A Curses XS
	# felé így a tisztán numerikus KERET és MŰHOLDAK mező sem numerikus
	# skalárként kerül továbbításra.
	$text = q{} . $text;
	return if $max_width <= 0;

	my ($window_height, $window_width);
	$window->getmaxyx($window_height, $window_width);

	return if $y < 0 || $y >= $window_height;
	return if $x < 0 || $x >= $window_width;

	my $remaining_width = $window_width - $x;

	# Az utolsó képernyőcellába történő írás egyes ncurses
	# változatokban ERR értéket adhat, ezért egy cellát szabadon hagyunk.
	$remaining_width-- if $remaining_width > 1;

	$max_width = $remaining_width
		if $max_width > $remaining_width;

	return if $max_width <= 0;

	if (length($text) > $max_width)
	{
		$text = substr($text, 0, $max_width);
	}

	$window->move($y, $x);

	# Az ncurses siker esetén 0-t is visszaadhat. Ez Perlben hamis,
	# ezért a visszatérési értéket nem szabad !addstring() formában
	# hibának tekinteni. A biztonságosan levágott szöveget egyszerűen
	# kiírjuk; egy rajzolási hiba nem állíthatja le az egész TUI-t.
	addstring($window, $text);
}

sub clear_rect
{
	my ($window, $y, $x, $height, $width) = @_;

	return if $height <= 0;
	return if $width <= 0;

	my $blank = ' ' x $width;

	for (my $row = 0; $row < $height; $row++)
	{
		$window->move($y + $row, $x);
		addstring($window, $blank);
	}
}

sub draw_box
{
	my ($window, $y, $x, $height, $width, $title) = @_;

	return if $height < 3;
	return if $width < 4;

	$window->move($y, $x);
	$window->addch(ACS_ULCORNER);

	for (my $i = 1; $i < $width - 1; $i++)
	{
		$window->addch(ACS_HLINE);
	}

	$window->addch(ACS_URCORNER);

	for (my $row = 1; $row < $height - 1; $row++)
	{
		$window->move($y + $row, $x);
		$window->addch(ACS_VLINE);

		$window->move($y + $row, $x + $width - 1);
		$window->addch(ACS_VLINE);
	}

	$window->move($y + $height - 1, $x);
	$window->addch(ACS_LLCORNER);

	for (my $i = 1; $i < $width - 1; $i++)
	{
		$window->addch(ACS_HLINE);
	}

	$window->addch(ACS_LRCORNER);

	if (defined $title && length($title))
	{
		my $visible_title = " $title ";
		my $max_length = $width - 4;

		if (length($visible_title) > $max_length)
		{
			$visible_title = substr($visible_title, 0, $max_length);
		}

		$window->move($y, $x + 2);
		addstring($window, $visible_title);
	}
}

sub clear_mouse_regions
{
	@mouse_regions = ();

	return;
}

sub add_mouse_region
{
	my (%region) = @_;

	return if !defined($region{x1});
	return if !defined($region{x2});
	return if !defined($region{y1});
	return if !defined($region{y2});

	push(@mouse_regions, \%region);

	return;
}

sub mouse_region_at
{
	my ($x, $y) = @_;

	for my $region (reverse(@mouse_regions))
	{
		next if $x < $region->{x1};
		next if $x > $region->{x2};
		next if $y < $region->{y1};
		next if $y > $region->{y2};

		return $region;
	}

	return undef;
}

sub activate_settings_mouse_row
{
	my ($index) = @_;

	return if $settings_editing;
	return if $index < 0 || $index > $#settings_items;

	$selected_setting = $index;

	my $item = $settings_items[$selected_setting];

	if (($item->{type} // '') eq 'boolean')
	{
		settings_toggle_boolean();
	}
	else
	{
		settings_start_edit();
	}

	return;
}

sub activate_file_mouse_row
{
	my ($index) = @_;

	return if !defined($file_dialog_kind);
	return if $index < 0 || $index > $#file_dialog_files;

	$file_dialog_selected = $index;

	my $file = $file_dialog_files[$file_dialog_selected];
	my $kind = $file_dialog_kind;

	if (ref($file) eq 'HASH'
		&& request_file_path(
			$kind,
			$file->{path},
			'tui_file_dialog_mouse'
		))
	{
		close_file_dialog();
	}

	return;
}

sub handle_mouse_event
{
	return if !$mouse_enabled;

	my $mouse_event = '';

	my $mouse_ok = eval
	{
		getmouse($mouse_event);
		1;
	};

	return if !$mouse_ok;
	return if !defined($mouse_event) || $mouse_event eq '';

	# A Perl Curses modul a natív ncurses MEVENT struktúrát egyetlen
	# bináris skalárba írja. A Linux/ncurses felépítés:
	#
	# short id;
	# 2 byte padding;
	# int x, y, z;
	# long bstate;
	my ($id, $x, $y, $z, $button_state) =
		unpack('s x2 i3 l', $mouse_event);

	return if !defined($x) || !defined($y);
	return if !defined($button_state);

	my $clicked =
		($button_state & BUTTON1_CLICKED)
		|| ($button_state & BUTTON1_DOUBLE_CLICKED);

	return if !$clicked;

	my $region = mouse_region_at($x, $y);
	return if ref($region) ne 'HASH';

	my $type = $region->{type} // '';

	if ($type eq 'menu')
	{
		my $index = $region->{index};
		return if !defined($index);

		$selected_menu = $index;
		activate_menu($index);
		return;
	}

	if ($type eq 'settings_item')
	{
		activate_settings_mouse_row($region->{index});
		return;
	}

	if ($type eq 'file_item')
	{
		activate_file_mouse_row($region->{index});
		return;
	}

	if ($type eq 'service_end')
	{
		return if !defined($service_dialog);

		disconnect_service($service_dialog, 1);
		$last_message = 'A szolgáltatás kapcsolata megszakítva.';
		return;
	}

	if ($type eq 'service_home')
	{
		return if !defined($service_dialog);

		$service_ui{$service_dialog}{dialog_visible} = 0;
		$service_dialog = undef;
		$last_message =
			'A szolgáltatás ablaka elrejtve; a kapcsolat megmaradt.';
		request_full_redraw();
		return;
	}

	if ($type eq 'settings_enter')
	{
		handle_settings_key("\n");
		return;
	}

	if ($type eq 'settings_escape')
	{
		handle_settings_key("\e");
		return;
	}

	if ($type eq 'file_enter')
	{
		handle_file_dialog_key("\n");
		return;
	}

	if ($type eq 'file_escape')
	{
		handle_file_dialog_key("\e");
		return;
	}

	return;
}

sub menu_item_text
{
	my ($index) = @_;

	my $item = $menu_items[$index];
	my $state = '';

	if ($item->{group} eq 'run' || $item->{group} eq 'toggle')
	{
		$state = $item->{active} ? '[#]' : '[_]';
	}

	my $text = '-' . $item->{key} . ':' . $item->{label} . $state . '-';

	if ($index == $selected_menu)
	{
		return '<|' . $text . '|>';
	}

	return '  ' . $text . '  ';
}

sub draw_menu
{
	my ($window, $width) = @_;

	my $x = 2;

	for (my $i = 0; $i < @menu_items; $i++)
	{
		my $text = menu_item_text($i);

		last if $x + length($text) >= $width - 1;

		safe_addstr($window, 1, $x, $text, $width - $x - 1);

		add_mouse_region(
			type  => 'menu',
			index => $i,
			x1    => $x,
			x2    => $x + length($text) - 1,
			y1    => 1,
			y2    => 1
		);

		$x += length($text);
	}
}

sub active_run_index
{
	for (my $i = 0; $i <= 4; $i++)
	{
		return $i if $menu_items[$i]->{active};
	}

	return 4;
}

sub set_run_mode
{
	my ($index) = @_;

	for (my $i = 0; $i <= 4; $i++)
	{
		$menu_items[$i]->{active} = ($i == $index) ? 1 : 0;
	}
}

sub activate_menu
{
	my ($index) = @_;

	my $item = $menu_items[$index];

	if ($index >= 0 && $index <= 3)
	{
		my $current_run = active_run_index();

		if ($current_run >= 0 && $current_run <= 3)
		{
			$last_message =
				'Feldolgozás már fut. Előbb az ÁLLJ menüt kell aktiválni.';
			return;
		}

		if ($index == 0)
		{
			request_recording('tui_menu');
		}
		elsif ($index == 1)
		{
			open_file_dialog('wav');
		}
		elsif ($index == 2)
		{
			open_file_dialog('raw');
		}
		else
		{
			open_file_dialog('json');
		}

		return;
	}

	if ($index == 4)
	{
		send_main({type => 'stop_requested'});
		$operation_failure = '';
		$operation_status = 'Leállítás folyamatban...';
		$last_message = 'Leállítás elküldve a mainnek.';
		request_full_redraw();
		return;
	}

	if ($index == 5)
	{
		request_service_start('bt', 'tui_menu');
		$last_message = 'A Bluetooth kapcsolat ablaka megnyitva.';
		return;
	}

	if ($index == 6)
	{
		request_service_start('sondehub', 'tui_menu');
		$last_message = 'A SondeHub kapcsolat ablaka megnyitva.';
		return;
	}

	if ($index == 7)
	{
		%settings_draft = %config;
		$ui_mode = 'SETTINGS';
		$selected_setting = 0;
		$settings_scroll = 0;
		$settings_editing = 0;
		$settings_edit_buffer = '';
		$settings_edit_cursor = 0;
		$last_message = 'A beállításlista megnyitva.';
		return;
	}

	if ($index == 8)
	{
		send_main({type => 'window_close_requested'});
		$running = 0;
		return;
	}
}

sub select_menu_by_key
{
	my ($key) = @_;

	for (my $i = 0; $i < @menu_items; $i++)
	{
		if (lc($menu_items[$i]->{key}) eq lc($key))
		{
			$selected_menu = $i;
			activate_menu($i);
			return 1;
		}
	}

	return 0;
}

sub draw_base_panel
{
	my ($window, $width, $terminal_width, $terminal_height) = @_;

	draw_box(
		$window,
		4,
		0,
		4,
		$width,
		'BÁZIS / VÉTELI / VEKTOR ADATOK'
	);

	# Első sor: minden mező fix karakteroszlopon kezdődik.
	safe_addstr(
		$window,
		5,
		2,
		'Bázis: Szél.: ' . $config{BASE_LAT},
		22
	);
	safe_addstr(
		$window,
		5,
		26,
		'Hossz.: ' . $config{BASE_LON},
		18
	);
	safe_addstr(
		$window,
		5,
		46,
		'Mag.: ' . $config{BASE_ALT} . ' m',
		16
	);
	safe_addstr(
		$window,
		5,
		64,
		'Szög: ' . $config{BASE_ANGLE},
		12
	);
	safe_addstr($window, 5, 78, 'Megosztás:' . config_toggle_text('SONDEHUB_SHARE'), 15);
	safe_addstr($window, 5, 95, 'Mobil:' . config_toggle_text('SONDEHUB_MOBIL'), 12);

	# Második sor: az első négy mező az első sor oszlopaihoz igazodik.
	safe_addstr($window, 6, 2, 'Távolság: ' . ($frontend_state->{calculated}{distance} // '?'), 22);
	safe_addstr($window, 6, 26, 'Irány: ' . ($frontend_state->{calculated}{bearing} // '?'), 18);
	safe_addstr($window, 6, 46, 'Szög: ' . ($frontend_state->{calculated}{elevation} // '?'), 16);
	safe_addstr(
		$window,
		6,
		64,
		'Frekvencia: '
			. $config{SONDEHUB_FREQUENCY_MHZ}
			. 'MHz',
		24
	);

	my $terminal_text =
		"Terminál méret: $terminal_width x $terminal_height";

	my $terminal_x = 95;

	safe_addstr(
		$window,
		6,
		$terminal_x,
		$terminal_text,
		$width - $terminal_x - 1
	);
}

sub draw_settings_panel
{
	my ($window, $width) = @_;

	draw_box($window, 9, 0, 5, $width, 'AKTUÁLIS BEÁLLÍTÁSOK');

	safe_addstr(
		$window,
		10,
		2,
		'Eszköz: ' . $config{AUDIO_DEVICE},
		24
	);
	safe_addstr(
		$window,
		10,
		34,
		'Hz: ' . $config{AUDIO_SAMPLE_RATE},
		10
	);
	safe_addstr(
		$window,
		10,
		46,
		'LF: ' . $config{AUDIO_LF},
		10
	);
	safe_addstr(
		$window,
		10,
		60,
		'HF: ' . $config{AUDIO_HF},
		12
	);
	safe_addstr(
		$window,
		10,
		72,
		'O: ' . $config{AUDIO_ORDER},
		8
	);
	safe_addstr(
		$window,
		10,
		84,
		'P: ' . $config{AUDIO_PEAK},
		8
	);
	safe_addstr(
		$window,
		10,
		95,
		'D: ' . $config{AUDIO_DELAY},
		8
	);
	safe_addstr(
		$window,
		10,
		106,
		'Inverz:' . config_toggle_text('AUDIO_INVERT'),
		$width - 110
	);

	safe_addstr(
		$window,
		11,
		2,
		'Mód: ' . uc($menu_items[active_run_index()]->{label}),
		30
	);

	safe_addstr(
		$window,
		11,
		34,
		'Állapot: ' . $operation_status,
		$width - 36
	);

	safe_addstr(
		$window,
		12,
		2,
		'Aktuális LOG mappa: ' . $config{LOG_DIRECTORY},
		$width - 4
	);
}

sub draw_statistics_panel
{
	my ($window, $width) = @_;

	draw_box($window, 15, 0, 3, $width, 'CSOMAGSTATISZTIKA');

	my $packet = $frontend_state->{packet_count};

	safe_addstr($window, 16, 2,
		'VALID: ' . ($packet->{VALID} // 0), 18);
	safe_addstr($window, 16, 20,
		'PARTIAL: ' . ($packet->{PARTIAL} // 0), 19);
	safe_addstr($window, 16, 39,
		'INVALID: ' . ($packet->{INVALID} // 0), 19);
	safe_addstr($window, 16, 58,
		'Arány: ' . packet_ratio_text($frontend_state), $width - 60);
}

sub draw_data_table
{
	my ($window, $width) = @_;

	my $y = 19;
	my $height = 16;
	my $middle = int($width * 0.36);

	$middle = 44 if $middle < 44;
	$middle = $width - 55 if $middle > $width - 55;

	draw_box(
		$window,
		$y,
		0,
		$height,
		$width,
		'ADATOK'
	);

	for (my $row = 1; $row < $height - 1; $row++)
	{
		$window->move($y + $row, $middle);
		$window->addch(ACS_VLINE);
	}

	my $left_name_x = 2;
	my $left_value_x = 22;
	my $right_name_x = $middle + 2;
	my $right_value_x = $middle + 27;

	if ($right_value_x > $width - 25)
	{
		$right_value_x = $middle + 23;
	}

	my $values = frontend_table_values($frontend_state);

	# A GUI-hoz hasonlóan a három alapmezőt közvetlenül az összevont,
	# utolsó vevőállapotból is feloldjuk. Így PARTIAL/INVALID keretnél
	# a hiányzó adat nem törli a korábban megkapott értéket.
	my $receiver_data =
		ref($frontend_state->{last_receiver_data}) eq 'HASH'
		? $frontend_state->{last_receiver_data}
		: {};

	$values->{frame} = $display_frame_number
		if defined($display_frame_number);

	$values->{satellites} = $display_satellites
		if defined($display_satellites);

	my $receiver_calibration =
		ref($receiver_data->{calibration}) eq 'HASH'
		? $receiver_data->{calibration}
		: {};

	$values->{calibration} =
		defined($receiver_calibration->{complete})
		? ($receiver_calibration->{complete} ? 'true' : 'false')
		: 'false';

	my @left_value_keys = qw(
		validity frame sonde_id battery latitude longitude altitude
		velocity_h heading velocity_v temperature humidity_temperature
		humidity empirical_rh
	);

	my @right_value_keys = qw(
		gps_time last_success total_path satellites pressure
		estimated_pressure peak_altitude calibration calibration_frames
		raw_t raw_h raw_th raw_p peak_time
	);

	for (my $i = 0; $i < 14; $i++)
	{
		my $row_y = $y + 1 + $i;

		safe_addstr(
			$window,
			$row_y,
			$left_name_x,
			$left_fields[$i],
			$left_value_x - $left_name_x - 1
		);

		safe_addstr(
			$window,
			$row_y,
			$left_value_x,
			$values->{$left_value_keys[$i]} // '',
			$middle - $left_value_x - 1
		);

		safe_addstr(
			$window,
			$row_y,
			$right_name_x,
			$right_fields[$i],
			$right_value_x - $right_name_x - 1
		);

		safe_addstr(
			$window,
			$row_y,
			$right_value_x,
			$values->{$right_value_keys[$i]} // '',
			$width - $right_value_x - 2
		);
	}
}

sub draw_diagnostics
{
	my ($window, $width, $height) = @_;

	my $y = 36;
	my $panel_height = $height - $y;

	return if $panel_height < 3;

	draw_box($window, $y, 0, $panel_height, $width, 'DIAGNOSZTIKA');

	my $available_rows = $panel_height - 2;
	my @lines = ($last_message, @diagnostics);
	my $start = @lines > $available_rows
		? @lines - $available_rows : 0;

	for (my $row = 0; $row < $available_rows; $row++)
	{
		my $index = $start + $row;
		last if $index >= @lines;

		safe_addstr(
			$window,
			$y + 1 + $row,
			2,
			$lines[$index],
			$width - 4
		);
	}
}

sub settings_apply_to_main
{
	my $draft = current_settings(\%settings_draft);

	send_main(
		{
			type => 'settings_apply_requested',
			settings =>
			{
				frequency => $draft->{frequency},
				share     => $draft->{share},
				mobile    => $draft->{mobile},
				base      => $draft->{base}
			},
			source => 'tui_settings_close_apply'
		}
	);

	$settings_state_pending = 1;

	return;
}

sub settings_save_to_main
{
	send_main(
		{
			type     => 'settings_save_requested',
			settings => current_settings(\%settings_draft),
			source   => 'tui_settings_close_save'
		}
	);

	$settings_state_pending = 1;

	return;
}

sub settings_start_edit
{
	my $item = $settings_items[$selected_setting];
	return if ref($item) ne 'HASH';

	my $config_key = $item->{config_key};

	$settings_edit_buffer = q{} . ($settings_draft{$config_key} // '');
	$settings_edit_cursor = length($settings_edit_buffer);
	$settings_editing = 1;
	$last_message = 'Beállítás szerkesztése: ' . $item->{label};

	return;
}

sub settings_cancel_edit
{
	$settings_editing = 0;
	$settings_edit_buffer = '';
	$settings_edit_cursor = 0;
	$last_message = 'A beállítás módosítása elvetve.';

	return;
}

sub settings_number_is_valid
{
	my ($config_key, $value) = @_;

	return (0, 'Az érték nem lehet üres.')
		if !defined($value) || $value eq '';

	return (0, 'Érvénytelen számformátum.')
		if $value !~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)$/;

	my $number = 0 + $value;

	return (0, 'A szélesség -90 és 90 közé essen.')
		if $config_key eq 'BASE_LAT'
		&& ($number < -90 || $number > 90);

	return (0, 'A hosszúság -180 és 180 közé essen.')
		if $config_key eq 'BASE_LON'
		&& ($number < -180 || $number > 180);

	return (0, 'A bázisszög 0 és 360 közé essen.')
		if $config_key eq 'BASE_ANGLE'
		&& ($number < 0 || $number > 360);

	return (0, 'A frekvencia legyen pozitív.')
		if $config_key eq 'SONDEHUB_FREQUENCY_MHZ'
		&& $number <= 0;

	return (0, 'A mintavételi frekvencia pozitív egész legyen.')
		if $config_key eq 'AUDIO_SAMPLE_RATE'
		&& ($value !~ /^\d+$/ || $number <= 0);

	return (0, 'Az LF érték legyen nemnegatív szám.')
		if $config_key eq 'AUDIO_LF'
		&& $number < 0;

	return (0, 'A HF érték legyen pozitív szám.')
		if $config_key eq 'AUDIO_HF'
		&& $number <= 0;

	return (0, 'A szűrőrend pozitív egész legyen.')
		if $config_key eq 'AUDIO_ORDER'
		&& ($value !~ /^\d+$/ || $number <= 0);

	return (0, 'A PEAK érték 0 és 1 közé essen.')
		if $config_key eq 'AUDIO_PEAK'
		&& ($number < 0 || $number > 1);

	return (0, 'A késleltetés nem lehet negatív.')
		if $config_key eq 'AUDIO_DELAY'
		&& $number < 0;

	return (0, 'Az LF értéknek kisebbnek kell lennie a HF értéknél.')
		if $config_key eq 'AUDIO_LF'
		&& $number >= (0 + ($settings_draft{AUDIO_HF} // 0));

	return (0, 'A HF értéknek nagyobbnak kell lennie az LF értéknél.')
		if $config_key eq 'AUDIO_HF'
		&& $number <= (0 + ($settings_draft{AUDIO_LF} // 0));

	return (1, '');
}

sub settings_commit_edit
{
	my $item = $settings_items[$selected_setting];
	return if ref($item) ne 'HASH';

	my $config_key = $item->{config_key};
	my $type = $item->{type} // 'string';
	my $value = $settings_edit_buffer;

	if ($type eq 'number')
	{
		my ($valid, $error) =
			settings_number_is_valid($config_key, $value);

		if (!$valid)
		{
			$last_message = $error;
			return 0;
		}
	}
	elsif (($type eq 'string' || $type eq 'directory')
		&& $value eq '')
	{
		$last_message = 'Az érték nem lehet üres.';
		return 0;
	}

	$settings_draft{$config_key} = $value;
	$settings_editing = 0;
	$settings_edit_buffer = '';
	$settings_edit_cursor = 0;

	$last_message =
		'A beállítás a szerkesztési listában módosítva: '
		. $item->{label}
		. ' = ' . $value;
	append_diagnostic($last_message);

	return 1;
}

sub settings_toggle_boolean
{
	my $item = $settings_items[$selected_setting];
	return 0 if ref($item) ne 'HASH';
	return 0 if ($item->{type} // '') ne 'boolean';

	my $config_key = $item->{config_key};
	$settings_draft{$config_key} =
		config_boolean_value($config_key, \%settings_draft)
		? 0
		: 1;

	$last_message =
		'A beállítás a szerkesztési listában módosítva: '
		. $item->{label}
		. ' = '
		. config_toggle_text($config_key, \%settings_draft);
	append_diagnostic($last_message);

	return 1;
}

sub settings_delete_before_cursor
{
	return if $settings_edit_cursor <= 0;

	substr(
		$settings_edit_buffer,
		$settings_edit_cursor - 1,
		1,
		''
	);
	$settings_edit_cursor--;

	return;
}

sub settings_delete_at_cursor
{
	return if $settings_edit_cursor >= length($settings_edit_buffer);

	substr(
		$settings_edit_buffer,
		$settings_edit_cursor,
		1,
		''
	);

	return;
}

sub settings_insert_character
{
	my ($character) = @_;

	return if !defined($character);
	return if length($character) != 1;
	return if ord($character) < 32 || ord($character) == 127;

	substr(
		$settings_edit_buffer,
		$settings_edit_cursor,
		0,
		$character
	);
	$settings_edit_cursor++;

	return;
}

sub draw_settings_dialog
{
	my ($window, $screen_width, $screen_height) = @_;

	my $dialog_width = 76;
	my $dialog_height = $screen_height - 8;

	$dialog_width = $screen_width - 8
		if $dialog_width > $screen_width - 8;

	$dialog_height = 22
		if $dialog_height > 22;

	$dialog_height = 10
		if $dialog_height < 10;

	my $dialog_x = int(($screen_width - $dialog_width) / 2);
	my $dialog_y = int(($screen_height - $dialog_height) / 2);

	clear_rect(
		$window,
		$dialog_y,
		$dialog_x,
		$dialog_height,
		$dialog_width
	);

	draw_box(
		$window,
		$dialog_y,
		$dialog_x,
		$dialog_height,
		$dialog_width,
		'BEÁLLÍTÁSOK'
	);

	my $list_top = $dialog_y + 2;
	my $list_rows = $dialog_height - 5;

	if ($selected_setting < $settings_scroll)
	{
		$settings_scroll = $selected_setting;
	}

	if ($selected_setting >= $settings_scroll + $list_rows)
	{
		$settings_scroll =
			$selected_setting - $list_rows + 1;
	}

	my $label_x = $dialog_x + 4;
	my $value_x = $dialog_x + 43;

	for (my $row = 0; $row < $list_rows; $row++)
	{
		my $index = $settings_scroll + $row;

		last if $index >= @settings_items;

		add_mouse_region(
			type  => 'settings_item',
			index => $index,
			x1    => $dialog_x + 1,
			x2    => $dialog_x + $dialog_width - 2,
			y1    => $list_top + $row,
			y2    => $list_top + $row
		);

		my $marker =
			($index == $selected_setting) ? '<| ' : '   ';

		my $label =
			$marker . $settings_items[$index]->{label};

		my $config_key =
			$settings_items[$index]->{config_key};

		my $value = $settings_draft{$config_key} // '';

		if ($settings_items[$index]->{type} eq 'boolean')
		{
			$value = config_boolean_value($config_key, \%settings_draft)
				? '[#]'
				: '[_]';
		}
		elsif ($settings_editing && $index == $selected_setting)
		{
			my $left = substr(
				$settings_edit_buffer,
				0,
				$settings_edit_cursor
			);
			my $right = substr(
				$settings_edit_buffer,
				$settings_edit_cursor
			);

			$value = $left . '|' . $right;
		}

		safe_addstr(
			$window,
			$list_top + $row,
			$dialog_x + 2,
			$label,
			$value_x - $dialog_x - 4
		);

		safe_addstr(
			$window,
			$list_top + $row,
			$value_x,
			$value,
			$dialog_width - ($value_x - $dialog_x) - 10
		);

		if ($index == $selected_setting)
		{
			my $right_marker_x =
				$dialog_x + $dialog_width - 5;

			safe_addstr(
				$window,
				$list_top + $row,
				$right_marker_x,
				'|>',
				2
			);
		}
	}

	my $position =
		($selected_setting + 1) . ' / ' . scalar(@settings_items);

	my $footer_y = $dialog_y + $dialog_height - 2;
	my $footer_x = $dialog_x + 2;

	if ($settings_editing)
	{
		my $prefix = 'Bal/Jobb: kurzor   ';
		my $enter_text = 'Enter: alkalmazás';
		my $escape_text = 'Esc: elvetés';
		my $enter_x = $footer_x + length($prefix);
		my $escape_x = $enter_x + length($enter_text) + 3;

		safe_addstr(
			$window,
			$footer_y,
			$footer_x,
			$prefix . $enter_text . '   ' . $escape_text,
			$dialog_width - 4
		);

		add_mouse_region(
			type => 'settings_enter',
			x1   => $enter_x,
			x2   => $enter_x + length($enter_text) - 1,
			y1   => $footer_y,
			y2   => $footer_y
		);

		add_mouse_region(
			type => 'settings_escape',
			x1   => $escape_x,
			x2   => $escape_x + length($escape_text) - 1,
			y1   => $footer_y,
			y2   => $footer_y
		);
	}
	else
	{
		my $prefix = 'Fel/Le: választás   ';
		my $enter_text =
			'Enter/Space: szerkesztés vagy kapcsolás';
		my $escape_text = 'Esc: vissza';
		my $enter_x = $footer_x + length($prefix);
		my $escape_x = $enter_x + length($enter_text) + 3;

		safe_addstr(
			$window,
			$footer_y,
			$footer_x,
			$prefix . $enter_text . '   ' . $escape_text,
			$dialog_width - 4
		);

		add_mouse_region(
			type => 'settings_enter',
			x1   => $enter_x,
			x2   => $enter_x + length($enter_text) - 1,
			y1   => $footer_y,
			y2   => $footer_y
		);

		add_mouse_region(
			type => 'settings_escape',
			x1   => $escape_x,
			x2   => $escape_x + length($escape_text) - 1,
			y1   => $footer_y,
			y2   => $footer_y
		);
	}

	safe_addstr(
		$window,
		$dialog_y + 1,
		$dialog_x + $dialog_width - length($position) - 3,
		$position,
		length($position)
	);
}

sub handle_settings_key
{
	my ($key) = @_;

	if ($settings_editing)
	{
		if ($key eq "\e")
		{
			settings_cancel_edit();
			return;
		}

		if ($key eq "\n"
			|| $key eq "\r"
			|| key_is_code($key, 10)
			|| key_is_code($key, 13)
			|| key_is_code($key, KEY_ENTER))
		{
			settings_commit_edit();
			return;
		}

		if (key_is_code($key, KEY_LEFT))
		{
			$settings_edit_cursor--
				if $settings_edit_cursor > 0;
			return;
		}

		if (key_is_code($key, KEY_RIGHT))
		{
			$settings_edit_cursor++
				if $settings_edit_cursor
				< length($settings_edit_buffer);
			return;
		}

		if (key_is_code($key, KEY_HOME))
		{
			$settings_edit_cursor = 0;
			return;
		}

		if (key_is_code($key, KEY_END))
		{
			$settings_edit_cursor =
				length($settings_edit_buffer);
			return;
		}

		if (key_is_code($key, KEY_BACKSPACE)
			|| key_is_code($key, 127)
			|| key_is_code($key, 8))
		{
			settings_delete_before_cursor();
			return;
		}

		if (key_is_code($key, KEY_DC))
		{
			settings_delete_at_cursor();
			return;
		}

		my $character = printable_key_character($key);

		if (defined($character))
		{
			settings_insert_character($character);
		}

		return;
	}

	if ($key eq "\e")
	{
		my $run_index = active_run_index();

		settings_apply_to_main();

		if ($run_index == 4)
		{
			settings_save_to_main();
			$last_message =
				'ALKALMAZ és MENTÉS elküldve; várakozás a main válaszára.';
		}
		else
		{
			$last_message =
				'Futó feldolgozás miatt csak ALKALMAZ elküldve.';
		}

		$ui_mode = 'MAIN';
		request_full_redraw();
		return;
	}

	if (key_is_code($key, KEY_UP))
	{
		$selected_setting--;

		if ($selected_setting < 0)
		{
			$selected_setting = $#settings_items;
		}

		return;
	}

	if (key_is_code($key, KEY_DOWN))
	{
		$selected_setting++;

		if ($selected_setting > $#settings_items)
		{
			$selected_setting = 0;
		}

		return;
	}

	if (
		$key eq ' '
		|| $key eq "\n"
		|| $key eq "\r"
		|| key_is_code($key, 10)
		|| key_is_code($key, 13)
		|| key_is_code($key, KEY_ENTER)
	)
	{
		my $item = $settings_items[$selected_setting];

		if (($item->{type} // '') eq 'boolean')
		{
			settings_toggle_boolean();
		}
		else
		{
			settings_start_edit();
		}

		return;
	}
}

sub draw_file_dialog
{
	my ($window, $screen_width, $screen_height) = @_;

	return if !defined($file_dialog_kind);

	my $dialog_width = 100;
	my $dialog_height = $screen_height - 10;

	$dialog_width = $screen_width - 8
		if $dialog_width > $screen_width - 8;

	$dialog_height = 28
		if $dialog_height > 28;

	$dialog_height = 12
		if $dialog_height < 12;

	my $dialog_x = int(($screen_width - $dialog_width) / 2);
	my $dialog_y = int(($screen_height - $dialog_height) / 2);
	my $label = file_kind_label($file_dialog_kind);

	clear_rect(
		$window,
		$dialog_y,
		$dialog_x,
		$dialog_height,
		$dialog_width
	);

	draw_box(
		$window,
		$dialog_y,
		$dialog_x,
		$dialog_height,
		$dialog_width,
		$label . ' FÁJLVÁLASZTÓ'
	);

	my $directory = display_work_directory(
		resolved_log_directory()
	);

	safe_addstr(
		$window,
		$dialog_y + 1,
		$dialog_x + 3,
		'LOG mappa: ' . $directory,
		$dialog_width - 6
	);

	my $list_top = $dialog_y + 3;
	my $list_rows = $dialog_height - 7;

	if (@file_dialog_files)
	{
		if ($file_dialog_selected < $file_dialog_scroll)
		{
			$file_dialog_scroll = $file_dialog_selected;
		}

		if ($file_dialog_selected
			>= $file_dialog_scroll + $list_rows)
		{
			$file_dialog_scroll =
				$file_dialog_selected - $list_rows + 1;
		}

		for (my $row = 0; $row < $list_rows; $row++)
		{
			my $index = $file_dialog_scroll + $row;
			last if $index >= @file_dialog_files;

			add_mouse_region(
				type  => 'file_item',
				index => $index,
				x1    => $dialog_x + 1,
				x2    => $dialog_x + $dialog_width - 2,
				y1    => $list_top + $row,
				y2    => $list_top + $row
			);

			my $marker =
				$index == $file_dialog_selected
				? '<| '
				: '   ';

			safe_addstr(
				$window,
				$list_top + $row,
				$dialog_x + 3,
				$marker . $file_dialog_files[$index]{name},
				$dialog_width - 8
			);

			if ($index == $file_dialog_selected)
			{
				safe_addstr(
					$window,
					$list_top + $row,
					$dialog_x + $dialog_width - 5,
					'|>',
					2
				);
			}
		}
	}
	else
	{
		safe_addstr(
			$window,
			$list_top,
			$dialog_x + 3,
			$file_dialog_error || 'Nincs választható fájl.',
			$dialog_width - 6
		);
	}

	my $position = @file_dialog_files
		? ($file_dialog_selected + 1)
			. ' / ' . scalar(@file_dialog_files)
		: '0 / 0';

	safe_addstr(
		$window,
		$dialog_y + 1,
		$dialog_x + $dialog_width - length($position) - 3,
		$position,
		length($position)
	);

	my $footer_y = $dialog_y + $dialog_height - 2;
	my $footer_x = $dialog_x + 3;
	my $prefix = 'Fel/Le: választás   PgUp/PgDn: görgetés   ';
	my $enter_text = 'Enter: megnyitás';
	my $escape_text = 'Esc: vissza';
	my $enter_x = $footer_x + length($prefix);
	my $escape_x = $enter_x + length($enter_text) + 3;

	safe_addstr(
		$window,
		$footer_y,
		$footer_x,
		$prefix . $enter_text . '   ' . $escape_text,
		$dialog_width - 6
	);

	add_mouse_region(
		type => 'file_enter',
		x1   => $enter_x,
		x2   => $enter_x + length($enter_text) - 1,
		y1   => $footer_y,
		y2   => $footer_y
	);

	add_mouse_region(
		type => 'file_escape',
		x1   => $escape_x,
		x2   => $escape_x + length($escape_text) - 1,
		y1   => $footer_y,
		y2   => $footer_y
	);

	return;
}

sub handle_file_dialog_key
{
	my ($key) = @_;

	return if !defined($file_dialog_kind);

	if ($key eq "\e")
	{
		close_file_dialog();
		$last_message = 'A fájlválasztó bezárva.';
		return;
	}

	return if !@file_dialog_files;

	if (key_is_code($key, KEY_UP))
	{
		$file_dialog_selected--;

		if ($file_dialog_selected < 0)
		{
			$file_dialog_selected = $#file_dialog_files;
		}

		return;
	}

	if (key_is_code($key, KEY_DOWN))
	{
		$file_dialog_selected++;

		if ($file_dialog_selected > $#file_dialog_files)
		{
			$file_dialog_selected = 0;
		}

		return;
	}

	if (key_is_code($key, KEY_PPAGE))
	{
		$file_dialog_selected -= 10;
		$file_dialog_selected = 0
			if $file_dialog_selected < 0;
		return;
	}

	if (key_is_code($key, KEY_NPAGE))
	{
		$file_dialog_selected += 10;
		$file_dialog_selected = $#file_dialog_files
			if $file_dialog_selected > $#file_dialog_files;
		return;
	}

	if (key_is_code($key, KEY_HOME))
	{
		$file_dialog_selected = 0;
		return;
	}

	if (key_is_code($key, KEY_END))
	{
		$file_dialog_selected = $#file_dialog_files;
		return;
	}

	if ($key eq "\n"
		|| $key eq "\r"
		|| key_is_code($key, 10)
		|| key_is_code($key, 13)
		|| key_is_code($key, KEY_ENTER))
	{
		my $file = $file_dialog_files[$file_dialog_selected];
		my $kind = $file_dialog_kind;

		if (ref($file) eq 'HASH'
			&& request_file_path(
				$kind,
				$file->{path},
				'tui_file_dialog'
			))
		{
			close_file_dialog();
		}

		return;
	}

	return;
}

sub draw_service_dialog
{
	my ($window, $screen_width, $screen_height, $service) = @_;
	my $state = $service_ui{$service};
	return if ref($state) ne 'HASH';

	my $dialog_width = 152;
	my $dialog_height = 20;

	$dialog_width = $screen_width - 8
		if $dialog_width > $screen_width - 8;

	$dialog_height = $screen_height - 8
		if $dialog_height > $screen_height - 8;

	$dialog_width = 20
		if $dialog_width < 20;

	$dialog_height = 10
		if $dialog_height < 10;

	my $dialog_x = int(($screen_width - $dialog_width) / 2);
	my $dialog_y = int(($screen_height - $dialog_height) / 2);

	clear_rect($window, $dialog_y, $dialog_x, $dialog_height, $dialog_width);
	draw_box(
		$window,
		$dialog_y,
		$dialog_x,
		$dialog_height,
		$dialog_width,
		service_label($service)
	);

	my $connection_text = $state->{connected}
		? 'Kapcsolat: AKTÍV'
		: $state->{pending}
			? 'Kapcsolat: VÁRAKOZÁS'
			: 'Kapcsolat: INAKTÍV';

	safe_addstr($window, $dialog_y + 1, $dialog_x + 3,
		$connection_text, $dialog_width - 6);

	my $content_top = $dialog_y + 2;
	my $content_rows = $dialog_height - 5;
	my @lines = @{$state->{lines}};

	# A sudo és más interaktív programok promptja gyakran nem zárul
	# sortöréssel. A még befejezetlen kimeneti töredéket is azonnal
	# megjelenítjük, ezért a jelszóbekérő sor ENTER előtt láthatóvá válik.
	for my $partial
	(
		$state->{output_buffer} // '',
		($state->{error_buffer} // '') ne ''
			? 'ERR: ' . $state->{error_buffer}
			: ''
	)
	{
		next if $partial eq '';
		$partial =~ s/[\r\n]+/ /g;
		push(@lines, $partial);
	}

	if (!@lines && ($state->{status} // '') ne '')
	{
		@lines = ($state->{status});
	}

	my $start = @lines > $content_rows
		? @lines - $content_rows
		: 0;

	for (my $row = 0; $row < $content_rows; $row++)
	{
		my $index = $start + $row;
		last if $index >= @lines;
		safe_addstr($window, $content_top + $row, $dialog_x + 3,
			$lines[$index], $dialog_width - 6);
	}

	my $control_y = $dialog_y + $dialog_height - 2;
	my $control_x = $dialog_x + 3;
	my $end_text = 'END: bezárás';
	my $home_text = 'HOME: ledobás';
	my $home_x = $control_x + length($end_text) + 4;

	safe_addstr(
		$window,
		$control_y,
		$control_x,
		$end_text . '    ' . $home_text,
		$dialog_width - 6
	);

	add_mouse_region(
		type => 'service_end',
		x1   => $control_x,
		x2   => $control_x + length($end_text) - 1,
		y1   => $control_y,
		y2   => $control_y
	);

	add_mouse_region(
		type => 'service_home',
		x1   => $home_x,
		x2   => $home_x + length($home_text) - 1,
		y1   => $control_y,
		y2   => $control_y
	);
}

sub printable_key_character
{
	my ($key) = @_;

	return undef if !defined($key) || ref($key);

	# Egyes Curses/Perl kombinációk a normál billentyűt egykarakteres
	# szövegként, mások annak numerikus ASCII-kódjaként adják vissza.
	return $key if length($key) == 1 && $key !~ /^\d+$/;

	if ($key =~ /^\d+$/)
	{
		my $code = int($key);
		return chr($code) if $code >= 32 && $code <= 126;
	}

	return $key if length($key) == 1;
	return undef;
}

sub handle_service_dialog_key
{
	my ($key) = @_;
	return if !defined($service_dialog);

	if (key_is_code($key, KEY_END))
	{
		disconnect_service($service_dialog, 1);
		$last_message = 'A szolgáltatás kapcsolata megszakítva.';
		return;
	}

	if (key_is_code($key, KEY_HOME))
	{
		$service_ui{$service_dialog}{dialog_visible} = 0;
		$service_dialog = undef;
		$last_message = 'A szolgáltatás ablaka elrejtve; a kapcsolat megmaradt.';
		return;
	}

	my $state = $service_ui{$service_dialog};
	return if !$state->{connected} || !$state->{input};

	my $text;
	my $character = printable_key_character($key);

	# Nyitott szolgáltatásablaknál minden nyomtatható karakter – köztük
	# a 0–9 számjegyek is – a közvetlen MAIN csatornára kerül. Itt nincs
	# menü-gyorsbillentyű értelmezés.
	if (defined($character))
	{
		if ($character eq "\n" || $character eq "\r")
		{
			$text = "\n";
		}
		elsif (ord($character) == 8 || ord($character) == 127)
		{
			$text = "\x7f";
		}
		else
		{
			$text = $character;
		}
	}
	elsif (key_is_code($key, KEY_ENTER)
		|| key_is_code($key, 10)
		|| key_is_code($key, 13))
	{
		$text = "\n";
	}
	elsif (key_is_code($key, KEY_BACKSPACE)
		|| key_is_code($key, 127)
		|| key_is_code($key, 8))
	{
		$text = "\x7f";
	}
	elsif (defined($key) && !ref($key) && $key =~ /^-?\d+$/
		&& int($key) >= 32 && int($key) <= 126)
	{
		# Egyes Curses-változatok a nyomtatható ASCII-karaktert valódi
		# numerikus kódként adják vissza. Ez a tartalék ág ezeket kezeli.
		$text = chr(int($key));
	}
	elsif (defined($key) && !ref($key) && $key !~ /^-?\d+$/)
	{
		$text = $key;
	}

	if (defined($text))
	{
		eval
		{
			print {$state->{input}} $text;
		};

		if ($@)
		{
			$state->{status} = 'A szolgáltatás bemenete bezárult.';
			close_service_handles($service_dialog);
		}
	}
}

sub draw_screen
{
	my ($window) = @_;

	my ($height, $width);
	$window->getmaxyx($height, $width);

	if ($force_full_redraw)
	{
		eval
		{
			# clearok() érvényteleníti az ncurses fizikai
			# képernyőmásolatát, touchwin() pedig minden sort
			# újrarajzolandónak jelöl.
			clearok($window, 1);
			touchwin($window);
			$window->clear();
		};

		$force_full_redraw = 0;
	}

	$window->erase();
	clear_mouse_regions();

	if ($width < $MIN_WIDTH || $height < $MIN_HEIGHT)
	{
		safe_addstr(
			$window,
			0,
			0,
			'A terminál túl kicsi az RS41 TUI megjelenítéséhez.',
			$width
		);

		safe_addstr(
			$window,
			1,
			0,
			"Aktuális méret: ${width} x ${height}",
			$width
		);

		safe_addstr(
			$window,
			2,
			0,
			"Minimális méret: ${MIN_WIDTH} x ${MIN_HEIGHT}",
			$width
		);

		safe_addstr($window, 4, 0, 'q = kilépés', $width);

		$window->refresh();
		return;
	}

	draw_box($window, 0, 0, 3, $width, 'MENÜ');
	draw_menu($window, $width);

	draw_base_panel($window, $width, $width, $height);
	draw_settings_panel($window, $width);
	draw_statistics_panel($window, $width);
	draw_data_table($window, $width);
	draw_diagnostics($window, $width, $height);

	if (defined($file_dialog_kind))
	{
		draw_file_dialog($window, $width, $height);
	}
	elsif ($ui_mode eq 'SETTINGS')
	{
		draw_settings_dialog($window, $width, $height);
	}
	elsif (defined($service_dialog)
		&& $service_ui{$service_dialog}{dialog_visible})
	{
		draw_service_dialog($window, $width, $height, $service_dialog);
	}

	$window->refresh();
}

my $window;


eval
{
	open($main_input, '<&', \*STDIN)
		or die "A main bemeneti csatornája nem másolható: $!";
	open($main_output, '>&', \*STDOUT)
		or die "A main kimeneti csatornája nem másolható: $!";

	binmode($main_input, ':raw');
	binmode($main_output, ':raw');
	$main_output->autoflush(1);

	open(STDIN, '<', '/dev/tty')
		or die "A /dev/tty nem nyitható meg olvasásra: $!";
	open(STDOUT, '>', '/dev/tty')
		or die "A /dev/tty nem nyitható meg írásra: $!";

	binmode(STDOUT, ':encoding(UTF-8)');
	STDOUT->autoflush(1);

	my $flags = fcntl($main_input, F_GETFL, 0);
	fcntl($main_input, F_SETFL, $flags | O_NONBLOCK);

	$window = initscr();

	cbreak();
	noecho();
	curs_set(0);

	$window->keypad(1);
	$window->timeout(100);

	my $old_mouse_mask = 0;

	$mouse_enabled = eval
	{
		mousemask(
			BUTTON1_CLICKED | BUTTON1_DOUBLE_CLICKED,
			$old_mouse_mask
		);
		mouseinterval(200);
		1;
	} ? 1 : 0;

	send_main({type => 'frontend_ready', frontend => 'tui'});
	draw_screen($window);

	while ($running)
	{
		my $key = $window->getch();

		read_main_messages();
		poll_service_connections();

		if ($force_full_redraw && $running)
		{
			draw_screen($window);
		}

		if (!defined($key) || key_is_code($key, ERR))
		{
			draw_screen($window) if $running;
			next;
		}

		if ($mouse_enabled && key_is_code($key, KEY_MOUSE))
		{
			handle_mouse_event();
			draw_screen($window) if $running;
			next;
		}

		if (defined($file_dialog_kind))
		{
			handle_file_dialog_key($key);
			draw_screen($window) if $running;
			next;
		}

		if (defined($service_dialog)
			&& $service_ui{$service_dialog}{dialog_visible})
		{
			handle_service_dialog_key($key);
			draw_screen($window) if $running;
			next;
		}

		if ($ui_mode eq 'SETTINGS')
		{
			handle_settings_key($key);
			draw_screen($window) if $running;
			next;
		}

		my $menu_character = printable_key_character($key);

		if (defined($menu_character) && $menu_character eq ' ')
		{
			activate_menu($selected_menu);
		}
		elsif ((defined($menu_character) && ($menu_character eq "\n" || $menu_character eq "\r"))
			|| key_is_code($key, KEY_ENTER))
		{
			activate_menu($selected_menu);
		}
		elsif (defined($menu_character)
			&& $menu_character =~ /^(?:[1-8qQ])$/)
		{
			select_menu_by_key($menu_character);
		}
		elsif (key_is_code($key, KEY_LEFT))
		{
			$selected_menu--;

			if ($selected_menu < 0)
			{
				$selected_menu = $#menu_items;
			}
		}
		elsif (key_is_code($key, KEY_RIGHT))
		{
			$selected_menu++;

			if ($selected_menu > $#menu_items)
			{
				$selected_menu = 0;
			}
		}
		elsif (
			key_is_code($key, 10)
			|| key_is_code($key, 13)
			|| key_is_code($key, KEY_ENTER)
		)
		{
			activate_menu($selected_menu);
		}
		elsif (key_is_code($key, KEY_RESIZE))
		{
			$last_message = 'A terminál mérete megváltozott.';
		}

		draw_screen($window) if $running;
	}
};

my $error = $@;

for my $service (qw(bt sondehub))
{
	disconnect_service($service, 0);
}

endwin();

if ($error)
{
	die "RS41 TUI hiba: $error";
}

print "Az RS41 TUI kilépett.\n";
