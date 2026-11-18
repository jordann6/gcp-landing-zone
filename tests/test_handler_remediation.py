"""Event remediation, edge self-heal and budget routes, with the Google APIs
stubbed. Run: python3 -m unittest tests.test_handler_remediation"""

import datetime
import json
import unittest

from tests import test_incident_handler as base  # installs the google.auth stubs

handler = base.handler
CFG = dict(
    base.CFG,
    remediate_projects=["111", "net-prod-r-1", "app-prod-x"],
    web_namespace="app",
    web_deployment="web",
    web_min_replicas=2,
    web_heal_cooldown_s=600,
)


def stubbed(responses, fn, *args):
    rec = base.Recorder(responses)
    orig_call, orig_wait = handler.call, handler.wait_global_op
    handler.call, handler.wait_global_op = rec, (lambda p, op: op)
    try:
        return fn(*args), rec
    finally:
        handler.call, handler.wait_global_op = orig_call, orig_wait


def fw(name="allow-ssh-anywhere", ranges=("0.0.0.0/0",), disabled=False, direction="INGRESS"):
    return {
        "asset": {
            "name": f"//compute.googleapis.com/projects/net-prod-r-1/global/firewalls/{name}",
            "assetType": "compute.googleapis.com/Firewall",
            "resource": {"data": {"name": name, "direction": direction, "sourceRanges": list(ranges), "disabled": disabled, "allowed": [{"IPProtocol": "tcp", "ports": ["22"]}]}},
        }
    }


def iam(bindings, prior=None):
    p = {"asset": {"name": "//cloudresourcemanager.googleapis.com/projects/111", "assetType": "cloudresourcemanager.googleapis.com/Project", "iamPolicy": {"bindings": bindings}}}
    if prior is not None:
        p["priorAsset"] = {"iamPolicy": {"bindings": prior}}
    return p


class Firewall(unittest.TestCase):
    def test_open_ingress_disabled_live(self):
        out, rec = stubbed({}, handler.asset_change, dict(CFG, dry_run=False), fw())
        self.assertEqual(out["action"], "remediate_firewall")
        self.assertIn(("PATCH", "https://compute.googleapis.com/compute/v1/projects/net-prod-r-1/global/firewalls/allow-ssh-anywhere"), rec.calls)

    def test_dry_run_writes_nothing(self):
        out, rec = stubbed({}, handler.asset_change, CFG, fw())
        self.assertTrue(out["dry_run"])
        self.assertEqual(rec.calls, [])

    def test_ignores_closed_managed_disabled_egress(self):
        for p in (fw(ranges=("10.0.0.0/8",)), fw(name="gke-prod-abc-all"), fw(name="k8s2-fw-x"), fw(disabled=True), fw(direction="EGRESS")):
            with self.assertRaises(handler.Skip):
                stubbed({}, handler.asset_change, dict(CFG, dry_run=False), p)

    def test_other_project_skipped(self):
        p = fw()
        p["asset"]["name"] = p["asset"]["name"].replace("net-prod-r-1", "someone-else")
        with self.assertRaises(handler.Skip):
            stubbed({}, handler.asset_change, dict(CFG, dry_run=False), p)


class StandingAdmin(unittest.TestCase):
    OWNER = {"role": "roles/owner", "members": ["user:intruder@example.com", "serviceAccount:sa-terraform@x"]}

    def test_new_human_owner_removed_with_etag(self):
        fresh = {"etag": "E", "bindings": [dict(self.OWNER), {"role": "roles/viewer", "members": ["user:intruder@example.com"]}]}
        sent = {}

        def rec(method, url, **kw):
            if url.endswith(":getIamPolicy"):
                return json.loads(json.dumps(fresh))
            sent.update(kw["json"])
            return {}

        orig = handler.call
        handler.call = rec
        try:
            out = handler.asset_change(dict(CFG, dry_run=False), iam([self.OWNER], prior=[]))
        finally:
            handler.call = orig
        self.assertEqual(out["removed"], ["roles/owner user:intruder@example.com"])
        owner = [b for b in sent["policy"]["bindings"] if b["role"] == "roles/owner"][0]
        self.assertEqual(owner["members"], ["serviceAccount:sa-terraform@x"])
        self.assertEqual(sent["policy"]["etag"], "E")
        # Only the primitive role is touched; viewer stays.
        self.assertTrue(any(b["role"] == "roles/viewer" for b in sent["policy"]["bindings"]))

    def test_pam_grant_with_condition_ignored(self):
        pam = {"role": "roles/editor", "members": ["user:op@example.com"], "condition": {"expression": "request.time < timestamp('2026-11-18T16:00:00Z')"}}
        with self.assertRaises(handler.Skip):
            stubbed({}, handler.asset_change, dict(CFG, dry_run=False), iam([pam], prior=[]))

    def test_preexisting_grant_not_reacted_to(self):
        with self.assertRaises(handler.Skip):
            stubbed({}, handler.asset_change, dict(CFG, dry_run=False), iam([self.OWNER], prior=[self.OWNER]))

    def test_service_account_owner_ignored(self):
        sa = {"role": "roles/owner", "members": ["serviceAccount:x@y"]}
        with self.assertRaises(handler.Skip):
            stubbed({}, handler.asset_change, dict(CFG, dry_run=False), iam([sa], prior=[]))


class WebHeal(unittest.TestCase):
    CLUSTER = {"controlPlaneEndpointsConfig": {"dnsEndpointConfig": {"endpoint": "gke-abc.us-central1-a.gke.goog"}}}

    def dep(self, replicas, healed=None):
        ann = {"lz.heal/at": healed} if healed else {}
        return {"spec": {"replicas": replicas, "template": {"metadata": {"annotations": ann}}}}

    def heal(self, dep, cfg=None):
        calls = []

        def rec(method, url, **kw):
            calls.append((method, url, kw.get("data")))
            if "container.googleapis.com" in url:
                return self.CLUSTER
            return dep if method == "GET" else {}

        orig = handler.call
        handler.call = rec
        try:
            out = handler.ops(dict(cfg or CFG, dry_run=False), {"incident": {"state": "open", "policy_name": "lz-ops-edge-uptime", "resource": {"labels": {}}}})
        finally:
            handler.call = orig
        return out, calls

    def test_scaled_to_zero_is_scaled_back(self):
        out, calls = self.heal(self.dep(0))
        patch = [c for c in calls if c[0] == "PATCH"][0]
        self.assertTrue(patch[1].startswith("https://gke-abc.us-central1-a.gke.goog/apis/apps/v1/namespaces/app/deployments/web"))
        self.assertEqual(json.loads(patch[2])["spec"]["replicas"], 2)
        self.assertIn("scale", out["did"])

    def test_healthy_count_gets_restart_not_scale(self):
        out, calls = self.heal(self.dep(2))
        body = json.loads([c for c in calls if c[0] == "PATCH"][0][2])
        self.assertNotIn("replicas", body["spec"])
        self.assertIn("lz.heal/at", body["spec"]["template"]["metadata"]["annotations"])

    def test_cooldown_skips(self):
        recent = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        with self.assertRaises(handler.Skip):
            self.heal(self.dep(0, healed=recent))


class Budget(unittest.TestCase):
    def test_threshold_crossed(self):
        out = handler.budget(CFG, {"budgetDisplayName": "organization-monthly", "costAmount": 26.0, "budgetAmount": 50, "alertThresholdExceeded": 0.5, "currencyCode": "USD"})
        self.assertEqual(out["crossed"]["actual"], 0.5)
        self.assertEqual(out["percent"], 52.0)

    def test_plain_update_is_not_a_page(self):
        out = handler.budget(CFG, {"budgetDisplayName": "organization-monthly", "costAmount": 3.0, "budgetAmount": 50})
        self.assertIsNone(out["crossed"])


if __name__ == "__main__":
    unittest.main()
