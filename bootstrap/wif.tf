# GitHub Actions federation.
#
# CI authenticates the same way an operator does: no key, an exchanged token,
# and a service account it may impersonate. Two identities, split by what the
# job is allowed to do:
#
#   sa-gha-plan   read-only at the org, plus state-bucket write for the lock.
#                 Reachable from any workflow run in this repository.
#   sa-gha-plan   read-only at the org. State reads everywhere, state writes
#                 only for the .tflock objects a plan takes and releases.
#                 Reachable from any workflow run in this repository.
#   sa-gha-apply  the CI apply identity. Reachable only from a job bound to the
#                 prod-apply or destroy GitHub environment, both of which carry a
#                 required reviewer. A PR that edits a workflow to skip the
#                 environment gets a token without the environment claim and
#                 cannot impersonate it. It can change one thing: the ci-proof
#                 root (networking in the seed project, and that root's state).
#
# sa-terraform is not reachable from CI at all. It holds organizationAdmin and
# can rewrite this file's trust, so the roots that need it (governance, network,
# workload, compute) stay operator-applied through impersonation.

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
  # token to this provider. The condition pins the pool to one repository by its
  # numeric IDs as well as its name: a name can be freed by a rename or a
  # deleted account and claimed by someone else, the IDs cannot.
  attribute_condition = join(" && ", [
    "assertion.repository == \"${var.github_repository}\"",
    "assertion.repository_id == \"${var.github_repository_id}\"",
    "assertion.repository_owner_id == \"${var.github_repository_owner_id}\"",
  ])

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

resource "google_storage_bucket_iam_member" "gha_plan_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.gha_plan.member
}

# The GCS backend takes its lock by writing a .tflock object, so a plan needs
# write on the bucket. The condition limits that write to lock objects: a plan
# identity that could overwrite state could apply by editing it.
resource "google_storage_bucket_iam_member" "gha_plan_lock" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.gha_plan.member

  condition {
    title       = "tflock-only"
    description = "Create and delete Terraform lock objects, nothing else."
    expression  = "resource.name.endsWith(\".tflock\")"
  }
}

resource "google_service_account_iam_member" "gha_plan" {
  service_account_id = google_service_account.gha_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.pool_principal_prefix}/attribute.repository/${var.github_repository}"
}

resource "google_service_account" "gha_apply" {
  project      = google_project.seed.project_id
  account_id   = "sa-gha-apply"
  display_name = "GitHub Actions apply (ci-proof only)"
  description  = "Gated CI apply and destroy of the ci-proof root. Reachable only from reviewer-gated GitHub environments."
}

# Networking in the seed project, which holds no network of its own: enough to
# create and delete the ci-proof VPC, subnet, and firewall rule. securityAdmin
# is the firewall half; networkAdmin excludes firewall rules.
resource "google_project_iam_member" "gha_apply_seed" {
  for_each = toset(["roles/compute.networkAdmin", "roles/compute.securityAdmin"])

  project = google_project.seed.project_id
  role    = each.value
  member  = google_service_account.gha_apply.member
}

# State write for the ci-proof prefix only. objects.list is authorized against
# the bucket itself, so the bucket name is the second clause; every object
# read, write, and delete outside the prefix is denied.
resource "google_storage_bucket_iam_member" "gha_apply_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.gha_apply.member

  condition {
    title       = "ci-proof-state-only"
    description = "Read and write the ci-proof root's state and lock, nothing else."
    expression = join(" || ", [
      "resource.name == \"projects/_/buckets/${google_storage_bucket.state.name}\"",
      "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.state.name}/objects/${var.ci_state_prefix}/\")",
    ])
  }
}

resource "google_service_account_iam_member" "gha_apply" {
  for_each = toset(var.github_apply_environments)

  service_account_id = google_service_account.gha_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.pool_principal_prefix}/attribute.environment/${each.value}"
}
