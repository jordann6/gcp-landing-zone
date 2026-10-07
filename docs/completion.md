# GCP landing-zone completion: verification and demo lifecycle

This is the runbook for a deploy, prove and destroy session, and the record of
what each proof showed. Nothing here is claimed without a recorded result. The
standing footprint is the bootstrap and governance roots; everything else is
deployed for a session and destroyed after.

## Session order

Every apply is a saved plan reviewed first; roots after bootstrap apply as
`sa-terraform` by impersonation.

```sh
make bootstrap
make deploy                      # governance
make deploy-image                # Artifact Registry Ubuntu mirror, bake VPC
make build-image                 # Packer bake, about 15 minutes
make deploy-network
make deploy-workload WORK_VARS='-var enable_ubuntu_node_pool=true -var enable_cross_region_replica=false'
make set-db-password             # once, after workload: sets Cloud SQL and the secret shell
make deploy-compute
make deploy-incident             # repository, identities, topic
make deploy-network              # again with -var enable_incident_access=true
make build-incident              # needs docker
make deploy-incident             # service and subscriptions
make deploy-observability        # with -var enable_incident_channel=true
```

The handler deploys in dry-run. Applying `incident` with `-var dry_run=false`
is the only way to make it act, and `-var sql_failover_live=true` is a second,
separate switch for Cloud SQL failover.

## Proof, and what each showed (2026-10-06)

| Proof | Result | What it covers |
|---|---|---|
| `make test` | 23 passed, 0 failed, 2 skipped | org policy denials name their constraint, inheritance, custom constraints, identity, logging, network |
| `make test-compute` | 20 passed, 0 failed | image policy, golden boot, live hardening, mirror-only apt, a successful patch job |
| `make test-observability` | 15 passed, 0 failed | metrics scope, 11 ops alert policies, a forced egress-deny alert opened in about 3 minutes |
| `make test-asset-history` | 9 passed, 0 failed | an IAM change found in the Asset Inventory feed and the BigQuery export, then reverted |
| `make test-incident`, dry-run | 15 passed, 0 failed | private service, quarantine firewall rule, a decision per sample message, nothing mutated |
| `make test-incident`, live | 24 passed, 0 failed | the management VM tagged, labeled, snapshotted, stopped and its service account detached, then restored; GKE pool resized 2 to 3 and back; Cloud SQL stayed dry |
| `make test-secrets` | 30 passed, 0 failed | no secret value in any of 7 state objects, `SECRET_ROTATE` published after 377 seconds, the stale-secret alert opened |
| `make test-handler` | 22 unit tests pass | handler decisions with the Google APIs stubbed |

SCC is not activated for the organization, which is console-only, so the SCC
path was proven by publishing a sample finding to the topic the SCC
notification config would publish to. Everything downstream of the topic is the
real path. `enable_scc_notifications`, `enable_scc_alerts` and
`enable_network_log_sink` default to off.

### Not proven, or proven with limits

- **Cloud SQL failover through the handler.** The first live incident run
  failed the primary over by mistake (the script claimed a dry-run gate the
  handler did not have). The instance came back available in a different zone;
  no timing was taken. Failover now has its own off-by-default switch, and the
  final live run left it dry.
- **A real rotation.** The notification fires, but no rotator mints a new
  version from it. `set-db-password.sh` does that by hand.
- **Cloud NGFW payload inspection.** Not enabled; see ADR-0002.
- **Backup vault delete path** with a backup present. Not tested. The vault `bv-prod-sql` held no data sources and no backups (the SQL association is off), and the workload destroy plan includes the vault and plan with `ignore_backup_plan_references = true` and `force_delete = false`. A populated vault would block deletion for the 1-day enforced retention.
- **`make test-workload`** has not been re-run since the database password
  moved out of Terraform.
- **CI apply, destroy and TTL guard.** Written, inactive ([ADR-0001](adr/0001-pipeline-on-shared-guardrails.md)).

## Teardown

Destroy in this order, which `make destroy` runs: observability, incident,
compute, workload, network, image, governance. Observability goes first so no
alert fires for resources being removed, and incident goes before the VM and
database it acts on.

Known blockers, all seen in this build:

- **Backup vault.** A vault holding backups enforces retention and can block
  the workload destroy. Check the delete path before the final destroy.
- **Quarantine leftovers.** A tag value with a binding cannot be deleted, and a
  snapshot keeps billing. The live test unbinds the tag and deletes the
  snapshot; `verify-teardown.sh` flags a surviving snapshot.
- **Deleted projects** stay in `DELETE_REQUESTED` for 30 days and count against
  the billing account's project cap. Two other projects were unlinked from
  billing to make room this session; relink them after the final destroy:
  `gcloud billing projects link idp-platform-63f7 --billing-account=<billing-account-id>`
  and the same for `jn-gitops-seed-277909`.
- **Workforce pool** soft-deletes for 30 days.
- **KMS key rings** cannot be deleted and cost nothing.
- A failed apply makes a saved plan stale. Re-plan; never reuse a plan.

## Verify and close out

```sh
scripts/verify-teardown.sh
```

It checks Terraform state for every root and then the live organization for
instances, routers, forwarding rules, VPN tunnels, disks, images, snapshots,
external addresses, GKE clusters, Artifact Registry repositories, Cloud SQL
instances and backup vaults in every ACTIVE landing-zone project, and that
Google's default org policies survived the destroy. A clean run reports no
active landing-zone projects or empty ones. ### Final teardown result (2026-10-06)

`make destroy` applied all seven roots without an error (observability 22,
incident 26, compute 14, workload 58, network 48, image 29, governance 183
resources) and every root's state is empty. `verify-teardown.sh` reported 15
passed, 22 failed. The Terraform state checks passed, every project reported
clean, and the three Google default org policies survived. All 22 failures
are `inventory unavailable`: the app, net, logging and images projects went to
`DELETE_REQUESTED`, so their list APIs no longer answer, and the seed project
denied `backupdr.backupVaults.list` to `sa-terraform`. Those are not leftover
resources, but the verifier could not prove their absence either. The vault `bv-prod-sql` was empty and deleted with its project's
workload destroy. Only the seed project (bootstrap) remains ACTIVE. Billing
was relinked for `idp-platform-63f7` and `jn-gitops-seed-277909`.

The verifier was then fixed: it lists only ACTIVE projects, so a
`DELETE_REQUESTED` project is skipped, and it lists the seed project's backup
vaults as the operator, since `sa-terraform` has no backupdr grant there. Re-run
afterwards: 11 passed, 0 failed.

Billing reporting lags, so a clean verifier does not establish a zero invoice.
Check billing once reporting catches up.
