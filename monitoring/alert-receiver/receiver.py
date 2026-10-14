"""Minimal webhook receiver for alert notifications.

Grafana (POST /grafana) and Logstash (POST /logstash) send their alerts here.
Every notification is printed as one readable line ("docker logs -f alert-receiver")
and appended to /var/log/alerts/notifications.log.

Optional: set FORWARD_WEBHOOK_URL to a Slack incoming webhook (or a Discord webhook
URL ending in /slack) and every line is forwarded there as well.
"""
import json
import os
import threading
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_FILE = "/var/log/alerts/notifications.log"
FORWARD_URL = os.environ.get("FORWARD_WEBHOOK_URL", "").strip()
PORT = 9095
# requests are handled in parallel threads; without a lock two lines can interleave
OUTPUT_LOCK = threading.Lock()


def format_grafana(payload):
    """Grafana sends one webhook per alert group, containing 1..n alerts."""
    lines = []
    for alert in payload.get("alerts", []):
        labels = alert.get("labels", {})
        summary = alert.get("annotations", {}).get("summary") or labels.get("alertname", "?")
        lines.append(
            "[GRAFANA] {status} {severity}: {summary}".format(
                status=alert.get("status", "?").upper(),
                severity=labels.get("severity", "-"),
                summary=summary,
            )
        )
    return lines


def format_logstash(payload):
    """Logstash sends one webhook per matched log line (throttled on its side)."""
    return [
        "[LOGSTASH] {severity} {rule} on {host}: {message}".format(
            severity=payload.get("severity", "-").upper(),
            rule=payload.get("rule", "?"),
            host=payload.get("host", "?"),
            message=str(payload.get("message", ""))[:300],
        )
    ]


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
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            payload = {"message": raw.decode(errors="replace")}

        if self.path.startswith("/grafana"):
            lines = format_grafana(payload)
        else:
            lines = format_logstash(payload)

        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
        with OUTPUT_LOCK, open(LOG_FILE, "a", encoding="utf-8") as log:
            for line in lines:
                entry = f"{now} {line}"
                print(entry, flush=True)
                log.write(entry + "\n")
        for line in lines:
            forward(line)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):  # health check
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"alert-receiver up")

    def log_message(self, *args):  # silence default per-request access log
        pass


if __name__ == "__main__":
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    print(f"alert-receiver listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
