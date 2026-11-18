"""orders-api: a small Cloud Run service the SLO is measured on.

GET /api/orders      a JSON list of orders. Fails with 503 for FAULT_PERCENT of
                     requests, which is how the burn-rate alert is proved.
GET /healthz         always 200, for the startup probe.

FAULT_PERCENT is an environment variable, so injecting a fault is a new
revision (gcloud run services update --update-env-vars), never something a
caller can trigger with a request.
"""

import json
import os
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FAULT = float(os.environ.get("FAULT_PERCENT", "0"))
ORDERS = [{"id": i, "sku": f"SKU-{1000 + i}", "qty": 1 + i % 3, "status": "shipped" if i % 4 else "pending"} for i in range(1, 21)]


def log(**fields):
    print(json.dumps(fields), flush=True)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        start = time.monotonic()
        if self.path == "/healthz":
            return self.reply(200, {"ok": True})
        if not self.path.startswith("/api/orders"):
            return self.reply(404, {"error": "not found"})
        if FAULT and random.uniform(0, 100) < FAULT:
            code, body = 503, {"error": "injected fault", "fault_percent": FAULT}
        else:
            code, body = 200, {"orders": ORDERS}
        self.reply(code, body)
        log(event="request", path=self.path, status=code, ms=round(1000 * (time.monotonic() - start), 2))

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
