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
		print "rs41_gui.pl $VERSION\n";
		exit 0;
	}
}
use FindBin;
use File::Spec;
use lib $FindBin::Bin;
BEGIN
{
	$ENV{XDG_CACHE_HOME}="$FindBin::Bin/cache";
	$ENV{XDG_DATA_HOME}="$FindBin::Bin/cache/data";
}
use Gtk3::WebKit2;
use dsPGtkGUI;
use Glib qw(TRUE FALSE);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Handle;
use POSIX ();
use IPC::Open2;
use RS41IPC qw(
	json_codec
	configure_json_stdio
	send_json_message
	decode_json_line
	is_frontend_event_request
);
use RS41FrontendData qw(new_frontend_state reset_frontend_state apply_receiver_update apply_runtime_statistics apply_calculated_fields packet_summary_text);

configure_json_stdio();
my $json=json_codec();
my ($UI,$GTK,$webview,$prc_buffer,$json_buffer);
my $internal=0;
my $stdin_buffer='';
my $frontend_state=new_frontend_state();

my $default_settings =
{
	work_dir   => './log',
	device     => 'default',
	sample_rate => '48000',
	lf         => '525',
	hf         => '14000',
	order      => '1',
	peak       => '0.75',
	delay      => '0.1',
	invert     => 1,
	frequency  => '403.700',
	share      => 0,
	mobile     => 0,
	base       =>
	{
		latitude  => '47.49786',
		longitude => '19.04022',
		altitude  => '110',
		angle     => '0'
	}
};

sub send_main
{
	send_json_message(\*STDOUT,$_[0]);
}

sub shell_quote
{
	my($value)=@_;
	$value='' if !defined($value);
	$value =~ s/'/'"'"'/g;
	return "'$value'";
}

sub find_executable
{
	my($name)=@_;

	for my $directory (split(/:/,$ENV{PATH}//''))
	{
		my $path="$directory/$name";
		return $path if -x $path;
	}

	return;
}

my %gui_service;

sub valid_pipeconnect_id
{
	my($id)=@_;

	return 0 if !defined($id) || $id eq '';
	return 0 if $id =~ /[\0\r\n]/;
	return 0 if length($id)>240;

	return 1;
}

sub stop_child_process
{
	my($pid)=@_;

	return if !defined($pid) || $pid<=0;

	kill('TERM',$pid);
	waitpid($pid,POSIX::WNOHANG());

	return;
}

sub close_gui_service
{
	my($service,$reset_toggle)=@_;
	my $state=delete($gui_service{$service});

	return 0 if ref($state) ne 'HASH';

	for my $handle_name(qw(control_writer control_reader))
	{
		my $handle=$state->{$handle_name};
		close($handle) if defined($handle);
	}

	for my $pid_name(qw(control_writer_pid control_reader_pid terminal_pid))
	{
		stop_child_process($state->{$pid_name});
	}

	if($reset_toggle && defined($GTK))
	{
		set_toggle(
			$service eq 'bt'
				?'bt_button'
				:'sondehub_button',
			0
		);
	}

	return 1;
}

sub open_gui_control_reader
{
	my($service)=@_;
	my $pipe_connect="$FindBin::Bin/pipeConnect.pl";

	return 0 if !-x $pipe_connect;

	my($output,$input);
	my $pid=open2(
		$output,
		$input,
		$^X,
		$pipe_connect,
		'-R'
	);

	close($input);

	my $id=<$output>;

	if(!defined($id))
	{
		stop_child_process($pid);
		return 0;
	}

	$id=~s/[\r\n]+\z//;

	if(!valid_pipeconnect_id($id))
	{
		close($output);
		stop_child_process($pid);
		return 0;
	}

	my $flags=fcntl($output,F_GETFL,0);
	fcntl($output,F_SETFL,$flags|O_NONBLOCK)
		if defined($flags);

	$gui_service{$service}=
	{
		control_reader_pid=>$pid,
		control_reader=>$output,
		control_receive_id=>$id,
		control_buffer=>'',
		terminal_control_receive_id=>'',
		ui_receive_id=>'',
		terminal_pid=>undef,
		control_writer_pid=>undef,
		control_writer=>undef
	};

	return 1;
}

sub open_gui_control_writer
{
	my($service,$receive_id)=@_;
	my $state=$gui_service{$service};

	return 0 if ref($state) ne 'HASH';
	return 0 if !valid_pipeconnect_id($receive_id);

	my($output,$input);
	my $pid=open2(
		$output,
		$input,
		$^X,
		"$FindBin::Bin/pipeConnect.pl",
		'-W',
		$receive_id
	);

	close($output);
	$input->autoflush(1);

	$state->{control_writer_pid}=$pid;
	$state->{control_writer}=$input;

	return 1;
}

sub launch_service_terminal
{
	my($service,$control_id)=@_;
	my $title=$service eq 'bt'
		?'Bluetooth GPS Bridge'
		:'SondeHub feltöltő';
	my $terminal_client="$FindBin::Bin/terminal_service.pl";

	return 0 if !-x $terminal_client;

	my $command=join(
		' ',
		shell_quote($terminal_client),
		'--service',
		shell_quote($service),
		'--control-id',
		shell_quote($control_id)
	);

	my @terminal;
	my $terminal_path;

	if($terminal_path=find_executable('gnome-terminal'))
	{
		@terminal=($terminal_path,'--title='.$title,'--','bash','-lc',$command);
	}
	elsif($terminal_path=find_executable('mate-terminal'))
	{
		@terminal=($terminal_path,'--title='.$title,'--','bash','-lc',$command);
	}
	elsif($terminal_path=find_executable('xfce4-terminal'))
	{
		@terminal=($terminal_path,'--title='.$title,'--command','bash -lc '.shell_quote($command));
	}
	elsif($terminal_path=find_executable('konsole'))
	{
		@terminal=($terminal_path,'-p','tabtitle='.$title,'-e','bash','-lc',$command);
	}
	elsif($terminal_path=find_executable('xterm'))
	{
		@terminal=($terminal_path,'-T',$title,'-e','bash','-lc',$command);
	}
	else
	{
		terminal_message('ERR','Nem található támogatott terminálprogram.');
		return 0;
	}

	my $pid=fork();

	if(!defined($pid))
	{
		return 0;
	}

	if($pid==0)
	{
		exec(@terminal) or POSIX::_exit(127);
	}

	$gui_service{$service}{terminal_pid}=$pid;
	return 1;
}

sub start_gui_service
{
	my($service)=@_;

	return 1 if ref($gui_service{$service}) eq 'HASH';

	if(!open_gui_control_reader($service))
	{
		terminal_message('ERR','A GUI kontroll pipeConnect -R nem indítható.');
		return 0;
	}

	my $control_id=$gui_service{$service}{control_receive_id};

	if(!launch_service_terminal($service,$control_id))
	{
		close_gui_service($service,1);
		return 0;
	}

	return 1;
}

sub poll_gui_service_controls
{
	for my $service(qw(bt sondehub))
	{
		my $state=$gui_service{$service};
		next if ref($state) ne 'HASH';
		next if !$state->{control_reader};

		while(1)
		{
			my $chunk='';
			my $count=sysread($state->{control_reader},$chunk,65536);

			if(defined($count)&&$count>0)
			{
				$state->{control_buffer}.=$chunk;

				while($state->{control_buffer}=~s/^(.*?\n)//s)
				{
					my $line=$1;
					my $message=eval{$json->decode($line)};
					next if ref($message) ne 'HASH';

					if(($message->{type}//'') eq 'terminal_ready')
					{
						$state->{ui_receive_id}=$message->{receive_id}//'';
						$state->{terminal_control_receive_id}=
							$message->{control_receive_id}//'';

						send_main(
							{
								type=>$service eq 'bt'
									?'bt_start_requested'
									:'sondehub_start_requested',
								receive_id=>$state->{ui_receive_id},
								settings=>$service eq 'sondehub'
									?settings()
									:undef,
								source=>'gui'
							}
						);
					}
				}
				next;
			}

			if(defined($count)&&$count==0)
			{
				close_gui_service($service,1);

				send_main(
					{
						type=>$service eq 'bt'
							?'bt_stop_requested'
							:'sondehub_stop_requested',
						source=>'gui_terminal_exit'
					}
				);

				last;
			}

			last if !defined($count)
				&& ($!{EAGAIN} || $!{EWOULDBLOCK});

			next if !defined($count) && $!{EINTR};

			close_gui_service($service,1);

			send_main(
				{
					type=>$service eq 'bt'
						?'bt_stop_requested'
						:'sondehub_stop_requested',
					source=>'gui_control_error'
				}
			);

			last;
		}
	}

	return 1;
}

sub complete_gui_service
{
	my($message)=@_;
	my $service=$message->{service}//'';
	my $state=$gui_service{$service};
	my $main_receive_id=$message->{receive_id}//'';

	return 0 if ref($state) ne 'HASH';
	return 0 if !valid_pipeconnect_id($main_receive_id);

	if(!open_gui_control_writer(
		$service,
		$state->{terminal_control_receive_id}
	))
	{
		close_gui_service($service,1);
		return 0;
	}

	my $raw=$json->encode(
		{
			type=>'main_receive_id',
			receive_id=>$main_receive_id
		}
	)."\n";

	if(!print {$state->{control_writer}} $raw)
	{
		close_gui_service($service,1);
		return 0;
	}

	return 1;
}

sub terminal_message
{
	my($level,$text)=@_;
	send_main({type=>'terminal',level=>uc($level//'INFO'),text=>$text//''});
}

sub on_main_window_destroy
{
	close_gui_service($_,0) for qw(bt sondehub);

	terminal_message('INFO','A főablak bezárult.');
	send_main({type=>'window_close_requested'});
	dsPGtkGUI->quit_main_loop();
	return;
}

sub apply_settings_to_widgets
{
	my($s)=@_;
	return if ref($s) ne 'HASH';

	my %map=
	(
		device_entry=>'device', sample_rate_entry=>'sample_rate',
		lf_entry=>'lf', hf_entry=>'hf', order_entry=>'order',
		peak_entry=>'peak', delay_entry=>'delay',
		frequency_entry=>'frequency'
	);

	$GTK->{$_}->set_text($s->{$map{$_}}//'') for keys %map;
	$GTK->{folder_button}->set_label($s->{work_dir}//'.');
	$GTK->{base_lat_entry}->set_text($s->{base}{latitude}//'');
	$GTK->{base_lon_entry}->set_text($s->{base}{longitude}//'');
	$GTK->{base_alt_entry}->set_text($s->{base}{altitude}//'');
	$GTK->{base_angle_entry}->set_text($s->{base}{angle}//'');
	set_toggle('invert_check',$s->{invert});
	set_toggle('share_check',$s->{share});
	set_toggle('mobile_check',$s->{mobile});
}

sub settings
{
	return
		{
			work_dir=>$GTK->{folder_button}->get_label(),
			device=>$GTK->{device_entry}->get_text(),
			sample_rate=>$GTK->{sample_rate_entry}->get_text(),
			lf=>$GTK->{lf_entry}->get_text(),
			hf=>$GTK->{hf_entry}->get_text(),
			order=>$GTK->{order_entry}->get_text(),
			peak=>$GTK->{peak_entry}->get_text(),
			delay=>$GTK->{delay_entry}->get_text(),
			invert=>$GTK->{invert_check}->get_active()?1:0,
			frequency=>$GTK->{frequency_entry}->get_text(),
			share=>$GTK->{share_check}->get_active()?1:0,
			mobile=>$GTK->{mobile_check}->get_active()?1:0,
			base=>
				{
					latitude=>$GTK->{base_lat_entry}->get_text(),
					longitude=>$GTK->{base_lon_entry}->get_text(),
					altitude=>$GTK->{base_alt_entry}->get_text(),
					angle=>$GTK->{base_angle_entry}->get_text()
				}
		};
}

sub choose_file
{
	my($title,$patterns)=@_;
	my $d=Gtk3::FileChooserDialog->new($title,$GTK->{main_window},'open','gtk-cancel'=>'cancel','gtk-open'=>'accept');
	$d->set_current_folder($GTK->{folder_button}->get_label()) if -d $GTK->{folder_button}->get_label();
	my $f=Gtk3::FileFilter->new();
	$f->set_name($title);
	$f->add_pattern($_) for @$patterns;
	$d->add_filter($f);
	my $p=$d->run() eq 'accept'?$d->get_filename():undef;
	$d->destroy();
	return $p;
}

sub apply_requested_setting
{
	my($name,$value)=@_;

	my %text_widgets=
	(
		device=>'device_entry',
		sample_rate=>'sample_rate_entry',
		lf=>'lf_entry',
		hf=>'hf_entry',
		order=>'order_entry',
		peak=>'peak_entry',
		delay=>'delay_entry',
		frequency=>'frequency_entry',
		base_latitude=>'base_lat_entry',
		base_longitude=>'base_lon_entry',
		base_altitude=>'base_alt_entry',
		base_angle=>'base_angle_entry'
	);

	if(exists($text_widgets{$name}))
	{
		$GTK->{$text_widgets{$name}}->set_text(defined($value)?$value:'');
	}
	elsif($name eq 'work_dir')
	{
		$GTK->{folder_button}->set_label(defined($value)?$value:'.');
	}
	elsif($name eq 'invert')
	{
		set_toggle('invert_check',$value);
	}
	elsif($name eq 'share' || $name eq 'SONDEHUB_SHARE')
	{
		set_toggle('share_check',$value);
	}
	elsif($name eq 'mobile' || $name eq 'SONDEHUB_MOBIL')
	{
		set_toggle('mobile_check',$value);
	}
	else
	{
		return 0;
	}

	terminal_message(
		'INFO',
		'Beállítási esemény a GUI mezőibe betöltve: '.$name
	);
	return 1;
}

sub normalize_selected_file_path
{
	my ($path) = @_;

	return if !defined($path) || $path eq '';
	return if $path =~ /[\0\r\n]/;

	my $absolute_path = File::Spec->file_name_is_absolute($path)
		? File::Spec->canonpath($path)
		: File::Spec->rel2abs($path, $FindBin::Bin);

	return if !-f $absolute_path || !-r $absolute_path;

	return $absolute_path;
}

sub request_file_path
{
	my($kind,$path,$source)=@_;
	$path=normalize_selected_file_path($path);

	if(!defined($path))
	{
		$GTK->{status_label}->set_text('Állapot: a kiválasztott fájl nem olvasható');
		return;
	}

	my %definition=
	(
		wav  => {type=>'play_wav_requested',  label=>'WAV'},
		raw  => {type=>'play_raw_requested',  label=>'RAW'},
		json => {type=>'play_json_requested', label=>'JSON'}
	);

	my $item=$definition{lc($kind//'')};
	return if ref($item) ne 'HASH';

	$GTK->{status_label}->set_text('Állapot: '.$item->{label}.' indítási kérés');
	terminal_message('INFO',$item->{label}.' megnyitási kérés: '.$path);
	send_main({type=>$item->{type},path=>$path,source=>$source//'gui'});
}

sub request_wav_path { request_file_path('wav', @_); }
sub request_raw_path { request_file_path('raw', @_); }
sub request_json_path { request_file_path('json', @_); }

sub request_recording
{
	my($source)=@_;
	terminal_message('INFO','Felvétel indítási kérés.');
	send_main({type=>'start_recording_requested',source=>$source//'gui'});
}

sub request_toggle_service
{
	my($service,$active,$source)=@_;
	$active=$active?1:0;

	if($service eq 'bt')
	{
		set_toggle('bt_button',$active);

		if($active)
		{
			start_gui_service('bt');
		}
		else
		{
			send_main({type=>'bt_stop_requested',source=>$source//'gui'});
		}
	}
	elsif($service eq 'sondehub')
	{
		set_toggle('sondehub_button',$active);

		if($active)
		{
			start_gui_service('sondehub');
		}
		else
		{
			send_main({type=>'sondehub_stop_requested',source=>$source//'gui'});
		}
	}
}

sub on_record_clicked
{
	request_recording('gui_menu');
}

sub on_open_wav_clicked
{
	my $p=choose_file('WAV fájl megnyitása',[qw(*.wav *.WAV)]);
	request_wav_path($p,'gui_menu') if $p;
}

sub on_open_raw_clicked
{
	my $p=choose_file('RAW fájl megnyitása',[qw(*.Rlog *.rlog *.raw *.RAW *.txt)]);
	request_raw_path($p,'gui_menu') if $p;
}

sub on_open_json_clicked
{
	my $p=choose_file('JSON fájl megnyitása',[qw(*.Jlog *.jlog *.json *.JSON *.txt)]);
	request_json_path($p,'gui_menu') if $p;
}

sub on_stop_clicked
{
	send_main({type=>'stop_requested'});
}

sub on_bt_toggled
{
	return if $internal;

	if($GTK->{bt_button}->get_active())
	{
		start_gui_service('bt');
	}
	else
	{
		send_main({type=>'bt_stop_requested'});
	}

	return;
}

sub on_sondehub_toggled
{
	return if $internal;

	if($GTK->{sondehub_button}->get_active())
	{
		start_gui_service('sondehub');
	}
	else
	{
		send_main({type=>'sondehub_stop_requested'});
	}

	return;
}

sub on_folder_clicked
{
	my $d=Gtk3::FileChooserDialog->new
	(
		'Munkamappa kiválasztása',
		$GTK->{main_window},
		'select-folder',
		'gtk-cancel'=>'cancel',
		'gtk-open'=>'accept'
	);

	$d->set_current_folder($GTK->{folder_button}->get_label()) if -d $GTK->{folder_button}->get_label();
	if($d->run() eq 'accept')
	{
		my $p=$d->get_filename();
		$GTK->{folder_button}->set_label($p);
	}
	$d->destroy();
}

sub on_refresh_clicked
{
	load_html();
}

sub on_apply_base_clicked
{
	my $current = settings();

	$GTK->{status_label}->set_text(
		'Állapot: bázis és frekvencia alkalmazása...'
	);

	send_main(
		{
			type => 'settings_apply_requested',
			settings =>
			{
				frequency => $current->{frequency},
				share     => $current->{share},
				mobile    => $current->{mobile},
				base      => $current->{base}
			},
			source => 'gui_apply_button'
		}
	);

	return;
}

sub on_share_toggled
{
	return if $internal;

	on_apply_base_clicked();
	return;
}

sub on_mobile_toggled
{
	return if $internal;

	on_apply_base_clicked();
	return;
}

sub on_center_toggled
{
	run_js('window.setFollowSonde('.($GTK->{center_check}->get_active()?'true':'false').');');
}

sub on_save_processing_clicked
{
	$GTK->{status_label}->set_text(
		'Állapot: az összes beállítás mentése...'
	);

	send_main(
		{
			type     => 'settings_save_requested',
			settings => settings(),
			source   => 'gui_save_button'
		}
	);

	return;
}

sub append_log
{
	my($target,$text)=@_;
	my $v=$target eq 'json'?$GTK->{json_view}:$GTK->{prc_view};
	my $b=$v->get_buffer();
	my $e=$b->get_end_iter();
	$b->insert($e,$text);
	my $m=$b->create_mark(undef,$b->get_end_iter(),FALSE);
	$v->scroll_to_mark($m,0,TRUE,0,1);
	$b->delete_mark($m);
}

sub run_js
{
	my($s)=@_;
	eval
	{
		$webview->run_javascript($s,undef,undef,undef)
	}
	;
	append_log('prc',"WebKit JavaScript hiba: $@\n") if $@;
}

sub read_html
{
	open my $h,'<:encoding(UTF-8)',"$FindBin::Bin/UI.html" or die $!;
	local $/;
	my $x=<$h>;
	close $h;
	return $x;
}

sub apply_html_config
{
	my($h,$c)=@_;
	my %r=
		(
			BASE_ARROW_COLOR=>$c->{base_arrow_color}//'#42c9ff',
			SONDE_ARROW_COLOR=>$c->{sonde_arrow_color}//'#e3a52b',
			TRACK_COLOR=>$json->encode($c->{track_color}//'#e3a52b'),
			TILE_SERVER=>$json->encode($c->{tile_server}//'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
			MAP_START_LAT=>$c->{map_start_lat}//47.49786,
			MAP_START_LON=>$c->{map_start_lon}//19.04022,
			MAP_START_ZOOM=>$c->{map_start_zoom}//9,
			TRACK_WIDTH=>$c->{track_width}//4,
			TRACK_OPACITY=>$c->{track_opacity}//0.9,
			TRACK_POINT_RADIUS=>$c->{track_point_radius}//3
		);

	$h =~ s/__\Q$_\E__/$r{$_}/g for keys %r;
	return $h;
}
my $html_config={};

sub load_html
{
	$webview->load_html(apply_html_config(read_html(),$html_config),'file:///');
	for my $d (200,600,1400)
	{
		Glib::Timeout->add
			(
				$d,
				sub
				{
					update_base_js(settings()->{base});
					run_js
						(
							'window.rs41RestoreTrack('.
							$json->encode($frontend_state->{track_history}).
							','.
							(defined $frontend_state->{last_receiver_data}?$json->encode($frontend_state->{last_receiver_data}):'null')
							.');'
						);
					return FALSE;
				}
			);
	}
}

sub update_base_js
{
	my($b)=@_;
	run_js
		(
			'window.baseUpdate('.
				$json->encode({latitude=>0+$b->{latitude},
				longitude=>0+$b->{longitude},
				altitude=>0+$b->{altitude},
				angle=>0+$b->{angle}}).
			');'
		) if $b->{latitude}=~/^-?\d/ && $b->{longitude}=~/^-?\d/;
}

sub set_toggle
{
	my($id,$v)=@_;
	$internal=1;
	$GTK->{$id}->set_active($v?TRUE:FALSE);
	$internal=0;
}

sub dispatch
{
	my($m)=@_;
	my $t=$m->{type}//'';
	if(is_frontend_event_request($m))
	{
		my $event=$m->{event}//'';

		if($event eq 'open_wav')
		{
			request_wav_path($m->{path},$m->{source}//'launcher');
		}
		elsif($event eq 'open_raw')
		{
			request_raw_path($m->{path},$m->{source}//'launcher');
		}
		elsif($event eq 'open_json')
		{
			request_json_path($m->{path},$m->{source}//'launcher');
		}
		elsif($event eq 'start_recording')
		{
			request_recording($m->{source}//'launcher');
		}
		elsif($event eq 'set_bt')
		{
			request_toggle_service('bt',$m->{active},$m->{source}//'launcher');
		}
		elsif($event eq 'set_sondehub')
		{
			request_toggle_service('sondehub',$m->{active},$m->{source}//'launcher');
		}
		elsif($event eq 'activate_menu')
		{
			my $key=$m->{menu_key}//'';
			$key eq '1' ? on_record_clicked()
				: $key eq '5' ? on_stop_clicked()
				: undef;
		}
		elsif($event eq 'setting_change')
		{
			apply_requested_setting($m->{name},$m->{value});
		}

		return;
	}
	if($t eq 'initialize')
	{
		$html_config=$m->{html_config}//{};
		apply_settings_to_widgets($m->{settings});
		load_html();
	}
	elsif($t eq 'settings_state')
	{
		$html_config=$m->{html_config}//$html_config//{};
		apply_settings_to_widgets($m->{settings});

		update_base_js($m->{settings}{base})
			if ref($m->{settings}) eq 'HASH'
			&& ref($m->{settings}{base}) eq 'HASH';

		$GTK->{status_label}->set_text(
			'Állapot: a main beállításai újratöltve'
		);
	}
	elsif($t eq 'append_log')
	{
		#append_log($m->{target},$m->{text});

		my $target=$m->{target}//'';
		my $text=$m->{text}//'';

		#append_log($target,$text)
		#	if $target ne 'prc' || $text !~ /^SondeHub:/;

		append_log($target,$text)
			if $target ne 'prc'
				|| $text !~ /^(?:BT|SondeHub):\s*/;

	}
	elsif($t eq 'clear_logs')
	{
		$GTK->{prc_view}->get_buffer()->set_text('');
		$GTK->{json_view}->get_buffer()->set_text('');
		run_js('window.rs41Reset();');
		reset_frontend_state($frontend_state);
	}
	elsif($t eq 'running_state')
	{
		my $r=$m->{running};
		$_->set_sensitive(!$r) for @{$GTK}{qw(record_button open_wav_button open_raw_button open_json_button folder_button)};
		$GTK->{stop_button}->set_sensitive($r);
		$GTK->{status_label}->set_text($r?'Állapot: '.($m->{description}//'fut'):'Állapot: áll');
	}
	elsif($t eq 'receiver_update')
	{
		apply_receiver_update($frontend_state,$m->{data});
		run_js('window.rs41Update('.$json->encode($m->{data}).');');
	}
	elsif($t eq 'runtime_statistics')
	{
		apply_runtime_statistics($frontend_state,$m);
		$GTK->{packet_counter_label}->set_text(packet_summary_text($frontend_state));
		run_js('window.rs41StatsUpdate('.$json->encode($m->{runtime}).');');
	}
	elsif($t eq 'calculated_fields')
	{
		apply_calculated_fields($frontend_state,$m);
		$GTK->{distance_entry}->set_text($m->{distance}//'?');
		$GTK->{bearing_entry}->set_text($m->{bearing}//'?');
		$GTK->{elevation_entry}->set_text($m->{elevation}//'?');
	}
	elsif($t eq 'base_position_update')
	{
		my $b=$m->{base};
		$GTK->{base_lat_entry}->set_text(sprintf('%.8f',$b->{latitude}));
		$GTK->{base_lon_entry}->set_text(sprintf('%.8f',$b->{longitude}));
		$GTK->{base_alt_entry}->set_text(sprintf('%.2f',$b->{altitude}));
		$GTK->{base_angle_entry}->set_text(sprintf('%.2f',$b->{angle}));
		update_base_js($b);
	}
	elsif($t eq 'service_opened')
	{
		complete_gui_service($m);
	}
	elsif($t eq 'bt_state')
	{
		set_toggle('bt_button',$m->{active});
		close_gui_service('bt',0) if !$m->{active};
	}
	elsif($t eq 'sondehub_state')
	{
		set_toggle('sondehub_button',$m->{active});
		close_gui_service('sondehub',0) if !$m->{active};
	}
	elsif($t eq 'shutdown')
	{
		close_gui_service($_,0) for qw(bt sondehub);
		dsPGtkGUI->quit_main_loop();
	}
}

sub read_stdin
{
	my $c='';
	my $n=sysread(STDIN,$c,65536);
	return FALSE if defined($n)&&$n==0;
	if(defined $n&&$n>0)
	{
		$stdin_buffer.=$c;
		while($stdin_buffer =~ s/^(.*?\n)//s)
		{
			my $m=decode_json_line($1);
			dispatch($m) if ref($m) eq 'HASH';
		}
	}
	return TRUE;
}

dsPGtkGUI->gtk_init();

$UI=dsPGtkGUI->LoadGLADE("$FindBin::Bin/UI.glade");
$GTK=$UI->{GTK};
$webview=$GTK->{webview};

for my $entry_name
(
	qw(
		base_lat_entry
		base_lon_entry
		base_alt_entry
		base_angle_entry
		device_entry
		sample_rate_entry
		lf_entry
		hf_entry
		order_entry
		peak_entry
		delay_entry
		frequency_entry
	)
)
{
	next if !defined($GTK->{$entry_name});

	$GTK->{$entry_name}->set_editable(TRUE);
	$GTK->{$entry_name}->set_can_focus(TRUE);
}

apply_settings_to_widgets($default_settings);
$GTK->{main_window}->show_all();
$GTK->{stop_button}->set_sensitive(FALSE);

my $flags=fcntl(STDIN,F_GETFL,0);

fcntl(STDIN,F_SETFL,$flags|O_NONBLOCK);

Glib::IO->add_watch(fileno(STDIN),['in','hup','err'],sub{return read_stdin();});

terminal_message('INFO','A GUI-folyamat elindult (v0.2.46) és a felület betöltődött.');

send_main({type=>'frontend_ready',frontend=>'gui'});

Glib::Timeout->add
(
	50,
	sub
	{
		poll_gui_service_controls();
		return TRUE;
	}
);

dsPGtkGUI->run_main_loop();

close_gui_service($_,0) for qw(bt sondehub);

terminal_message('INFO','A GUI-folyamat leáll.');

exit 0;
