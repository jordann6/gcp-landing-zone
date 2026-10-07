"""Incident handler: SCC findings and ops alerts, both arriving as Pub/Sub push.

Two routes on one private Cloud Run service:

  POST /scc  a Security Command Center finding. If it names the management VM,
             quarantine it: secure tag (a deny-all NGFW rule targets the tag),
             label, disk snapshot, stop, detach the service account.
  POST /secret-age  Cloud Scheduler, daily: log an ERROR (stale_secret) for each
             secret whose newest enabled version is older than the limit. A
             log-based metric and alert policy (observability/) turn that into
             a notification. Reads version metadata only, never a value.
  POST /ops  a Cloud Monitoring incident. Maps one policy to one action: GKE
             node-not-ready resizes the node pool by one (bounded), Cloud SQL
             primary down fails the instance over.

Every mutating step defaults to dry-run (DRY_RUN unset or anything but "false"):
the handler reads, decides, and logs what it WOULD do. Malformed or ineligible
messages are acknowledged (HTTP 200) and logged, never retried, so a bad message
cannot loop. Only a failed API call returns 5xx, which makes Pub/Sub redeliver.

Config comes from environment variables set by Terraform; nothing is read from
the message except which resource the finding or alert names, and that is
checked against the configured target before anything is touched.
"""

import base64
import datetime
import hashlib
import json
import logging
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import google.auth
from google.auth.transport.requests import AuthorizedSession

log = logging.getLogger("incident")

SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]

OPS_ACTIONS = {
    "lz-ops-gke-node-not-ready": "gke_resize",
    "lz-ops-sql-instance-down": "sql_failover",
}

INSTANCE_RE = re.compile(
    r"^//compute\.googleapis\.com/projects/(?P<project>[^/]+)/zones/(?P<zone>[^/]+)/instances/(?P<name>[^/]+)$"
)


class Skip(Exception):
    """Message is valid but not actionable. Acknowledge it."""


def config():
    return {
        "dry_run": os.environ.get("DRY_RUN", "true").strip().lower() != "false",
        "app_project": os.environ.get("APP_PROJECT_ID", ""),
        "app_project_number": os.environ.get("APP_PROJECT_NUMBER", ""),
        "eligible_label": os.environ.get("QUARANTINE_LABEL", "role=mgmt"),
        "tag_value": os.environ.get("QUARANTINE_TAG_VALUE", ""),
        "gke_cluster": os.environ.get("GKE_CLUSTER", ""),
        "gke_location": os.environ.get("GKE_LOCATION", ""),
        "gke_pool": os.environ.get("GKE_NODE_POOL", ""),
        "gke_max_nodes": int(os.environ.get("GKE_MAX_NODES", "3")),
        "sql_instance": os.environ.get("SQL_INSTANCE", ""),
        # A failover is a real outage for the primary, so it has its own switch:
        # it stays a dry run unless this is "true", even when DRY_RUN is "false".
        "secret_max_age_days": int(os.environ.get("SECRET_MAX_AGE_DAYS", "90")),
        "sql_live": os.environ.get("SQL_FAILOVER_LIVE", "false").strip().lower() == "true",
    }


_session = None


def session():
    global _session
    if _session is None:
        creds, _ = google.auth.default(scopes=SCOPES)
        _session = AuthorizedSession(creds)
    return _session


def call(method, url, **kw):
    r = session().request(method, url, timeout=60, **kw)
    if r.status_code >= 400:
        raise RuntimeError(f"{method} {url} -> {r.status_code} {r.text[:300]}")
    return r.json() if r.text else {}


def decode(envelope):
    try:
        msg = envelope["message"]
        return json.loads(base64.b64decode(msg["data"]).decode())
    except (KeyError, ValueError, TypeError) as e:
        raise Skip(f"unparseable push envelope: {e}")


def step(cfg, what, fn):
    """Run one mutating step, or log that dry-run skipped it."""
    if cfg["dry_run"]:
        log.warning(json.dumps({"event": "dry_run", "would": what}))
        return None
    log.warning(json.dumps({"event": "act", "doing": what}))
    return fn()


def wait_zone_op(project, zone, op):
    name = op.get("name")
    if not name or op.get("status") == "DONE":
        return op
    url = f"https://compute.googleapis.com/compute/v1/projects/{project}/zones/{zone}/operations/{name}/wait"
    done = call("POST", url)
    if done.get("error"):
        raise RuntimeError(f"operation {name} failed: {done['error']}")
    return done


# ---- quarantine ---------------------------------------------------------------


def finding_target(finding):
    m = INSTANCE_RE.match(finding.get("resourceName", ""))
    if not m:
        raise Skip(f"finding names no Compute instance: {finding.get('resourceName')!r}")
    return m.groupdict()


def eligible(cfg, inst):
    key, _, val = cfg["eligible_label"].partition("=")
    return (inst.get("labels") or {}).get(key) == val


def quarantine(cfg, finding):
    t = finding_target(finding)
    if t["project"] not in (cfg["app_project"], cfg["app_project_number"]):
        raise Skip(f"instance is in {t['project']}, not the configured app project")
    base = f"https://compute.googleapis.com/compute/v1/projects/{cfg['app_project']}/zones/{t['zone']}"
    try:
        inst = call("GET", f"{base}/instances/{t['name']}")
    except RuntimeError as e:
        if " 404 " in str(e):
            raise Skip(f"instance {t['name']} does not exist")
        raise
    if not eligible(cfg, inst):
        raise Skip(f"{t['name']} lacks label {cfg['eligible_label']}; not quarantine-eligible")
    if not cfg["tag_value"]:
        raise RuntimeError("QUARANTINE_TAG_VALUE is not configured")

    tag = hashlib.sha256(finding.get("name", t["name"]).encode()).hexdigest()[:8]
    done = []

    # 1. Cut the network first: everything after this runs against an isolated VM.
    def bind():
        try:
            op = call(
                "POST",
                f"https://{t['zone']}-cloudresourcemanager.googleapis.com/v3/tagBindings",
                json={
                    "parent": f"//compute.googleapis.com/projects/{cfg['app_project_number']}/zones/{t['zone']}/instances/{inst['id']}",
                    "tagValue": cfg["tag_value"],
                },
            )
            return op
        except RuntimeError as e:
            if "409" in str(e) or "ALREADY_EXISTS" in str(e):
                return {}
            raise

    step(cfg, f"bind secure tag {cfg['tag_value']} to {t['name']} (deny-all firewall rule targets it)", bind)
    done.append("tag")

    # 2. Label, so the VM is findable and patch/inventory automation can skip it.
    def label():
        labels = dict(inst.get("labels") or {})
        labels["quarantine"] = "true"
        op = call(
            "POST",
            f"{base}/instances/{t['name']}/setLabels",
            json={"labels": labels, "labelFingerprint": inst["labelFingerprint"]},
        )
        wait_zone_op(cfg["app_project"], t["zone"], op)

    step(cfg, f"label {t['name']} quarantine=true", label)
    done.append("label")

    # 3. Preserve the disks before anything else changes.
    for d in inst.get("disks", []):
        disk = d["source"].rsplit("/", 1)[-1]
        snap = f"quarantine-{disk}-{tag}"[:62]

        def snapshot(disk=disk, snap=snap):
            try:
                op = call(
                    "POST",
                    f"{base}/disks/{disk}/createSnapshot",
                    json={"name": snap, "labels": {"quarantine": "true", "source-instance": t["name"]}},
                )
                wait_zone_op(cfg["app_project"], t["zone"], op)
            except RuntimeError as e:
                if "409" not in str(e) and "alreadyExists" not in str(e):
                    raise

        step(cfg, f"snapshot disk {disk} as {snap}", snapshot)
        done.append(f"snapshot:{snap}")

    # 4. Detaching the service account needs the instance stopped.
    def stop():
        if inst.get("status") in ("TERMINATED", "STOPPING", "STOPPED"):
            return
        op = call("POST", f"{base}/instances/{t['name']}/stop")
        wait_zone_op(cfg["app_project"], t["zone"], op)

    step(cfg, f"stop {t['name']}", stop)
    done.append("stop")

    def detach():
        op = call(
            "POST",
            f"{base}/instances/{t['name']}/setServiceAccount",
            json={"email": "", "scopes": []},
        )
        wait_zone_op(cfg["app_project"], t["zone"], op)

    if inst.get("serviceAccounts"):
        step(cfg, f"detach service account from {t['name']}", detach)
        done.append("detach-sa")
    return {"action": "quarantine", "finding": finding.get("name"), "instance": t["name"], "steps": done, "dry_run": cfg["dry_run"]}


# ---- ops remediation ----------------------------------------------------------


def gke_resize(cfg, labels):
    cluster = labels.get("cluster_name")
    if cluster and cluster != cfg["gke_cluster"]:
        raise Skip(f"alert is for cluster {cluster}, configured {cfg['gke_cluster']}")
    pool = (
        f"projects/{cfg['app_project']}/locations/{cfg['gke_location']}"
        f"/clusters/{cfg['gke_cluster']}/nodePools/{cfg['gke_pool']}"
    )
    cur = call("GET", f"https://container.googleapis.com/v1/{pool}")
    if cur.get("autoscaling", {}).get("enabled"):
        raise Skip("node pool is autoscaled; the autoscaler owns its size")
    # initialNodeCount is the pool's declared size; the live count is per zone.
    count = int(cur.get("initialNodeCount", 1))
    # Resize from the live size when the API reports it.
    try:
        igs = cur.get("instanceGroupUrls") or []
        if igs:
            ig = call("GET", igs[0])
            count = int(ig.get("targetSize", ig.get("size", count)))
    except RuntimeError:
        pass
    target = min(count + 1, cfg["gke_max_nodes"])
    if target <= count:
        raise Skip(f"node pool already at the cap ({cfg['gke_max_nodes']})")
    step(
        cfg,
        f"resize {cfg['gke_pool']} from {count} to {target}",
        lambda: call("POST", f"https://container.googleapis.com/v1/{pool}:setSize", json={"nodeCount": target}),
    )
    return {"action": "gke_resize", "from": count, "to": target, "dry_run": cfg["dry_run"]}


def sql_failover(cfg, labels):
    inst = labels.get("database_id", "").split(":")[-1]
    if inst and inst != cfg["sql_instance"]:
        raise Skip(f"alert is for {inst}, configured {cfg['sql_instance']}")
    url = f"https://sqladmin.googleapis.com/v1/projects/{cfg['app_project']}/instances/{cfg['sql_instance']}"
    cur = call("GET", url)
    if cur.get("settings", {}).get("availabilityType") != "REGIONAL":
        raise Skip("instance is not highly available; there is nothing to fail over to")
    version = cur["settings"]["settingsVersion"]
    step(
        {**cfg, "dry_run": cfg["dry_run"] or not cfg["sql_live"]},
        f"fail over {cfg['sql_instance']}",
        lambda: call("POST", f"{url}/failover", json={"failoverContext": {"settingsVersion": version}}),
    )
    return {"action": "sql_failover", "instance": cfg["sql_instance"], "dry_run": cfg["dry_run"] or not cfg["sql_live"]}


def ops(cfg, payload):
    inc = payload.get("incident") or {}
    if inc.get("state") != "open":
        raise Skip(f"incident state {inc.get('state')!r}; only open incidents act")
    policy = inc.get("policy_name", "")
    action = OPS_ACTIONS.get(policy)
    if not action:
        raise Skip(f"no remediation mapped to policy {policy!r}")
    labels = (inc.get("resource") or {}).get("labels") or {}
    out = {"gke_resize": gke_resize, "sql_failover": sql_failover}[action](cfg, labels)
    return {**out, "incident_id": inc.get("incident_id")}


def scc(cfg, payload):
    finding = payload.get("finding") or {}
    if finding.get("state") not in (None, "ACTIVE"):
        raise Skip(f"finding state {finding.get('state')!r}")
    return quarantine(cfg, finding)


def secret_age(cfg, payload):
    """payload is the Scheduler body: {"max_age_days": N} overrides the default."""
    limit = int(payload.get("max_age_days", cfg["secret_max_age_days"]))
    base = f"https://secretmanager.googleapis.com/v1/projects/{cfg['app_project']}/secrets"
    names, token = [], None
    while True:
        page = call("GET", base, params={"pageSize": 100, **({"pageToken": token} if token else {})})
        names += [x["name"] for x in page.get("secrets", [])]
        token = page.get("nextPageToken")
        if not token:
            break
    now = datetime.datetime.now(datetime.timezone.utc)
    stale, checked = [], []
    for name in names:
        versions = call("GET", f"https://secretmanager.googleapis.com/v1/{name}/versions", params={"filter": "state:ENABLED", "pageSize": 100}).get("versions", [])
        short = name.rsplit("/", 1)[-1]
        if versions:
            newest = max(datetime.datetime.fromisoformat(v["createTime"].replace("Z", "+00:00")) for v in versions)
            age = (now - newest).days
        else:
            age = None  # an empty shell has no value to be old
        checked.append({"secret": short, "age_days": age})
        if age is not None and age > limit:
            stale.append(short)
            log.error(json.dumps({"event": "stale_secret", "secret": short, "age_days": age, "limit_days": limit}))
    return {"action": "secret_age", "limit_days": limit, "checked": checked, "stale": stale}


# route -> (function, arrives as a Pub/Sub push envelope)
ROUTES = {"/scc": (scc, True), "/ops": (ops, True), "/secret-age": (secret_age, False)}


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802 (http.server API)
        self.reply(200, {"ok": True})

    def do_POST(self):  # noqa: N802
        route = ROUTES.get(self.path)
        if route is None:
            return self.reply(404, {"error": "no such route"})
        try:
            n = int(self.headers.get("content-length", "0"))
            fn, enveloped = route
            body = json.loads(self.rfile.read(n) or b"{}")
            payload = decode(body) if enveloped else body
            result = fn(config(), payload)
            log.warning(json.dumps({"event": "handled", "route": self.path, **result}))
            self.reply(200, result)
        except Skip as s:
            log.warning(json.dumps({"event": "skipped", "route": self.path, "reason": str(s)}))
            self.reply(200, {"skipped": str(s)})
        except ValueError as e:
            log.warning(json.dumps({"event": "skipped", "route": self.path, "reason": f"bad json: {e}"}))
            self.reply(200, {"skipped": "bad json"})
        except Exception as e:  # noqa: BLE001 (any API failure must be retried)
            log.error(json.dumps({"event": "failed", "route": self.path, "error": str(e)}))
            self.reply(500, {"error": str(e)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("", port), Handler).serve_forever()
