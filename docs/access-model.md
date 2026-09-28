# Access model

Humans sign in through **Workforce Identity Federation**: the corporate IdP
(Entra ID, Okta) stays authoritative, nobody is synced into Google, and IAM
binds on the IdP's `groups` claim through principalSet URIs. Removing someone
from an IdP group removes their GCP access on their next token.

Every binding is to a **group**, at **folder or org scope**, so it inherits to
every project beneath, including projects vended later. Nobody holds standing
write in prod. Source of truth: `terraform/identity.tf`.

## Persona matrix

| Persona | Scope | Standing roles | Elevation (PAM) | CIS |
|---|---|---|---|---|
| admin | org | organizationViewer, folderViewer, iam.securityReviewer | `org-admin`: folderAdmin + orgpolicy.policyAdmin, 1h, security approves | 1.6, 1.8 |
| platform_eng | core folder | compute.networkAdmin, dns.admin, logging.viewer | | 1.6 |
| platform_eng | workloads folder | viewer, container.viewer | | 1.6 |
| platform_eng | dev, test folders | container.admin, cloudsql.admin | | 1.6 |
| platform_eng | prod folder | (inherits read only) | `prod-write`: container.admin, cloudsql.admin, compute.instanceAdmin.v1, 1h, security approves | 1.6, 1.8 |
| junior_eng | dev folder | container.developer, cloudsql.client, logging.viewer, compute.viewer | | 1.6 |
| junior_eng | test folder | viewer | | 1.6 |
| junior_eng | prod | none | none | 1.6 |
| manager | workloads folder | browser, monitoring.viewer | | 1.6 |
| manager | billing account | billing.viewer (when manage_billing_iam) | | |
| finops | org | organizationViewer, recommender.viewer | | |
| finops | billing account | billing.viewer, billing.costsManager (when manage_billing_iam) | | |
| security | org | iam.securityReviewer, securitycenter.adminViewer, orgpolicy.policyViewer, accesscontextmanager.policyReader, cloudasset.viewer | approves all PAM grants | 1.8, 1.11 |
| security | logging project | logging.privateLogViewer, bigquery.dataViewer, bigquery.jobUser | | 2.x |
| platform_eng, junior_eng | sandbox folder | editor | | |

## Machine identities

| Identity | Where | What it can do | How it authenticates |
|---|---|---|---|
| sa-terraform | seed | Org-level apply roles (`bootstrap/identity.tf`) | Impersonated by operators, or by CI jobs in the `prod-apply` / `destroy` GitHub environments only |
| sa-gha-plan | seed | Predefined viewer roles at the org, state lock | Any workflow in this repository, via WIF |
| sa-gke-nodes | app-prod | logWriter, metricWriter, AR reader | Node metadata; hidden from pods by GKE_METADATA |
| app/app KSA | app-prod | secretAccessor on the DB secret, cloudsql.client | Workload Identity (direct principal binding, no GSA, no key) |
| external-secrets KSA | app-prod | secretAccessor on the DB secret | Workload Identity |
| sa-probe | net-prod-r | nothing | VM metadata |

## Org-admin hardening and break-glass

- The org's original admin (the account that created it) is the **break-glass**
  principal. It is outside the IdP on purpose: it exists for when federation is
  what broke.
- Every API call it makes raises an alert (`break-glass-used` in
  `terraform/monitoring.tf`), as does any change to org IAM, org policy, the
  VPC-SC perimeter, or firewall policy.
- Day to day it applies nothing. Terraform runs as sa-terraform, and the human's
  only operational grant is `serviceAccountTokenCreator` on it.
- **Documented, not codified:** removing the break-glass account's own standing
  org roles. Terraform does not strip the grants of the identity that could
  repair Terraform; that is a deliberate manual step, recorded here.
- MFA and hardware keys for the break-glass account are enforced in the Google
  account itself (CIS 1.2 / 1.3), outside Terraform.

## Just-in-time elevation

Privileged Access Manager entitlements (`google_privileged_access_manager_entitlement`):

1. A platform engineer requests `prod-write` with a justification.
2. A security approver approves with their own justification.
3. The roles exist on the prod folder for at most one hour, then PAM removes them.
4. The request, approval, and every action under the grant are in the org audit log.

This is the same control as Azure PIM eligible assignments and the AWS
short-session prod permission set, expressed natively.
