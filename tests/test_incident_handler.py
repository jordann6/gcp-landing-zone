"""Handler decisions, with the Google APIs stubbed. No network, no credentials.

Run: python3 -m unittest tests.test_incident_handler  (needs google-auth on the path
only for import; the stub replaces the session before any call)."""

import base64
import json
import os
import sys
import types
import unittest

# The handler imports google.auth at module load; stub it so the tests run anywhere.
google = types.ModuleType("google")
google.auth = types.ModuleType("google.auth")
google.auth.default = lambda scopes=None: (None, None)
transport = types.ModuleType("google.auth.transport")
requests_mod = types.ModuleType("google.auth.transport.requests")
requests_mod.AuthorizedSession = object
sys.modules.update(
    {
        "google": google,
        "google.auth": google.auth,
        "google.auth.transport": transport,
        "google.auth.transport.requests": requests_mod,
    }
)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "incident", "app"))
import handler  # noqa: E402

CFG = {
    "dry_run": True,
    "app_project": "app-prod-x",
    "app_project_number": "111",
    "eligible_label": "role=mgmt",
    "tag_value": "tagValues/9",
    "gke_cluster": "gke-prod",
    "gke_location": "us-central1-a",
    "gke_pool": "pool-default",
    "gke_max_nodes": 3,
    "sql_instance": "pg-prod-ab",
    "sql_live": False,
}

VM = "//compute.googleapis.com/projects/111/zones/us-central1-a/instances/prod-mgmt"


class Recorder:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def __call__(self, method, url, **kw):
        self.calls.append((method, url))
        for needle, body in self.responses.items():
            if needle in url:
                return body
        return {}


def vm(labels):
    return {
        "id": "42",
        "labels": labels,
        "labelFingerprint": "f",
        "status": "RUNNING",
        "disks": [{"source": "https://x/zones/z/disks/prod-mgmt"}],
        "serviceAccounts": [{"email": "sa@x"}],
    }


class Quarantine(unittest.TestCase):
    def run_scc(self, cfg, finding, responses):
        rec = Recorder(responses)
        orig = handler.call
        handler.call = rec
        try:
            return handler.scc(cfg, {"finding": finding}), rec
        finally:
            handler.call = orig

    def test_dry_run_reads_but_never_writes(self):
        out, rec = self.run_scc(CFG, {"name": "f1", "resourceName": VM, "state": "ACTIVE"}, {"instances/prod-mgmt": vm({"role": "mgmt"})})
        self.assertTrue(out["dry_run"])
        self.assertEqual(out["steps"], ["tag", "label", "snapshot:quarantine-prod-mgmt-" + out["steps"][2].rsplit("-", 1)[1], "stop", "detach-sa"])
        self.assertTrue(all(m == "GET" for m, _ in rec.calls), rec.calls)

    def test_live_runs_every_step_in_order(self):
        cfg = dict(CFG, dry_run=False)
        orig = handler.wait_zone_op
        handler.wait_zone_op = lambda *a: {}
        try:
            _, rec = self.run_scc(cfg, {"name": "f1", "resourceName": VM}, {"instances/prod-mgmt": vm({"role": "mgmt"})})
        finally:
            handler.wait_zone_op = orig
        order = [u.rsplit("/", 1)[-1] for m, u in rec.calls if m == "POST"]
        self.assertEqual(order, ["tagBindings", "setLabels", "createSnapshot", "stop", "setServiceAccount"])

    def test_ineligible_instance_is_skipped(self):
        with self.assertRaises(handler.Skip):
            self.run_scc(CFG, {"resourceName": VM}, {"instances/prod-mgmt": vm({"role": "web"})})

    def test_other_project_is_skipped_before_any_call(self):
        rec = Recorder({})
        orig = handler.call
        handler.call = rec
        try:
            with self.assertRaises(handler.Skip):
                handler.scc(CFG, {"finding": {"resourceName": VM.replace("111", "999")}})
        finally:
            handler.call = orig
        self.assertEqual(rec.calls, [])

    def test_missing_instance_is_skipped_not_retried(self):
        def gone(method, url, **kw):
            raise RuntimeError(f"{method} {url} -> 404 not found")

        orig = handler.call
        handler.call = gone
        try:
            with self.assertRaises(handler.Skip):
                handler.scc(CFG, {"finding": {"resourceName": VM}})
        finally:
            handler.call = orig

    def test_non_instance_resource_is_skipped(self):
        with self.assertRaises(handler.Skip):
            handler.scc(CFG, {"finding": {"resourceName": "//storage.googleapis.com/projects/_/buckets/b"}})

    def test_inactive_finding_is_skipped(self):
        with self.assertRaises(handler.Skip):
            handler.scc(CFG, {"finding": {"resourceName": VM, "state": "INACTIVE"}})


class Ops(unittest.TestCase):
    def run_ops(self, cfg, payload, responses):
        rec = Recorder(responses)
        orig = handler.call
        handler.call = rec
        try:
            return handler.ops(cfg, payload), rec
        finally:
            handler.call = orig

    def inc(self, policy, state="open", labels=None):
        return {"incident": {"policy_name": policy, "state": state, "resource": {"labels": labels or {}}}}

    def test_closed_incident_does_nothing(self):
        with self.assertRaises(handler.Skip):
            handler.ops(CFG, self.inc("lz-ops-gke-node-not-ready", state="closed"))

    def test_unmapped_policy_does_nothing(self):
        with self.assertRaises(handler.Skip):
            handler.ops(CFG, self.inc("lz-ops-sql-cpu-high"))

    def test_gke_resize_is_bounded(self):
        pool = {"initialNodeCount": 3}
        with self.assertRaises(handler.Skip):
            self.run_ops(CFG, self.inc("lz-ops-gke-node-not-ready", labels={"cluster_name": "gke-prod"}), {"nodePools": pool, "pool-default": pool})

    def test_gke_resize_dry_run(self):
        out, rec = self.run_ops(
            CFG,
            self.inc("lz-ops-gke-node-not-ready", labels={"cluster_name": "gke-prod"}),
            {"pool-default": {"initialNodeCount": 1}},
        )
        self.assertEqual((out["from"], out["to"]), (1, 2))
        self.assertTrue(all(m == "GET" for m, _ in rec.calls))

    def test_gke_autoscaled_pool_is_left_alone(self):
        with self.assertRaises(handler.Skip):
            self.run_ops(CFG, self.inc("lz-ops-gke-node-not-ready"), {"pool-default": {"autoscaling": {"enabled": True}}})

    def test_sql_failover_requires_ha(self):
        with self.assertRaises(handler.Skip):
            self.run_ops(CFG, self.inc("lz-ops-sql-instance-down"), {"instances/pg-prod-ab": {"settings": {"availabilityType": "ZONAL", "settingsVersion": 1}}})

    def test_sql_failover_wrong_instance(self):
        with self.assertRaises(handler.Skip):
            handler.ops(CFG, self.inc("lz-ops-sql-instance-down", labels={"database_id": "p:other"}))

    def test_sql_failover_stays_dry_without_its_own_switch(self):
        cfg = dict(CFG, dry_run=False)
        out, rec = self.run_ops(
            cfg,
            self.inc("lz-ops-sql-instance-down", labels={"database_id": "app-prod-x:pg-prod-ab"}),
            {"instances/pg-prod-ab": {"settings": {"availabilityType": "REGIONAL", "settingsVersion": 7}}},
        )
        self.assertTrue(out["dry_run"])
        self.assertTrue(all(m == "GET" for m, _ in rec.calls))

    def test_sql_failover_live_posts_failover(self):
        cfg = dict(CFG, dry_run=False, sql_live=True)
        out, rec = self.run_ops(
            cfg,
            self.inc("lz-ops-sql-instance-down", labels={"database_id": "app-prod-x:pg-prod-ab"}),
            {"instances/pg-prod-ab": {"settings": {"availabilityType": "REGIONAL", "settingsVersion": 7}}},
        )
        self.assertEqual(out["action"], "sql_failover")
        self.assertIn(("POST", "https://sqladmin.googleapis.com/v1/projects/app-prod-x/instances/pg-prod-ab/failover"), rec.calls)


class SecretAge(unittest.TestCase):
    def run_age(self, payload, versions):
        def fake(method, url, **kw):
            if url.endswith("/secrets"):
                return {"secrets": [{"name": "projects/p/secrets/db"}, {"name": "projects/p/secrets/empty"}]}
            if "/secrets/db/versions" in url:
                return {"versions": versions}
            return {}

        orig = handler.call
        handler.call = fake
        try:
            return handler.secret_age(CFG | {"secret_max_age_days": 90}, payload)
        finally:
            handler.call = orig

    def test_old_secret_is_stale_and_empty_shell_is_not(self):
        out = self.run_age({}, [{"createTime": "2020-01-01T00:00:00Z"}])
        self.assertEqual(out["stale"], ["db"])
        self.assertIsNone([c for c in out["checked"] if c["secret"] == "empty"][0]["age_days"])

    def test_fresh_secret_is_not_stale(self):
        now = handler.datetime.datetime.now(handler.datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(self.run_age({}, [{"createTime": now}])["stale"], [])

    def test_payload_overrides_the_limit(self):
        now = handler.datetime.datetime.now(handler.datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(self.run_age({"max_age_days": -1}, [{"createTime": now}])["stale"], ["db"])


class Envelope(unittest.TestCase):
    def test_decode(self):
        data = base64.b64encode(json.dumps({"a": 1}).encode()).decode()
        self.assertEqual(handler.decode({"message": {"data": data}}), {"a": 1})

    def test_garbage_is_a_skip_not_a_crash(self):
        with self.assertRaises(handler.Skip):
            handler.decode({"nope": 1})

    def test_dry_run_is_the_default(self):
        os.environ.pop("DRY_RUN", None)
        self.assertTrue(handler.config()["dry_run"])
        os.environ["DRY_RUN"] = "false"
        self.assertFalse(handler.config()["dry_run"])
        os.environ.pop("DRY_RUN")


if __name__ == "__main__":
    unittest.main()
