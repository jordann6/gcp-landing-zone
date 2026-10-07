# ADR-0001: CI on the shared guardrails, not a bespoke pipeline

- **Status:** accepted
- **Date:** 2026-10-06

## Context

A landing zone that governs an organization cannot be gated by a formatter. It
needs secret scanning, IaC misconfiguration checks, policy-as-code, a destroy
guard over stateful resources, and cost visibility, and it needs the same gates
the other two landing zones and the rest of the fleet already run, so a fix in
one place lands everywhere. The binding constraint: this is one of three
parallel landing zones (AWS, Azure, GCP) that must read identically, maintained
by one person, so duplicated CI is a maintenance cost with no upside.

## Decision

Call the reusable workflows in `jordann6/platform-guardrails`, pinned to
`v1.4.0`: `tf-ci.yml` for the credential-free static gates, one job per root
(`guardrails.yml`), with the GCP policy rules the shared suite carries. The
repo's own rules in `policy/` run beside them and a violations fixture must
fail, so a rule that silently stops matching is caught. `apply.yml`,
`destroy.yml` and `ttl-guard.yml` call the shared `tf-apply.yml` and
`tf-destroy.yml`; they authenticate with Workload Identity Federation to
separate plan (read) and apply (environment-gated) service accounts, with no
keys.

The cost gate is the one piece kept local (`finops-gate.yml`, plus
`scripts/check-cost.py`). It fails closed on a missing or malformed Infracost
report, where the shared workflow's fallback reads the missing figure as $0 and
passes, and a root with no baseline on the base branch gets a zero baseline
instead of a failed estimate.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| A bespoke `validate.yml` (fmt and validate) | Not governance: no secret, policy, cost or destroy gate, and it drifts from the other two zones |
| Build apply, destroy and the TTL guard in this repo | Three zones would each grow a copy; the shared repo is the point of a fleet toolkit |
| One all-powerful CI identity | A read on a PR could then mint a token that changes the org; splitting plan from apply, with apply bound to a reviewer-gated environment, is the just-in-time control |
| Use the shared cost workflow as is | Its fallback passes on a missing report, which is the wrong failure direction for a gate |

## Consequences

Today the static gates and the cost gate are live; they run without cloud
credentials. The apply, destroy and TTL workflows are written but inactive: they
need the bootstrap WIF outputs set as repository variables, a committed CI
backend config (the local `backend.hcl` carries an impersonation setting CI must
not use), and a `prod-apply` environment with a required reviewer. Until then
every apply and destroy runs locally as `sa-terraform` by impersonation, and
`scripts/verify-teardown.sh` is the standing-resource check. The cost gate needs
an `INFRACOST_API_KEY` repository secret; whether it exists has not been
verified. If the shared workflows ever need a change this repo cannot wait for,
that is the signal to reconsider vendoring them.
