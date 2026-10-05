# Landing Zone Build Prompt

Paste the block below into a fresh chat to build one landing zone. Start with AWS as written; for the next builds, change only the `TARGET CLOUD:` line to Azure, then GCP, each in its own chat. The three zones are standalone and do not communicate. The prompt carries all three clouds' requirements so the parity is visible, but you build only the target cloud in each chat.

---

You are helping me build one of three standalone, isolated cloud landing zones as a portfolio demonstration. The goal is to show I can architect and engineer a high-level, best-practice landing zone for each provider. The three zones (AWS, Azure, GCP) DO NOT and WILL NOT communicate with each other. There is no cross-cloud connectivity.

TARGET CLOUD: AWS
(For the Azure build, change the line above to "TARGET CLOUD: Azure"; for GCP, "TARGET CLOUD: GCP". Build only the target cloud in this chat, using the matching PER-CLOUD block below.)

FIRST STEP: Read the canonical design reference at
/Users/jordannelson/aws-scp-governance/docs/multicloud-networking-design.md
It is the single source of truth. If anything here conflicts with it, the doc wins. If the file is missing, use the summary below.

STRATEGY SUMMARY (all three zones follow the same shape):
- Standalone and isolated. No cross-cloud peering, VPN, or shared address space. Each zone can reuse the same private address plan.
- Compliance target: CIS Foundations Benchmark for the target cloud. Produce a docs/cis-mapping.md that maps CIS control IDs to the exact Terraform resource or policy that implements them, with honest "not implemented / N/A in a demo account" rows.
- IaC: Terraform for everything. Bespoke modules, not the native accelerator, but add a docs note positioning bespoke vs the accelerator (AWS LZA / Azure Verified Modules / GCP foundations blueprint) as a deliberate choice.
- Posture: deploy, test/demo, destroy. Nothing left standing. Standing footprint after destroy must be ~$1 to $3/mo (KMS keys only). A full deploy/demo/destroy session should run under ~$7.

ENVIRONMENTS AND HIERARCHY (five tiers, identical across clouds):
- Platform: AWS Security OU + Infrastructure OU (network, shared-services, log-archive, audit accounts); Azure Platform MG (management, connectivity, identity subscriptions); GCP core folder (network + logging projects).
- Dev, Test, Prod: workload accounts/subscriptions/projects under a Workloads OU/MG/folder. Prod governed more strictly via inheritance.
- Sandbox: isolated account/subscription/project.

ADDRESS PLAN (same in each cloud, because isolated):
- Platform/hub 10.0.0.0/16, Dev 10.1.0.0/16, Test 10.2.0.0/16, Prod 10.3.0.0/16, Sandbox 10.4.0.0/16, growth 10.5.0.0/16 onward.
- Kubernetes prod ranges carved from 10.3.0.0/16: nodes 10.3.0.0/20, pods 10.3.64.0/18, services 10.3.32.0/19.

PILLARS (cloud-agnostic intent; the PER-CLOUD block says how this cloud implements each):
1. Resource hierarchy + the five tiers above.
2. Preventive guardrails as policy-as-code, applied at the hierarchy so inheritance enforces them. No audit-only where a deny is possible.
3. Human identity: federated SSO, least-privilege personas (admin, senior/platform eng, junior eng, manager, finops, security, break-glass) as groups bound at hierarchy scope, permission boundaries, no standing prod write (just-in-time elevation), root/global-admin hardened. Produce docs/access-model.md with the persona-by-scope matrix and the CIS control each row satisfies.
4. Networking: hub-and-spoke with centralized egress inspection, private endpoints for registry/secrets/logging, private DNS resolver, no public admin path, hybrid connectivity as a reserved on-prem placeholder only, k8s network policy default-deny.
5. Centralized logging to a dedicated account/project + detective monitoring.
6. Encryption: customer-managed keys with rotation; envelope-encrypt k8s etcd secrets with the same key family.
7. Secrets: the cloud secrets manager is the only sanctioned path, rooted in the CMK, with rotation; for the k8s demo, External Secrets Operator pulling via workload identity (no static keys).
8. Data tier: private data subnets, segmentation so dev/test/prod data tiers cannot reach each other and only the app tier reaches the DB on its port (include a who-can-talk-to-whom matrix); isolated backup vault with immutability; a small managed DB proven on a timed run; active-passive failover with defined RTO/RPO.
9. Supply chain: private registry with pull-through cache as the only image source, deny public registries, image scanning, cosign signing + SBOM + provenance attestation, admission verification. Golden-image pipeline for VMs.
10. Cost/FinOps: budgets and anomaly alerts, tag/label enforcement (cost_center, owner, environment, data_classification).

PER-CLOUD UNIQUE REQUIREMENTS (use only the block matching TARGET CLOUD):

=== AWS ===
- Hierarchy: AWS Organizations. OUs = Security, Infrastructure (network + shared-services + log-archive + audit accounts), Workloads (dev/test/prod accounts), Sandbox. Management account is SCP-exempt by design.
- Guardrails: SCPs (deny root user, deny leave-org, region lockdown with global-service exceptions, require encryption, deny public S3, deny disabling CloudTrail/Config/GuardDuty). Enable Security Hub with the CIS AWS Foundations Benchmark standard for scored coverage; add AWS Config conformance pack.
- Identity: IAM Identity Center permission sets bound to groups per OU; permissions boundaries cap delegation; short-session permission set for prod elevation; sealed break-glass with MFA.
- Network: Transit Gateway in the network account; egress/inspection VPC with NAT + AWS Network Firewall; ingress, egress, and east-west inspected; interface endpoints + S3 gateway endpoint; SSM Session Manager (no bastion, no public SSH).
- Logging/monitoring: org CloudTrail to an Object-Lock S3 bucket in log-archive; AWS Config; Security Hub + GuardDuty in the security account.
- Encryption/secrets: KMS CMK with rotation; Secrets Manager with a rotation lambda.
- Data/backup: RDS Multi-AZ; AWS Backup vault with Vault Lock (WORM) in an isolated account; cross-region copy.
- Supply chain: ECR + pull-through cache; Amazon Inspector image scan; EC2 Image Builder for hardened AMIs; deny non-ECR pulls.
- CI: GitHub OIDC role, no static keys.
- k8s (if this is the live cloud): EKS with OIDC provider + IRSA, KMS envelope encryption of Kubernetes secrets, private API endpoint.
- Gotchas: keep the management account SCP-exempt; detach TGW attachments before delete; empty S3 buckets before destroy; region-lockdown must exempt global services (IAM, STS, CloudFront, Route 53, Organizations).

=== Azure ===
- Hierarchy: management groups (Platform, Workloads, Sandbox). Ideal target is platform subscriptions (management, connectivity, identity) + workload subscriptions (dev/test/prod). CONSTRAINT: if only one subscription is available (no EA/MCA to vend subscriptions), represent the tiers with management groups + resource groups and document the intended subscription-per-tier design. Also my Azure subscription has 0 App Service VM quota, so avoid App Service; use Consumption/alternatives or document the quota-increase request.
- Guardrails: Azure Policy with DENY effects (not Audit); assign the built-in CIS Microsoft Azure Foundations Benchmark initiative; deny public IP, allowed locations, require tags.
- Identity: Entra ID groups + RBAC assigned at management group scope; PIM for time-bound, approver-gated JIT elevation; global admin hardened.
- Network: hub VNet + Azure Firewall + Bastion + a UDR forcing 0.0.0.0/0 through the firewall; VNet peering; Private Endpoints + Private DNS zones.
- Logging/monitoring: central Log Analytics workspace + diagnostic settings; Microsoft Defender for Cloud with its CIS assessment.
- Encryption/secrets: Key Vault + CMK + rotation; purge protection + soft delete on.
- Data/backup: Azure SQL failover group or zone-redundant (tier above the cheapest Basic DTU); Azure Backup with immutability + soft delete.
- Supply chain: ACR + cache rules; Defender for Containers scan; VM Image Builder + Azure Compute Gallery.
- CI: GitHub OIDC federated credential on a user-assigned managed identity.
- k8s (if this is the live cloud): AKS with Azure Workload Identity federated credentials; KMS etcd encryption via Key Vault; private cluster.
- Gotchas: VPN Gateway and Firewall take 10-30 min to delete; failover group tier requirement; single-subscription and App Service quota constraints above.

=== GCP ===
- Hierarchy: org + folders (core; workloads -> dev/test/prod; sandbox). Project factory so a project cannot exist without a folder, billing link, audit logging, and the default network suppressed.
- Guardrails: org policies applied at the ORG ROOT (disable service account key creation and upload, skip default network creation, require OS Login, disable serial port access, restrict public IP on Cloud SQL, uniform bucket-level access, deny VM external IP, resource locations). Keep allowedPolicyMemberDomains OFF by default (it blocks allUsers and breaks public Cloud Run). Use SCC posture / CIS scoring.
- Identity: Cloud Identity federation; IAM roles granted at folder scope (inherit down); IAM Conditions or short-lived grants for JIT; org admin hardened.
- Network: Shared VPC per environment (separate host projects); Cloud NAT; hierarchical firewall policies at org/folder; VPC Service Controls perimeter around data services; Private Google Access + Private Service Connect; IAP-only SSH.
- Logging/monitoring: org log sink with include_children to a partitioned BigQuery dataset; Security Command Center (Standard, free) streaming findings to Pub/Sub.
- Encryption/secrets: Cloud KMS CMEK across telemetry with rotation; Secret Manager with rotation.
- Data/backup: Cloud SQL HA + cross-region replica; automated backups.
- Supply chain: Artifact Registry + remote repositories (cache); Artifact Analysis scan; cosign + KMS signing + Binary Authorization (reuse gcp-supply-chain-security); Packer images.
- CI: Workload Identity Federation for GitHub Actions (reuse gcp-workload-identity-federation).
- k8s (if this is the live cloud): GKE Workload Identity; application-layer secrets encryption with Cloud KMS; private cluster.
- Gotchas: needs an org, an open billing account, and specific roles (org admin, billing admin) that are commonly missing; apply org policy at the org root, not a folder (a folder policy is bypassed by creating a project elsewhere); respect sink/project deletion order on teardown; list constraints can be widened by a child policy for deliberate exceptions.

PIPELINE (wire this repo to my shared toolkit):
- Use the reusable workflows in github.com/jordann6/platform-guardrails (tf-ci.yml, tf-plan.yml, finops-gate.yml). Do not build a bespoke parallel CI.
- Existing gates to keep: full-history gitleaks, fmt+validate, lockfile-committed assertion, tflint, Checkov, Trivy config, conftest OPA (tags/network/cost/finops), destroy-guard (blocks stateful delete/replace without a destroy-approved label), Infracost threshold gate.
- Additions this build should contribute: OIDC auth for the target cloud (no static keys), a gated tf-apply bound to a GitHub environment with a required reviewer, a tf-destroy plus a scheduled TTL auto-destroy job, and (GCP) OPA rules for google_ resources.

DELIVERABLES (every landing zone ships all of these):
- Deploy / test / destroy automation. A Makefile (or scripts/) exposing three verbs, mirroring my existing validate.sh / make verify pattern:
  * make deploy: terraform init/apply in the correct order, idempotent, OIDC or documented local auth. Confirm and show projected cost before anything that bills hourly.
  * make test: a live demo that PROVES the guardrails work, not just that apply succeeded. For example, assert a forbidden action returns AccessDenied under an SCP/Deny policy, a public resource is blocked, the DB rejects an unencrypted or public path, backups are immutable, and the failover promotes. Print pass/fail per check.
  * make destroy: terraform destroy followed by a verification step that lists any resource with an hourly rate still alive (fail if any remain). Document the cloud-specific teardown traps.
- Official architecture diagram. Generate docs/architecture.png with the mingrammer `diagrams` Python library using the OFFICIAL AWS/Azure/GCP service icons (no generic boxes). Commit both the generator (docs/diagram.py) and the rendered PNG. Show the hierarchy/tiers, hub-spoke network, logging, and guardrails. It is the first thing in the README.
- A great README. Match the voice and depth of my gcp-landing-zone README (it is the strongest). Structure:
  * One or two sentence statement of what it is.
  * The architecture diagram.
  * The problem it solves, in plain terms.
  * How this cloud differs from the other two on the relevant controls.
  * What gets built, by tier and pillar, with the specific resources and why.
  * Deploy / test / destroy commands and what each proves.
  * Cost (standing vs demo-window) and the teardown traps.
  * A link to docs/cis-mapping.md and docs/access-model.md.
  No AI-generated filler; every claim must be true of the actual code.

DDoS: free Standard/always-on tier is fine to rely on; Cloud Armor rules OK to demo on GCP; do NOT deploy Shield Advanced or Azure DDoS Network Protection (document as designed only).

CONSTRAINTS AND STYLE:
- No em dashes in prose.
- No AI attribution or co-author trailers in any commit, PR, or file.
- Plan before you apply. Show me the plan and the projected cost before any credentialed apply. Confirm before deploying anything that bills hourly.
- Every hourly resource must be destroyed after the demo (enforced by make destroy's verification step).
- Reuse my existing repos where they fit (aws-secrets-lifecycle, azure-secrets-lifecycle, aws-backup-system, azure-backup-system, multi-region-failover-manager, azure-multi-region-failover, gcp-supply-chain-security, azure-aks-runtime-security, eks-terraform, gcp-gke-config-sync, gcp-workload-identity-federation) pointed at landing-zone outputs, rather than rebuilding.
- Live Kubernetes runs on ONE cloud only (I will tell you which; default AWS). The other two are reference-wired.

BUILD ORDER FOR THIS CLOUD:
1. Wire the repo to platform-guardrails and get all static gates green.
2. Hierarchy + tiers + guardrails (governance).
3. Identity: federation + personas + root hardening.
4. Networking: hub-spoke + inspection + private endpoints + DNS.
5. Logging/monitoring + CMK + secrets.
6. Data tier: segmentation + backup vault + timed DB/failover.
7. Supply chain + (if this is the live-k8s cloud) the paved-road cluster demo.
8. Deliverables: make deploy/test/destroy, docs/architecture.png (+ diagram.py), cis-mapping.md, access-model.md, accelerator-vs-bespoke note, and the README.

Start by reading the design doc and the current state of the target cloud's repo, then propose a build plan for phase 1 (pipeline wiring) before writing code. My AWS repo today is aws-scp-governance (SCPs + org only, no networking yet); Azure is azure-landing-zone; GCP is gcp-landing-zone.
