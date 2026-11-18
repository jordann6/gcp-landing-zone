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
- ~~**CI apply, destroy and TTL guard.**~~ Proven live after this record:
  gated apply, gated destroy and the 4-root TTL guard ran on GitHub WIF (run
  IDs in the README's Pipeline section).
- ~~**A real rotation.**~~ Built and proven 2026-11-18 (`rotation/`,
  ADR-0006), with the failover write probe, the edge, self-heal, event
  remediation, the SLO and the FinOps views. See Proof, 2026-11-18.

## Proof, 2026-11-18

Deployed on a reduced footprint (no image bake, compute root or probe VM; those
were proven 2026-10-06 and nothing added here needs them): bootstrap FinOps
datasets, governance 184, network 43, workload 56, rotation 10, slo 8, edge 3,
incident 37, observability 28.

| Proof | Result |
|---|---|
| `make test-rotation` | 10 passed, 0 failed. Decoys skipped; rotated 1s after the scheduled time, 0.8s of work; exactly one enabled version; db-check connected over TLS with it; new value in none of 11 state objects |
| `make test-failover` | 7 passed, 0 failed. us-central1-c to us-central1-f, operation 36s; client write outage 14.5s, 50 failed attempts; 0 of 723 acknowledged writes lost |
| `make test-edge` | 11 passed, 0 failed. First 200 after 302s of programming; 403 for SQLi, XSS, LFI; benign 200; 59 x 200 and 121 x 429 from a 180-request burst at 60/min |
| `make test-self-heal` | 8 passed, 0 failed. Edge down 12s after the break; `lz-ops-edge-uptime` opened at 163s; the handler scaled app/web 0 to 2 and the edge served 200 at 173s. The first run healed at 388s because the role lacked `container.clusters.connect` (below); this is the rerun with it in place |
| `make test-remediation` | 9 passed, 0 failed. Open rule disabled 22s after creation; editor removed 15s after the grant; viewer kept; `lz-ops-remediation-applied` opened |
| SLO | Fault revision served 17:03:55Z; slow-burn ticket 17:08:36Z; fast-burn page 17:10:39Z; fault removed 17:29:25Z; page closed 447s later under 2,165 clean requests. `test-slo.sh` itself was stopped by a quoting bug (below), so these times come from the Monitoring alerts API and the revision timestamps; the fixed script has not been re-run end to end |
| FinOps | Console export enabled, table created within the hour, views applied, `make finops-report` ran on the backfill |

### What the live run found

1. **No `google_sql_user` without a password.** Cloud SQL for PostgreSQL
   rejects a built-in user with no password, and this path had never been
   applied since the password moved out of Terraform. The user is now created
   by `set-db-password.sh`.
2. **Cloud Run memory floor.** 256Mi is rejected with always-allocated CPU;
   512Mi is the minimum.
3. **`kubectl wait` on a Job's pod** fails at once if the pod does not exist
   yet. The drill waits for the pod, then for Running.
4. **A write in flight during failover hangs.** `connect_timeout` only bounds
   opening a connection; the INSERT on a connection whose server went away
   waited on TCP for over 10 minutes. Each write now has a 3s ceiling. An
   application with no statement or socket timeout has the same failure.
5. **`gcloud ... security-policies describe`** returned a one-element array.
6. **Unquoted jq path** in `test-slo.sh` lost its inner quotes to the shell,
   so the script polled for a policy with an empty name.
7. **IAM member casing.** IAM stores a user in the account's canonical casing,
   so a case-sensitive match reported the viewer grant as removed and could
   not clean it up. Matches are case-insensitive now.
8. **The GKE DNS endpoint needs `container.clusters.connect`.** Without it
   every call is a front-end 403 before the API server sees it.
9. **New log-based metrics** take up to 10 minutes before an alert policy can
   reference them; a second apply creates the rest.
10. **Process.** The remediation script was edited while a run was reading
    it, which crashed that run and left a test viewer grant behind; it was
    removed by hand and the run repeated.

After the session, CI flagged two things the live run did not exercise: lock
files generated on macOS carried no linux_amd64 hashes (fixed with `terraform
providers lock`), and Trivy KSV-0014 on the edge web container. Its root
filesystem is now read-only, verified locally with the same image under
`docker --read-only --tmpfs /tmp`, not in a second live session.

The firewall remediation also showed the retry path working: the first
attempts hit `resource not ready` while the rule was still being created,
returned 500, and Pub/Sub redelivered until the disable succeeded.

## Session for the 2026-11-18 additions

After the session above through `deploy-observability`, in this order. Every
apply is a saved plan reviewed first.

```sh
make deploy                      # governance again: run API on app projects, budget topic output
make deploy-network              # Cloud Run service agent on the restricted subnet
make deploy-rotation             # identities
make build-rotator
make deploy-rotation             # service and push subscription
make test-rotation
make test-failover
make deploy-edge
make test-edge
make deploy-slo                  # identities (slo/terraform.tfvars holds alert_email)
make build-orders
make deploy-slo
make test-slo
make deploy-incident             # with -var dry_run=false (new routes, roles, subscriptions)
make deploy-observability        # with -var enable_incident_channel=true -var enable_edge_uptime=true
make test-self-heal
make test-remediation
make finops-report               # after the one console step in bootstrap/finops.tf
```

`make destroy` now deletes the edge Ingress first and waits for the
controller to remove the load balancer, then destroys observability, incident,
rotation, slo, edge and the rest.

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
