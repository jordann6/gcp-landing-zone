# Terraform's own identity.
#
# Every root above this one applies as sa-terraform through impersonation, not
# as a human. A person holds exactly one grant that matters day to day:
# serviceAccountTokenCreator on this account, which is short-lived, logged per
# token, and revoked by removing one binding. The org-level roles below belong
# to the service account, so no human carries them standing.
#
# This layer is the one exception: it runs as the operator's own credentials,
# because it is what creates the identity everything else runs as.

resource "google_service_account" "terraform" {
  project      = google_project.seed.project_id
  account_id   = "sa-terraform"
  display_name = "Landing zone Terraform"
  description  = "Applies the landing zone roots. Impersonated by operators and by the gated CI apply; never has a key."
}

locals {
  # The operational org-level roles an apply needs. organizationAdmin
  # administers IAM at the org and grants almost none of the operational
  # permissions, which is why the list is this long: each entry was an apply
  # failing on exactly one resource in the v1 build, or is its Phase 4
  # equivalent (VPC-SC, PAM, workforce federation, hierarchical firewall).
  terraform_org_roles = [
    "roles/accesscontextmanager.policyAdmin",
    "roles/billing.projectManager",
    "roles/compute.orgFirewallPolicyAdmin",
    "roles/compute.orgSecurityResourceAdmin",
    "roles/compute.xpnAdmin",
    "roles/essentialcontacts.admin",
    "roles/iam.workforcePoolAdmin",
    "roles/logging.configWriter",
    "roles/orgpolicy.policyAdmin",
    "roles/privilegedaccessmanager.admin",
    "roles/resourcemanager.folderAdmin",
    "roles/resourcemanager.organizationAdmin",
    "roles/resourcemanager.projectCreator",
    "roles/resourcemanager.projectDeleter",
    "roles/securitycenter.admin",
  ]
}

resource "google_organization_iam_member" "terraform" {
  # checkov:skip=CKV_GCP_45: sa-terraform is the org's apply identity and needs
  # securitycenter.admin for the SCC notification config (v1 proved the
  # narrower notificationConfigEditor is not sufficient). No human holds it.
  for_each = toset(local.terraform_org_roles)

  org_id = var.org_id
  role   = each.value
  member = google_service_account.terraform.member
}

# Linking billing to a vended project needs billing.user on the account; the
# budget needs costsManager. Neither is an org role.
resource "google_billing_account_iam_member" "terraform" {
  for_each = toset(["roles/billing.user", "roles/billing.costsManager"])

  billing_account_id = var.billing_account
  role               = each.value
  member             = google_service_account.terraform.member
}

# The quota project for every call. Without serviceUsageConsumer the SA cannot
# bill API usage to the seed and every request fails before it starts.
resource "google_project_iam_member" "terraform_seed" {
  for_each = toset(["roles/serviceusage.serviceUsageConsumer"])

  project = google_project.seed.project_id
  role    = each.value
  member  = google_service_account.terraform.member
}

resource "google_storage_bucket_iam_member" "terraform_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.terraform.member
}

# The single standing human grant.
resource "google_service_account_iam_member" "operators" {
  for_each = toset(var.operators)

  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}
