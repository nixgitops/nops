import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, generate_latest, multiprocess


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        metrics_path = os.environ.get("NOPS_METRICS_PATH", "/metrics")
        if self.path not in (metrics_path, "/"):
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not Found\n")
            return

        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        payload = generate_latest(registry)

        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPE_LATEST)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    listen_address = os.environ.get("NOPS_METRICS_ADDRESS", "0.0.0.0")
    listen_port = int(os.environ.get("NOPS_METRICS_PORT", "9102"))
    server = ThreadingHTTPServer((listen_address, listen_port), MetricsHandler)
    server.serve_forever()