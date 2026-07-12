#!/usr/bin/env python3

import argparse
import struct
import sys

import numpy as np
from scipy import signal


DEFAULT_LOW_CUT_HZ = 200.0
DEFAULT_HIGH_CUT_HZ = 8000.0
DEFAULT_FILTER_ORDER = 3
DEFAULT_TARGET_PEAK = 0.75
DEFAULT_DELAY_SECONDS = 0.5
DEFAULT_MAX_GAIN = 8.0


def parse_args():
	parser = argparse.ArgumentParser(
		description=(
			"Folyamatos RS41 WAV-stream szűrő. "
			"PCM S16_LE mono WAV-adatot olvas stdinről, és folyamatos WAV-adatot ír stdout-ra."
		),
	)

	parser.add_argument(
		"-LF",
		"--low-frequency",
		type=float,
		default=DEFAULT_LOW_CUT_HZ,
		metavar="HZ",
		help=f"Alsó vágási frekvencia. Alapérték: {DEFAULT_LOW_CUT_HZ:g} Hz.",
	)
	parser.add_argument(
		"-HF",
		"--high-frequency",
		type=float,
		default=DEFAULT_HIGH_CUT_HZ,
		metavar="HZ",
		help=f"Felső vágási frekvencia. Alapérték: {DEFAULT_HIGH_CUT_HZ:g} Hz.",
	)
	parser.add_argument(
		"-O",
		"--order",
		type=int,
		default=DEFAULT_FILTER_ORDER,
		metavar="N",
		help=f"Butterworth szűrő rendje. Alapérték: {DEFAULT_FILTER_ORDER}.",
	)
	parser.add_argument(
		"-P",
		"--peak",
		type=float,
		default=DEFAULT_TARGET_PEAK,
		metavar="VALUE",
		help=f"AGC célcsúcsszint 0 és 1 között. Alapérték: {DEFAULT_TARGET_PEAK:g}.",
	)
	parser.add_argument(
		"-D",
		"--delay",
		type=float,
		default=DEFAULT_DELAY_SECONDS,
		metavar="SEC",
		help=(
			"Feldolgozási blokk és hozzávetőleges késleltetés másodpercben. "
			f"Alapérték: {DEFAULT_DELAY_SECONDS:g} s."
		),
	)
	parser.add_argument(
		"-MG",
		"--max-gain",
		type=float,
		default=DEFAULT_MAX_GAIN,
		metavar="X",
		help=f"Az automatikus erősítés felső korlátja. Alapérték: {DEFAULT_MAX_GAIN:g}×.",
	)
	parser.add_argument(
		"-NA",
		"--no-agc",
		action="store_true",
		help="Automatikus csúcsszint-beállítás kikapcsolása.",
	)
	parser.add_argument(
		"-V",
		"--verbose",
		action="store_true",
		help="A tényleges paraméterek kiírása stderr-re.",
	)

	return parser.parse_args()


def read_exact(stream, size):
	data = bytearray()

	while len(data) < size:
		part = stream.read(size - len(data))

		if not part:
			break

		data.extend(part)

	return bytes(data)


def read_wav_header(stream):
	header = read_exact(stream, 12)

	if len(header) != 12:
		raise RuntimeError("Hiányos WAV-fejléc.")

	riff, riff_size, wave = struct.unpack("<4sI4s", header)

	if riff not in (b"RIFF", b"RF64") or wave != b"WAVE":
		raise RuntimeError("A bemenet nem RIFF/WAVE adatfolyam.")

	fmt = None
	data_size = None

	while True:
		chunk_header = read_exact(stream, 8)

		if len(chunk_header) != 8:
			raise RuntimeError("A WAV data chunk nem található.")

		chunk_id, chunk_size = struct.unpack("<4sI", chunk_header)

		if chunk_id == b"fmt ":
			chunk = read_exact(stream, chunk_size)

			if len(chunk) != chunk_size or chunk_size < 16:
				raise RuntimeError("Hiányos WAV fmt chunk.")

			audio_format, channels, sample_rate, byte_rate, block_align, bits = struct.unpack(
				"<HHIIHH",
				chunk[:16],
			)
			fmt = {
				"audio_format": audio_format,
				"channels": channels,
				"sample_rate": sample_rate,
				"byte_rate": byte_rate,
				"block_align": block_align,
				"bits": bits,
			}

		elif chunk_id == b"data":
			data_size = chunk_size
			break

		else:
			skipped = read_exact(stream, chunk_size)

			if len(skipped) != chunk_size:
				raise RuntimeError(f"Hiányos WAV chunk: {chunk_id!r}.")

		if chunk_size & 1:
			read_exact(stream, 1)

	if fmt is None:
		raise RuntimeError("A WAV fmt chunk nem található.")

	if fmt["audio_format"] != 1:
		raise RuntimeError(
			f"Csak PCM WAV támogatott, a kapott formátumkód: {fmt['audio_format']}."
		)

	if fmt["channels"] != 1:
		raise RuntimeError(
			f"Csak mono WAV támogatott, a kapott csatornaszám: {fmt['channels']}."
		)

	if fmt["bits"] != 16:
		raise RuntimeError(
			f"Csak 16 bites PCM WAV támogatott, a kapott bitszám: {fmt['bits']}."
		)

	return fmt, data_size


def write_streaming_wav_header(stream, sample_rate):
	# Nagy, előre megadott méret: folyamatos pipe esetén a tényleges hossz nem ismert.
	data_size = 0x7FFFF000
	riff_size = 36 + data_size
	channels = 1
	bits = 16
	block_align = channels * bits // 8
	byte_rate = sample_rate * block_align

	header = struct.pack(
		"<4sI4s4sIHHIIHH4sI",
		b"RIFF",
		riff_size,
		b"WAVE",
		b"fmt ",
		16,
		1,
		channels,
		sample_rate,
		byte_rate,
		block_align,
		bits,
		b"data",
		data_size,
	)

	stream.write(header)
	stream.flush()


def validate_args(args, sample_rate):
	nyquist = sample_rate / 2.0

	if args.low_frequency <= 0.0:
		raise ValueError("Az -LF értékének 0 Hz-nél nagyobbnak kell lennie.")

	if args.high_frequency <= args.low_frequency:
		raise ValueError("A -HF értékének nagyobbnak kell lennie az -LF értékénél.")

	if args.high_frequency >= nyquist:
		raise ValueError(
			f"A -HF értékének kisebbnek kell lennie {nyquist:g} Hz-nél."
		)

	if args.order < 1:
		raise ValueError("Az -O értékének legalább 1-nek kell lennie.")

	if not 0.0 < args.peak <= 1.0:
		raise ValueError("A -P értékének 0 és 1 közé kell esnie.")

	if args.delay < 0.1:
		raise ValueError("A -D értékének legalább 0,1 másodpercnek kell lennie.")

	if args.max_gain <= 0.0:
		raise ValueError("Az -MG értékének 0-nál nagyobbnak kell lennie.")


def make_filters(sample_rate, args):
	sos_high = signal.butter(
		args.order,
		args.low_frequency,
		btype="highpass",
		fs=sample_rate,
		output="sos",
	)
	sos_low = signal.butter(
		args.order,
		args.high_frequency,
		btype="lowpass",
		fs=sample_rate,
		output="sos",
	)

	return sos_high, sos_low


def filter_window(audio, sos_high, sos_low):
	if audio.size < 64:
		return audio.copy()

	filtered = signal.sosfiltfilt(
		sos_high,
		audio,
	)
	filtered = signal.sosfiltfilt(
		sos_low,
		filtered,
	)

	return filtered


def read_pcm_chunk(stream, samples, remaining_bytes):
	wanted_bytes = samples * 2

	if remaining_bytes is not None:
		wanted_bytes = min(wanted_bytes, remaining_bytes)

	if wanted_bytes <= 0:
		return np.empty(0, dtype=np.float64), remaining_bytes

	data = read_exact(stream, wanted_bytes)

	if not data:
		return np.empty(0, dtype=np.float64), remaining_bytes

	if len(data) & 1:
		data = data[:-1]

	if remaining_bytes is not None:
		remaining_bytes -= len(data)

	audio = np.frombuffer(data, dtype="<i2").astype(np.float64)
	audio /= 32768.0

	return audio, remaining_bytes


def write_pcm(stream, audio):
	audio = np.clip(audio, -0.999969482421875, 0.999969482421875)
	pcm = np.rint(audio * 32768.0).astype("<i2")
	stream.write(pcm.tobytes())
	stream.flush()


def update_gain(current_gain, filtered_window, args):
	if args.no_agc:
		return 1.0

	peak = float(np.max(np.abs(filtered_window))) if filtered_window.size else 0.0

	if peak <= 1.0e-12:
		desired_gain = 1.0
	else:
		desired_gain = min(args.peak / peak, args.max_gain)

	if current_gain is None:
		return desired_gain

	# Túlvezérlés felé gyorsan, erősítés növelése felé lassabban reagál.
	alpha = 0.65 if desired_gain < current_gain else 0.15

	return current_gain + alpha * (desired_gain - current_gain)


def process_stream(args):
	input_stream = sys.stdin.buffer
	output_stream = sys.stdout.buffer

	fmt, data_size = read_wav_header(input_stream)
	sample_rate = fmt["sample_rate"]
	validate_args(args, sample_rate)

	# 0 vagy 0xFFFFFFFF gyakran ismeretlen hosszúságú streaming WAV-ot jelent.
	if data_size in (0, 0xFFFFFFFF, 0x7FFFFFFF):
		remaining_bytes = None
	else:
		remaining_bytes = data_size

	block_samples = max(1, int(round(sample_rate * args.delay)))
	sos_high, sos_low = make_filters(sample_rate, args)

	if args.verbose:
		print(
			f"sample_rate={sample_rate} Hz, LF={args.low_frequency:g} Hz, "
			f"HF={args.high_frequency:g} Hz, order={args.order}, "
			f"peak={args.peak:g}, delay≈{args.delay:g} s, "
			f"block={block_samples} samples, "
			f"AGC={'off' if args.no_agc else 'on'}",
			file=sys.stderr,
			flush=True,
		)

	write_streaming_wav_header(output_stream, sample_rate)

	first, remaining_bytes = read_pcm_chunk(
		input_stream,
		block_samples,
		remaining_bytes,
	)

	if first.size == 0:
		return

	second, remaining_bytes = read_pcm_chunk(
		input_stream,
		block_samples,
		remaining_bytes,
	)

	current_gain = None

	if second.size == 0:
		filtered = filter_window(first, sos_high, sos_low)
		current_gain = update_gain(current_gain, filtered, args)
		write_pcm(output_stream, filtered * current_gain)
		return

	# Első blokk: csak jobb oldali környezet áll rendelkezésre.
	window = np.concatenate((first, second))
	filtered = filter_window(window, sos_high, sos_low)
	current_gain = update_gain(current_gain, filtered, args)
	write_pcm(output_stream, filtered[:first.size] * current_gain)

	previous = first
	current = second

	while True:
		next_chunk, remaining_bytes = read_pcm_chunk(
			input_stream,
			block_samples,
			remaining_bytes,
		)

		if next_chunk.size == 0:
			window = np.concatenate((previous, current))
			filtered = filter_window(window, sos_high, sos_low)
			current_gain = update_gain(current_gain, filtered, args)
			write_pcm(output_stream, filtered[previous.size:] * current_gain)
			break

		window = np.concatenate((previous, current, next_chunk))
		filtered = filter_window(window, sos_high, sos_low)
		current_gain = update_gain(current_gain, filtered, args)

		start = previous.size
		end = start + current.size
		write_pcm(output_stream, filtered[start:end] * current_gain)

		previous = current
		current = next_chunk


def main():
	args = parse_args()
	process_stream(args)


if __name__ == "__main__":
	try:
		main()
	except BrokenPipeError:
		pass
	except KeyboardInterrupt:
		pass
	except Exception as error:
		print(f"HIBA: {error}", file=sys.stderr, flush=True)
		sys.exit(1)
