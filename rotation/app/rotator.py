"""Secret rotator: Secret Manager SECRET_ROTATE to a new Cloud SQL password.

Secret Manager does not rotate anything itself. On schedule it publishes
SECRET_ROTATE to the secret's topic, and a consumer has to do the work. This is
that consumer, on a private Cloud Run service inside the VPC-SC perimeter, fed
by a Pub/Sub push subscription in the same project.

One rotation, in order:
  1. mint a password (secrets.token_urlsafe, never logged)
  2. set it on the Cloud SQL user through the Admin API and wait for the
     operation, so the database accepts it before anything can read it
  3. add it to Secret Manager as a new version (the value lives only here and in
     Cloud SQL, never in Terraform state)
  4. disable every older enabled version, so nothing can read a dead password

If step 3 fails after step 2, the handler returns 500 and Pub/Sub redelivers.
The redelivery sees no version newer than the message and rotates again with a
fresh password, so the two converge instead of staying split.

Idempotent on redelivery: a message is skipped when the newest enabled version
was created after the message was published, which means a previous delivery
already rotated for it.

Single-user rotation, deliberately: Cloud SQL keeps sessions open across a
password change, and new connections read the latest version, so the gap is a
connection opened between steps 2 and 3. The AWS zone alternates two users to
close that gap; ADR-0006 records why this one does not.
"""

import base64
import datetime
import json
import logging
import os
import re
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import google.auth
from google.auth.transport.requests import AuthorizedSession

log = logging.getLogger("rotator")

SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]
SQLADMIN = "https://sqladmin.googleapis.com/v1"
SECRETMANAGER = "https://secretmanager.googleapis.com/v1"


class Skip(Exception):
    """Valid message that needs no rotation. Acknowledge it."""


def config():
    return {
        "project": os.environ.get("PROJECT_ID", ""),
        "project_number": os.environ.get("PROJECT_NUMBER", ""),
        "secret": os.environ.get("SECRET_ID", ""),  # projects/P/secrets/S
        "instance": os.environ.get("SQL_INSTANCE", ""),
        "user": os.environ.get("SQL_USER", "app"),
        "op_timeout": int(os.environ.get("SQL_OP_TIMEOUT", "240")),
    }


_session = None


def session():
    global _session
    if _session is None:
        creds, _ = google.auth.default(scopes=SCOPES)
        _session = AuthorizedSession(creds)
    return _session


def emit(event, **fields):
    print(json.dumps({"event": event, "severity": fields.pop("severity", "INFO"), **fields}), flush=True)


def parse_time(value):
    """RFC 3339 with Z and up to nanoseconds; Python takes at most microseconds."""
    m = re.match(r"^(.*?T\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)$", value)
    if not m:
        raise ValueError(f"bad timestamp {value!r}")
    head, frac, tz = m.groups()
    frac = (frac or ".0")[1:7].ljust(6, "0")
    return datetime.datetime.fromisoformat(f"{head}.{frac}{'+00:00' if tz == 'Z' else tz}")


def decode(envelope):
    msg = (envelope or {}).get("message")
    if not isinstance(msg, dict):
        raise Skip("no message in push envelope")
    attrs = msg.get("attributes") or {}
    published = msg.get("publishTime")
    if not published:
        raise Skip("message has no publishTime")
    return attrs, parse_time(published), msg.get("messageId", "")


def check(attrs, cfg):
    event = attrs.get("eventType", "")
    if event != "SECRET_ROTATE":
        raise Skip(f"eventType {event or 'missing'} is not SECRET_ROTATE")
    # secretId names the project by number; the config names it by id. Accept
    # either for the project, and require the secret id to match exactly.
    secret = attrs.get("secretId", "")
    parts = secret.split("/")
    want_id = cfg["secret"].split("/")[-1]
    if len(parts) != 4 or parts[0] != "projects" or parts[2] != "secrets" or parts[3] != want_id:
        raise Skip(f"secret {secret or 'missing'} is not the configured secret")
    if parts[1] not in (cfg["project"], cfg["project_number"]):
        raise Skip(f"secret {secret} is in another project")


def enabled_versions(cfg):
    url = f"{SECRETMANAGER}/{cfg['secret']}/versions"
    out, token = [], None
    while True:
        r = session().get(url, params={"filter": "state:ENABLED", **({"pageToken": token} if token else {})})
        r.raise_for_status()
        body = r.json()
        out += body.get("versions", [])
        token = body.get("nextPageToken")
        if not token:
            return out


def set_sql_password(cfg, password):
    url = f"{SQLADMIN}/projects/{cfg['project']}/instances/{cfg['instance']}/users"
    r = session().put(url, params={"name": cfg["user"]}, json={"name": cfg["user"], "password": password})
    r.raise_for_status()
    op = r.json()["name"]
    deadline = time.monotonic() + cfg["op_timeout"]
    while time.monotonic() < deadline:
        s = session().get(f"{SQLADMIN}/projects/{cfg['project']}/operations/{op}")
        s.raise_for_status()
        body = s.json()
        if body.get("status") == "DONE":
            if body.get("error"):
                raise RuntimeError(f"Cloud SQL operation {op} failed: {body['error']}")
            return op
        time.sleep(2)
    raise TimeoutError(f"Cloud SQL operation {op} did not finish in {cfg['op_timeout']}s")


def add_version(cfg, password):
    data = base64.b64encode(password.encode()).decode()
    r = session().post(f"{SECRETMANAGER}/{cfg['secret']}:addVersion", json={"payload": {"data": data}})
    r.raise_for_status()
    return r.json()["name"]


def disable(name):
    r = session().post(f"{SECRETMANAGER}/{name}:disable", json={})
    r.raise_for_status()


def rotate(envelope, cfg=None):
    cfg = cfg or config()
    attrs, published, message_id = decode(envelope)
    check(attrs, cfg)

    before = enabled_versions(cfg)
    newer = [v for v in before if parse_time(v["createTime"]) > published]
    if newer:
        raise Skip(f"already rotated: {newer[0]['name'].split('/')[-1]} is newer than the message")

    started = time.monotonic()
    password = secrets.token_urlsafe(24)
    op = set_sql_password(cfg, password)
    version = add_version(cfg, password)
    del password
    disabled = []
    for v in before:
        if v["name"] != version:
            disable(v["name"])
            disabled.append(v["name"].split("/")[-1])
    result = {
        "secret": cfg["secret"].split("/")[-1],
        "version": version.split("/")[-1],
        "disabled": disabled,
        "sql_operation": op,
        "message_id": message_id,
        "seconds": round(time.monotonic() - started, 1),
    }
    emit("rotated", **result)
    return result


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            envelope = json.loads(self.rfile.read(length) or b"{}")
            rotate(envelope)
            self._reply(200)
        except Skip as e:
            emit("skipped", reason=str(e))
            self._reply(200)
        except (ValueError, json.JSONDecodeError) as e:
            emit("malformed", reason=str(e), severity="WARNING")
            self._reply(200)
        except Exception as e:  # an API call failed: let Pub/Sub redeliver
            emit("rotation_failed", error=f"{type(e).__name__}: {e}"[:500], severity="ERROR")
            self._reply(500)

    def do_GET(self):
        self._reply(200)

    def _reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("", port), Handler).serve_forever()
