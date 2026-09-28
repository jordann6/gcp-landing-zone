# Human identity.
#
# Federated SSO through Workforce Identity Federation, personas bound at folder
# scope, no standing prod write, and elevation through Privileged Access Manager.
#
# Why workforce federation rather than Cloud Identity groups: this organization
# has no Cloud Identity directory behind it, and that is a common shape for a
# company whose source of truth is already Entra ID or Okta. Workforce
# federation lets the external IdP stay authoritative. Users are never synced
# into Google; a signed-in session carries the IdP's groups claim, and IAM binds
# on that claim directly. Removing someone from a group in the IdP removes their
# GCP access on the next token, with no deprovisioning job to forget.
#
# Bindings are on principalSet URIs for the groups, never on individuals, and
# at folder scope, so they inherit to every project beneath, including projects
# vended tomorrow. That is also why folder design is a security decision here.

resource "google_iam_workforce_pool" "lz" {
  workforce_pool_id = var.workforce_pool_id
  parent            = "organizations/${var.org_id}"
  location          = "global"
  display_name      = "Landing zone workforce"
  description       = "Human SSO for the landing zone. Personas bind on the IdP groups claim."

  # Short sessions. The console default is 1 hour, set explicitly so it is a
  # reviewed number and not an inherited one.
  session_duration = "3600s"
}

resource "google_iam_workforce_pool_provider" "idp" {
  count = var.workforce_idp.issuer_uri == "" ? 0 : 1

  workforce_pool_id = google_iam_workforce_pool.lz.workforce_pool_id
  location          = google_iam_workforce_pool.lz.location
  provider_id       = "idp-oidc"
  display_name      = "Corporate IdP (OIDC)"

  attribute_mapping = {
    "google.subject"      = "assertion.sub"
    "google.groups"       = "assertion.groups"
    "google.display_name" = "assertion.name"
  }

  oidc {
    issuer_uri = var.workforce_idp.issuer_uri
    client_id  = var.workforce_idp.client_id

    web_sso_config {
      response_type             = "ID_TOKEN"
      assertion_claims_behavior = "ONLY_ID_TOKEN_CLAIMS"
    }
  }
}

locals {
  persona_principal = {
    for k, g in var.persona_groups :
    k => "principalSet://iam.googleapis.com/${google_iam_workforce_pool.lz.name}/group/${g}"
  }

  # Standing grants: persona -> scope -> roles. Read access is broad, write
  # access is narrow and never standing in prod. docs/access-model.md renders
  # this same matrix with the CIS control each row satisfies.
  standing_grants = concat(
    # Org-wide read, for the personas whose job is to see everything.
    [for r in ["roles/iam.securityReviewer", "roles/securitycenter.adminViewer", "roles/orgpolicy.policyViewer", "roles/accesscontextmanager.policyReader", "roles/cloudasset.viewer"] :
    { persona = "security", scope = "org", target = "", role = r }],
    [for r in ["roles/resourcemanager.organizationViewer", "roles/resourcemanager.folderViewer", "roles/iam.securityReviewer"] :
    { persona = "admin", scope = "org", target = "", role = r }],
    [for r in ["roles/resourcemanager.organizationViewer", "roles/recommender.viewer"] :
    { persona = "finops", scope = "org", target = "", role = r }],

    # Platform engineering owns core networking and can read every workload.
    [for r in ["roles/compute.networkAdmin", "roles/dns.admin", "roles/logging.viewer"] :
    { persona = "platform_eng", scope = "folder", target = "core", role = r }],
    [for r in ["roles/viewer", "roles/container.viewer"] :
    { persona = "platform_eng", scope = "folder", target = "workloads", role = r }],
    [for env in ["dev", "test"] : { persona = "platform_eng", scope = "folder", target = env, role = "roles/container.admin" }],
    [for env in ["dev", "test"] : { persona = "platform_eng", scope = "folder", target = env, role = "roles/cloudsql.admin" }],

    # Junior engineers deploy to dev, read test, and have nothing in prod.
    [for r in ["roles/container.developer", "roles/cloudsql.client", "roles/logging.viewer", "roles/compute.viewer"] :
    { persona = "junior_eng", scope = "folder", target = "dev", role = r }],
    [{ persona = "junior_eng", scope = "folder", target = "test", role = "roles/viewer" }],

    # Managers see what exists and how it is performing, not its data.
    [for r in ["roles/browser", "roles/monitoring.viewer"] :
    { persona = "manager", scope = "folder", target = "workloads", role = r }],

    # Everyone gets the sandbox, which is what it is for.
    [for p in ["platform_eng", "junior_eng"] : { persona = p, scope = "folder", target = "sandbox", role = "roles/editor" }],
  )

  folder_ids = merge(
    { core = google_folder.core.name, workloads = google_folder.workloads.name, sandbox = google_folder.sandbox.name },
    { for k, f in google_folder.env : k => f.name },
  )
}

resource "google_organization_iam_member" "persona" {
  for_each = {
    for g in local.standing_grants : "${g.persona}/${g.role}" => g if g.scope == "org"
  }

  org_id = var.org_id
  role   = each.value.role
  member = local.persona_principal[each.value.persona]
}

resource "google_folder_iam_member" "persona" {
  for_each = {
    for g in local.standing_grants : "${g.persona}/${g.target}/${g.role}" => g if g.scope == "folder"
  }

  folder = local.folder_ids[each.value.target]
  role   = each.value.role
  member = local.persona_principal[each.value.persona]
}

# FinOps reads cost at the billing account, which sits outside the hierarchy.
# Setting IAM on a billing account takes billing.admin there, which would let
# the apply identity grant anyone spend on every project the account pays for.
# sa-terraform deliberately holds only billing.user and costsManager, so these
# grants are off unless the account is dedicated to the landing zone and
# sa-terraform has been given billing.admin on it.
resource "google_billing_account_iam_member" "finops" {
  for_each = var.manage_billing_iam ? toset(["roles/billing.viewer", "roles/billing.costsManager"]) : toset([])

  billing_account_id = var.billing_account
  role               = each.value
  member             = local.persona_principal["finops"]
}

resource "google_billing_account_iam_member" "manager" {
  count = var.manage_billing_iam ? 1 : 0

  billing_account_id = var.billing_account
  role               = "roles/billing.viewer"
  member             = local.persona_principal["manager"]
}

# Security reads the audit trail where it lands.
resource "google_project_iam_member" "security_logging" {
  for_each = toset(["roles/logging.privateLogViewer", "roles/bigquery.dataViewer", "roles/bigquery.jobUser"])

  project = module.logging_project.project_id
  role    = each.value
  member  = local.persona_principal["security"]
}

# ---- just-in-time elevation -----------------------------------------------------
#
# Nobody holds write in prod. A platform engineer requests the prod-write
# entitlement with a justification, a security approver grants it, and the
# roles exist on the prod folder for at most an hour before PAM removes them.
# The grant, the approval, and every action taken under it are in the audit log.
# This is the GCP equivalent of Azure PIM eligible assignments and the AWS
# short-session prod permission set.

locals {
  pam_approvers = length(var.pam_approvers) > 0 ? var.pam_approvers : [local.persona_principal["security"]]

  pam_entitlements = {
    prod-write = {
      parent        = google_folder.env["prod"].name
      resource      = "//cloudresourcemanager.googleapis.com/${google_folder.env["prod"].name}"
      resource_type = "cloudresourcemanager.googleapis.com/Folder"
      requesters    = [local.persona_principal["platform_eng"]]
      roles         = ["roles/container.admin", "roles/cloudsql.admin", "roles/compute.instanceAdmin.v1"]
      duration      = "3600s"
    }
    org-admin = {
      parent        = "organizations/${var.org_id}"
      resource      = "//cloudresourcemanager.googleapis.com/organizations/${var.org_id}"
      resource_type = "cloudresourcemanager.googleapis.com/Organization"
      requesters    = [local.persona_principal["admin"]]
      roles         = ["roles/resourcemanager.folderAdmin", "roles/orgpolicy.policyAdmin"]
      duration      = "3600s"
    }
  }
}

# PAM grants and revokes roles as its org service agent, not as the requester
# or as sa-terraform. The agent only exists once checkOnboardingStatus has been
# called against the org (make deploy does that as sa-terraform), and an
# entitlement fails to create until the agent can edit IAM where it grants.
# organizationServiceAgent covers the org's own policy only; folder-scoped
# entitlements (prod-write) also need folderServiceAgent, granted here at the
# org so it reaches every folder, including ones vended later.
resource "google_organization_iam_member" "pam_agent" {
  for_each = var.enable_pam ? toset([
    "roles/privilegedaccessmanager.organizationServiceAgent",
    "roles/privilegedaccessmanager.folderServiceAgent",
  ]) : toset([])

  org_id = var.org_id
  role   = each.value
  member = "serviceAccount:service-org-${var.org_id}@gcp-sa-pam.iam.gserviceaccount.com"
}

moved {
  from = google_organization_iam_member.pam_agent[0]
  to   = google_organization_iam_member.pam_agent["roles/privilegedaccessmanager.organizationServiceAgent"]
}

resource "google_privileged_access_manager_entitlement" "this" {
  for_each = var.enable_pam ? local.pam_entitlements : {}

  depends_on = [google_organization_iam_member.pam_agent]

  entitlement_id       = each.key
  location             = "global"
  parent               = each.value.parent
  max_request_duration = each.value.duration

  eligible_users {
    principals = each.value.requesters
  }

  privileged_access {
    gcp_iam_access {
      resource      = each.value.resource
      resource_type = each.value.resource_type

      dynamic "role_bindings" {
        for_each = each.value.roles
        content {
          role = role_bindings.value
        }
      }
    }
  }

  requester_justification_config {
    unstructured {}
  }

  approval_workflow {
    manual_approvals {
      require_approver_justification = true

      steps {
        approvals_needed = 1
        approvers {
          principals = local.pam_approvers
        }
      }
    }
  }
}
