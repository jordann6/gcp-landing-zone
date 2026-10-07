"""Regression tests for a gate that must never interpret missing cost as zero."""

import contextlib
import importlib.util
import io
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "check_cost", Path(__file__).resolve().parents[1] / "scripts/check-cost.py"
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class CostGateTests(unittest.TestCase):
    def check(self, delta, limit="50", approved=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return gate.check(
                {"projects": [{"name": "workload"}], "diffTotalMonthlyCost": delta},
                limit,
                approved,
            )

    def test_under_limit_and_savings_pass(self):
        for delta in ("0", "2.50", "-100", "50"):
            with self.subTest(delta=delta):
                self.assertEqual(self.check(delta), 0)

    def test_over_limit_fails_without_approval(self):
        self.assertEqual(self.check("50.01"), 1)

    def test_approval_allows_over_limit(self):
        self.assertEqual(self.check("50.01", approved=True), 0)

    def test_invalid_cost_fails_even_with_approval(self):
        for delta in (None, True, [], {}, "", "unknown", "NaN", "Infinity"):
            for approved in (False, True):
                with self.subTest(delta=delta, approved=approved):
                    with self.assertRaises(ValueError):
                        self.check(delta, approved=approved)

    def test_missing_delta_fails(self):
        with self.assertRaises(ValueError):
            gate.check({"projects": [{}]}, "50", False)

    def test_null_diff_uses_known_totals(self):
        report = {
            "projects": [{"name": "network"}],
            "diffTotalMonthlyCost": None,
            "pastTotalMonthlyCost": "100",
            "totalMonthlyCost": "100",
        }
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.check(report, "50", False), 0)
            report["totalMonthlyCost"] = "150.01"
            self.assertEqual(gate.check(report, "50", False), 1)

    def test_missing_or_empty_projects_fail(self):
        for projects in (None, [], "workload"):
            with self.subTest(projects=projects):
                with self.assertRaises(ValueError):
                    gate.check({"projects": projects, "diffTotalMonthlyCost": "0"}, "50", False)

    def test_invalid_limit_fails(self):
        for limit in ("-1", "NaN", "Infinity", "", "unknown"):
            with self.subTest(limit=limit):
                with self.assertRaises(ValueError):
                    self.check("2.50", limit=limit)


if __name__ == "__main__":
    unittest.main()
