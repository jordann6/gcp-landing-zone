# ADR-0004: Management VM inside the VPC Service Controls perimeter

- **Status:** accepted
- **Date:** 2026-10-06

## Context

Each landing zone deploys one hardened management VM as the operator's foothold
on the restricted tier. On GCP the restricted tier is inside a VPC-SC
perimeter, and the choice is whether the VM sits inside it. Inside means it
reaches Google APIs only through the restricted PSC bundle. Outside means it
needs no perimeter rules but is not on the restricted subnet.

## Decision

Place the VM in the prod app project on the restricted Shared VPC subnet,
inside the perimeter: golden image family, shielded, OS Login, IAP only, no
external IP, its own service account. Artifact Registry is not a restricted
service, so the VM reads the mirror in the image project, which is outside the
perimeter, without an egress rule.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| A VM outside the perimeter | It would not be on the restricted subnet, so it could not reach the data tier the way an operator on that tier must, and a foothold outside the boundary defeats the boundary |
| A perimeter-wide ingress rule for the operator | The operator is deliberately outside the perimeter so `make test` can prove the denial; admitting that identity would remove the proof |

## Consequences

The VM is the target of the quarantine runbook, and the perimeter shaped that
design: the incident handler runs outside the perimeter, and because Compute
is not a restricted service it can tag, snapshot and stop the VM across the
boundary; only Cloud SQL Admin and Secret Manager, which are restricted, need
an ingress rule for the handler's service account. OS Config patching works
through the restricted bundle, and `test-compute.sh` proves a patch job
succeeds. Guest attributes, which inventory reporting needs, are disabled by
the organization, so inventory is unavailable and patch jobs do not need it.
