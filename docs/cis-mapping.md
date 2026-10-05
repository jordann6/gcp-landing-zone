# CIS Google Cloud Platform Foundation Benchmark mapping

Maps CIS GCP Foundations (v3.0 numbering) controls to the Terraform resource or
policy that implements them in this repo. Rows marked **N/A** or **not
implemented** say why, rather than being left out.

Scored CIS reporting (the Security Health Analytics compliance dashboard) needs
Security Command Center Premium or Enterprise, which are priced against total
asset spend. This build wires SCC Standard (free) findings to Pub/Sub and
treats Premium as the production design, the same way Shield Advanced is
documented-only in the AWS zone. Activating SCC for an organization is a
console-only step with no API or Terraform resource, so the findings stream is
gated by `enable_scc_notifications` and was off in the recorded deploy. The
controls below are enforced whether or not anything is scoring them.

## 1. Identity and Access Management

| CIS | Control | Implementation |
|---|---|---|
| 1.1 | Corporate credentials only | Humans federate through Workforce Identity Federation (`terraform/identity.tf`); no personal accounts are bound to any persona role |
| 1.2 | MFA for non-service accounts | Enforced at the external IdP (Entra ID / Okta Conditional Access), which the workforce pool trusts. **Not codified here** |
| 1.3 | Security key enforcement for admins | IdP-side, as 1.2. **Not codified here** |
| 1.4 | Only GCP-managed service account keys | `iam.disableServiceAccountKeyCreation` and `...Upload` (Google defaults, asserted by `make test`); `network.rego` denies `google_service_account_key` at PR time |
| 1.5 | No admin privileges on service accounts | Workload SAs carry scoped predefined roles only (`workload/gke.tf`); the one exception (GKE agent `compute.securityAdmin` on the host) is documented in `network/iam.tf` |
| 1.6 | No user-managed SA roles at project level for users | Personas bind at folder scope to principalSets, never to users |
| 1.7 | Key rotation for user-managed keys | N/A: no user-managed keys can exist (1.4) |
| 1.8 | Separation of duties for SA roles | sa-terraform is impersonated; the only human grant is `serviceAccountTokenCreator` on it (`bootstrap/identity.tf`) |
| 1.9 | KMS keys not anonymously or publicly accessible | Key IAM is per service agent only (`terraform/kms.tf`, `workload/kms.tf`) |
| 1.10 | KMS keys rotated within 90 days | `rotation_period = 7776000s` on every symmetric key |
| 1.11 | Separation of duties for KMS roles | Encrypter/decrypter granted to service agents; admin is sa-terraform only |
| 1.12 | API keys | N/A: no API keys are created |
| 1.15 | Essential contacts configured | `google_essential_contacts_contact.org` (`terraform/monitoring.tf`) when `alert_email` is set |
| 1.17 | Secrets not stored in function env vars | Secrets live in Secret Manager under CMEK (`workload/secrets.tf`); pods read them through Workload Identity |

## 2. Logging and Monitoring

| CIS | Control | Implementation |
|---|---|---|
| 2.1 | Cloud Audit Logging for all services and users | `google_project_iam_audit_config` with ADMIN_READ, DATA_READ, DATA_WRITE on every vended project (`modules/project-factory`) and the seed |
| 2.2 | Sinks configured for all log entries | Two org sinks with `include_children` (`terraform/logging.tf`), filtered to the security-relevant audit streams |
| 2.3 | Retention policies on log buckets | Partition expiry on the BigQuery dataset and `retention_days` on the log bucket. The bucket is **unlocked** so the demo can be destroyed; production sets `locked = true` |
| 2.4 | Alert on project ownership changes | `cis-2-4-project-ownership` metric and alert (`terraform/monitoring.tf`) |
| 2.5 | Alert on audit configuration changes | `cis-2-5-audit-config` |
| 2.6 | Alert on custom role changes | `cis-2-6-custom-role` |
| 2.7 | Alert on VPC firewall rule changes | `cis-2-7-vpc-firewall`, plus `firewall-policy-change` for hierarchical and network policies |
| 2.8 | Alert on VPC route changes | `cis-2-8-vpc-route` |
| 2.9 | Alert on VPC network changes | `cis-2-9-vpc-network` |
| 2.10 | Alert on Cloud Storage IAM changes | `cis-2-10-storage-iam` |
| 2.11 | Alert on SQL instance configuration changes | `cis-2-11-sql-config` |
| 2.12 | Cloud DNS logging for all VPCs | Hub inbound policy logs (`network/hub.tf`). **Not implemented** on every environment VPC; a per-VPC `google_dns_policy` with `enable_logging` is the fix |
| 2.13 | Cloud Asset Inventory enabled | Security persona holds `cloudasset.viewer`; the API is not explicitly enabled per project. **Partial** |
| 2.16 | Logging on HTTP(S) load balancers | N/A: no load balancers are created |

## 3. Networking

| CIS | Control | Implementation |
|---|---|---|
| 3.1 | Default network does not exist | `compute.skipDefaultNetworkCreation` + `auto_create_network = false` in the factory; `make test` asserts a vended project has zero networks |
| 3.2 | Legacy networks do not exist | All VPCs are custom mode (`repo policy` denies auto mode) |
| 3.3 | DNSSEC for Cloud DNS | N/A: private zones only (DNSSEC applies to public zones) |
| 3.6 | SSH not open to the internet | Org hierarchical policy denies internet ingress and allows 22 only from the IAP range (`network/firewall.tf`); `network.rego` denies 0.0.0.0/0 on non-web ports |
| 3.7 | RDP not open to the internet | Same org rule; 3389 is never allowed |
| 3.8 | VPC flow logs on every subnet | `log_config` on every subnet; `repo policy` denies a subnet without it |
| 3.9 | No weak SSL policies | N/A: no HTTPS load balancers |
| 3.10 | IAP for inbound TCP | IAP-only SSH to the probe VM |

## 4. Virtual Machines

| CIS | Control | Implementation |
|---|---|---|
| 4.1 | Not using the default Compute SA | Probe VM and GKE nodes use dedicated SAs; `repo policy` denies a node pool without one |
| 4.2 | Default SA not given full API access | Same |
| 4.3 | Block project-wide SSH keys | `block-project-ssh-keys = TRUE` on the probe; `compute.requireOsLogin` org-wide |
| 4.4 | OS Login enabled | `compute.requireOsLogin` |
| 4.5 | Serial port disabled | `compute.disableSerialPortAccess` |
| 4.6 | IP forwarding disabled | Not enabled anywhere (default). **Not enforced by policy** |
| 4.7 | Disks encrypted with CSEK | **Not implemented** by design: CMEK is used for all workload data; CSEK skipped with reason on the stateless probe |
| 4.8 | Shielded VM | `compute.requireShieldedVm` org-wide |
| 4.9 | No public IPs | `compute.vmExternalIpAccess` deny-all; `make test` proves the denial |
| 4.11 | Confidential Computing | **Not implemented** (cost and machine-family constraint) |

## 5. Storage

| CIS | Control | Implementation |
|---|---|---|
| 5.1 | Buckets not anonymously or publicly accessible | `storage.publicAccessPrevention` org-wide; `network.rego` denies allUsers grants |
| 5.2 | Uniform bucket-level access | `storage.uniformBucketLevelAccess` (Google default, asserted by `make test`) |

## 6. Cloud SQL

| CIS | Control | Implementation |
|---|---|---|
| 6.2.1 to 6.2.8 | PostgreSQL logging flags | Static `database_flags` on primary and replica (`workload/sql.tf`) |
| 6.2.9 | pgAudit | `cloudsql.enable_pgaudit = on`, `pgaudit.log = ddl,role` |
| 6.4 | Require SSL | `ssl_mode = ENCRYPTED_ONLY` (TLS on every connection). Client-certificate mode is the Auth Proxy upgrade |
| 6.5 | Not open to the world | `sql.restrictAuthorizedNetworks` |
| 6.6 | No public IP | `sql.restrictPublicIp` + `ipv4_enabled = false`; `make test-workload` asserts private-only |
| 6.7 | Automated backups | `backup_configuration` with PITR; immutable vault in `workload/backup.tf` |

## 7. BigQuery

| CIS | Control | Implementation |
|---|---|---|
| 7.1 | Datasets not public | No public grants; dataset IAM is the sink writer and the security persona |
| 7.2, 7.3 | CMEK on tables and datasets | `default_encryption_configuration` on the audit dataset |

## Beyond CIS (landing zone controls)

| Control | Implementation |
|---|---|
| Prod requires CMEK | `gcp.restrictNonCmekServices` on the prod folder only |
| Label (cost_center) enforcement | Custom constraint on GKE clusters (`terraform/custom_constraints.tf`); Cloud SQL labels in review via `policy/gcp_lz.rego` (the SQL API does not expose labels to custom constraints) |
| Cloud SQL private IP only | Custom constraint `custom.sqlRequirePrivateIp` (`terraform/custom_constraints.tf`) |
| Data exfiltration boundary | VPC Service Controls perimeter around the restricted tier (`network/vpc_sc.tf`) |
| Egress allowlist | Cloud NGFW Standard FQDN rules, default-deny egress (`network/firewall.tf`) |
| Threat-intel deny | `iplist-known-malicious-ips` both directions at the org |
| Supply chain admission | Binary Authorization with a KMS attestor (`workload/binauthz.tf`) |
