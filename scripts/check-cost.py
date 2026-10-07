#!/usr/bin/env python3
"""Enforce the monthly cost delta without relying on hosted policy settings."""

import argparse
import json
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path


def amount(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise ValueError("cost must be a finite number")
    try:
        result = Decimal(str(value))
    except InvalidOperation as exc:
        raise ValueError("cost must be a finite number") from exc
    if not result.is_finite():
        raise ValueError("cost must be a finite number")
    return result


def check(report, limit, approved):
    if not isinstance(report, dict):
        raise ValueError("cost report must be a JSON object")
    if not isinstance(report.get("projects"), list) or not report["projects"]:
        raise ValueError("cost report has no projects")
    if "diffTotalMonthlyCost" not in report:
        raise ValueError("cost report is missing its monthly delta")
    if report["diffTotalMonthlyCost"] is None:
        # Infracost can omit a numeric diff when no priced resource changed.
        # Derive it only from two known totals, never from an assumed zero.
        delta = amount(report.get("totalMonthlyCost")) - amount(
            report.get("pastTotalMonthlyCost")
        )
    else:
        delta = amount(report["diffTotalMonthlyCost"])
    ceiling = amount(limit)
    if ceiling < 0:
        raise ValueError("cost limit must be nonnegative")
    print(f"Projected monthly change: ${delta} (limit: ${ceiling})")
    if delta > ceiling:
        if approved:
            print("Cost increase approved by the cost-approved PR label.")
        else:
            print("Cost gate failed. Justify the increase and add cost-approved.")
            return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--limit", required=True)
    parser.add_argument("--approved", choices=("true", "false"), default="false")
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text())
        return check(report, args.limit, args.approved == "true")
    except (OSError, ValueError) as exc:
        print(f"Cost gate failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
