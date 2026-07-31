#!/usr/bin/env bash

set -u

CALL_DIR="$(pwd)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

export PYTHONIOENCODING="UTF-8"

fail()
{
	printf '%s\n' "startGUI HIBA -> $*" >&2
	exit 1
}

[[ -x "$SCRIPT_DIR/rs41_main.pl" ]] \
	|| fail "Az rs41_main.pl nem található vagy nem futtatható."

[[ -x "$SCRIPT_DIR/rs41_gui.pl" ]] \
	|| fail "A rs41_gui.pl nem található vagy nem futtatható."

#[[ -x "$SCRIPT_DIR/rs41_service_terminal.pl" ]] \
#	|| fail "Az rs41_service_terminal.pl nem található vagy nem futtatható."

#[[ -x "$SCRIPT_DIR/dsPipeBroker" ]] \
#	|| fail "A dsPipeBroker nem található vagy nem futtatható."

#[[ -x "$SCRIPT_DIR/rs41_service_master.pl" ]] \
#	|| fail "Az rs41_service_master.pl nem található vagy nem futtatható."

perl -I"$SCRIPT_DIR" -MRS41IPC -MRS41FrontendData -e '1' 2>/dev/null \
	|| fail "Az RS41IPC.pm vagy RS41FrontendData.pm nem tölthető be a projekt könyvtárából."

exec python3 - "$SCRIPT_DIR" "$CALL_DIR" "$@" <<'PYCODE'
import json
import os
import signal
import subprocess
import sys
import threading

base_dir = sys.argv[1]
call_dir = sys.argv[2]
arguments = sys.argv[3:]
main_path = os.path.join(base_dir, "rs41_main.pl")
frontend_path = os.path.join(base_dir, "rs41_gui.pl")

processes = []
stopping = threading.Event()
frontend_events = []
config_overrides = {}


def configure_text_stream(stream):
	try:
		stream.reconfigure(encoding="utf-8", errors="replace")
	except (AttributeError, ValueError):
		pass


configure_text_stream(sys.stdout)
configure_text_stream(sys.stderr)


def terminal_line(sender, level, text):
	level = str(level or "INFO").upper()
	prefix = f"{sender} {level} -> "
	lines = str(text or "").splitlines() or [""]

	for line in lines:
		print(prefix + line, file=sys.stderr, flush=True)


def resolve_input_path(value, option_name):
	if not value:
		raise ValueError(f"A {option_name} opcióhoz fájlnevet kell megadni.")

	path = os.path.expanduser(value)

	if not os.path.isabs(path):
		path = os.path.join(call_dir, path)

	path = os.path.abspath(path)

	if not os.path.isfile(path):
		raise ValueError(f"A fájl nem található ({option_name}): {path}")

	return path


def add_file_event(event_name, value):
	path = resolve_input_path(value, '-' + event_name.split('_', 1)[-1].upper())
	frontend_events.append(
		{
			"type": "frontend_event_request",
			"event": event_name,
			"path": path,
			"source": "startGUI",
		}
	)


def parse_arguments():
	run_events = 0

	for argument in arguments:
		upper = argument.upper()

		if upper.startswith("-WAV=") or upper.startswith("--WAV="):
			add_file_event("open_wav", argument.split("=", 1)[1])
			run_events += 1
		elif upper.startswith("-RAW=") or upper.startswith("--RAW="):
			add_file_event("open_raw", argument.split("=", 1)[1])
			run_events += 1
		elif upper.startswith("-JSON=") or upper.startswith("--JSON="):
			add_file_event("open_json", argument.split("=", 1)[1])
			run_events += 1
		elif upper in ("-FELV", "--FELV", "-RECORD", "--RECORD"):
			frontend_events.append(
				{
					"type": "frontend_event_request",
					"event": "start_recording",
					"source": "startGUI",
				}
			)
			run_events += 1
		elif upper in ("-BT", "--BT"):
			frontend_events.append(
				{
					"type": "frontend_event_request",
					"event": "set_bt",
					"active": True,
					"source": "startGUI",
				}
			)
		elif upper in ("-SHUB", "--SHUB", "-SONDEHUB", "--SONDEHUB"):
			frontend_events.append(
				{
					"type": "frontend_event_request",
					"event": "set_sondehub",
					"active": True,
					"source": "startGUI",
				}
			)
		elif "=" in argument and argument.startswith("-"):
			name, value = argument.lstrip("-").split("=", 1)

			if name.upper().startswith("CONFIG:"):
				name = name.split(":", 1)[1]
			elif name.upper().startswith("CFG:"):
				name = name.split(":", 1)[1]

			name = name.upper()

			if not name or any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_" for character in name):
				raise ValueError(f"Érvénytelen konfigurációs név: {name}")

			config_overrides[name] = value
		else:
			raise ValueError(f"Ismeretlen indítási opció: {argument}")

	if run_events > 1:
		raise ValueError("A FELV/WAV/RAW/JSON indítási módok közül egyszerre csak egy adható meg.")


try:
	parse_arguments()
except ValueError as error:
	terminal_line("startGUI", "ERR", str(error))
	sys.exit(2)


child_environment = os.environ.copy()
child_environment.update(config_overrides)

for name, value in sorted(config_overrides.items()):
	terminal_line("startGUI", "INFO", f"Config override: {name}={value}")


def stderr_relay(sender, stream):
	try:
		for raw in iter(stream.readline, b""):
			text = raw.decode("utf-8", errors="replace").rstrip("\r\n")
			terminal_line(sender, "ERR", text)
	finally:
		stream.close()


def send_event(destination, event):
	raw = (json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
	destination.write(raw)
	destination.flush()
	terminal_line(
		"startGUI",
		"INFO",
		f"Frontend eseménykérés elküldve: {event.get('event')} {event.get('path', '')}",
	)


def json_relay(sender, source, destination, main_to_frontend=False):
	try:
		for raw in iter(source.readline, b""):
			try:
				message = json.loads(raw.decode("utf-8"))
			except Exception:
				terminal_line(
					sender,
					"ERR",
					"Érvénytelen JSON az STDOUT csatornán: "
					+ raw.decode("utf-8", errors="replace").rstrip(),
				)
				continue

			if isinstance(message, dict) and message.get("type") == "terminal":
				terminal_line(
					sender,
					message.get("level", "INFO"),
					message.get("text", ""),
				)
				continue

			try:
				destination.write(raw)
				destination.flush()

				# Az initialize mindig megelőzi a launcher eseménykéréseit.
				if main_to_frontend and isinstance(message, dict) and message.get("type") == "initialize":
					while frontend_events:
						send_event(destination, frontend_events.pop(0))
			except (BrokenPipeError, ValueError):
				break
	finally:
		try:
			source.close()
		except Exception:
			pass

		try:
			destination.close()
		except Exception:
			pass


def stop_all(signum=None, frame=None):
	if stopping.is_set():
		return

	stopping.set()

	for process in processes:
		if process.poll() is None:
			process.terminate()


signal.signal(signal.SIGINT, stop_all)
signal.signal(signal.SIGTERM, stop_all)

main_process = subprocess.Popen(
	[main_path],
	cwd=base_dir,
	stdin=subprocess.PIPE,
	stdout=subprocess.PIPE,
	stderr=subprocess.PIPE,
	start_new_session=True,
	env=child_environment,
)
processes.append(main_process)

frontend_process = subprocess.Popen(
	[frontend_path],
	cwd=base_dir,
	stdin=subprocess.PIPE,
	stdout=subprocess.PIPE,
	stderr=subprocess.PIPE,
	start_new_session=True,
	env=child_environment,
)
processes.append(frontend_process)

threads = [
	threading.Thread(
		target=json_relay,
		args=("rs41_main", main_process.stdout, frontend_process.stdin, True),
		daemon=True,
	),
	threading.Thread(
		target=json_relay,
		args=("rs41_gui", frontend_process.stdout, main_process.stdin, False),
		daemon=True,
	),
	threading.Thread(
		target=stderr_relay,
		args=("rs41_main", main_process.stderr),
		daemon=True,
	),
	threading.Thread(
		target=stderr_relay,
		args=("rs41_gui", frontend_process.stderr),
		daemon=True,
	),
]

for thread in threads:
	thread.start()

terminal_line(
	"startGUI",
	"INFO",
	"Az rs41_main.pl és rs41_gui.pl folyamatok elindultak, a JSON-csatornák összekapcsolva.",
)

exit_code = 0

try:
	while True:
		main_code = main_process.poll()
		frontend_code = frontend_process.poll()

		if main_code is not None or frontend_code is not None:
			if main_code not in (None, 0):
				terminal_line("rs41_main", "ERR", f"A folyamat kilépési kódja: {main_code}")
				exit_code = main_code

			if frontend_code not in (None, 0):
				terminal_line("rs41_gui", "ERR", f"A folyamat kilépési kódja: {frontend_code}")

				if exit_code == 0:
					exit_code = frontend_code

			break

		stopping.wait(0.1)

		if stopping.is_set():
			break
finally:
	stop_all()

	for process in processes:
		try:
			process.wait(timeout=3)
		except subprocess.TimeoutExpired:
			try:
				os.killpg(process.pid, signal.SIGKILL)
			except ProcessLookupError:
				pass
			process.wait()

terminal_line("startGUI", "INFO", "Mindkét folyamat leállt.")
sys.exit(exit_code)
PYCODE
