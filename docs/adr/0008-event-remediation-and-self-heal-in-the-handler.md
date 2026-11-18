# ADR-0008: Event remediation and edge self-heal as handler routes

- **Status:** accepted
- **Date:** 2026-11-18

## Context

The AWS zone has a `remediation/` root (EventBridge to Lambda) that reverts
risky changes, and an `uptime/` root. This zone already had the org Asset
Inventory feed publishing IAM and firewall changes, and an incident handler
with a dry-run safety model, a push identity and per-action custom roles.

Org policy already prevents most drift outright (no SA keys, no public IPs on
VMs, no public buckets, no internet ingress at the org firewall). Two changes
it cannot prevent are a VPC firewall rule that opens 0.0.0.0/0 (blocked in
effect by the org rule, but still a misconfiguration nobody intended) and a
standing `roles/owner` or `roles/editor` grant to a human, which bypasses PAM
just-in-time access.

## Decision

Add `/asset` to the existing handler, pushed from the asset feed. It disables
an enabled ingress rule admitting 0.0.0.0/0 (skipping GKE-managed `gke-` and
`k8s` rules) and removes newly added primitive-role grants to `user:`,
`group:` or `domain:` members that carry no IAM condition. PAM grants always
carry an expiry condition, so they never match. It only acts in the
environment's app project and its Shared VPC hosts.

Add `web_heal` to `/ops`, mapped to the edge uptime alert. It reads the web
Deployment through the GKE DNS endpoint as the handler's own identity and
scales it back to its floor, or restarts it, with a 10-minute cooldown.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| A separate remediation service | Another image, push identity, subscription set and dry-run switch, all duplicating the handler |
| An IAM deny policy against primitive roles for humans | Prevents rather than reverts, which is better where it fits. It also blocks the break-glass path and needs care with PAM. Worth adding later; remediation still catches what a deny policy is not written for |
| Self-heal with a Kubernetes operator in the cluster | Kubernetes already restarts crashed pods. This covers what it will not undo, someone scaling a Deployment to zero, and it starts from the user-facing signal |

## Consequences

- `resourcemanager.projects.setIamPolicy` is the sharpest permission the
  handler holds. With it the handler could grant itself anything in those
  projects. The code only removes primitive-role human members, re-reads the
  policy with its etag so it cannot overwrite a concurrent change, and stays
  in dry-run unless `dry_run=false`.
- The handler's own change produces a new feed message, which finds nothing
  to fix and is skipped, so there is no loop.
- The handler reaches the cluster over the public DNS endpoint, authorized by
  IAM, with no kubeconfig or Kubernetes secret. The endpoint itself checks
  `container.clusters.connect` before anything reaches the API server, and
  `container.deployments.get` and `update` are checked after. The first live
  run had only the latter and got a front-end 403 on every call.
