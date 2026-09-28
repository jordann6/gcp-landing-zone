# GCP Landing Zone

An organization built as code to Google's security foundations blueprint: five
governed tiers, org policy and custom constraints at the root, per-environment
base and restricted Shared VPCs behind a VPC Service Controls perimeter,
workforce-federated personas with just-in-time prod access, and a private GKE
plus Cloud SQL paved road that proves the controls hold for a real workload.

![Architecture](docs/architecture.png)

It is one of three standalone landing zones (AWS, Azure, GCP) built to the same
design: the same tiers, the same `10.x` address plan, the same pipeline, and no
connectivity between them. Canonical design:
`aws-scp-governance/docs/multicloud-networking-design.md`.

**Cost:** under $0.50/month standing. A full deploy, test, and destroy session is
about $2 to $5. Every hourly resource lives in a root that is torn down on its own.

## The problem

A cloud organization decays in a predictable direction. Projects get created
outside any hierarchy, each with a default VPC nobody chose. Service account keys
accumulate. Audit logs exist per project and nowhere centrally, so "who read
that" has no answer. A workload can reach any address on the internet and any
public registry. Spend is discovered monthly.

None of this is caused by bad engineers. It is caused by the defaults being
wrong, and by every correct decision needing to be remade by each person who
creates a project. A landing zone moves those decisions into the hierarchy,
where inheritance enforces them and nobody can skip them.

## How GCP differs from AWS and Azure here

**Org policy constrains configuration, not callers.** An SCP is a deny boundary
evaluated against IAM at request time. Azure Policy evaluates resources and can
deny, audit, or mutate. GCP org policy constrains the shape of the configuration
itself: the API rejects a resource that violates a constraint.

**Exceptions work in the opposite direction.** An SCP deny cannot be un-denied
lower in the tree, so AWS grants exceptions by moving accounts. A GCP child
policy can widen an inherited list constraint. The sandbox folder does exactly
that for `gcp.resourceLocations`, and prod does the reverse, adding a CMEK
requirement nothing else carries.

**IAM inherits down the hierarchy.** A role on a folder applies to every project
beneath it, including projects that do not exist yet. Folder design is a
security decision.

**Inspection is distributed, not centralized.** AWS routes every VPC through an
inspection VPC with Network Firewall. On GCP, Cloud NGFW enforces firewall
policy at every VM NIC in the fabric, so the equivalent control (default-deny
egress with an FQDN allowlist, threat-intel deny) is policy attached to each
VPC, with no appliance to route through, scale, or fail over. Building an
AWS-style hub with NVAs here would reproduce, at cost, what the platform does
natively. The hub in this zone holds only what is genuinely shared: DNS and the
hybrid attachment point.

**Perimeters are a control IAM cannot express.** VPC Service Controls decide
whether a call may cross a boundary, independent of whether the caller has the
permission. A stolen credential still cannot read a bucket in the perimeter from
outside it.

## Layout

| Root | What | Cost posture |
|---|---|---|
| `bootstrap/` | Seed project, state bucket, `sa-terraform`, GitHub WIF (plan and gated-apply identities). Runs as you, once | Pennies |
| `terraform/` | Governance: folders, project factory, org policy, custom constraints, workforce federation, PAM, org sinks, CMEK, SCC, budgets, org-admin and CIS alerts | Nearly free |
| `network/` | Base + restricted Shared VPCs, Cloud NAT, hierarchical + network firewall policy, PSC + private DNS, hub, VPC-SC, probe VM | Hourly |
| `workload/` | Paved road in `app-prod`: private GKE, Cloud SQL HA + DR replica, Secret Manager, Artifact Registry, Binary Authorization, backup vault | Hourly |

Each root after bootstrap applies as `sa-terraform` through impersonation and
reads the root beneath it from remote state.

## What gets built

**Hierarchy (five tiers, same as AWS OUs and Azure MGs).** `core` (logging,
net-hub), `workloads` (dev, test, prod), `sandbox`. Every project goes through
`modules/project-factory`, so none exists without a folder, billing, data-access
audit logs, and the default network suppressed.

**Org policy at the root.** Ten boolean constraints (no default network, OS
Login, Shielded VM, no serial port, no guest attributes or nested
virtualization, Shared VPC lien protection, no public or authorized-network
Cloud SQL, public access prevention), no VM external IPs, and US-only
locations. Prod adds `gcp.restrictNonCmekServices`; sandbox widens locations to
the EU.

Six constraints Google pre-applies to new orgs (SA key creation and upload,
uniform bucket access, and three others) are **deliberately not managed**. v1
imported them, which made Terraform their owner, and `terraform destroy` then
deleted them. `make test` asserts they are still enforced instead.

**Custom constraints.** CEL rules, enforced at the org: GKE clusters must use
private nodes, and GKE clusters and Cloud SQL instances must carry a
`cost_center` label. Spend that cannot be allocated is rejected at creation.
This is GCP's tag enforcement, and it is stronger than a report.

**Identity.** Workforce Identity Federation to an external OIDC IdP, seven
personas bound to IdP groups at folder scope, no standing prod write, and two
Privileged Access Manager entitlements (`prod-write`, `org-admin`) that grant
roles for one hour after a security approval. Break-glass is the org's original
admin, and every call it makes raises an alert. See
[docs/access-model.md](docs/access-model.md).

**Network.** Per environment `/16`, split into a restricted `/17` (GKE nodes
10.3.0.0/20, services 10.3.32.0/19, pods 10.3.64.0/18, PSA 10.3.16.0/20) and a
base `/17`. The default internet route is deleted on every VPC and re-added only
for Cloud NAT. The org hierarchical policy denies internet ingress except IAP
SSH and health checks, and drops known-malicious IPs both ways. Each VPC's
network policy denies all egress except its own range, the PSC endpoint, and an
FQDN allowlist. Google APIs resolve to a PSC endpoint through private zones: the
`all-apis` bundle on base, `vpc-sc` on restricted. Environments are not peered
to each other or to the hub.

**VPC Service Controls.** The restricted host and its app project sit in one
perimeter that restricts Storage, BigQuery, Cloud SQL, Secret Manager, KMS, and
Pub/Sub. `sa-terraform` is admitted by an ingress rule, the org sinks by an
egress rule, and you are not, which is what `make test` proves.

**Logging and detection.** Two org sinks with `include_children`: a CMEK
BigQuery dataset for long-form audit queries, and a Log Analytics bucket that
the alert metrics count against (org IAM, org policy, VPC-SC, firewall policy,
break-glass use, and CIS 2.4 to 2.11). SCC Standard streams findings to Pub/Sub.
Budgets on the billing account and, separately, the sandbox.

**Paved road.** A private zonal GKE cluster (DNS endpoint for operators, no IP
allowlist, no bastion), Dataplane V2 NetworkPolicy, Workload Identity with
direct principal bindings (no GSA, no key), KMS envelope encryption of etcd,
CMEK node disks, and Binary Authorization requiring a KMS-signed attestation.
Images come only from an Artifact Registry virtual repo over org images and a
Docker Hub pull-through cache. Cloud SQL for PostgreSQL 17 is regional HA,
private IP, TLS-only, CMEK, with PITR and a cross-region replica in us-east1.
Only the GKE nodes' service account reaches the PSA range on 5432; NetworkPolicy
narrows that to `tier=app` pods.

## Deploy

Requires an org and an open billing account. Bootstrap runs as you and needs
`organizationAdmin`, `billing.admin`, and `projectCreator`; it grants everything
else to `sa-terraform`.

```bash
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars   # org, billing, operators
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # vend set, alert email
cp network/terraform.tfvars.example network/terraform.tfvars       # operators

make bootstrap        # seed, state, sa-terraform, WIF; writes backend.hcl + lz.auto.tfvars
make deploy           # governance (nearly free)
make deploy-network   # hourly
make deploy-workload  # hourly
```

**Project cap.** A self-serve billing account caps linked projects, and deleted
projects count for 30 days. The full design vends 10 plus the seed. The `vend`
flags in `terraform.tfvars` pick a reduced set (seed, logging, net-prod-r,
app-prod) that still exercises the workload root; the example file shows both.

## Test

```bash
make test            # governance + network
make test-workload   # paved road (includes a Cloud SQL failover; SKIP_FAILOVER=1 to skip)
```

Every check prints PASS, FAIL, or SKIP, and a denial passes only if the error
names the expected control, so a denial for some other reason is not a false
pass.

| Check | Proves |
|---|---|
| Google default constraints still enforced | Destroy did not delete what it did not create |
| SA key creation, out-of-region bucket, VM external IP | Org policy denials, each naming its constraint |
| Bucket without CMEK: rejected in prod, accepted in dev | Placement alone changes governance |
| Sandbox resolves EU locations, prod does not | Child policy widening, inheritance |
| Freshly vended project has zero networks | Factory + `skipDefaultNetworkCreation` |
| Custom constraints enforced; workforce pool and PAM entitlement exist | Identity and label controls are live |
| Org sink delivering | Audit trail from every project |
| Probe: github.com reachable, example.com denied | FQDN allowlist, default-deny egress |
| Probe: `storage.googleapis.com` resolves to 10.x | PSC + private DNS |
| You are denied reading storage in the perimeter; sa-terraform is admitted | VPC Service Controls |
| Unsigned image rejected; signed digest admitted | Binary Authorization |
| Job reads its secret through WI and connects over TLS | Workload Identity, Secret Manager, private Cloud SQL |
| Unlabelled pod and the probe VM cannot reach 5432 | NetworkPolicy and firewall-policy segmentation |
| Private IP only, CMEK, HA, PITR, replica running | Data tier |
| Failover changes zone, keeps the IP | HA, with the time printed as measured RTO |

## Cost

| | |
|---|---|
| Governance, standing | KMS key versions, a small BigQuery dataset: pennies |
| Network, while up | PSC endpoints, NAT (billed per VM using it), NGFW per GB, probe e2-micro: about $0.10 to $0.15/hr |
| Workload, while up | Cloud SQL HA on 1 vCPU (about $0.13/hr), DR replica (about $0.07/hr), two e2-standard-2 nodes (about $0.20/hr). The zonal GKE management fee is covered by the free tier: about $0.40 to $0.50/hr |
| Full session (about 3.5 hours) | About $2 to $5 |
| After destroy | Under $0.50/mo (key rings cannot be deleted; empty ones are free) |

## Destroy

```bash
make destroy   # workload, then network, then governance, then verify-teardown.sh
terraform -chdir=bootstrap destroy   # last, with force_destroy_state = true
```

`scripts/verify-teardown.sh` checks both Terraform state and the live org: no
VMs, routers, forwarding rules, VPN tunnels, disks, clusters, or SQL instances in
any landing zone project, and Google's default constraints still present. A
LoadBalancer Service's forwarding rule or a PVC's disk is never in Terraform
state, and this is what catches it.

GCP teardown traps, all hit for real in v1 or designed around here:

- **Importing a policy makes you its owner, and destroy then deletes it.** v1
  imported Google's pre-applied constraints and destroy removed them, leaving
  the org less protected than before. Restore with
  `gcloud resource-manager org-policies enable-enforce <constraint> --organization=<org>`.
  This build never imports them.
- **Org policies are deleted, not reverted.** Destroy returns the org to Google's
  defaults, not to some previous state.
- **Folders must be empty,** including of projects in `DELETE_REQUESTED`.
- **KMS key rings cannot be deleted, ever.** Destroy drops them from state;
  deleting the project takes them with it.
- **Deleted projects linger 30 days** with IDs never reusable. They still show in
  `gcloud projects list`. Check lifecycle state and billing, not absence.
- **Org sinks are org-level.** A partial destroy can leave a sink writing to a
  dataset that no longer exists, silently.
- **A backup vault with backups in it cannot be deleted** until its enforced
  retention passes. The Cloud SQL association is off by default for that reason
  (`associate_sql_with_vault`).
- **The PSA peering outlives Cloud SQL by a few minutes.** `deletion_policy =
  ABANDON` lets the network root finish.

## What the live v1 deploy taught (2026-08-10)

**A new GCP organization is not greenfield.** Google pre-applies a
secure-by-default policy set. Declaring those constraints fails with `409
POLICY_ALREADY_EXISTS`.

**Billing accounts cap linked projects,** and `DELETE_REQUESTED` projects count.

**A resource count must be knowable at plan time.** Hence explicit `vend` and
`attach_shared_vpc` flags instead of counts derived from generated IDs.

**`organizationAdmin` grants almost none of the operational org roles.**
folderAdmin, policyAdmin, xpnAdmin, and logging.configWriter each had to be
added after an apply failed on exactly one resource. `sa-terraform` now carries
the full list, and `securitycenter.admin` replaces the notification role that
proved insufficient.

**`skipDefaultNetworkCreation` governs a project's starting state, not the name
`default`.** Creating a network called `default` later succeeds. Verify the
control by listing a freshly vended project's networks.

v1 deployed 52 resources, proved inheritance, the org sink, and two policy
denials, and was destroyed for under $0.20.

## Pipeline

`.github/workflows/guardrails.yml` runs the shared
[platform-guardrails](https://github.com/jordann6/platform-guardrails) static
gates on every root (gitleaks over full history, fmt, validate, lock files,
tflint, Checkov, Trivy), this repo's own conftest rules with a fixture that must
fail, and shellcheck. The gated apply, destroy, and hourly TTL guard use WIF
through the bootstrap identities; they are wired and inactive until the shared
workflows' GCP auth path is tagged. See the header of each workflow for the
activation steps.

## What changes at production scale

- **Regional GKE control plane** and at least two node pools; the free tier
  covers only a zonal one.
- **SCC Premium or Enterprise** for scored CIS compliance.
- **A locked log bucket** and `delete_contents_on_destroy = false`.
- **Cloud SQL client certificates** through the Auth Proxy or connectors, and
  IAM database authentication instead of a password.
- **A secret rotator** subscribed to the rotation topic (the pattern in
  `aws-secrets-lifecycle` and `azure-secrets-lifecycle`).
- **An exception workflow** for org policy, since hardcoded overrides are where
  landing zones erode.
- **Interconnect** in place of the HA VPN placeholder.

See [docs/cis-mapping.md](docs/cis-mapping.md),
[docs/access-model.md](docs/access-model.md), and
[docs/accelerator-vs-bespoke.md](docs/accelerator-vs-bespoke.md).
