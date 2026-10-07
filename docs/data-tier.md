# Data tier and paved-road workload

The `workload/` root builds the prod paved road in the `app-prod` project on
the restricted Shared VPC: a private GKE cluster, Cloud SQL for PostgreSQL in
regional HA with private IP only, a backup vault with enforced retention, a
private registry path, and Secret Manager with Workload Identity.

## Who can talk to whom

Segmentation is enforced at three layers: separate VPCs per environment, network
firewall policy rules that name identities rather than IPs, and Kubernetes
NetworkPolicy under Dataplane V2.

| Source | Destination | Port | Allowed | Enforced by |
|---|---|---|---|---|
| GKE nodes (by service account) | Cloud SQL | 5432 | yes | `allow-app-to-db` egress rule, priority 800 |
| pods labelled `tier=app` in `app` | Cloud SQL | 5432 | yes | node rule above, narrowed by `k8s/10-netpol.yaml` |
| other pods | Cloud SQL | any | no | NetworkPolicy |
| other VMs, the probe VM included | the data tier | any | no | `deny-other-to-db`, priority 850, ahead of the VPC's allow-internal rule |
| anything | Cloud SQL | public | no | `ipv4_enabled = false`, private services access only |
| dev or test | prod data tier | any | no | separate VPCs in separate host projects, no peering |

The two firewall rules live in the network root's policy for this VPC but are
owned by `workload/`, because they name the workload's own service account.

## Availability

| Property | Value | How |
|---|---|---|
| Model | Active-passive | Regional HA: a synchronous standby in a second zone |
| Zonal failure | RPO 0, automatic failover on the same private IP | Synchronous replication to the standby zone |
| Regional loss | RPO seconds, manual promote | Optional asynchronous read replica in `replica_region` (default `us-east1`), `enable_cross_region_replica` |
| Backups | Daily automated, 7 retained, point-in-time recovery with 7 days of logs | `backup_configuration` on the instance |

These are the design values from `sql.tf`. `make test-workload` checks regional
HA, CMEK, private IP, point-in-time recovery and, when the replica exists, that
it is running; its failover check restarts the primary into its standby zone
and compares zones before and after (skip with `SKIP_FAILOVER=1`). A failover
timing is not recorded here. The replica is off in the compute-baseline session
(`enable_cross_region_replica=false`) to halve the hourly cost.

## Backups and immutability

A Backup and DR vault (`bv-prod-sql`) enforces a minimum retention
(`backup_vault_min_retention`, default `86400s`): nobody, the project owner and
`sa-terraform` included, can delete a backup before it elapses. That is the
GCP counterpart of Vault Lock and Azure immutable vaults. The instance's own
automated backups live with the instance and go when it does, which is why the
vault is a separate layer. The Cloud SQL association to the vault's plan is off
by default (`associate_sql_with_vault`).

A vault holding backups survives a destroy until they age out, and still bills.
`scripts/verify-teardown.sh` lists vaults as `sa-terraform` for that reason. The
delete path with a backup present has not been proven yet; see
[completion.md](completion.md).

## Supply chain and the cluster

- **Private registry only.** Nodes cannot reach Docker Hub: the NGFW egress
  policy denies every destination not on the FQDN allowlist. Public images
  arrive through an Artifact Registry remote repository, a pull-through cache,
  and workloads use one virtual repository over it and the org's own `apps`
  repository (immutable tags, CMEK).
- **Admission.** Binary Authorization admits an image only if its digest has an
  attestation signed by the KMS key in `binauthz.tf`; Google's system images
  are exempt. `make test-workload` deploys an unsigned image and expects the denial.
  `scripts/sign-image.sh` signs a digest and shows it admitted.
- **Private control plane.** Private nodes and a private endpoint, reached
  through the IAM-authenticated DNS endpoint, with no IP allowlist.
  Workload Identity is on.
- **Secrets.** The database password is in exactly two places: Cloud SQL and a
  CMEK-encrypted Secret Manager secret. Terraform manages the secret as an
  empty shell and never holds the value, so it is in no state file.
  `scripts/set-db-password.sh` sets both in one step, and the app reads it
  through Workload Identity. Rotation is a schedule (30 days) plus a Pub/Sub
  notification; a daily check reports any secret older than 90 days. See
  [completion.md](completion.md) for what was proven.
- **Nodes and images.** GKE nodes use Google-managed images with a weekend
  maintenance window; the golden image is for standalone VMs only
  ([compute-baseline.md](compute-baseline.md)).
