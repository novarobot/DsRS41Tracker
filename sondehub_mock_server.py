#!/usr/bin/env python3

import gzip
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from datetime import datetime

HOST = "127.0.0.1"
PORT = 8080
LOG_DIR = Path("./mock-sondehub-log")


class Handler(BaseHTTPRequestHandler):
	def do_PUT(self):
		if self.path not in ("/sondes/telemetry", "/listeners"):
			self.send_error(404, "Unknown endpoint")
			return

		length = int(self.headers.get("Content-Length", "0"))
		body = self.rfile.read(length)

		if self.headers.get("Content-Encoding", "").lower() == "gzip":
			try:
				body = gzip.decompress(body)
			except Exception as error:
				self.send_error(400, f"Invalid gzip body: {error}")
				return

		try:
			payload = json.loads(body.decode("utf-8"))
		except Exception as error:
			self.send_error(400, f"Invalid JSON: {error}")
			return

		if self.path == "/sondes/telemetry" and not isinstance(payload, list):
			self.send_error(400, "Telemetry payload must be a JSON array")
			return

		if self.path == "/listeners" and not isinstance(payload, dict):
			self.send_error(400, "Listener payload must be a JSON object")
			return

		LOG_DIR.mkdir(parents=True, exist_ok=True)
		name = "telemetry" if self.path == "/sondes/telemetry" else "listener"
		stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S_%f")
		log_file = LOG_DIR / f"{stamp}_{name}.json"
		log_file.write_text(
			json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
			encoding="utf-8",
		)

		print(
			f"{self.command} {self.path} "
			f"encoding={self.headers.get('Content-Encoding', 'identity')} "
			f"saved={log_file}"
		)

		response = b"Mock SondeHub upload accepted"
		self.send_response(200)
		self.send_header("Content-Type", "text/plain; charset=utf-8")
		self.send_header("Content-Length", str(len(response)))
		self.end_headers()
		self.wfile.write(response)

	def log_message(self, format, *args):
		return


def main():
	server = ThreadingHTTPServer((HOST, PORT), Handler)
	print(f"Mock SondeHub API: http://{HOST}:{PORT}")
	print("Telemetry: /sondes/telemetry")
	print("Listener:  /listeners")
	server.serve_forever()


if __name__ == "__main__":
	main()
