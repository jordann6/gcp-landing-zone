# ADR-0002: Distributed Cloud NGFW instead of centralized inspection

- **Status:** accepted
- **Date:** 2026-10-06

## Context

The AWS landing zone routes every VPC through an inspection VPC with AWS Network
Firewall behind a Transit Gateway. The three zones are meant to read as one
design, so the obvious move is to build the same hub on GCP. The constraint that
matters: Cloud NGFW enforces firewall policy in the fabric at every VM NIC, so
GCP already provides the control that the AWS hub exists to provide.

## Decision

Enforce egress inspection with firewall policy attached to each VPC, not with
an appliance path. An organization-level hierarchical policy applies to every
VPC, including ones this landing zone did not create: it denies internet
ingress, admits IAP and health checks, and denies known-malicious IPs in both
directions. Each VPC's network firewall policy adds default-deny egress with an
FQDN allowlist. The hub project holds only what is genuinely shared: DNS and the
hybrid attachment point.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| NVAs or a centralized inspection VPC, mirroring AWS | Adds an appliance to size, scale and fail over, a routing choke point, and cost, to reproduce what the platform does natively |
| Classic VPC firewall rules only | No hierarchy, so a VPC created outside the landing zone is ungoverned, and no FQDN or threat-intelligence matching |
| Cloud NAT as the egress control | NAT translates addresses; it does not decide which destinations are allowed |

## Consequences

Every control is policy, so there is nothing to route through and one fewer
failure mode, but there is also no single place where all egress is observable
as one flow. Visibility comes from firewall logging on each rule, which feeds the
egress-deny alert in `observability/`. Two limits are real and tested: the
organization policy's IAP allow is final, so a quarantined VM (see `incident/`)
keeps IAP SSH; and rule priorities are unique per policy across both
directions, which constrains where new rules can go. Revisit if a requirement
appears for payload inspection (TLS decryption, IPS), which is a separate
Cloud NGFW tier and not enabled here.
