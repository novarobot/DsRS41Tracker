package RS41FrontendData;

use strict;
use warnings;
use utf8;

use Exporter qw(import);

our @EXPORT_OK = qw(
	new_frontend_state
	reset_frontend_state
	apply_receiver_update
	apply_runtime_statistics
	apply_calculated_fields
	packet_summary_text
	packet_ratio_text
	frontend_table_values
);

sub new_frontend_state
{
	return
	{
		track_history      => [],
		last_receiver_data => undef,
		packet_count       =>
		{
			VALID   => 0,
			PARTIAL => 0,
			INVALID => 0
		},
		runtime =>
		{
			last_success_age_s => undef,
			total_path_m       => undef,
			peak_altitude_m    => undef,
			peak_altitude_time => undef
		},
		calculated =>
		{
			distance  => '?',
			bearing   => '?',
			elevation => '?'
		}
	};
}

sub reset_frontend_state
{
	my ($state) = @_;

	return if ref($state) ne 'HASH';

	my $new_state = new_frontend_state();
	%{$state} = %{$new_state};

	return;
}

sub _value
{
	my ($hash, @path) = @_;

	my $value = $hash;

	for my $key (@path)
	{
		return undef if ref($value) ne 'HASH';
		return undef if !exists($value->{$key});
		$value = $value->{$key};
	}

	return $value;
}

sub _first_defined
{
	for my $value (@_)
	{
		return $value if defined($value) && $value ne '';
	}

	return undef;
}

sub _merge_defined
{
	my ($target, $source) = @_;

	return if ref($target) ne 'HASH';
	return if ref($source) ne 'HASH';

	for my $key (keys %{$source})
	{
		my $value = $source->{$key};

		# PARTIAL/INVALID keretben a hiányzó (undef) mező nem törli
		# a korábban sikeresen dekódolt értéket.
		next if !defined($value);

		if (ref($value) eq 'HASH')
		{
			$target->{$key} = {}
				if ref($target->{$key}) ne 'HASH';
			_merge_defined($target->{$key}, $value);
		}
		else
		{
			$target->{$key} = $value;
		}
	}

	return;
}

sub apply_receiver_update
{
	my ($state, $data) = @_;

	return if ref($state) ne 'HASH';
	return if ref($data) ne 'HASH';

	$state->{last_receiver_data} = {}
		if ref($state->{last_receiver_data}) ne 'HASH';

	_merge_defined($state->{last_receiver_data}, $data);

	my $position = ref($data->{position}) eq 'HASH'
		? $data->{position}
		: {};

	if (defined($position->{latitude_deg})
		&& defined($position->{longitude_deg}))
	{
		push @{$state->{track_history}},
		{
			lat     => 0 + $position->{latitude_deg},
			lon     => 0 + $position->{longitude_deg},
			alt     => $position->{altitude_m},
			heading => $position->{heading_deg},
			time    => _value($data, 'gps_time', 'utc_uncorrected')
		};
	}

	return;
}

sub apply_runtime_statistics
{
	my ($state, $message) = @_;

	return if ref($state) ne 'HASH';
	return if ref($message) ne 'HASH';

	if (ref($message->{packet_count}) eq 'HASH')
	{
		for my $key (qw(VALID PARTIAL INVALID))
		{
			$state->{packet_count}{$key} =
				0 + ($message->{packet_count}{$key} // 0);
		}
	}

	if (ref($message->{runtime}) eq 'HASH')
	{
		$state->{runtime} =
		{
			%{$state->{runtime}},
			%{$message->{runtime}}
		};
	}

	return;
}

sub apply_calculated_fields
{
	my ($state, $message) = @_;

	return if ref($state) ne 'HASH';
	return if ref($message) ne 'HASH';

	for my $key (qw(distance bearing elevation))
	{
		$state->{calculated}{$key} = $message->{$key}
			if exists($message->{$key});
	}

	return;
}

sub packet_summary_text
{
	my ($state) = @_;

	my $packet = ref($state->{packet_count}) eq 'HASH'
		? $state->{packet_count}
		: {};

	return sprintf(
		'VALID: %d / PARTIAL: %d / INVALID: %d',
		$packet->{VALID} // 0,
		$packet->{PARTIAL} // 0,
		$packet->{INVALID} // 0
	);
}

sub packet_ratio_text
{
	my ($state) = @_;

	my $packet = ref($state->{packet_count}) eq 'HASH'
		? $state->{packet_count}
		: {};

	my $valid = 0 + ($packet->{VALID} // 0);
	my $partial = 0 + ($packet->{PARTIAL} // 0);
	my $invalid = 0 + ($packet->{INVALID} // 0);
	my $total = $valid + $partial + $invalid;

	return '0.0% / 0.0% / 0.0%' if !$total;

	return sprintf(
		'%.1f%% / %.1f%% / %.1f%%',
		100 * $valid / $total,
		100 * $partial / $total,
		100 * $invalid / $total
	);
}

sub frontend_table_values
{
	my ($state) = @_;

	my $data = ref($state->{last_receiver_data}) eq 'HASH'
		? $state->{last_receiver_data}
		: {};

	my $position = ref($data->{position}) eq 'HASH'
		? $data->{position}
		: {};

	my $ptu = ref($data->{ptu}) eq 'HASH'
		? $data->{ptu}
		: {};

	my $raw = ref($data->{raw}) eq 'HASH'
		? $data->{raw}
		: {};

	my $raw_measurements = ref($ptu->{raw_measurements}) eq 'HASH'
		? $ptu->{raw_measurements}
		: {};

	my $calibration = ref($data->{calibration}) eq 'HASH'
		? $data->{calibration}
		: {};

	my $runtime = ref($state->{runtime}) eq 'HASH'
		? $state->{runtime}
		: {};

	return
	{
		validity => $data->{validity},
		frame => _first_defined($data->{frame_number}, $data->{frame}),
		sonde_id => _first_defined($data->{sonde_id}, $data->{serial}),
		battery => defined($data->{battery_v})
			? $data->{battery_v} . ' V' : undef,
		latitude => defined($position->{latitude_deg})
			? $position->{latitude_deg} . '°' : undef,
		longitude => defined($position->{longitude_deg})
			? $position->{longitude_deg} . '°' : undef,
		altitude => defined($position->{altitude_m})
			? $position->{altitude_m} . ' m' : undef,
		velocity_h => defined($position->{velocity_h_ms})
			? $position->{velocity_h_ms} . ' m/s' : undef,
		heading => defined($position->{heading_deg})
			? $position->{heading_deg} . '°' : undef,
		velocity_v => defined($position->{velocity_v_ms})
			? $position->{velocity_v_ms} . ' m/s' : undef,
		temperature => defined($ptu->{temperature_c})
			? $ptu->{temperature_c} . ' °C' : undef,
		humidity_temperature => defined($ptu->{humidity_sensor_temperature_c})
			? $ptu->{humidity_sensor_temperature_c} . ' °C' : undef,
		humidity => defined($ptu->{relative_humidity_pct})
			? $ptu->{relative_humidity_pct} . ' %' : undef,
		empirical_rh => defined($ptu->{relative_humidity_empirical_pct})
			? $ptu->{relative_humidity_empirical_pct} . ' %' : undef,
		gps_time => _first_defined(
			_value($data, 'gps_time', 'utc_uncorrected'),
			_value($data, 'gps_time', 'utc')
		),
		last_success => defined($runtime->{last_success_age_s})
			? $runtime->{last_success_age_s} . ' s' : undef,
		total_path => defined($runtime->{total_path_m})
			? $runtime->{total_path_m} . ' m' : undef,
		satellites => $position->{satellites},
		pressure => defined($ptu->{pressure_hpa})
			? $ptu->{pressure_hpa} . ' hPa' : undef,
		estimated_pressure => defined($ptu->{pressure_estimated_hpa})
			? $ptu->{pressure_estimated_hpa} . ' hPa' : undef,
		peak_altitude => defined($runtime->{peak_altitude_m})
			? $runtime->{peak_altitude_m} . ' m' : undef,
		calibration => _first_defined(
			$calibration->{complete},
			$data->{calibration_complete}
		),
		calibration_frames => _first_defined(
			$calibration->{frames_text},
			defined($calibration->{seen_count})
				? $calibration->{seen_count} . ' / 51' : undef,
			$data->{calibration_frames}
		),
		raw_t => _first_defined(
			$raw->{T}, $ptu->{raw_t},
			ref($raw_measurements->{temperature}) eq 'ARRAY'
				? join('/', @{$raw_measurements->{temperature}}) : undef
		),
		raw_h => _first_defined(
			$raw->{H}, $ptu->{raw_h},
			ref($raw_measurements->{humidity}) eq 'ARRAY'
				? join('/', @{$raw_measurements->{humidity}}) : undef
		),
		raw_th => _first_defined(
			$raw->{TH}, $ptu->{raw_th},
			ref($raw_measurements->{humidity_temp}) eq 'ARRAY'
				? join('/', @{$raw_measurements->{humidity_temp}}) : undef
		),
		raw_p => _first_defined(
			$raw->{P}, $ptu->{raw_p},
			ref($raw_measurements->{pressure}) eq 'ARRAY'
				? join('/', @{$raw_measurements->{pressure}}) : undef
		),
		peak_time => $runtime->{peak_altitude_time}
	};
}

1;
