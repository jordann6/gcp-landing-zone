# ADR-0007: Edge through a GKE Ingress, Cloud Armor by BackendConfig, HTTP only

- **Status:** accepted
- **Date:** 2026-11-18

## Context

The Azure zone fronts its workload with Front Door and a WAF, and the AWS zone
with CloudFront. This zone had no internet entry point at all. The nodes are
private, the org firewall policy denies internet ingress except IAP and the
Google front-end ranges, and the app namespace is default-deny.

## Decision

Terraform owns the reserved global address and the Cloud Armor policy (WAF
rules for SQL injection, XSS, path traversal and Log4j, a per-IP throttle, a
default allow). A GKE Ingress builds the global external Application Load
Balancer, and a BackendConfig attaches the policy. Traffic reaches pods
through container-native NEGs from 35.191.0.0/16 and 130.211.0.0/22, which
the org firewall rule `allow-health-checks` already admits, and a
NetworkPolicy admits only those ranges to the web pods.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Build the URL map, backend service and NEGs in Terraform | The NEGs belong to the GKE NEG controller. A Terraform-owned backend over controller-owned NEGs means two writers on the same resources |
| Gateway API | Equally valid and newer. It needs the cluster's Gateway API channel turned on and a GCPBackendPolicy for Cloud Armor. Ingress plus BackendConfig works on the cluster as it is |
| HTTPS with a Google-managed certificate | Needs a domain this demo does not own. A self-signed certificate would prove nothing a reviewer cares about |

## Consequences

- The controller creates load balancer resources Terraform does not track.
  `scripts/test-edge.sh --teardown` (run by `make destroy`) deletes the Ingress
  and waits until they are gone, and `verify-teardown.sh` lists backend
  services, URL maps, NEGs and security policies.
- TLS at the edge is documented, not proven. A real deployment adds a
  certificate map or ManagedCertificate on its own domain and an HTTP to HTTPS
  redirect.
- The org-level health-check rule is broad (every TCP port from the Google
  front-end ranges). The NetworkPolicy narrows it to 8080 on the web pods.
