"""Rotator decisions and ordering, with the Google APIs stubbed. No network.

Run: python3 -m unittest tests.test_rotator"""

import base64
import os
import sys
import types
import unittest

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
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "rotation", "app"))
import rotator  # noqa: E402

CFG = {
    "project": "app-prod-x",
    "project_number": "111",
    "secret": "projects/app-prod-x/secrets/app-db-password",
    "instance": "sql-prod",
    "user": "app",
    "op_timeout": 5,
}
SECRET = "projects/111/secrets/app-db-password"


class Resp:
    def __init__(self, body=None, code=200):
        self.body, self.status_code = body or {}, code

    def json(self):
        return self.body

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


class FakeSession:
    """Records calls in order; versions and failures are configurable."""

    def __init__(self, versions, fail_add=False, op_error=None):
        self.versions, self.fail_add, self.op_error = versions, fail_add, op_error
        self.calls, self.sql_password, self.added = [], None, None

    def get(self, url, params=None):
        self.calls.append(("GET", url))
        if url.endswith("/versions"):
            return Resp({"versions": list(self.versions)})
        if "/operations/" in url:
            body = {"status": "DONE"}
            if self.op_error:
                body["error"] = self.op_error
            return Resp(body)
        raise AssertionError(url)

    def put(self, url, params=None, json=None):
        self.calls.append(("PUT", url))
        self.sql_password = json["password"]
        return Resp({"name": "op-1"})

    def post(self, url, json=None):
        self.calls.append(("POST", url))
        if url.endswith(":addVersion"):
            if self.fail_add:
                return Resp(code=503)
            self.added = base64.b64decode(json["payload"]["data"]).decode()
            return Resp({"name": f"{CFG['secret']}/versions/3"})
        if url.endswith(":disable"):
            return Resp({})
        raise AssertionError(url)


def envelope(event="SECRET_ROTATE", secret=SECRET, published="2026-11-18T15:00:00.123456789Z"):
    return {"message": {"attributes": {"eventType": event, "secretId": secret}, "publishTime": published, "messageId": "m1"}}


OLD = [
    {"name": f"{CFG['secret']}/versions/1", "createTime": "2026-10-01T00:00:00Z"},
    {"name": f"{CFG['secret']}/versions/2", "createTime": "2026-11-01T00:00:00.5Z"},
]


class RotatorTest(unittest.TestCase):
    def use(self, fake):
        rotator._session = fake
        return fake

    def test_rotates_sql_before_secret_then_disables_old(self):
        fake = self.use(FakeSession(OLD))
        out = rotator.rotate(envelope(), CFG)
        order = [c[0] + (" add" if c[1].endswith(":addVersion") else " disable" if c[1].endswith(":disable") else "") for c in fake.calls]
        self.assertLess(order.index("PUT"), order.index("POST add"))
        self.assertLess(order.index("POST add"), order.index("POST disable"))
        self.assertEqual(out["disabled"], ["1", "2"])
        self.assertEqual(out["version"], "3")

    def test_same_value_reaches_sql_and_secret(self):
        fake = self.use(FakeSession(OLD))
        rotator.rotate(envelope(), CFG)
        self.assertEqual(fake.sql_password, fake.added)
        self.assertGreaterEqual(len(fake.added), 32)

    def test_password_never_in_result(self):
        fake = self.use(FakeSession(OLD))
        out = rotator.rotate(envelope(), CFG)
        self.assertNotIn(fake.added, repr(out))

    def test_redelivery_after_rotation_is_skipped(self):
        newer = OLD + [{"name": f"{CFG['secret']}/versions/3", "createTime": "2026-11-18T15:00:09Z"}]
        fake = self.use(FakeSession(newer))
        with self.assertRaises(rotator.Skip):
            rotator.rotate(envelope(), CFG)
        self.assertFalse(any(c[0] == "PUT" for c in fake.calls))

    def test_other_event_types_skipped(self):
        for event in ("SECRET_UPDATE", "SECRET_VERSION_ADD", ""):
            fake = self.use(FakeSession(OLD))
            with self.assertRaises(rotator.Skip):
                rotator.rotate(envelope(event=event), CFG)
            self.assertEqual(fake.calls, [])

    def test_other_secret_skipped(self):
        for secret in ("projects/111/secrets/other", "projects/999/secrets/app-db-password", "garbage"):
            fake = self.use(FakeSession(OLD))
            with self.assertRaises(rotator.Skip):
                rotator.rotate(envelope(secret=secret), CFG)
            self.assertEqual(fake.calls, [])

    def test_project_id_form_accepted(self):
        self.use(FakeSession(OLD))
        out = rotator.rotate(envelope(secret="projects/app-prod-x/secrets/app-db-password"), CFG)
        self.assertEqual(out["version"], "3")

    def test_add_failure_raises_and_disables_nothing(self):
        fake = self.use(FakeSession(OLD, fail_add=True))
        with self.assertRaises(RuntimeError):
            rotator.rotate(envelope(), CFG)
        self.assertFalse(any(c[1].endswith(":disable") for c in fake.calls))

    def test_sql_operation_error_stops_before_secret(self):
        fake = self.use(FakeSession(OLD, op_error={"errors": [{"code": "X"}]}))
        with self.assertRaises(RuntimeError):
            rotator.rotate(envelope(), CFG)
        self.assertFalse(any(c[1].endswith(":addVersion") for c in fake.calls))

    def test_missing_envelope_fields_skip(self):
        for env in ({}, {"message": {}}, {"message": {"attributes": {}}}):
            with self.assertRaises(rotator.Skip):
                rotator.rotate(env, CFG)

    def test_parse_time_nanoseconds(self):
        t = rotator.parse_time("2026-11-18T15:00:00.123456789Z")
        self.assertEqual(t.microsecond, 123456)
        self.assertEqual(rotator.parse_time("2026-11-18T15:00:00Z").second, 0)


if __name__ == "__main__":
    unittest.main()
