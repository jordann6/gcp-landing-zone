# ADR-0005: Google's default org policies are deliberately unmanaged

- **Status:** accepted
- **Date:** 2026-10-06

## Context

Google pre-applies a secure-by-default set of organization policies on new
organizations, including `iam.disableServiceAccountKeyCreation`,
`iam.disableServiceAccountKeyUpload` and `storage.uniformBucketLevelAccess`.
The first build of this landing zone imported them to resolve 409 conflicts.
That made Terraform their owner, and a `terraform destroy` then deleted them,
leaving the organization less protected than before the landing zone existed.

## Decision

Do not manage them. `google_default_constraints` in `terraform/org_policies.tf`
lists the six this zone relies on and documents them; none has a Terraform
resource, so destroy cannot touch them. Two scripts keep the dependency honest:
`scripts/test-guardrails.sh` asserts each is still enforced, and
`scripts/verify-teardown.sh` fails if three of them are missing after a destroy
and prints the command to restore them.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Import and manage them | A destroy then removes them, which is the failure this ADR exists to prevent |
| Ignore them entirely | The zone's controls (no service account keys, uniform bucket access) would depend on constraints nothing checks |
| Manage them with `prevent_destroy` | Blocks the documented teardown of the whole governance root |

## Consequences

The zone depends on controls it does not own, so a change to Google's defaults,
or someone removing one by hand, is detected only when the tests run. The checks
are the compensating control, and they run in `make test` and after every
destroy. If Google changes the default set, update the list and the checks
together.
