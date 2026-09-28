#!/usr/bin/env bash
# Shared helpers for the test and teardown scripts.
#
# Two identities, on purpose:
#   OPERATOR  your own gcloud credentials. Tests that prove a control DENIES run
#             as you, because you are outside the VPC-SC perimeter and hold no
#             standing write anywhere, which is the point.
#   SA        sa-terraform through impersonation ($IMP). Tests that need to
#             attempt a write (to prove an org policy rejects it) run as the
#             identity that could otherwise have done it, so a denial is the
#             policy and not missing IAM.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tfout() { terraform -chdir="$ROOT/$1" output -raw "$2" 2>/dev/null; }
tfjson() { terraform -chdir="$ROOT/$1" output -json "$2" 2>/dev/null; }

SA="$(tfout bootstrap terraform_service_account)"
# Used by every script that sources this file.
# shellcheck disable=SC2034
IMP="--impersonate-service-account=${SA}"

PASS=0
FAIL=0
SKIP=0

ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        ${2:0:300}"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $1"; SKIP=$((SKIP + 1)); }
section() { echo; echo "== $1"; }

# expect_denied "<label>" "<regex the error must match>" cmd...
# Passes only when the command fails AND its output names the expected control,
# so a denial for an unrelated reason (missing IAM, a typo) is not a false pass.
expect_denied() {
	local label="$1" pattern="$2"
	shift 2
	local out
	if out="$("$@" 2>&1)"; then
		bad "$label (command SUCCEEDED; the control did not deny)" "$out"
		return 1
	fi
	if grep -Eq "$pattern" <<<"$out"; then
		ok "$label"
	else
		bad "$label (denied, but not by the expected control)" "$out"
	fi
}

# expect_ok "<label>" cmd...
expect_ok() {
	local label="$1"
	shift
	local out
	if out="$("$@" 2>&1)"; then
		ok "$label"
	else
		bad "$label" "$out"
	fi
}

summary() {
	echo
	echo "== ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
	[ "$FAIL" -eq 0 ]
}
