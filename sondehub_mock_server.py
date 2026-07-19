#!/usr/bin/env python3

import argparse
import gzip
import json
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from typing import Any


class SessionLogger:
	def __init__(self, output_directory: Path) -> None:
		self.output_directory = output_directory
		self.output_directory.mkdir(parents=True, exist_ok=True)

		self.session_timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
		self.telemetry_path = (
			self.output_directory
			/ f"telemetry_{self.session_timestamp}.json"
		)
		self.listener_path = (
			self.output_directory
			/ f"listener_{self.session_timestamp}.json"
		)

		self.lock = Lock()

		# A két fájl már a szerver indulásakor létrejön.
		self.telemetry_path.write_text("", encoding="utf-8")
		self.listener_path.write_text("", encoding="utf-8")

	def _request_timestamp(self) -> str:
		return datetime.now().strftime("%Y%m%d-%H%M%S")

	def append_telemetry_batch(self, payload: list[Any]) -> None:
		timestamp = self._request_timestamp()

		with self.lock:
			with self.telemetry_path.open("a", encoding="utf-8") as handle:
				handle.write(f"#{timestamp}\n")
				handle.write("[\n")

				for index, item in enumerate(payload):
					line = json.dumps(
						item,
						ensure_ascii=False,
						separators=(",", ": "),
					)

					if index + 1 < len(payload):
						line += ","

					handle.write(line + "\n")

				handle.write("]\n")
				handle.flush()

	def append_listener(self, payload: dict[str, Any]) -> None:
		timestamp = self._request_timestamp()
		line = json.dumps(
			payload,
			ensure_ascii=False,
			separators=(",", ": "),
		)

		with self.lock:
			with self.listener_path.open("a", encoding="utf-8") as handle:
				handle.write(f"#{timestamp}\n")
				handle.write(line + "\n")
				handle.flush()


class MockSondeHubHandler(BaseHTTPRequestHandler):
	server_version = "MockSondeHub/0.2"

	def log_message(self, format_string: str, *args: Any) -> None:
		sys.stdout.write(
			"%s - - [%s] %s\n"
			% (
				self.client_address[0],
				self.log_date_time_string(),
				format_string % args,
			)
		)
		sys.stdout.flush()

	def _send_text(self, status_code: int, message: str) -> None:
		body = (message + "\n").encode("utf-8")

		self.send_response(status_code)
		self.send_header("Content-Type", "text/plain; charset=utf-8")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)

	def _read_request_body(self) -> tuple[bytes, str]:
		content_length_header = self.headers.get("Content-Length")

		if content_length_header is None:
			raise ValueError("Missing Content-Length header")

		try:
			content_length = int(content_length_header)
		except ValueError as error:
			raise ValueError("Invalid Content-Length header") from error

		if content_length < 0:
			raise ValueError("Invalid negative Content-Length")

		body = self.rfile.read(content_length)
		encoding = self.headers.get("Content-Encoding", "identity").strip().lower()

		if encoding in ("", "identity"):
			return body, "identity"

		if encoding == "gzip":
			try:
				return gzip.decompress(body), "gzip"
			except OSError as error:
				raise ValueError(f"Invalid GZIP request body: {error}") from error

		raise ValueError(f"Unsupported Content-Encoding: {encoding}")

	def do_PUT(self) -> None:
		try:
			raw_body, content_encoding = self._read_request_body()

			try:
				payload = json.loads(raw_body.decode("utf-8"))
			except UnicodeDecodeError as error:
				raise ValueError(f"Request body is not valid UTF-8: {error}") from error
			except json.JSONDecodeError as error:
				raise ValueError(f"Invalid JSON: {error}") from error

			if self.path == "/sondes/telemetry":
				if not isinstance(payload, list):
					raise ValueError(
						"Telemetry payload must be a JSON array."
					)

				self.server.session_logger.append_telemetry_batch(payload)
				self._send_text(200, "Mock SondeHub telemetry upload accepted")

				print(
					f"PUT {self.path} encoding={content_encoding} "
					f"packets={len(payload)} "
					f"saved={self.server.session_logger.telemetry_path}",
					flush=True,
				)
				return

			if self.path == "/listeners":
				if not isinstance(payload, dict):
					raise ValueError(
						"Listener payload must be a JSON object."
					)

				self.server.session_logger.append_listener(payload)
				self._send_text(200, "Mock SondeHub listener upload accepted")

				print(
					f"PUT {self.path} encoding={content_encoding} "
					f"saved={self.server.session_logger.listener_path}",
					flush=True,
				)
				return

			self._send_text(404, f"Unknown endpoint: {self.path}")

		except ValueError as error:
			self._send_text(400, str(error))
			print(
				f"PUT {self.path} rejected: {error}",
				file=sys.stderr,
				flush=True,
			)
		except Exception as error:
			self._send_text(500, f"Internal mock server error: {error}")
			print(
				f"PUT {self.path} internal error: {error}",
				file=sys.stderr,
				flush=True,
			)


class MockSondeHubServer(ThreadingHTTPServer):
	daemon_threads = True
	allow_reuse_address = True

	def __init__(
		self,
		server_address: tuple[str, int],
		session_logger: SessionLogger,
	) -> None:
		super().__init__(server_address, MockSondeHubHandler)
		self.session_logger = session_logger


def parse_arguments() -> argparse.Namespace:
	parser = argparse.ArgumentParser(
		description="Local mock server for SondeHub telemetry and listener PUT requests."
	)
	parser.add_argument(
		"--host",
		default="127.0.0.1",
		help="Bind address. Default: 127.0.0.1",
	)
	parser.add_argument(
		"--port",
		type=int,
		default=8080,
		help="TCP port. Default: 8080",
	)
	parser.add_argument(
		"--output-directory",
		default="./mock-sondehub-log",
		help="Directory for the two session log files.",
	)
	return parser.parse_args()


def main() -> int:
	args = parse_arguments()
	output_directory = Path(args.output_directory).expanduser().resolve()
	session_logger = SessionLogger(output_directory)
	server = MockSondeHubServer(
		(args.host, args.port),
		session_logger,
	)


	print(
		f"Mock SondeHub server listening on http://{args.host}:{args.port}",
		flush=True,
	)
	print(f"Telemetry log: {session_logger.telemetry_path}", flush=True)
	print(f"Listener log:  {session_logger.listener_path}", flush=True)

	try:
		server.serve_forever()
	except KeyboardInterrupt:
		print("\nStopping server.", flush=True)
	finally:
		server.server_close()

	return 0


if __name__ == "__main__":
	raise SystemExit(main())
