#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use feature qw(say);
use FindBin qw($Bin);
use File::Spec;
use POSIX qw(strftime WNOHANG);
use Math::Trig qw(deg2rad rad2deg);
use List::Util qw(min max);
use JSON::PP;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Handle;
use Socket qw(AF_UNIX SOCK_DGRAM PF_UNSPEC);
use IO::Select;
use IPC::Open3;
use Symbol qw(gensym);
use Glib qw(TRUE FALSE);
use Gtk3 '-init';
use Gtk3::WebKit2;

$| = 1;

my $APP_TITLE = 'RS41 vevő GUI v0.1.31';
my $configfile = File::Spec->catfile($Bin, 'config.txt');
my %config_cache;
my $config_loaded = 0;
my $BASE_SHARE_INTERVAL_S = 5;
my $BT_UI_INTERVAL_MS = 250;
my @decoder_candidates = (
	File::Spec->catfile($Bin, 'rs41_raw_decode_fixed_fields.pl'),
	File::Spec->catfile($Bin, 'rs41_raw_decode_fixed.pl'),
	File::Spec->catfile($Bin, 'rs41_raw_decode.pl'),
);
my ($decoder_path) = grep { -f $_ } @decoder_candidates;
$decoder_path //= $decoder_candidates[0];
my $filter_path = File::Spec->catfile($Bin, 'rs41_filter_stream.py');
my $bt_bridge_path = File::Spec->catfile($Bin, 'gps_bridge_bt.pl');
my @sondehub_candidates = (
	File::Spec->catfile($Bin, 'sondehub_upload_v9.pl'),
	File::Spec->catfile($Bin, 'sondehub_upload.pl'),
);
my ($sondehub_path) = grep { -f $_ } @sondehub_candidates;
$sondehub_path //= $sondehub_candidates[0];
my $configured_log_dir = load_config('LOG_DIRECTORY', './log');
my $work_dir = File::Spec->rel2abs($configured_log_dir, $Bin);
$work_dir = File::Spec->rel2abs('.', $Bin) if !-d $work_dir;

my $processor_pid;
my $processor_out;
my $processor_watch;
my $read_buffer = '';
my $recorder_pid;
my $current_mode = 'idle';
my $current_wav;
my $current_description = '';
my $current_rlog;
my $current_jlog;
my $restart_pending = 0;
my $bt_pid;
my $bt_out;
my $bt_watch;
my $bt_process_poll;
my $bt_read_buffer = '';
my $bt_latest_json_line;
my $bt_flush_timer;
my $bt_last_lat;
my $bt_last_lon;
my $bt_last_alt;
my $bt_last_angle;
my $bt_internal_toggle = 0;
my $sondehub_relay_pid;
my $sondehub_sock;
my $sondehub_process_poll;
my $sondehub_internal_toggle = 0;
my $sondehub_send_error_reported = 0;
my $last_base_share_epoch;
my $json = JSON::PP->new->canonical(1)->allow_nonref(1);

my %entry;
my %output_entry;
my $invert_check;
my $share_check;
my $mobile_check;
my $center_check;
my $last_receiver_data;
my ($window, $webview, $folder_button, $refresh_button, $record_button, $open_button, $raw_open_button, $json_open_button, $stop_button, $bt_button, $sondehub_button, $status_label);
my ($notebook, $prc_view, $prc_buffer, $json_view, $json_buffer, $save_filter_button, $packet_counter_label);
my %packet_count = (VALID => 0, PARTIAL => 0, INVALID => 0);
my $last_valid_epoch;
my $last_success_age_enabled = 0;
my $total_path_m = 0.0;
my $previous_track_position;
my $peak_altitude_m;
my $peak_altitude_time = '?';
my @track_history;

build_gui();
load_html();
Gtk3->main();

sub build_gui
{
	$window = Gtk3::Window->new('toplevel');
	$window->set_title($APP_TITLE);
	$window->set_default_size(1280, 900);
	$window->signal_connect(delete_event => sub
	{
		stop_pipeline();
		stop_bt_connection();
		stop_sondehub_connection();
		Gtk3->main_quit();
		return FALSE;
	});

	my $root = Gtk3::Box->new('vertical', 2);
	$window->add($root);

	$root->pack_start(wrap_horizontal_bar(build_file_bar()), FALSE, FALSE, 0);
	$root->pack_start(wrap_horizontal_bar(build_base_bar()), FALSE, FALSE, 0);
	$root->pack_start(wrap_horizontal_bar(build_filter_bar()), FALSE, FALSE, 0);

	my $pane = Gtk3::Paned->new('vertical');
	$root->pack_start($pane, TRUE, TRUE, 0);

	$webview = Gtk3::WebKit2::WebView->new();
	$pane->pack1($webview, TRUE, TRUE);

	$notebook = Gtk3::Notebook->new();
	$notebook->set_tab_pos('bottom');

	($prc_view, $prc_buffer) = create_log_view();
	my $prc_scroll = Gtk3::ScrolledWindow->new();
	$prc_scroll->set_policy('automatic', 'automatic');
	$prc_scroll->add($prc_view);
	$notebook->append_page($prc_scroll, Gtk3::Label->new('PRC'));

	($json_view, $json_buffer) = create_log_view();
	my $json_scroll = Gtk3::ScrolledWindow->new();
	$json_scroll->set_policy('automatic', 'automatic');
	$json_scroll->add($json_view);
	$notebook->append_page($json_scroll, Gtk3::Label->new('JSON'));

	$notebook->set_current_page(0);
	$notebook->set_size_request(-1, 1);
	$pane->pack2($notebook, TRUE, TRUE);
	$pane->set_position(630);

	$window->show_all();
	set_running_state(FALSE);
	Glib::Timeout->add(1000, sub
	{
		refresh_runtime_statistics();
		maybe_send_base_to_sondehub(FALSE);
		return TRUE;
	});
}


sub wrap_horizontal_bar
{
	my ($bar) = @_;
	my $scroll = Gtk3::ScrolledWindow->new();
	$scroll->set_policy('automatic', 'never');
	$scroll->set_shadow_type('none');
	$scroll->set_min_content_height(34);
	$scroll->add_with_viewport($bar);
	return $scroll;
}

sub build_file_bar
{
	my $bar = Gtk3::Box->new('horizontal', 5);
	$bar->set_border_width(3);

	$record_button = Gtk3::Button->new_with_label('Felvétel indítása');
	$open_button = Gtk3::Button->new_with_label('WAV megnyitása');
	$raw_open_button = Gtk3::Button->new_with_label('RAW megnyitás');
	$json_open_button = Gtk3::Button->new_with_label('JSON megnyitás');
	$stop_button = Gtk3::Button->new_with_label('Leállítás');
	$bt_button = Gtk3::ToggleButton->new_with_label('BT kapcsolat');
	$bt_button->set_tooltip_text('A telefonos GPS/iránytű kapcsolat indítása vagy leállítása.');
	$sondehub_button = Gtk3::ToggleButton->new_with_label('sondeHUB');
	$sondehub_button->set_tooltip_text('A külön terminálban futó SondeHUB feltöltő indítása vagy leállítása.');
	$folder_button = Gtk3::Button->new_with_label($work_dir);
	$refresh_button = Gtk3::Button->new_with_label('Frissítés');
	$status_label = Gtk3::Label->new('Állapot: áll');

	$record_button->signal_connect(clicked => sub { start_recording(); });
	$open_button->signal_connect(clicked => sub { choose_and_play_wav(); });
	$raw_open_button->signal_connect(clicked => sub { choose_and_play_raw(); });
	$json_open_button->signal_connect(clicked => sub { choose_and_play_json(); });
	$stop_button->signal_connect(clicked => sub { stop_pipeline(); });
	$bt_button->signal_connect(toggled => sub
	{
		return if $bt_internal_toggle;
		if ($bt_button->get_active())
		{
			start_bt_connection();
		}
		else
		{
			set_bt_button_active(TRUE) if defined $bt_pid;
			stop_bt_connection();
		}
	});
	$sondehub_button->signal_connect(toggled => sub
	{
		return if $sondehub_internal_toggle;
		if ($sondehub_button->get_active())
		{
			start_sondehub_connection();
		}
		else
		{
			set_sondehub_button_active(TRUE) if defined $sondehub_relay_pid;
			stop_sondehub_connection();
		}
	});
	$folder_button->signal_connect(clicked => sub { choose_work_dir(); });
	$refresh_button->signal_connect(clicked => sub { load_html(); });

	$bar->pack_start($record_button, FALSE, FALSE, 0);
	$bar->pack_start($open_button, FALSE, FALSE, 0);
	$bar->pack_start($raw_open_button, FALSE, FALSE, 0);
	$bar->pack_start($json_open_button, FALSE, FALSE, 0);
	$bar->pack_start($stop_button, FALSE, FALSE, 0);
	$bar->pack_start($bt_button, FALSE, FALSE, 0);
	$bar->pack_start($sondehub_button, FALSE, FALSE, 0);
	$bar->pack_start(Gtk3::Label->new('Mappa:'), FALSE, FALSE, 3);
	$bar->pack_start($folder_button, TRUE, TRUE, 0);
	$bar->pack_start($refresh_button, FALSE, FALSE, 3);
	$bar->pack_end($status_label, FALSE, FALSE, 6);

	return $bar;
}

sub build_base_bar
{
	my $bar = Gtk3::Box->new('horizontal', 5);
	$bar->set_border_width(3);

	$bar->pack_start(Gtk3::Label->new('Bázis:'), FALSE, FALSE, 2);
	add_labeled_entry($bar, 'Szélesség', 'base_lat', load_config('BASE_LAT', '47.49786'), 10);
	add_labeled_entry($bar, 'Hosszúság', 'base_lon', load_config('BASE_LON', '19.04022'), 10);
	add_labeled_entry($bar, 'Magasság', 'base_alt', load_config('BASE_ALT', '110'), 8);
	add_labeled_entry($bar, 'Szög', 'base_angle', load_config('BASE_ANGLE', '0'), 7);

	my $apply = Gtk3::Button->new_with_label('Alkalmaz');
	$apply->signal_connect(clicked => sub { update_base_marker(); });
	$bar->pack_start($apply, FALSE, FALSE, 4);

	add_labeled_entry(
		$bar,
		'Frekvencia MHz',
		'frequency',
		load_config('SONDEHUB_FREQUENCY_MHZ', '400.000'),
		8,
	);

	$share_check = Gtk3::CheckButton->new_with_label('Megosztás');
	$share_check->set_active(FALSE);
	$share_check->set_tooltip_text('Bekapcsolva a bázispozíció külön listener adatként kerül a SondeHubra.');
	$share_check->signal_connect(toggled => sub
	{
		$last_base_share_epoch = undef;
		if ($share_check->get_active())
		{
			append_prc("Bázispozíció megosztása bekapcsolva.\n");
			if (defined $sondehub_sock)
			{
				maybe_send_base_to_sondehub(TRUE);
			}
			else
			{
				append_prc("A bázisadat a SondeHUB kapcsolat bekapcsolásakor lesz elküldve.\n");
			}
		}
		else
		{
			append_prc("Bázispozíció megosztása kikapcsolva.\n");
		}
	});
	$bar->pack_start($share_check, FALSE, FALSE, 4);

	$mobile_check = Gtk3::CheckButton->new_with_label('Mobil');
	$mobile_check->set_active(FALSE);
	$mobile_check->set_tooltip_text('Bekapcsolva mobil chase-car, kikapcsolva fix állomásként küldi a bázist.');
	$mobile_check->signal_connect(toggled => sub
	{
		append_prc(
			$mobile_check->get_active()
				? "Bázistípus: mobil.\n"
				: "Bázistípus: fix.\n"
		);
		maybe_send_base_to_sondehub(TRUE)
			if defined $share_check
			&& $share_check->get_active()
			&& defined $sondehub_sock;
	});
	$bar->pack_start($mobile_check, FALSE, FALSE, 4);

	$center_check = Gtk3::CheckButton->new_with_label('Középre');
	$center_check->set_active(TRUE);
	$center_check->set_tooltip_text('Bekapcsolva a térkép mindig a szonda aktuális pozícióját követi.');
	$center_check->signal_connect(toggled => sub
	{
		my $enabled = $center_check->get_active() ? 'true' : 'false';
		run_js('window.setFollowSonde(' . $enabled . ');');
	});
	$bar->pack_start($center_check, FALSE, FALSE, 4);

	add_output_entry($bar, 'Távolság', 'distance', '?', 10);
	add_output_entry($bar, 'Irány', 'bearing', '?', 8);
	add_output_entry($bar, 'Szög', 'elevation', '?', 8);

	return $bar;
}

sub build_filter_bar
{
	my $bar = Gtk3::Box->new('horizontal', 5);
	$bar->set_border_width(3);

	$bar->pack_start(Gtk3::Label->new('Feldolgozás:'), FALSE, FALSE, 2);
	add_labeled_entry($bar, 'Eszköz', 'device', load_config('AUDIO_DEVICE', 'default'), 10);
	add_labeled_entry($bar, 'Hz', 'sample_rate', load_config('AUDIO_SAMPLE_RATE', '48000'), 7);
	add_labeled_entry($bar, 'LF', 'lf', load_config('AUDIO_LF', '525'), 6);
	add_labeled_entry($bar, 'HF', 'hf', load_config('AUDIO_HF', '14000'), 6);
	add_labeled_entry($bar, 'O', 'order', load_config('AUDIO_ORDER', '1'), 4);
	add_labeled_entry($bar, 'P', 'peak', load_config('AUDIO_PEAK', '0.75'), 5);
	add_labeled_entry($bar, 'D', 'delay', load_config('AUDIO_DELAY', '0.1'), 5);

	$invert_check = Gtk3::CheckButton->new_with_label('Invertált');
	$invert_check->set_active(config_boolean('AUDIO_INVERT', 1) ? TRUE : FALSE);
	$invert_check->set_tooltip_text('Bekapcsolva az rs41_mod -i kapcsolóval dolgozik; kikapcsolva nem invertált jelet vár.');
	$bar->pack_start($invert_check, FALSE, FALSE, 6);

	$save_filter_button = Gtk3::Button->new_with_label('Mentés');
	$save_filter_button->set_tooltip_text('Az új feldolgozási beállítások alkalmazása és a feldolgozás újraindítása.');
	$save_filter_button->signal_connect(clicked => sub { apply_processing_settings(); });
	$bar->pack_start($save_filter_button, FALSE, FALSE, 4);

	$packet_counter_label = Gtk3::Label->new('VALID: 0 / PARTIAL: 0 / INVALID: 0');
	$packet_counter_label->set_selectable(FALSE);
	$packet_counter_label->set_tooltip_text('Az aktuális feldolgozási munkamenet dekódolt csomagjainak száma.');
	$bar->pack_start($packet_counter_label, FALSE, FALSE, 8);

	return $bar;
}

sub add_labeled_entry
{
	my ($box, $label, $name, $value, $width) = @_;
	$box->pack_start(Gtk3::Label->new($label . ':'), FALSE, FALSE, 0);
	my $e = Gtk3::Entry->new();
	$e->set_text($value);
	$e->set_width_chars($width);
	$entry{$name} = $e;
	$box->pack_start($e, FALSE, FALSE, 0);
}


sub add_output_entry
{
	my ($box, $label, $name, $value, $width) = @_;
	$box->pack_start(Gtk3::Label->new($label . ':'), FALSE, FALSE, 0);
	my $e = Gtk3::Entry->new();
	$e->set_text($value);
	$e->set_width_chars($width);
	$e->set_editable(FALSE);
	$e->set_can_focus(FALSE);
	$output_entry{$name} = $e;
	$box->pack_start($e, FALSE, FALSE, 0);
}

sub choose_work_dir
{
	my $dialog = Gtk3::FileChooserDialog->new(
		'Munkamappa kiválasztása',
		$window,
		'select-folder',
		'gtk-cancel' => 'cancel',
		'gtk-open' => 'accept',
	);
	$dialog->set_current_folder($work_dir) if -d $work_dir;

	if ($dialog->run() eq 'accept')
	{
		my $selected = $dialog->get_filename();
		if (defined $selected && -d $selected)
		{
			$work_dir = $selected;
			$folder_button->set_label($work_dir);
		}
	}
	$dialog->destroy();
}

sub choose_and_play_wav
{
	return if pipeline_running();

	my $dialog = Gtk3::FileChooserDialog->new(
		'WAV fájl megnyitása',
		$window,
		'open',
		'gtk-cancel' => 'cancel',
		'gtk-open' => 'accept',
	);
	$dialog->set_current_folder($work_dir) if -d $work_dir;

	my $filter = Gtk3::FileFilter->new();
	$filter->set_name('WAV hangfájlok');
	$filter->add_pattern('*.wav');
	$filter->add_pattern('*.WAV');
	$dialog->add_filter($filter);

	if ($dialog->run() eq 'accept')
	{
		my $wav = $dialog->get_filename();
		$dialog->destroy();
		start_playback($wav) if defined $wav;
		return;
	}
	$dialog->destroy();
}

sub choose_and_play_raw
{
	return if pipeline_running();

	my $dialog = Gtk3::FileChooserDialog->new(
		'RAW fájl megnyitása',
		$window,
		'open',
		'gtk-cancel' => 'cancel',
		'gtk-open' => 'accept',
	);
	$dialog->set_current_folder($work_dir) if -d $work_dir;

	my $filter = Gtk3::FileFilter->new();
	$filter->set_name('RS41 RAW naplók');
	$filter->add_pattern('*.Rlog');
	$filter->add_pattern('*.rlog');
	$filter->add_pattern('*.raw');
	$filter->add_pattern('*.RAW');
	$filter->add_pattern('*.txt');
	$dialog->add_filter($filter);

	if ($dialog->run() eq 'accept')
	{
		my $raw = $dialog->get_filename();
		$dialog->destroy();
		start_raw_playback($raw) if defined $raw;
		return;
	}
	$dialog->destroy();
}

sub choose_and_play_json
{
	return if pipeline_running();

	my $dialog = Gtk3::FileChooserDialog->new(
		'JSON fájl megnyitása',
		$window,
		'open',
		'gtk-cancel' => 'cancel',
		'gtk-open' => 'accept',
	);
	$dialog->set_current_folder($work_dir) if -d $work_dir;

	my $filter = Gtk3::FileFilter->new();
	$filter->set_name('RS41 JSON naplók');
	$filter->add_pattern('*.Jlog');
	$filter->add_pattern('*.jlog');
	$filter->add_pattern('*.json');
	$filter->add_pattern('*.JSON');
	$filter->add_pattern('*.txt');
	$dialog->add_filter($filter);

	if ($dialog->run() eq 'accept')
	{
		my $json_file = $dialog->get_filename();
		$dialog->destroy();
		start_json_playback($json_file) if defined $json_file;
		return;
	}
	$dialog->destroy();
}

sub start_bt_connection
{
	return if defined $bt_pid;

	if (!-f $bt_bridge_path)
	{
		append_prc("HIBA: a BT GPS bridge nem található: $bt_bridge_path\n");
		set_bt_button_active(FALSE);
		return;
	}

	append_prc("BT kapcsolat indítása: $bt_bridge_path\n");

	my $stderr = gensym();
	my $stdin;
	my $pid;
	eval
	{
		my $wrapped_command = shell_quote($bt_bridge_path) . ' 2>&1';
		$pid = open3($stdin, $bt_out, $stderr, 'setsid', 'sh', '-c', $wrapped_command);
	};
	if ($@)
	{
		append_prc("HIBA: a BT kapcsolat nem indítható: $@\n");
		set_bt_button_active(FALSE);
		return;
	}

	close $stdin if defined $stdin;
	close $stderr;
	$bt_pid = $pid;
	$bt_read_buffer = '';
	$bt_latest_json_line = undef;
	$bt_last_lat = numeric_or_null($entry{base_lat}->get_text());
	$bt_last_lon = numeric_or_null($entry{base_lon}->get_text());
	$bt_last_alt = numeric_or_null($entry{base_alt}->get_text());
	$bt_last_angle = numeric_or_null($entry{base_angle}->get_text());
	set_nonblocking($bt_out);
	$bt_watch = Glib::IO->add_watch(
		fileno($bt_out),
		['in', 'hup', 'err'],
		sub { return read_bt_output(); },
	);
	set_bt_button_active(TRUE);
	$bt_flush_timer = Glib::Timeout->add($BT_UI_INTERVAL_MS, sub
	{
		return FALSE if !defined $bt_pid;
		if (defined $bt_latest_json_line)
		{
			my $line = $bt_latest_json_line;
			$bt_latest_json_line = undef;
			handle_bt_line($line);
		}
		return TRUE;
	});
	$bt_process_poll = Glib::Timeout->add(250, sub
	{
		return FALSE if !defined $bt_pid;
		my $result = waitpid($bt_pid, WNOHANG);
		if ($result == $bt_pid)
		{
			finish_bt_connection();
			return FALSE;
		}
		return TRUE;
	});
}

sub read_bt_output
{
	my $saw_eof = 0;

	while (1)
	{
		my $chunk = '';
		my $count = sysread($bt_out, $chunk, 65536);

		if (defined $count && $count > 0)
		{
			$bt_read_buffer .= $chunk;
			while ($bt_read_buffer =~ s/^(.*?\n)//s)
			{
				queue_bt_line($1);
			}

			if (length($bt_read_buffer) > 1048576)
			{
				$bt_read_buffer = substr($bt_read_buffer, -65536);
			}
			next;
		}

		if (defined $count && $count == 0)
		{
			$saw_eof = 1;
			last;
		}

		last if $!{EAGAIN} || $!{EWOULDBLOCK};
		append_prc("HIBA: BT kapcsolat olvasási hiba: $!\n");
		finish_bt_connection();
		return FALSE;
	}

	if ($saw_eof)
	{
		queue_bt_line($bt_read_buffer) if length $bt_read_buffer;
		$bt_read_buffer = '';
		if (defined $bt_latest_json_line)
		{
			handle_bt_line($bt_latest_json_line);
			$bt_latest_json_line = undef;
		}
		finish_bt_connection();
		return FALSE;
	}

	return TRUE;
}

sub queue_bt_line
{
	my ($line) = @_;
	my $candidate = $line;
	$candidate =~ s/^\s+|\s+$//g;
	return if $candidate eq '';

	if ($candidate =~ /^\{.*\}$/s)
	{
		$bt_latest_json_line = $candidate;
		return;
	}

	append_prc("BT: $candidate\n");
}

sub handle_bt_line
{
	my ($line) = @_;
	my $candidate = $line;
	$candidate =~ s/^\s+|\s+$//g;
	return if $candidate eq '';

	if ($candidate !~ /^\{.*\}$/s)
	{
		append_prc("BT: $candidate\n");
		return;
	}

	my $data = eval { $json->decode($candidate) };
	if ($@ || ref($data) ne 'HASH')
	{
		append_prc("BT: érvénytelen JSON: $candidate\n");
		return;
	}

	my $angle = defined $data->{heading_true}
		? $data->{heading_true}
		: defined $data->{heading_mag}
			? $data->{heading_mag}
			: $data->{course};

	$bt_last_lat = 0 + $data->{lat}
		if defined $data->{lat} && is_finite_number($data->{lat});
	$bt_last_lon = 0 + $data->{lon}
		if defined $data->{lon} && is_finite_number($data->{lon});
	$bt_last_alt = 0 + $data->{alt}
		if defined $data->{alt} && is_finite_number($data->{alt});
	$bt_last_angle = normalize_angle($angle)
		if defined $angle && is_finite_number($angle);

	return if !defined $bt_last_lat
		|| !defined $bt_last_lon
		|| !defined $bt_last_alt
		|| !defined $bt_last_angle;

	$entry{base_lat}->set_text(sprintf('%.8f', $bt_last_lat));
	$entry{base_lon}->set_text(sprintf('%.8f', $bt_last_lon));
	$entry{base_alt}->set_text(sprintf('%.2f', $bt_last_alt));
	$entry{base_angle}->set_text(sprintf('%.2f', $bt_last_angle));
	update_base_marker();
}

sub stop_bt_connection
{
	if (defined $bt_pid)
	{
		append_prc("BT kapcsolat leállítása...\n");
		kill 'TERM', -$bt_pid;
		Glib::Timeout->add(800, sub
		{
			kill 'KILL', -$bt_pid if defined $bt_pid && kill(0, $bt_pid);
			return FALSE;
		});
	}
	else
	{
		set_bt_button_active(FALSE);
	}
}

sub finish_bt_connection
{
	waitpid($bt_pid, WNOHANG) if defined $bt_pid;
	close $bt_out if defined $bt_out;
	$bt_pid = undef;
	$bt_out = undef;
	$bt_watch = undef;
	$bt_process_poll = undef;
	$bt_flush_timer = undef;
	$bt_read_buffer = '';
	$bt_latest_json_line = undef;
	$bt_last_lat = undef;
	$bt_last_lon = undef;
	$bt_last_alt = undef;
	$bt_last_angle = undef;
	set_bt_button_active(FALSE);
	append_prc("BT kapcsolat befejeződött.\n");
}

sub set_bt_button_active
{
	my ($active) = @_;
	return if !defined $bt_button;
	$bt_internal_toggle = 1;
	$bt_button->set_active($active ? TRUE : FALSE);
	$bt_internal_toggle = 0;
}


sub check_sondehub_uploader_protocol
{
	my $command = shell_quote($^X)
		. ' ' . shell_quote($sondehub_path)
		. ' --protocol-version 2>&1';
	my $output = `$command`;
	my $exit_code = $? >> 8;
	$output =~ s/^\s+|\s+$//g;

	return (1, '') if $exit_code == 0 && $output eq '2';

	my $detail = $output ne '' ? $output : "kilépési kód: $exit_code";
	return
	(
		0,
		"nem kompatibilis SondeHUB feltöltő: $sondehub_path; "
		. "a GUI JSON protokoll v2-t vár. A fájl válasza: $detail",
	);
}

sub start_sondehub_connection
{
	return if defined $sondehub_relay_pid;

	if (!-f $sondehub_path)
	{
		append_prc("HIBA: a SondeHUB feltöltő nem található: $sondehub_path\n");
		set_sondehub_button_active(FALSE);
		return;
	}

	my ($protocol_ok, $protocol_message) = check_sondehub_uploader_protocol();
	if (!$protocol_ok)
	{
		append_prc("HIBA: $protocol_message\n");
		set_sondehub_button_active(FALSE);
		return;
	}
	append_prc("SondeHUB feltöltő: $sondehub_path (JSON protokoll v2)\n");

	my ($gui_sock, $relay_sock);
	if (!socketpair($gui_sock, $relay_sock, AF_UNIX, SOCK_DGRAM, PF_UNSPEC))
	{
		append_prc("HIBA: a SondeHUB külön adatcsatornája nem hozható létre: $!\n");
		set_sondehub_button_active(FALSE);
		return;
	}

	my $log_path = File::Spec->catfile(
		'/tmp',
		sprintf('rs41_sondehub_%d_%d.log', $$, time()),
	);

	my $pid = fork();
	if (!defined $pid)
	{
		append_prc("HIBA: a SondeHUB reléfolyamat nem indítható: $!\n");
		close $gui_sock;
		close $relay_sock;
		set_sondehub_button_active(FALSE);
		return;
	}

	if ($pid == 0)
	{
		close $gui_sock;
		sondehub_relay_main($relay_sock, $log_path);
		POSIX::_exit(0);
	}

	close $relay_sock;
	$sondehub_relay_pid = $pid;
	$sondehub_sock = $gui_sock;
	set_nonblocking($sondehub_sock);
	$sondehub_send_error_reported = 0;
	set_sondehub_button_active(TRUE);
	append_prc("SondeHUB külön reléfolyamat elindult.\n");
	$last_base_share_epoch = undef;
	maybe_send_base_to_sondehub(TRUE);

	$sondehub_process_poll = Glib::Timeout->add(250, sub
	{
		return FALSE if !defined $sondehub_relay_pid;
		my $result = waitpid($sondehub_relay_pid, WNOHANG);
		if ($result == $sondehub_relay_pid)
		{
			finish_sondehub_connection();
			return FALSE;
		}
		return TRUE;
	});
}

sub sondehub_relay_main
{
	my ($relay_sock, $log_path) = @_;
	local $SIG{PIPE} = 'IGNORE';

	my $log_fh;
	if (!open($log_fh, '>', $log_path))
	{
		POSIX::_exit(121);
	}
	$log_fh->autoflush(1);

	my ($uploader_read, $uploader_write);
	if (!pipe($uploader_read, $uploader_write))
	{
		close $log_fh;
		POSIX::_exit(122);
	}

	my $uploader_pid = fork();
	if (!defined $uploader_pid)
	{
		close $uploader_read;
		close $uploader_write;
		close $log_fh;
		POSIX::_exit(123);
	}

	if ($uploader_pid == 0)
	{
		POSIX::setsid();
		close $relay_sock;
		close $uploader_write;
		open(STDIN, '<&', $uploader_read) or POSIX::_exit(124);
		open(STDOUT, '>&', $log_fh) or POSIX::_exit(125);
		open(STDERR, '>&', $log_fh) or POSIX::_exit(126);
		close $uploader_read;
		close $log_fh;
		chdir $Bin;
		exec($^X, $sondehub_path) or POSIX::_exit(127);
	}

	close $uploader_read;
	close $log_fh;
	$uploader_write->autoflush(1);

	my $terminal_pid = start_sondehub_log_terminal(
		$log_path,
		$relay_sock,
		$uploader_write,
		$uploader_pid,
	);

	my $selector = IO::Select->new($relay_sock);
	while (1)
	{
		if (defined $terminal_pid)
		{
			my $terminal_result = waitpid($terminal_pid, WNOHANG);
			last if $terminal_result == $terminal_pid;
		}

		my $uploader_result = waitpid($uploader_pid, WNOHANG);
		last if $uploader_result == $uploader_pid;

		my @ready = $selector->can_read(0.25);
		next if !@ready;

		my $message = '';
		my $received = recv($relay_sock, $message, 65535, 0);
		last if !defined $received;
		last if $message eq '__STOP__';
		next if $message eq '';

		my $offset = 0;
		while ($offset < length($message))
		{
			my $written = syswrite(
				$uploader_write,
				$message,
				length($message) - $offset,
				$offset,
			);
			last if !defined $written || $written <= 0;
			$offset += $written;
		}
		last if $offset < length($message);
	}

	close $uploader_write;
	close $relay_sock;

	kill 'TERM', -$uploader_pid if kill(0, $uploader_pid);
	waitpid($uploader_pid, 0);

	if (defined $terminal_pid)
	{
		for (1 .. 10)
		{
			my $result = waitpid($terminal_pid, WNOHANG);
			last if $result == $terminal_pid;
			select undef, undef, undef, 0.1;
		}
		if (kill(0, $terminal_pid))
		{
			kill 'TERM', -$terminal_pid;
			waitpid($terminal_pid, 0);
		}
	}

	unlink $log_path if -e $log_path;
}

sub start_sondehub_log_terminal
{
	my ($log_path, $relay_sock, $uploader_write, $uploader_pid) = @_;
	my $runner = 'tail --pid=' . int($uploader_pid)
		. ' -n +1 -f ' . shell_quote($log_path);
	my @terminal = terminal_command($runner);
	return undef if !@terminal;

	my $pid = fork();
	return undef if !defined $pid;

	if ($pid == 0)
	{
		POSIX::setsid();
		close $relay_sock;
		close $uploader_write;
		exec(@terminal) or POSIX::_exit(127);
	}

	return $pid;
}

sub terminal_command
{
	my ($runner) = @_;
	for my $candidate (
		['gnome-terminal', '--wait', '--', 'sh', '-lc', $runner],
		['xfce4-terminal', '--disable-server', '--command', 'sh -lc ' . shell_quote($runner)],
		['mate-terminal', '--disable-factory', '--', 'sh', '-lc', $runner],
		['xterm', '-T', 'SondeHUB feltöltő', '-e', 'sh', '-lc', $runner],
	)
	{
		my $program = $candidate->[0];
		my $found = `command -v ${program} 2>/dev/null`;
		chomp $found;
		return @$candidate if $found ne '';
	}
	return;
}

sub send_sondehub_message
{
	my ($payload) = @_;
	return 0 if !defined $sondehub_sock;

	my $line = $json->encode($payload) . "\n";
	my $sent = send($sondehub_sock, $line, 0);
	if (!defined $sent)
	{
		if ($!{EAGAIN} || $!{EWOULDBLOCK})
		{
			if (!$sondehub_send_error_reported)
			{
				append_prc("FIGYELEM: a SondeHUB küldési sor megtelt; egy csomag kimaradt.\n");
				$sondehub_send_error_reported = 1;
			}
			return 0;
		}

		append_prc("HIBA: a SondeHUB külön adatcsatornája megszakadt: $!\n");
		finish_sondehub_connection();
		return 0;
	}

	$sondehub_send_error_reported = 0;
	return 1;
}

sub send_sonde_to_sondehub
{
	my ($data) = @_;
	return if !defined $sondehub_sock;
	return if $current_mode ne 'record';
	return if ($data->{validity} // '') ne 'VALID';
	return if ref($data->{calibration}) ne 'HASH' || !$data->{calibration}{complete};
	return if ref($data->{ptu}) ne 'HASH' || !$data->{ptu}{calibration_ready};
	return if ref($data->{position}) ne 'HASH';
	return if ref($data->{gps_time}) ne 'HASH';

	my $frequency = numeric_or_null($entry{frequency}->get_text());
	$frequency = config_number('SONDEHUB_FREQUENCY_MHZ', 400.000)
		if !defined $frequency;

	my %payload =
	(
		message_type => 'sonde',
		serial => $data->{sonde_id},
		frame => $data->{frame_number},
		datetime => $data->{gps_time}{utc_uncorrected},
		lat => $data->{position}{latitude_deg},
		lon => $data->{position}{longitude_deg},
		alt => $data->{position}{altitude_m},
		frequency => $frequency,
		temp => $data->{ptu}{temperature_c},
		humidity => $data->{ptu}{relative_humidity_pct},
		pressure => $data->{ptu}{pressure_hpa},
		vel_h => $data->{position}{velocity_h_ms},
		vel_v => $data->{position}{velocity_v_ms},
		heading => $data->{position}{heading_deg},
		sats => $data->{position}{satellites},
		batt => $data->{battery_v},
	);

	for my $name (qw(serial frame datetime lat lon alt frequency temp humidity pressure vel_h vel_v heading sats batt))
	{
		return if !defined $payload{$name};
	}

	my $base_lat = numeric_or_null($entry{base_lat}->get_text());
	my $base_lon = numeric_or_null($entry{base_lon}->get_text());
	my $base_alt = numeric_or_null($entry{base_alt}->get_text());
	if (defined $base_lat && defined $base_lon && defined $base_alt)
	{
		$payload{uploader_position} = [ $base_lat, $base_lon, $base_alt ];
	}

	send_sondehub_message(\%payload);
}

sub maybe_send_base_to_sondehub
{
	my ($force) = @_;
	return if !defined $sondehub_sock;
	return if !defined $share_check || !$share_check->get_active();

	my $now = time();
	if (!$force && defined $last_base_share_epoch)
	{
		return if $now - $last_base_share_epoch < $BASE_SHARE_INTERVAL_S;
	}

	my $lat = numeric_or_null($entry{base_lat}->get_text());
	my $lon = numeric_or_null($entry{base_lon}->get_text());
	my $alt = numeric_or_null($entry{base_alt}->get_text());
	return if !defined $lat || !defined $lon || !defined $alt;

	my %payload =
	(
		message_type => 'base',
		lat => $lat,
		lon => $lon,
		alt => $alt,
		mobile => defined $mobile_check && $mobile_check->get_active()
			? JSON::PP::true
			: JSON::PP::false,
	);

	if (send_sondehub_message(\%payload))
	{
		$last_base_share_epoch = $now;
		append_prc(sprintf(
			"SondeHUB bázis JSON átadva: lat=%.8f lon=%.8f alt=%.2f mód=%s\n",
			$lat,
			$lon,
			$alt,
			$mobile_check->get_active() ? 'mobil' : 'fix',
		));
	}
}

sub stop_sondehub_connection
{
	if (defined $sondehub_sock)
	{
		send($sondehub_sock, '__STOP__', 0);
		close $sondehub_sock;
		$sondehub_sock = undef;
	}

	if (defined $sondehub_relay_pid)
	{
		Glib::Timeout->add(1000, sub
		{
			kill 'TERM', $sondehub_relay_pid
				if defined $sondehub_relay_pid && kill(0, $sondehub_relay_pid);
			return FALSE;
		});
	}
	else
	{
		set_sondehub_button_active(FALSE);
	}
}

sub finish_sondehub_connection
{
	close $sondehub_sock if defined $sondehub_sock;
	$sondehub_sock = undef;
	waitpid($sondehub_relay_pid, WNOHANG) if defined $sondehub_relay_pid;
	$sondehub_relay_pid = undef;
	$sondehub_process_poll = undef;
	$sondehub_send_error_reported = 0;
	$last_base_share_epoch = undef;
	set_sondehub_button_active(FALSE);
	append_prc("SondeHUB kapcsolat befejeződött.\n");
}

sub set_sondehub_button_active
{
	my ($active) = @_;
	return if !defined $sondehub_button;
	$sondehub_internal_toggle = 1;
	$sondehub_button->set_active($active ? TRUE : FALSE);
	$sondehub_internal_toggle = 0;
}

sub is_finite_number
{
	my ($value) = @_;
	return 0 if ref($value);
	return 0 if $value !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
	return 1;
}

sub normalize_angle
{
	my ($angle) = @_;
	$angle %= 360.0;
	$angle += 360.0 if $angle < 0.0;
	return $angle;
}

sub start_recording
{
	return if session_running();

	if (!-d $work_dir)
	{
		append_prc("HIBA: a munkamappa nem létezik: $work_dir\n");
		return;
	}

	eval { validate_numeric_entries(); };
	if ($@)
	{
		append_prc("HIBA: $@");
		return;
	}

	my $base_name = 'rs41_' . strftime('%Y-%m-%d_%H-%M-%S', localtime());
	$current_wav = File::Spec->catfile($work_dir, $base_name . '.wav');
	$current_rlog = File::Spec->catfile($work_dir, $base_name . '.Rlog');
	$current_jlog = File::Spec->catfile($work_dir, $base_name . '.Jlog');
	$current_mode = 'record';
	$current_description = "Felvétel: $current_wav";
	reset_session_views();
	$last_success_age_enabled = 1;

	for my $log_path ($current_rlog, $current_jlog)
	{
		my $log_fh;
		if (!open($log_fh, '>', $log_path))
		{
			append_prc("HIBA: a naplófájl nem hozható létre: $log_path: $!\n");
			$current_mode = 'idle';
			return;
		}
		close $log_fh;
	}

	my $record_command = build_recorder_command($current_wav);
	append_prc("$current_description\n");
	append_prc("RÖGZÍTŐ ÉS HANGMONITOR: $record_command\n");
	append_prc("RAW napló: $current_rlog\nJSON napló: $current_jlog\n");

	my $pid = fork();
	if (!defined $pid)
	{
		append_prc("HIBA: a rögzítő nem indítható: $!\n");
		$current_mode = 'idle';
		return;
	}
	if ($pid == 0)
	{
		POSIX::setsid();
		exec('sh', '-c', $record_command) or POSIX::_exit(127);
	}
	$recorder_pid = $pid;

	start_processor(build_live_processing_command(), $current_description);
	set_running_state(TRUE, $current_description);
}

sub start_playback
{
	my ($wav) = @_;
	return if session_running();
	return if !defined $wav || !-f $wav;

	eval { validate_numeric_entries(); };
	if ($@)
	{
		append_prc("HIBA: $@");
		return;
	}

	$current_wav = $wav;
	$current_mode = 'playback';
	$current_description = "Lejátszás: $wav";
	reset_session_views();
	$last_success_age_enabled = 1;
	start_processor(build_play_command($wav), $current_description);
	set_running_state(TRUE, $current_description);
}

sub start_raw_playback
{
	my ($raw) = @_;
	return if session_running();
	return if !defined $raw || !-f $raw;

	$current_wav = $raw;
	$current_mode = 'raw_playback';
	$current_description = "RAW feldolgozás: $raw";
	reset_session_views();
	$last_success_age_enabled = 1;
	start_processor(build_raw_play_command($raw), $current_description);
	set_running_state(TRUE, $current_description);
}

sub start_json_playback
{
	my ($json_file) = @_;
	return if session_running();
	return if !defined $json_file || !-f $json_file;

	$current_wav = $json_file;
	$current_mode = 'json_playback';
	$current_description = "JSON beolvasás: $json_file";
	reset_session_views();
	$last_success_age_enabled = 1;
	start_processor(build_json_play_command($json_file), $current_description);
	set_running_state(TRUE, $current_description);
}

sub build_recorder_command
{
	my ($wav) = @_;
	return join(' ',
		'arecord',
		'-D', shell_quote($entry{device}->get_text()),
		'-t wav',
		'-f S16_LE',
		'-r', shell_quote($entry{sample_rate}->get_text()),
		'-c 1',
		'-q',
		'-',
		'|', 'tee', shell_quote($wav),
		'|', 'aplay', '-q',
	);
}

sub build_live_processing_command
{
	validate_numeric_entries();
	die "A RAW vagy JSON naplófájl útvonala nincs beállítva.\n"
		if !defined $current_rlog || !defined $current_jlog;

	return join(' ',
		'arecord',
		'-D', shell_quote($entry{device}->get_text()),
		'-t wav',
		'-f S16_LE',
		'-r', shell_quote($entry{sample_rate}->get_text()),
		'-c 1',
		'-q',
		'|', filter_command(),
		'|', rs41mod_command(),
		'|', 'tee', '-a', shell_quote($current_rlog),
		'|', shell_quote($decoder_path), '--json',
		'|', 'tee', '-a', shell_quote($current_jlog),
	);
}

sub build_play_command
{
	my ($wav) = @_;
	validate_numeric_entries();
	my $rate = shell_quote($entry{sample_rate}->get_text());

	return join(' ',
		'sox', shell_quote($wav),
		'-t wav',
		'-b 16',
		'-e signed-integer',
		'-c 1',
		'-r', $rate,
		'-',
		'|', filter_command(),
		'|', rs41mod_command(),
		'|', shell_quote($decoder_path), '--json',
	);
}

sub build_raw_play_command
{
	my ($raw) = @_;
	return join(' ',
		'cat', shell_quote($raw),
		'|', shell_quote($decoder_path), '--json',
		'|', shell_quote('./pipe_delay.pl'),
	);
}

sub build_json_play_command
{
	my ($json_file) = @_;
	return join(' ',
		'cat', shell_quote($json_file),
		'|', shell_quote('./pipe_delay.pl'),
	);
}

sub rs41mod_command
{
	my @command = ('./rs41_mod', '-vv', '-r');
	push @command, '-i' if defined $invert_check && $invert_check->get_active();
	push @command, '/dev/stdin';
	return join(' ', @command);
}

sub filter_command
{
	return join(' ',
		shell_quote($filter_path),
		'-LF', shell_quote($entry{lf}->get_text()),
		'-HF', shell_quote($entry{hf}->get_text()),
		'-O', shell_quote($entry{order}->get_text()),
		'-P', shell_quote($entry{peak}->get_text()),
		'-D', shell_quote($entry{delay}->get_text()),
		'-V',
	);
}

sub validate_numeric_entries
{
	for my $name (qw(sample_rate lf hf order peak delay))
	{
		my $value = $entry{$name}->get_text();
		die "Érvénytelen numerikus mező: $name=$value\n"
			if $value !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
	}

	my $frequency = $entry{frequency}->get_text();
	$frequency =~ s/^\s+|\s+$//g;

	if ($frequency ne '')
	{
		die "Érvénytelen frekvencia MHz-ben: $frequency\n"
			if $frequency !~ /^(?:\d+(?:\.\d*)?|\.\d+)$/;

		die "A frekvencia ésszerű tartománya 100..2000 MHz.\n"
			if $frequency < 100 || $frequency > 2000;
	}
}

sub apply_processing_settings
{
	eval { validate_numeric_entries(); };
	if ($@)
	{
		append_prc("HIBA: $@");
		return;
	}

	if ($current_mode eq 'idle')
	{
		append_prc("A feldolgozási beállítások elmentve.\n");
		return;
	}

	if ($current_mode eq 'raw_playback' || $current_mode eq 'json_playback')
	{
		append_prc("Ehhez a fájltípushoz nincs alkalmazható hang- vagy szűrőbeállítás.\n");
		return;
	}

	append_prc("\nÚj feldolgozási beállítások alkalmazása...\n");
	$restart_pending = 1;
	stop_processor();
}

sub start_processor
{
	my ($command, $description) = @_;
	append_json("$description\nPARANCS: $command\n\n");

	my $stderr = gensym();
	my $stdin;
	my $pid;
	eval
	{
		my $wrapped_command = '( ' . $command . ' ) 2>&1';
		$pid = open3($stdin, $processor_out, $stderr, 'setsid', 'sh', '-c', $wrapped_command);
	};
	if ($@)
	{
		append_prc("HIBA: a feldolgozó nem indítható: $@\n");
		return;
	}

	close $stdin if defined $stdin;
	close $stderr;
	$processor_pid = $pid;
	set_nonblocking($processor_out);
	$read_buffer = '';
	$processor_watch = Glib::IO->add_watch(
		fileno($processor_out),
		['in', 'hup', 'err'],
		sub { return read_processor_output(); },
	);
}

sub read_processor_output
{
	my $chunk = '';
	my $count = sysread($processor_out, $chunk, 65536);
	if (defined $count && $count > 0)
	{
		$read_buffer .= $chunk;
		while ($read_buffer =~ s/^(.*?\n)//s)
		{
			handle_processor_line($1);
		}
		return TRUE;
	}
	if (defined $count && $count == 0)
	{
		handle_processor_line($read_buffer) if length $read_buffer;
		$read_buffer = '';
		finish_processor();
		return FALSE;
	}
	return TRUE if $!{EAGAIN} || $!{EWOULDBLOCK};
	append_prc("HIBA: feldolgozó olvasási hiba: $!\n");
	finish_processor();
	return FALSE;
}

sub handle_processor_line
{
	my ($line) = @_;
	append_json($line);
	my $candidate = $line;
	$candidate =~ s/^\s+|\s+$//g;
	return if $candidate !~ /^\{.*\}$/s;
	my $data = eval { $json->decode($candidate) };
	return if $@ || ref($data) ne 'HASH' || ($data->{type} // '') ne 'RS41';
	append_prc(format_prc_output($data));
	update_runtime_statistics($data);
	update_receiver_view($data);
	eval { send_sonde_to_sondehub($data); };
	append_prc("HIBA: SondeHUB belső hiba: $@") if $@;
}

sub format_prc_output
{
	my ($r) = @_;
	my $pos = ref($r->{position}) eq 'HASH' ? $r->{position} : {};
	my $ptu = ref($r->{ptu}) eq 'HASH' ? $r->{ptu} : {};
	my $raw = ref($ptu->{raw_measurements}) eq 'HASH' ? $ptu->{raw_measurements} : {};
	my $time = ref($r->{gps_time}) eq 'HASH' ? value_or_q($r->{gps_time}{utc_uncorrected}) : '?';
	my $total = ref($r->{packet_status}) eq 'HASH' ? scalar(keys %{ $r->{packet_status} }) : 6;
	my $cal = defined $ptu->{calibration_ready} ? ($ptu->{calibration_ready} ? 'READY' : 'WAIT') : '?';

	my $text = sprintf(
		"[%s] frame=%s id=%s batt=%s V time=%s packets=%s/%s upstream=%s lat=%s lon=%s alt=%s vH=%s D=%s vV=%s sats=%s T=%sC TH=%sC RH=%s%% RHemp=%s%% P=%shPa Pest=%shPa cal=%s\n",
		value_or_q($r->{validity}), value_or_q($r->{frame_number}), value_or($r->{sonde_id}, '????????'), number_or_q($r->{battery_v}, '%.1f'),
		$time, value_or_q($r->{valid_packets}), $total, value_or_q($r->{upstream_state}),
		number_or_q($pos->{latitude_deg}, '%.5f'), number_or_q($pos->{longitude_deg}, '%.5f'), number_or_q($pos->{altitude_m}, '%.2f'),
		number_or_q($pos->{velocity_h_ms}, '%.1f'), number_or_q($pos->{heading_deg}, '%.1f'), number_or_q($pos->{velocity_v_ms}, '%.1f'), value_or_q($pos->{satellites}),
		number_or_q($ptu->{temperature_c}, '%.2f'), number_or_q($ptu->{humidity_sensor_temperature_c}, '%.2f'),
		number_or_q($ptu->{relative_humidity_pct}, '%.1f'), number_or_q($ptu->{relative_humidity_empirical_pct}, '%.1f'),
		number_or_q($ptu->{pressure_hpa}, '%.2f'), number_or_q($ptu->{pressure_estimated_hpa}, '%.2f'), $cal,
	);

	if (ref($r->{packet_status}) eq 'HASH')
	{
		my @bad;
		for my $name (sort keys %{ $r->{packet_status} })
		{
			my $packet = $r->{packet_status}{$name};
			next if ref($packet) eq 'HASH' && $packet->{crc_ok};
			push @bad, $name . '=' . (ref($packet) eq 'HASH' ? value_or_q($packet->{reason}) : '?');
		}
		$text .= '  Hibás/hiányzó blokkok: ' . join(', ', @bad) . "\n" if @bad;
	}

	$text .= sprintf(
		"  PTU RAW: T=%s H=%s TH=%s P=%s Ptemp=%s\n",
		triplet_or_q($raw->{temperature}), triplet_or_q($raw->{humidity}),
		triplet_or_q($raw->{humidity_temp}), triplet_or_q($raw->{pressure}), value_or_q($raw->{pressure_temp_raw}),
	);
	return $text;
}

sub value_or
{
	my ($value, $fallback) = @_;
	return defined $value && $value ne '' ? $value : $fallback;
}

sub value_or_q
{
	return value_or($_[0], '?');
}

sub number_or_q
{
	my ($value, $format) = @_;
	return '?' if !defined $value;
	return sprintf($format, $value);
}

sub triplet_or_q
{
	my ($array) = @_;
	return '?/?/?' if ref($array) ne 'ARRAY';
	return join('/', map { defined $_ ? $_ : '?' } @$array);
}

sub stop_processor
{
	return if !processor_running();
	kill 'TERM', -$processor_pid;
	Glib::Timeout->add(800, sub
	{
		kill 'KILL', -$processor_pid if processor_running();
		return FALSE;
	});
}

sub finish_processor
{
	waitpid($processor_pid, WNOHANG) if defined $processor_pid;
	close $processor_out if defined $processor_out;
	$processor_pid = undef;
	$processor_out = undef;
	$processor_watch = undef;

	if ($restart_pending)
	{
		$restart_pending = 0;
		if ($current_mode eq 'playback')
		{
			reset_runtime_statistics();
			$last_receiver_data = undef;
			set_output_value('distance', '?');
			set_output_value('bearing', '?');
			set_output_value('elevation', '?');
			run_js('window.rs41Reset();');
		}
		my $command = $current_mode eq 'record'
			? build_live_processing_command()
			: build_play_command($current_wav);
		append_prc("A feldolgozás újraindult az új beállításokkal.\n");
		start_processor($command, $current_description);
		return;
	}

	if ($current_mode eq 'playback' || $current_mode eq 'raw_playback' || $current_mode eq 'json_playback')
	{
		$last_success_age_enabled = 0;
		refresh_runtime_statistics();

		my $finished_text = $current_mode eq 'playback'
			? 'A WAV feldolgozása befejeződött.'
			: $current_mode eq 'raw_playback'
				? 'A RAW fájl feldolgozása befejeződött.'
				: 'A JSON fájl beolvasása befejeződött.';
		append_prc("\n$finished_text\n");
		$current_mode = 'idle';
		set_running_state(FALSE);
	}
	elsif ($current_mode eq 'record' && defined $recorder_pid)
	{
		append_prc("\nA feldolgozó leállt, a rögzítés tovább fut. Mentéssel újraindítható.\n");
	}
}

sub stop_pipeline
{
	return if !session_running();
	$restart_pending = 0;
	append_prc("\nLeállítás kérése...\n");
	stop_processor();
	if (defined $recorder_pid)
	{
		kill 'TERM', -$recorder_pid;
		Glib::Timeout->add(1000, sub
		{
			kill 'KILL', -$recorder_pid if defined $recorder_pid && kill(0, $recorder_pid);
			waitpid($recorder_pid, WNOHANG);
			$recorder_pid = undef;
			return FALSE;
		});
	}
	$current_mode = 'idle';
	$current_wav = undef;
	$current_rlog = undef;
	$current_jlog = undef;
	$last_success_age_enabled = 0;
	refresh_runtime_statistics();
	set_running_state(FALSE);
}

sub processor_running
{
	return defined $processor_pid;
}

sub session_running
{
	return $current_mode ne 'idle' || defined $processor_pid || defined $recorder_pid;
}

sub pipeline_running
{
	return session_running();
}

sub set_running_state
{
	my ($running, $description) = @_;
	$record_button->set_sensitive(!$running);
	$open_button->set_sensitive(!$running);
	$raw_open_button->set_sensitive(!$running);
	$json_open_button->set_sensitive(!$running);
	$folder_button->set_sensitive(!$running);
	$stop_button->set_sensitive($running);
	$save_filter_button->set_sensitive(TRUE) if defined $save_filter_button;
	$status_label->set_text($running ? "Állapot: $description" : 'Állapot: áll');
}

sub set_nonblocking
{
	my ($fh) = @_;
	my $flags = fcntl($fh, F_GETFL, 0);
	fcntl($fh, F_SETFL, $flags | O_NONBLOCK);
}

sub create_log_view
{
	my $view = Gtk3::TextView->new();
	$view->set_editable(FALSE);
	$view->set_cursor_visible(FALSE);
	$view->set_monospace(TRUE);
	$view->set_wrap_mode('none');
	return ($view, $view->get_buffer());
}

sub append_to_log
{
	my ($view, $buffer, $text) = @_;
	my $end = $buffer->get_end_iter();
	$buffer->insert($end, $text);
	my $mark = $buffer->create_mark(undef, $buffer->get_end_iter(), FALSE);
	$view->scroll_to_mark($mark, 0.0, TRUE, 0.0, 1.0);
	$buffer->delete_mark($mark);
}

sub append_prc
{
	append_to_log($prc_view, $prc_buffer, $_[0]);
}

sub append_json
{
	append_to_log($json_view, $json_buffer, $_[0]);
}

sub append_terminal
{
	append_prc($_[0]);
}

sub clear_terminal
{
	$prc_buffer->set_text('');
	$json_buffer->set_text('');
}

sub reset_session_views
{
	clear_terminal();
	reset_runtime_statistics();
	$last_receiver_data = undef;
	set_output_value('distance', '?');
	set_output_value('bearing', '?');
	set_output_value('elevation', '?');
	run_js('window.rs41Reset();');
}

sub reset_runtime_statistics
{
	%packet_count = (VALID => 0, PARTIAL => 0, INVALID => 0);
	$last_valid_epoch = undef;
	$total_path_m = 0.0;
	$previous_track_position = undef;
	$peak_altitude_m = undef;
	$peak_altitude_time = '?';
	@track_history = ();
	refresh_runtime_statistics();
}

sub update_runtime_statistics
{
	my ($data) = @_;
	my $validity = $data->{validity} // '';
	$packet_count{$validity}++ if exists $packet_count{$validity};
	$last_valid_epoch = time() if $validity eq 'VALID';

	if (ref($data->{position}) eq 'HASH')
	{
		my $lat = $data->{position}{latitude_deg};
		my $lon = $data->{position}{longitude_deg};
		my $alt = $data->{position}{altitude_m};
		if (defined $lat && defined $lon && defined $alt)
		{
			if (ref($previous_track_position) eq 'HASH')
			{
				my ($ground_distance) = great_circle_distance_and_bearing(
					$previous_track_position->{lat},
					$previous_track_position->{lon},
					$lat,
					$lon,
				);
				my $height_difference = $alt - $previous_track_position->{alt};
				$total_path_m += sqrt($ground_distance * $ground_distance + $height_difference * $height_difference);
			}
			$previous_track_position = {
				lat => $lat,
				lon => $lon,
				alt => $alt,
			};

			if (!defined $peak_altitude_m || $alt > $peak_altitude_m)
			{
				$peak_altitude_m = $alt;
				if (ref($data->{gps_time}) eq 'HASH' && defined $data->{gps_time}{utc_uncorrected})
				{
					$peak_altitude_time = $data->{gps_time}{utc_uncorrected};
				}
				else
				{
					$peak_altitude_time = strftime('%Y-%m-%d %H:%M:%S', localtime());
				}
			}
		}
	}
	refresh_runtime_statistics();
}

sub refresh_runtime_statistics
{
	if (defined $packet_counter_label)
	{
		$packet_counter_label->set_text(sprintf(
			'VALID: %d / PARTIAL: %d / INVALID: %d',
			$packet_count{VALID},
			$packet_count{PARTIAL},
			$packet_count{INVALID},
		));
	}

	my $seconds_since_valid = $last_success_age_enabled && defined $last_valid_epoch
		? int(time() - $last_valid_epoch)
		: undef;
	my %stats = (
		last_success_age_s => $seconds_since_valid,
		total_path_m => 0 + sprintf('%.1f', $total_path_m),
		peak_altitude_m => defined $peak_altitude_m ? 0 + sprintf('%.2f', $peak_altitude_m) : undef,
		peak_altitude_time => $peak_altitude_time,
	);
	run_js('window.rs41StatsUpdate(' . $json->encode(\%stats) . ');') if defined $webview;
}

sub merge_receiver_state
{
	my ($target, $source) = @_;

	return $target if !defined $source;

	if (ref($source) eq 'HASH')
	{
		$target = {} if ref($target) ne 'HASH';
		for my $key (keys %$source)
		{
			$target->{$key} = merge_receiver_state($target->{$key}, $source->{$key});
		}
		return $target;
	}

	if (ref($source) eq 'ARRAY')
	{
		my @meaningful = grep
		{
			defined $_ && (!ref($_) ? $_ ne '' && $_ ne '?' : 1)
		} @$source;
		return $target if !@meaningful;
		return [ map { ref($_) ? merge_receiver_state(undef, $_) : $_ } @$source ];
	}

	return $target if !ref($source) && ($source eq '' || $source eq '?');
	return $source;
}

sub update_receiver_view
{
	my ($data) = @_;
	$last_receiver_data = merge_receiver_state($last_receiver_data, $data);
	if (ref($data->{position}) eq 'HASH')
	{
		remember_track_point($data);
		update_calculated_fields();
	}
	my $payload = $json->encode($data);
	my $script = 'window.rs41Update(' . $payload . ');';
	run_js($script);
}

sub remember_track_point
{
	my ($data) = @_;
	return if ref($data) ne 'HASH';
	return if ref($data->{position}) ne 'HASH';

	my $position = $data->{position};
	my $lat = $position->{latitude_deg};
	my $lon = $position->{longitude_deg};
	return if !defined $lat || !defined $lon;

	my %point =
	(
		lat => 0 + $lat,
		lon => 0 + $lon,
	);

	$point{heading} = 0 + $position->{heading_deg}
		if defined $position->{heading_deg};
	$point{alt} = 0 + $position->{altitude_m}
		if defined $position->{altitude_m};
	$point{time} = $data->{gps_time}{utc_uncorrected}
		if ref($data->{gps_time}) eq 'HASH' && defined $data->{gps_time}{utc_uncorrected};

	push @track_history, \%point;
}

sub restore_track_history
{
	return if !defined $webview;

	my $points_json = $json->encode(\@track_history);
	my $last_data_json = defined $last_receiver_data
		? $json->encode($last_receiver_data)
		: 'null';

	run_js('window.rs41RestoreTrack(' . $points_json . ',' . $last_data_json . ');');
}

sub update_base_marker
{
	my %base = (
		latitude => numeric_or_null($entry{base_lat}->get_text()),
		longitude => numeric_or_null($entry{base_lon}->get_text()),
		altitude => numeric_or_null($entry{base_alt}->get_text()),
		angle => numeric_or_null($entry{base_angle}->get_text()),
	);
	update_calculated_fields();
	run_js('window.baseUpdate(' . $json->encode(\%base) . ');');
}


sub update_calculated_fields
{
	set_output_value('distance', '?');
	set_output_value('bearing', '?');
	set_output_value('elevation', '?');

	return if !defined $last_receiver_data || ref($last_receiver_data) ne 'HASH';
	return if ref($last_receiver_data->{position}) ne 'HASH';

	my $base_lat = numeric_or_null($entry{base_lat}->get_text());
	my $base_lon = numeric_or_null($entry{base_lon}->get_text());
	my $base_alt = numeric_or_null($entry{base_alt}->get_text());
	my $sonde_lat = $last_receiver_data->{position}{latitude_deg};
	my $sonde_lon = $last_receiver_data->{position}{longitude_deg};
	my $sonde_alt = $last_receiver_data->{position}{altitude_m};

	return if !defined $base_lat || !defined $base_lon || !defined $base_alt;
	return if !defined $sonde_lat || !defined $sonde_lon || !defined $sonde_alt;

	my ($ground_distance, $bearing) = great_circle_distance_and_bearing(
		$base_lat,
		$base_lon,
		$sonde_lat,
		$sonde_lon,
	);
	my $height_difference = $sonde_alt - $base_alt;
	my $slant_distance = sqrt($ground_distance * $ground_distance + $height_difference * $height_difference);
	my $elevation = rad2deg(atan2($height_difference, $ground_distance));

	set_output_value('distance', sprintf('%.1f m', $slant_distance));
	set_output_value('bearing', sprintf('%.1f°', $bearing));
	set_output_value('elevation', sprintf('%.2f°', $elevation));
}

sub great_circle_distance_and_bearing
{
	my ($lat1_deg, $lon1_deg, $lat2_deg, $lon2_deg) = @_;
	my $earth_radius = 6371008.8;
	my $lat1 = deg2rad($lat1_deg);
	my $lon1 = deg2rad($lon1_deg);
	my $lat2 = deg2rad($lat2_deg);
	my $lon2 = deg2rad($lon2_deg);
	my $dlat = $lat2 - $lat1;
	my $dlon = $lon2 - $lon1;

	my $a = sin($dlat / 2.0) ** 2
		+ cos($lat1) * cos($lat2) * sin($dlon / 2.0) ** 2;
	$a = max(0.0, min(1.0, $a));
	my $central_angle = 2.0 * atan2(sqrt($a), sqrt(1.0 - $a));
	my $distance = $earth_radius * $central_angle;

	my $y = sin($dlon) * cos($lat2);
	my $x = cos($lat1) * sin($lat2)
		- sin($lat1) * cos($lat2) * cos($dlon);
	my $bearing = rad2deg(atan2($y, $x));
	$bearing += 360.0 if $bearing < 0.0;

	return ($distance, $bearing);
}

sub set_output_value
{
	my ($name, $value) = @_;
	return if !defined $output_entry{$name};
	$output_entry{$name}->set_text($value);
}

sub numeric_or_null
{
	my ($value) = @_;
	return 0 + $value if $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
	return undef;
}

sub run_js
{
	my ($script) = @_;
	eval
	{
		$webview->run_javascript($script, undef, undef, undef);
	};
	append_terminal("WebKit JavaScript hiba: $@\n") if $@;
}

sub load_html
{
	my $html = html_page();
	$webview->load_html($html, 'file:///');

	# A WebKit oldal betöltési ideje terheléstől függően változhat. A teljes
	# állapotot több alkalommal, idempotens módon visszatöltjük, így a betöltés
	# közben érkező mérési adatok sem vesznek el a frissítés után.
	for my $delay_ms (200, 600, 1400)
	{
		Glib::Timeout->add($delay_ms, sub
		{
			update_base_marker();
			refresh_runtime_statistics();
			restore_track_history();
			return FALSE;
		});
	}
}

sub html_page
{
	my $html = <<'HTML';
<!doctype html>
<html lang="hu">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RS41</title>
<style>

/* Beépített minimál Leaflet-kompatibilis CSS: nincs külső CSS letöltés. */
.leaflet-container{position:relative;overflow:hidden;background:#263542;outline:0;touch-action:none;font-family:Sans,Arial,sans-serif}
.leaflet-tile-pane,.leaflet-overlay-pane,.leaflet-marker-pane{position:absolute;left:0;top:0;width:100%;height:100%;overflow:hidden}
.leaflet-tile-pane{z-index:200}.leaflet-overlay-pane{z-index:400;pointer-events:none}.leaflet-marker-pane{z-index:600;pointer-events:none}
.leaflet-tile{position:absolute;width:256px;height:256px;border:0;user-select:none;-webkit-user-drag:none}
.leaflet-marker-icon{position:absolute;display:block;pointer-events:none}
.leaflet-control-container{position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none;z-index:1000}
.leaflet-top,.leaflet-bottom{position:absolute;z-index:1000;pointer-events:none}.leaflet-top{top:0}.leaflet-bottom{bottom:0}.leaflet-left{left:0}.leaflet-right{right:0}
.leaflet-control{position:relative;pointer-events:auto;margin:10px}.leaflet-bar{box-shadow:0 1px 5px rgba(0,0,0,.65);border-radius:4px;overflow:hidden}
.leaflet-bar a{display:block;width:26px;height:26px;line-height:26px;text-align:center;text-decoration:none;background:#fff;color:#000;border-bottom:1px solid #ccc;font-weight:bold;cursor:pointer;user-select:none}
.leaflet-bar a:last-child{border-bottom:0}.leaflet-bar a:hover{background:#f4f4f4}
.leaflet-control-attribution{position:absolute;right:0;bottom:0;background:rgba(255,255,255,.8);color:#333;padding:0 5px;margin:0;font-size:10px;line-height:1.4;pointer-events:auto}
.leaflet-control-attribution a{color:#0078A8;text-decoration:none}.leaflet-overlay-svg{position:absolute;left:0;top:0;width:100%;height:100%;overflow:visible;pointer-events:none}
.leaflet-circle-marker{position:absolute;border-radius:50%;box-sizing:border-box;pointer-events:none}

</style>
<style>
html,body{height:100%;margin:0;background:#111820;color:#e8edf2;font-family:Sans,Arial,sans-serif;overflow:hidden}
#layout{height:100%;display:flex;flex-direction:column;padding:6px;box-sizing:border-box;min-width:0;min-height:0}
#map{flex:1 1 auto;min-height:45px;border:1px solid #3c4a57;border-radius:4px;overflow:hidden;background:#263542}
#dataSplitter{height:8px;flex:0 0 8px;cursor:row-resize;position:relative}
#dataSplitter:after{content:'';position:absolute;left:45%;right:45%;top:3px;height:2px;background:#526575;border-radius:2px}
#dataPanel{height:285px;min-height:26px;flex:0 0 auto;display:flex;flex-direction:column;overflow:hidden;border:1px solid #344451;border-radius:4px;background:#141e27}
#dataHeader{height:26px;min-height:26px;display:flex;align-items:center;padding:0 6px;background:#1b2630;border-bottom:1px solid #344451;box-sizing:border-box}
#dataToggle{border:0;background:transparent;color:#dce7ef;font-weight:bold;cursor:pointer;padding:2px 6px}
#data{flex:1 1 auto;min-height:0;display:grid;grid-template-columns:repeat(7,minmax(112px,1fr));gap:5px;overflow:auto;padding:5px;box-sizing:border-box}
#dataPanel.collapsed{height:26px!important}
#dataPanel.collapsed #data{display:none}
.card{background:#1b2630;border:1px solid #344451;border-radius:4px;padding:6px 8px;min-height:43px}
.card .name{font-size:11px;color:#91a7b9;text-transform:uppercase}.card .value{font-family:monospace;font-size:16px;margin-top:3px;overflow-wrap:anywhere}
.good{color:#70e090}.wait{color:#ffca4b}.bad{color:#ff7474}
.arrow-marker{background:transparent;border:0}
.arrow-shape{width:30px;height:30px;display:flex;align-items:center;justify-content:center;font-size:29px;line-height:30px;filter:drop-shadow(0 1px 2px rgba(0,0,0,.9));transform-origin:50% 50%}
.arrow-base{color:__BASE_ARROW_COLOR__}.arrow-sonde{color:__SONDE_ARROW_COLOR__}
.leaflet-control-attribution{font-size:10px}
</style>
</head>
<body>
<div id="layout">
	<div id="map"></div>
	<div id="dataSplitter" title="Húzd az adatrész méretének módosításához"></div>
	<div id="dataPanel">
		<div id="dataHeader"><button id="dataToggle" type="button">▼ Adatok összecsukása</button></div>
		<div id="data"></div>
	</div>
</div>
<script>

/* Beépített minimál Leaflet-kompatibilis JS: a GUI által használt funkciókhoz. */
(function(){
'use strict';
const TILE_SIZE=256;
function extend(target,source){source=source||{};Object.keys(source).forEach(k=>target[k]=source[k]);return target;}
function clamp(v,min,max){return Math.max(min,Math.min(max,v));}
function latLngToPoint(lat,lon,zoom){
 const scale=TILE_SIZE*Math.pow(2,zoom);
 const sinLat=clamp(Math.sin(lat*Math.PI/180),-0.9999,0.9999);
 return {x:(lon+180)/360*scale,y:(0.5-Math.log((1+sinLat)/(1-sinLat))/(4*Math.PI))*scale};
}
function pointToLatLng(x,y,zoom){
 const scale=TILE_SIZE*Math.pow(2,zoom);
 const lon=x/scale*360-180;
 const n=Math.PI-2*Math.PI*y/scale;
 const lat=180/Math.PI*Math.atan(0.5*(Math.exp(n)-Math.exp(-n)));
 return [lat,lon];
}
function normalizeLatLng(ll){return Array.isArray(ll)?{lat:Number(ll[0]),lng:Number(ll[1])}:{lat:Number(ll.lat),lng:Number(ll.lng!==undefined?ll.lng:ll.lon)};}
class MiniMap{
 constructor(id,options){
  this._container=typeof id==='string'?document.getElementById(id):id;
  this._options=options||{};this._zoom=9;this._center={lat:0,lng:0};this._layers=[];
  this._container.classList.add('leaflet-container');this._container.innerHTML='';
  this._tilePane=document.createElement('div');this._tilePane.className='leaflet-tile-pane';
  this._overlayPane=document.createElement('div');this._overlayPane.className='leaflet-overlay-pane';
  this._markerPane=document.createElement('div');this._markerPane.className='leaflet-marker-pane';
  this._controlContainer=document.createElement('div');this._controlContainer.className='leaflet-control-container';
  this._container.appendChild(this._tilePane);this._container.appendChild(this._overlayPane);this._container.appendChild(this._markerPane);this._container.appendChild(this._controlContainer);
  if(this._options.zoomControl!==false)this._addZoomControl();
  this._initDrag();this._initWheel();
  window.addEventListener('resize',()=>this.invalidateSize(false));
 }
 _addZoomControl(){
  const wrap=document.createElement('div');wrap.className='leaflet-top leaflet-left';
  const bar=document.createElement('div');bar.className='leaflet-control leaflet-bar';
  const zin=document.createElement('a');zin.href='#';zin.textContent='+';zin.title='Nagyítás';
  const zout=document.createElement('a');zout.href='#';zout.textContent='−';zout.title='Kicsinyítés';
  zin.addEventListener('click',e=>{e.preventDefault();this.setView([this._center.lat,this._center.lng],this._zoom+1);});
  zout.addEventListener('click',e=>{e.preventDefault();this.setView([this._center.lat,this._center.lng],this._zoom-1);});
  bar.appendChild(zin);bar.appendChild(zout);wrap.appendChild(bar);this._controlContainer.appendChild(wrap);
 }
 _initWheel(){
  this._container.addEventListener('wheel',e=>{e.preventDefault();const d=e.deltaY<0?1:-1;this.setView([this._center.lat,this._center.lng],this._zoom+d);},{passive:false});
 }
 _initDrag(){
  let dragging=false,start={x:0,y:0},startCenter=null;
  this._container.addEventListener('mousedown',e=>{dragging=true;start={x:e.clientX,y:e.clientY};startCenter=this.project(this._center);e.preventDefault();});
  document.addEventListener('mousemove',e=>{if(!dragging)return;const dx=e.clientX-start.x;const dy=e.clientY-start.y;const ll=pointToLatLng(startCenter.x-dx,startCenter.y-dy,this._zoom);this._center={lat:ll[0],lng:ll[1]};this._redraw();});
  document.addEventListener('mouseup',()=>{dragging=false;});
 }
 getSize(){return {x:this._container.clientWidth||1,y:this._container.clientHeight||1};}
 project(ll){ll=normalizeLatLng(ll);return latLngToPoint(ll.lat,ll.lng,this._zoom);}
 latLngToContainerPoint(ll){const p=this.project(ll);const c=this.project(this._center);const s=this.getSize();return {x:p.x-c.x+s.x/2,y:p.y-c.y+s.y/2};}
 setView(ll,zoom){ll=normalizeLatLng(ll);this._center=ll;this._zoom=clamp(Math.round(Number(zoom)),1,this._options.maxZoom||19);this._redraw();return this;}
 fitBounds(bounds,opts){
  const a=normalizeLatLng(bounds[0]);const b=normalizeLatLng(bounds[1]);const center=[(a.lat+b.lat)/2,(a.lng+b.lng)/2];
  const size=this.getSize();let chosen=1;
  for(let z=1;z<=(this._options.maxZoom||19);z++){
   const pa=latLngToPoint(a.lat,a.lng,z),pb=latLngToPoint(b.lat,b.lng,z);
   if(Math.abs(pa.x-pb.x)<=size.x-20&&Math.abs(pa.y-pb.y)<=size.y-20)chosen=z;else break;
  }
  return this.setView(center,chosen);
 }
 panTo(ll,opts){return this.setView(ll,this._zoom);}
 invalidateSize(animate){this._redraw();return this;}
 addLayer(layer){if(this._layers.indexOf(layer)<0)this._layers.push(layer);layer._addToMap(this);this._redraw();return this;}
 removeLayer(layer){this._layers=this._layers.filter(l=>l!==layer);if(layer._removeFromMap)layer._removeFromMap();this._redraw();return this;}
 _redraw(){this._layers.forEach(l=>{if(l._redraw)l._redraw();});}
}
class TileLayer{
 constructor(url,options){this._url=url;this._options=options||{};this._tiles={};}
 addTo(target){target.addLayer(this);return this;}
 _addToMap(map){this._map=map;this._pane=map._tilePane;this._redraw();this._setAttribution();}
 _setAttribution(){if(!this._options.attribution||this._attrib)return;this._attrib=document.createElement('div');this._attrib.className='leaflet-control-attribution';this._attrib.innerHTML=this._options.attribution;this._map._controlContainer.appendChild(this._attrib);}
 _removeFromMap(){Object.values(this._tiles).forEach(t=>t.remove());this._tiles={};if(this._attrib)this._attrib.remove();}
 _tileUrl(x,y,z){return this._url.replace('{z}',z).replace('{x}',x).replace('{y}',y).replace('{s}','a');}
 _redraw(){
  if(!this._map)return;const z=this._map._zoom;const maxZ=this._options.maxZoom||19;const useZ=Math.min(z,maxZ);const size=this._map.getSize();const center=this._map.project(this._map._center);const topLeft={x:center.x-size.x/2,y:center.y-size.y/2};
  const minX=Math.floor(topLeft.x/TILE_SIZE)-1,maxX=Math.floor((topLeft.x+size.x)/TILE_SIZE)+1,minY=Math.floor(topLeft.y/TILE_SIZE)-1,maxY=Math.floor((topLeft.y+size.y)/TILE_SIZE)+1;
  const maxTile=Math.pow(2,useZ);const wanted={};
  for(let x=minX;x<=maxX;x++)for(let y=minY;y<=maxY;y++){
   if(y<0||y>=maxTile)continue;let tx=((x%maxTile)+maxTile)%maxTile;const key=useZ+':'+tx+':'+y;wanted[key]=true;
   let img=this._tiles[key];if(!img){img=document.createElement('img');img.className='leaflet-tile';img.draggable=false;img.src=this._tileUrl(tx,y,useZ);this._tiles[key]=img;this._pane.appendChild(img);}
   img.style.left=(x*TILE_SIZE-topLeft.x)+'px';img.style.top=(y*TILE_SIZE-topLeft.y)+'px';
  }
  Object.keys(this._tiles).forEach(k=>{if(!wanted[k]){this._tiles[k].remove();delete this._tiles[k];}});
 }
}
class LayerGroup{
 constructor(){this._layers=[];this._map=null;}
 addTo(target){target.addLayer(this);return this;}
 addLayer(layer){this._layers.push(layer);if(this._map)layer._addToMap(this._map);return this;}
 clearLayers(){this._layers.forEach(l=>{if(l._removeFromMap)l._removeFromMap();});this._layers=[];return this;}
 _addToMap(map){this._map=map;this._layers.forEach(l=>l._addToMap(map));}
 _removeFromMap(){this.clearLayers();this._map=null;}
 _redraw(){this._layers.forEach(l=>{if(l._redraw)l._redraw();});}
}
class Polyline{
 constructor(latlngs,options){this._latlngs=latlngs||[];this._options=options||{};this._map=null;this._canvas=null;this._ctx=null;}
 addTo(target){target.addLayer(this);return this;}
 setLatLngs(latlngs){this._latlngs=latlngs||[];this._redraw();return this;}
 appendLatLng(latlng){
  const previous=this._latlngs.length?this._latlngs[this._latlngs.length-1]:null;
  this._latlngs.push(latlng);
  if(previous&&this._map&&this._ctx){this._drawSegment(previous,latlng);this._drawPoint(latlng);}
  else this._redraw();
  return this;
 }
 _addToMap(map){
  this._map=map;
  this._canvas=document.createElement('canvas');
  this._canvas.className='leaflet-overlay-svg';
  this._canvas.style.pointerEvents='none';
  map._overlayPane.appendChild(this._canvas);
  this._redraw();
 }
 _removeFromMap(){if(this._canvas)this._canvas.remove();this._canvas=null;this._ctx=null;this._map=null;}
 _prepareCanvas(){
  if(!this._map||!this._canvas)return false;
  const size=this._map.getSize();
  const ratio=Math.max(1,window.devicePixelRatio||1);
  const width=Math.max(1,Math.round(size.x*ratio));
  const height=Math.max(1,Math.round(size.y*ratio));
  if(this._canvas.width!==width||this._canvas.height!==height){
   this._canvas.width=width;
   this._canvas.height=height;
   this._canvas.style.width=size.x+'px';
   this._canvas.style.height=size.y+'px';
  }
  this._ctx=this._canvas.getContext('2d');
  this._ctx.setTransform(ratio,0,0,ratio,0,0);
  this._ctx.lineWidth=this._options.weight||3;
  this._ctx.strokeStyle=this._options.color||'#3388ff';
  this._ctx.globalAlpha=this._options.opacity!==undefined?this._options.opacity:1;
  this._ctx.lineJoin='round';
  this._ctx.lineCap='round';
  return true;
 }
 _drawSegment(from,to){
  if(!this._ctx||!this._map)return;
  const a=this._map.latLngToContainerPoint(from);
  const b=this._map.latLngToContainerPoint(to);
  this._ctx.beginPath();
  this._ctx.moveTo(a.x,a.y);
  this._ctx.lineTo(b.x,b.y);
  this._ctx.stroke();
 }
 _drawPoint(latlng){
  if(!this._ctx||!this._map)return;
  const radius=Math.max(0,Number(this._options.pointRadius||0));
  if(radius<=0)return;
  const p=this._map.latLngToContainerPoint(latlng);
  this._ctx.beginPath();
  this._ctx.arc(p.x,p.y,radius,0,Math.PI*2);
  this._ctx.fillStyle=this._options.pointColor||this._options.color||'#3388ff';
  this._ctx.fill();
 }
 _redraw(){
  if(!this._prepareCanvas())return;
  const size=this._map.getSize();
  this._ctx.clearRect(0,0,size.x,size.y);
  if(this._latlngs.length>=2){
   this._ctx.beginPath();
   this._latlngs.forEach((ll,index)=>{
    const p=this._map.latLngToContainerPoint(ll);
    if(index===0)this._ctx.moveTo(p.x,p.y);else this._ctx.lineTo(p.x,p.y);
   });
   this._ctx.stroke();
  }
  this._latlngs.forEach((ll)=>this._drawPoint(ll));
 }
}
class CircleMarker{
 constructor(latlng,options){this._latlng=latlng;this._options=options||{};}
 addTo(target){target.addLayer(this);return this;}
 _addToMap(map){this._map=map;this._el=document.createElement('div');this._el.className='leaflet-circle-marker';this._el.style.width=(this._options.radius||3)*2+'px';this._el.style.height=(this._options.radius||3)*2+'px';this._el.style.border=(this._options.weight||1)+'px solid '+(this._options.color||'#3388ff');this._el.style.background=this._options.fillColor||this._options.color||'#3388ff';this._el.style.opacity=this._options.fillOpacity!==undefined?this._options.fillOpacity:1;map._overlayPane.appendChild(this._el);this._redraw();}
 _removeFromMap(){if(this._el)this._el.remove();}
 _redraw(){if(!this._map||!this._el)return;const p=this._map.latLngToContainerPoint(this._latlng);const r=this._options.radius||3;this._el.style.left=(p.x-r)+'px';this._el.style.top=(p.y-r)+'px';}
}
class Marker{
 constructor(latlng,options){this._latlng=latlng;this._options=options||{};}
 addTo(target){target.addLayer(this);return this;}
 setLatLng(ll){this._latlng=ll;this._redraw();return this;}
 setIcon(icon){this._options.icon=icon;this._renderIcon();this._redraw();return this;}
 _addToMap(map){this._map=map;this._el=document.createElement('div');this._el.className='leaflet-marker-icon';this._el.style.zIndex=String(600+(this._options.zIndexOffset||0));map._markerPane.appendChild(this._el);this._renderIcon();this._redraw();}
 _renderIcon(){if(!this._el)return;const icon=this._options.icon||{};this._el.className='leaflet-marker-icon '+(icon.className||'');this._el.innerHTML=icon.html||'';this._size=icon.iconSize||[24,24];this._anchor=icon.iconAnchor||[this._size[0]/2,this._size[1]/2];this._el.style.width=this._size[0]+'px';this._el.style.height=this._size[1]+'px';}
 _removeFromMap(){if(this._el)this._el.remove();}
 _redraw(){if(!this._map||!this._el)return;const p=this._map.latLngToContainerPoint(this._latlng);this._el.style.left=(p.x-this._anchor[0])+'px';this._el.style.top=(p.y-this._anchor[1])+'px';}
}
window.L={
 map:(id,options)=>new MiniMap(id,options),
 tileLayer:(url,options)=>new TileLayer(url,options),
 layerGroup:()=>new LayerGroup(),
 polyline:(latlngs,options)=>new Polyline(latlngs,options),
 circleMarker:(latlng,options)=>new CircleMarker(latlng,options),
 marker:(latlng,options)=>new Marker(latlng,options),
 divIcon:(options)=>extend({},options||{})
};
})();

</script>
<script>
const fields=[
['Érvényesség','validity'],['Keret','frame_number'],['Szonda ID','sonde_id'],['Akkumulátor','battery_v',' V'],['GPS idő','gps_time.utc_uncorrected'],['Utolsó sikeres vétel','runtime.last_success_age_s',' s'],['Megtett összút','runtime.total_path_m',' m'],
['Szélesség','position.latitude_deg','°'],['Hosszúság','position.longitude_deg','°'],['Magasság','position.altitude_m',' m'],['Vízszintes seb.','position.velocity_h_ms',' m/s'],['Irány','position.heading_deg','°'],['Függőleges seb.','position.velocity_v_ms',' m/s'],['Műholdak','position.satellites'],
['Hőmérséklet','ptu.temperature_c',' °C'],['Páraszenzor hőm.','ptu.humidity_sensor_temperature_c',' °C'],['Páratartalom','ptu.relative_humidity_pct',' %'],['Empirikus RH','ptu.relative_humidity_empirical_pct',' %'],['Nyomás','ptu.pressure_hpa',' hPa'],['Becsült nyomás','ptu.pressure_estimated_hpa',' hPa'],['Csúcsmagasság','runtime.peak_altitude_m',' m'],
['Kalibráció','ptu.calibration_ready'],['Kal. keretek','calibration.seen_count',' / 51'],['RAW T','ptu.raw_measurements.temperature'],['RAW H','ptu.raw_measurements.humidity'],['RAW TH','ptu.raw_measurements.humidity_temp'],['RAW P','ptu.raw_measurements.pressure'],['Csúcsmagasság ideje','runtime.peak_altitude_time']
];
function get(o,path){return path.split('.').reduce((a,k)=>a!==null&&a!==undefined?a[k]:undefined,o)}
function fmt(v){if(v===undefined||v===null||v==='')return '?';if(Array.isArray(v))return v.join('/');if(typeof v==='number')return Number.isInteger(v)?String(v):String(Math.round(v*100000)/100000);return String(v)}
function isNumber(v){return typeof v==='number'&&Number.isFinite(v)}
function angleDifference(a,b){const d=Math.abs(Number(a||0)-Number(b||0))%360;return Math.min(d,360-d)}
function distanceMeters(a,b){
 if(!a||!b||!isNumber(a.latitude)||!isNumber(a.longitude)||!isNumber(b.latitude)||!isNumber(b.longitude))return Infinity;
 const lat=(a.latitude+b.latitude)*Math.PI/360;
 const dy=(b.latitude-a.latitude)*111320;
 const dx=(b.longitude-a.longitude)*111320*Math.max(.15,Math.cos(lat));
 return Math.sqrt(dx*dx+dy*dy);
}
let currentData={runtime:{last_success_age_s:null,total_path_m:0,peak_altitude_m:null,peak_altitude_time:'?'}};
let followSonde=true;
let baseData=null;
let baseMarker=null;
let sondeMarker=null;
let trackLayer=null;
let trackLine=null;
let trackPoints=[];
let map=null;
let lastSondePosition=null;
let dataPanelHeight=285;
let dataCollapsed=false;
let fieldElements=[];
let dataRefreshPending=false;
function invalidateMap(){if(map)setTimeout(()=>map.invalidateSize(false),0)}
function setDataCollapsed(collapsed){
 dataCollapsed=!!collapsed;
 const panel=document.getElementById('dataPanel');
 const toggle=document.getElementById('dataToggle');
 panel.classList.toggle('collapsed',dataCollapsed);
 toggle.textContent=dataCollapsed?'▲ Adatok kinyitása':'▼ Adatok összecsukása';
 if(!dataCollapsed)panel.style.height=dataPanelHeight+'px';
 invalidateMap();
}
function initDataResize(){
 const splitter=document.getElementById('dataSplitter');
 const panel=document.getElementById('dataPanel');
 document.getElementById('dataToggle').addEventListener('click',()=>setDataCollapsed(!dataCollapsed));
 splitter.addEventListener('mousedown',(event)=>{
  event.preventDefault();
  if(dataCollapsed)setDataCollapsed(false);
  const startY=event.clientY;
  const startHeight=panel.getBoundingClientRect().height;
  function move(e){
   const maxHeight=Math.max(26,document.getElementById('layout').clientHeight-55);
   dataPanelHeight=Math.max(26,Math.min(maxHeight,startHeight-(e.clientY-startY)));
   panel.style.height=dataPanelHeight+'px';
   invalidateMap();
  }
  function up(){document.removeEventListener('mousemove',move);document.removeEventListener('mouseup',up);}
  document.addEventListener('mousemove',move);
  document.addEventListener('mouseup',up);
 });
}
function mergeDefined(target,source){
 if(source===null||source===undefined)return target;
 if(Array.isArray(source))return source.slice();
 if(typeof source!=='object')return source;
 if(typeof target!=='object'||target===null||Array.isArray(target))target={};
 Object.keys(source).forEach((key)=>{
  const value=source[key];
  if(value===null||value===undefined)return;
  if(Array.isArray(value))target[key]=value.slice();
  else if(typeof value==='object')target[key]=mergeDefined(target[key],value);
  else target[key]=value;
 });
 return target;
}
function initDataCards(){
 const root=document.getElementById('data');
 root.innerHTML='';
 fieldElements=fields.map(([name])=>{
  const card=document.createElement('div');
  card.className='card';
  const nameElement=document.createElement('div');
  nameElement.className='name';
  nameElement.textContent=name;
  const valueElement=document.createElement('div');
  valueElement.className='value';
  card.appendChild(nameElement);
  card.appendChild(valueElement);
  root.appendChild(card);
  return valueElement;
 });
}
function refreshDataCards(){
 dataRefreshPending=false;
 fields.forEach((field,index)=>{
  const value=get(currentData,field[1]);
  fieldElements[index].textContent=fmt(value)+(value===undefined||value===null?'':field[2]||'');
 });
}
function scheduleDataRefresh(){
 if(dataRefreshPending)return;
 dataRefreshPending=true;
 window.requestAnimationFrame(refreshDataCards);
}
function arrowIcon(kind,angle){
 const cls=kind==='base'?'arrow-base':'arrow-sonde';
 return L.divIcon({
  className:'arrow-marker',
  html:'<div class="arrow-shape '+cls+'" style="transform:rotate('+(Number(angle||0)-90)+'deg)">➤</div>',
  iconSize:[30,30],
  iconAnchor:[15,15]
 });
}
function initMap(){
 map=L.map('map',{zoomControl:true,preferCanvas:true});
 L.tileLayer(__TILE_SERVER__,{
  maxZoom:19,
  attribution:'&copy; OpenStreetMap közreműködők'
 }).addTo(map);
 trackLayer=L.layerGroup().addTo(map);
 trackLine=L.polyline([], {color:__TRACK_COLOR__,weight:__TRACK_WIDTH__,opacity:__TRACK_OPACITY__,pointRadius:__TRACK_POINT_RADIUS__,pointColor:__TRACK_COLOR__,interactive:false}).addTo(trackLayer);
 map.setView([__MAP_START_LAT__,__MAP_START_LON__],__MAP_START_ZOOM__);
}
function fitBaseArea(lat,lon){
 const halfHeightKm=25;
 const latDelta=halfHeightKm/111.32;
 const lonScale=Math.max(0.15,Math.cos(lat*Math.PI/180));
 const lonDelta=halfHeightKm/(111.32*lonScale);
 map.fitBounds([[lat-latDelta,lon-lonDelta],[lat+latDelta,lon+lonDelta]],{animate:false,padding:[10,10]});
}
function followPositionIfNeeded(ll){
 if(!followSonde||!map)return;
 const p=map.latLngToContainerPoint(ll);
 const size=map.getSize();
 const marginX=Math.max(30,size.x*.22);
 const marginY=Math.max(30,size.y*.22);
 if(p.x<marginX||p.x>size.x-marginX||p.y<marginY||p.y>size.y-marginY){
  map.panTo(ll,{animate:false});
 }
}
function render(d){
 currentData=mergeDefined(currentData,d||{});
 scheduleDataRefresh();
 const incoming=d&&d.position&&isNumber(d.position.latitude_deg)&&isNumber(d.position.longitude_deg)?d.position:null;
 if(incoming){
  const lat=incoming.latitude_deg;
  const lon=incoming.longitude_deg;
  const heading=isNumber(incoming.heading_deg)?incoming.heading_deg:0;
  const ll=[lat,lon];
  trackPoints.push(ll);
  trackLine.appendLatLng(ll);
  if(!sondeMarker)sondeMarker=L.marker(ll,{icon:arrowIcon('sonde',heading),zIndexOffset:1000}).addTo(map);
  else{sondeMarker.setLatLng(ll);sondeMarker.setIcon(arrowIcon('sonde',heading));}
  lastSondePosition=ll;
  followPositionIfNeeded(ll);
 }
}
window.rs41Update=render;
window.rs41RestoreTrack=function(points,lastData){
 if(!Array.isArray(points))points=[];
 if(lastData)currentData=mergeDefined(currentData,lastData);
 lastSondePosition=null;
 trackPoints=[];
 if(trackLayer){
  trackLayer.clearLayers();
  trackLine=L.polyline([], {color:__TRACK_COLOR__,weight:__TRACK_WIDTH__,opacity:__TRACK_OPACITY__,pointRadius:__TRACK_POINT_RADIUS__,pointColor:__TRACK_COLOR__,interactive:false}).addTo(trackLayer);
 }
 if(sondeMarker){map.removeLayer(sondeMarker);sondeMarker=null;}
 let lastHeading=0;
 points.forEach((p)=>{
  if(!p||!isNumber(p.lat)||!isNumber(p.lon))return;
  const ll=[p.lat,p.lon];
  trackPoints.push(ll);
  lastSondePosition=ll;
  if(isNumber(p.heading))lastHeading=p.heading;
 });
 if(trackLine)trackLine.setLatLngs(trackPoints);
 if(lastSondePosition)sondeMarker=L.marker(lastSondePosition,{icon:arrowIcon('sonde',lastHeading),zIndexOffset:1000}).addTo(map);
 scheduleDataRefresh();
 if(followSonde&&lastSondePosition)map.panTo(lastSondePosition,{animate:false});
};
window.rs41StatsUpdate=function(stats){
 currentData.runtime=mergeDefined(currentData.runtime||{},stats||{});
 scheduleDataRefresh();
};
window.rs41Reset=function(){
 currentData={runtime:{last_success_age_s:null,total_path_m:0,peak_altitude_m:null,peak_altitude_time:'?'}};
 lastSondePosition=null;
 trackPoints=[];
 if(trackLayer){
  trackLayer.clearLayers();
  trackLine=L.polyline([], {color:__TRACK_COLOR__,weight:__TRACK_WIDTH__,opacity:__TRACK_OPACITY__,pointRadius:__TRACK_POINT_RADIUS__,pointColor:__TRACK_COLOR__,interactive:false}).addTo(trackLayer);
 }
 if(sondeMarker){map.removeLayer(sondeMarker);sondeMarker=null;}
 scheduleDataRefresh();
};
window.setFollowSonde=function(enabled){
 followSonde=!!enabled;
 if(followSonde&&lastSondePosition)map.panTo(lastSondePosition,{animate:false});
};
window.baseUpdate=function(b){
 if(!b||!isNumber(b.latitude)||!isNumber(b.longitude))return;
 const previous=baseData;
 baseData=b;
 const positionChanged=!previous||distanceMeters(previous,b)>=1.0;
 const altitudeChanged=!previous||!isNumber(previous.altitude)||!isNumber(b.altitude)||Math.abs(previous.altitude-b.altitude)>=0.5;
 const angleChanged=!previous||angleDifference(previous.angle,b.angle)>=1.0;
 if(baseMarker&&!positionChanged&&!altitudeChanged&&!angleChanged)return;
 const ll=[b.latitude,b.longitude];
 if(!baseMarker){
  baseMarker=L.marker(ll,{icon:arrowIcon('base',b.angle||0),zIndexOffset:900}).addTo(map);
  fitBaseArea(b.latitude,b.longitude);
 }else{
  if(positionChanged)baseMarker.setLatLng(ll);
  if(angleChanged)baseMarker.setIcon(arrowIcon('base',b.angle||0));
 }
};
initMap();
initDataResize();
initDataCards();
render({});
</script>
</body>
</html>
HTML

	my $base_arrow_color = config_color('BASE_ARROW_COLOR', '#42c9ff');
	my $sonde_arrow_color = config_color('SONDE_ARROW_COLOR', '#e3a52b');
	my $track_color = config_color('TRACK_COLOR', '#e3a52b');
	my $tile_server = load_config('TILE_SERVER', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
	my $map_start_lat = config_number('MAP_START_LAT', 47.49786);
	my $map_start_lon = config_number('MAP_START_LON', 19.04022);
	my $map_start_zoom = config_number('MAP_START_ZOOM', 9);
	my $track_width = config_number('TRACK_WIDTH', 4);
	my $track_opacity = config_number('TRACK_OPACITY', 0.9);
	my $track_point_radius = config_number('TRACK_POINT_RADIUS', 3);

	$html =~ s/__BASE_ARROW_COLOR__/$base_arrow_color/g;
	$html =~ s/__SONDE_ARROW_COLOR__/$sonde_arrow_color/g;
	$html =~ s/__TRACK_COLOR__/$json->encode($track_color)/ge;
	$html =~ s/__TILE_SERVER__/$json->encode($tile_server)/ge;
	$html =~ s/__MAP_START_LAT__/$map_start_lat/g;
	$html =~ s/__MAP_START_LON__/$map_start_lon/g;
	$html =~ s/__MAP_START_ZOOM__/$map_start_zoom/g;
	$html =~ s/__TRACK_WIDTH__/$track_width/g;
	$html =~ s/__TRACK_OPACITY__/$track_opacity/g;
	$html =~ s/__TRACK_POINT_RADIUS__/$track_point_radius/g;

	return $html;
}

sub load_config
{
	my ($field, $default) = @_;

	if (!$config_loaded)
	{
		$config_loaded = 1;
		%config_cache = ();

		if (-f $configfile)
		{
			my $fh;
			if (open($fh, '<:encoding(UTF-8)', $configfile))
			{
				while (my $line = <$fh>)
				{
					$line =~ s/^\x{FEFF}//;
					$line =~ s/[\r\n]+$//;
					$line =~ s/^\s+|\s+$//g;
					next if $line eq '' || $line =~ /^#/;
					next if $line !~ /^([A-Za-z0-9_.-]+)\s*=\s*(.*)$/;

					my ($name, $value) = (uc($1), $2);
					$value =~ s/^\s+|\s+$//g;
					$value =~ s/^"(.*)"$/$1/;
					$value =~ s/^'(.*)'$/$1/;
					$config_cache{$name} = $value;
				}
				close $fh;
			}
		}
	}

	my $key = uc($field // '');
	return $config_cache{$key}
		if exists $config_cache{$key} && $config_cache{$key} ne '';
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
	my ($field, $default) = @_;
	my $value = load_config($field, $default);
	return 0 + $value
		if defined $value && $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
	return 0 + $default;
}

sub config_color
{
	my ($field, $default) = @_;
	my $value = load_config($field, $default);
	return $value
		if defined $value && $value =~ /^#[0-9A-Fa-f]{6}$/;
	return $default;
}

sub shell_quote
{
	my ($value) = @_;
	$value //= '';
	$value =~ s/'/'"'"'/g;
	return "'$value'";
}
