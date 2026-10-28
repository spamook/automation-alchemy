"""Webhook receiver for Alertmanager notifications.

Alertmanager POSTs every notification to /alertmanager. Each alert becomes one readable
line on stdout ("kubectl -n monitoring logs deploy/alert-receiver", and in Kibana through
Fluent Bit). GET / shows the last 100 lines.

Optional: FORWARD_WEBHOOK_URL = a Slack incoming webhook (or a Discord webhook URL
ending in /slack); every line is forwarded there as well.
"""
import json
import os
import threading
import urllib.request
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 9095
FORWARD_URL = os.environ.get("FORWARD_WEBHOOK_URL", "").strip()
RECENT = deque(maxlen=100)
# requests are handled in parallel threads; without a lock two lines can interleave
LOCK = threading.Lock()


def format_alerts(payload):
    """Alertmanager sends one webhook per alert group, containing 1..n alerts."""
    lines = []
    for alert in payload.get("alerts", []):
        labels = alert.get("labels", {})
        summary = alert.get("annotations", {}).get("summary") or labels.get("alertname", "?")
        lines.append(
            "[{status}] {severity} {name}: {summary}".format(
                status=alert.get("status", "?").upper(),
                severity=labels.get("severity", "-"),
                name=labels.get("alertname", "?"),
                summary=summary,
            )
        )
    return lines


def forward(text):
    if not FORWARD_URL:
        return
    body = json.dumps({"text": text}).encode()
    req = urllib.request.Request(FORWARD_URL, data=body, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception as exc:  # a broken chat webhook must never break alert reception
        print(f"forwarding failed: {exc}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        lines = format_alerts(payload)
        with LOCK:
            for line in lines:
                entry = f"{now} {line}"
                RECENT.append(entry)
                print(entry, flush=True)
        for line in lines:
            forward(line)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):
        with LOCK:
            body = "\n".join(RECENT) or "no alerts received yet"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write((body + "\n").encode())

    def log_message(self, *args):  # silence the default per-request access log
        pass


if __name__ == "__main__":
    print(f"alert-receiver listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
