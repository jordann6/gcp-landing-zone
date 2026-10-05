# GitHub Actions federation.
#
# CI authenticates the same way an operator does: no key, an exchanged token,
# and a service account it may impersonate. Two identities, split by what the
# job is allowed to do:
#
#   sa-gha-plan   read-only at the org, plus state-bucket write for the lock.
#                 Reachable from any workflow run in this repository.
#   sa-terraform  the apply identity. Reachable only from a job bound to the
#                 prod-apply or destroy GitHub environment, both of which carry a
#                 required reviewer. A PR that edits a workflow to skip the
#                 environment gets a token without the environment claim and
#                 cannot impersonate it.

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.seed.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "OIDC tokens from GitHub Actions for ${var.github_repository}."

  depends_on = [google_project_service.seed]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  # checkov:skip=CKV_GCP_125: the check wants an exact assertion.sub match, which
  # pins federation to one ref. The pool is pinned to this repository by
  # attribute_condition, and which identity a job may impersonate is decided
  # per GitHub environment by the principalSet bindings below, which is
  # Google's recommended shape for GitHub Actions.
  project                            = google_project.seed.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"         = "assertion.sub"
    "attribute.repository"   = "assertion.repository"
    "attribute.environment"  = "assertion.environment"
    "attribute.ref"          = "assertion.ref"
    "attribute.workflow_ref" = "assertion.job_workflow_ref"
  }

  # Without a condition, any GitHub repository in the world could present a
  # token to this provider. The condition pins the pool to one repository.
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "gha_plan" {
  project      = google_project.seed.project_id
  account_id   = "sa-gha-plan"
  display_name = "GitHub Actions plan (read-only)"
}

locals {
  # Predefined read-only roles rather than basic roles/viewer: a plan refreshes
  # every resource type the roots manage, and nothing else.
  plan_org_roles = [
    "roles/accesscontextmanager.policyReader",
    "roles/artifactregistry.reader",
    "roles/bigquery.metadataViewer",
    "roles/billing.viewer",
    "roles/binaryauthorization.policyViewer",
    "roles/browser",
    "roles/cloudkms.publicKeyViewer",
    "roles/cloudkms.viewer",
    "roles/cloudsql.viewer",
    "roles/compute.orgFirewallPolicyUser",
    "roles/compute.viewer",
    "roles/container.clusterViewer",
    "roles/dns.reader",
    "roles/iam.securityReviewer",
    "roles/iam.workforcePoolViewer",
    "roles/logging.viewer",
    "roles/monitoring.viewer",
    "roles/orgpolicy.policyViewer",
    "roles/privilegedaccessmanager.viewer",
    "roles/pubsub.viewer",
    "roles/secretmanager.viewer",
    "roles/serviceusage.serviceUsageViewer",
  ]

  pool_principal_prefix = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}"
}

resource "google_organization_iam_member" "gha_plan" {
  for_each = toset(local.plan_org_roles)

  org_id = var.org_id
  role   = each.value
  member = google_service_account.gha_plan.member
}

resource "google_project_iam_member" "gha_plan_seed" {
  project = google_project.seed.project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = google_service_account.gha_plan.member
}

# objectAdmin rather than objectViewer: the GCS backend takes its lock by
# writing a .tflock object, so a read-only plan still needs write on the bucket.
resource "google_storage_bucket_iam_member" "gha_plan_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.gha_plan.member
}

resource "google_service_account_iam_member" "gha_plan" {
  service_account_id = google_service_account.gha_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.pool_principal_prefix}/attribute.repository/${var.github_repository}"
}

resource "google_service_account_iam_member" "gha_apply" {
  for_each = toset(var.github_apply_environments)

  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.pool_principal_prefix}/attribute.environment/${each.value}"
}
