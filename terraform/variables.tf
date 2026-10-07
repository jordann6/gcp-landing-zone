variable "org_id" {
  description = "Numeric GCP organization ID the landing zone governs."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{10,14}$", var.org_id))
    error_message = "org_id must be the numeric organization ID."
  }
}

variable "billing_account" {
  description = "Billing account ID in XXXXXX-XXXXXX-XXXXXX form."
  type        = string
}

variable "seed_project_id" {
  description = "Seed project from the bootstrap layer. Holds state and is the quota project for every API call."
  type        = string
}

variable "terraform_service_account" {
  description = "sa-terraform email from the bootstrap layer. Every root applies as this account through impersonation."
  type        = string
}

variable "customer_id" {
  description = <<-EOT
    Cloud Identity customer ID, used only by domain restricted sharing.

    Find it with: gcloud organizations describe <org_id> --format='value(owner.directoryCustomerId)'
  EOT
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Prefix for every project ID the factory vends."
  type        = string
  default     = "jn-lz"
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "bigquery_location" {
  description = <<-EOT
    Location for the audit log dataset.

    Regional rather than the US multi-region on purpose: BigQuery CMEK requires
    the key to be co-located with the dataset, and a multi-region dataset cannot
    use a regional key.
  EOT
  type        = string
  default     = "us-central1"
}

# ---- hierarchy and project vending -------------------------------------------

variable "environments" {
  description = <<-EOT
    Workload environments. Each gets a folder under workloads/ unconditionally,
    and projects only where a flag is true.

      base        vend a base Shared VPC host project (net-<env>)
      restricted  vend a restricted Shared VPC host project (net-<env>-r), the one
                  that sits inside the VPC Service Controls perimeter
      app         vend the service project (app-<env>). It attaches to the
                  restricted host when there is one, otherwise to the base host,
                  because a service project can attach to exactly one host

    The flags exist because a self-serve billing account caps how many projects
    can be linked at once, and projects in DELETE_REQUESTED keep counting for 30
    days. Folders, policy, and inheritance are proven with or without projects
    inside them; the flags decide how much of the network is instantiated.
  EOT
  type = map(object({
    base       = bool
    restricted = bool
    app        = bool
  }))
  default = {
    dev  = { base = true, restricted = false, app = true }
    test = { base = true, restricted = false, app = true }
    prod = { base = true, restricted = true, app = true }
  }

  validation {
    condition     = alltrue([for k, _ in var.environments : contains(["dev", "test", "prod"], k)])
    error_message = "environments keys must be dev, test, or prod (the address plan maps them to 10.1, 10.2, 10.3)."
  }

  validation {
    condition     = alltrue([for _, e in var.environments : !e.app || e.base || e.restricted])
    error_message = "An environment with app = true needs a base or restricted host to attach to."
  }
}

variable "vend_hub" {
  description = "Vend the core network hub project (10.0.0.0/16): DNS inbound forwarding and the reserved hybrid-connectivity placeholder."
  type        = bool
  default     = true
}

variable "vend_sandbox" {
  description = "Vend the sandbox project (10.4.0.0/16, standalone VPC, its own budget)."
  type        = bool
  default     = true
}

# ---- guardrails --------------------------------------------------------------

variable "allowed_resource_locations" {
  description = <<-EOT
    Value groups allowed by gcp.resourceLocations at the org.

    Value groups (in:us-locations) are preferred over bare region names because
    they track new regions as Google adds them, where a hand-listed set silently
    goes stale.
  EOT
  type        = list(string)
  default     = ["in:us-locations"]
}

variable "sandbox_extra_locations" {
  description = "Extra location groups granted to the sandbox folder only, to demonstrate a folder-level widening of an inherited policy."
  type        = list(string)
  default     = ["in:eu-locations"]
}

variable "prod_cmek_services" {
  description = <<-EOT
    Services that must use CMEK in the prod folder (gcp.restrictNonCmekServices).

    Prod-only on purpose: identical resources, different governance, from
    placement alone. A dev Cloud SQL instance may use Google-managed keys; the
    same instance in prod is rejected at the API without one.
  EOT
  type        = list(string)
  default = [
    "artifactregistry.googleapis.com",
    "container.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ]
}

variable "enable_custom_constraints" {
  description = "Create and enforce the custom org policy constraints (GKE private nodes, cost_center label on GKE and Cloud SQL)."
  type        = bool
  default     = true
}

variable "enable_domain_restricted_sharing" {
  description = <<-EOT
    Enforce iam.allowedPolicyMemberDomains at the organization.

    Off by default and deliberately so: this constraint blocks binding allUsers
    or allAuthenticatedUsers, which breaks any public Cloud Run service. Enable
    it only when no workload in the org needs unauthenticated public access.
  EOT
  type        = bool
  default     = false
}

# ---- identity ----------------------------------------------------------------

variable "workforce_pool_id" {
  description = "Workforce Identity Federation pool ID (org-level). Human SSO lands here."
  type        = string
  default     = "lz-workforce"
}

variable "workforce_idp" {
  description = <<-EOT
    External OIDC IdP for the workforce pool. Empty issuer_uri means the pool
    and every persona binding exist, but no provider is attached, so no one can
    sign in through it yet. Entra ID example:
      issuer_uri = "https://login.microsoftonline.com/<tenant-id>/v2.0"
      client_id  = "<app registration client id>"
    The IdP must emit a groups claim; persona bindings match on it.
  EOT
  type = object({
    issuer_uri = string
    client_id  = string
  })
  default = {
    issuer_uri = ""
    client_id  = ""
  }
}

variable "persona_groups" {
  description = "IdP group identifier (the value in the groups claim) for each persona."
  type        = map(string)
  default = {
    admin        = "gcp-lz-admin"
    platform_eng = "gcp-lz-platform-eng"
    junior_eng   = "gcp-lz-junior-eng"
    manager      = "gcp-lz-manager"
    finops       = "gcp-lz-finops"
    security     = "gcp-lz-security"
  }

  validation {
    condition     = length(setsubtract(["admin", "platform_eng", "junior_eng", "manager", "finops", "security"], keys(var.persona_groups))) == 0
    error_message = "persona_groups must define admin, platform_eng, junior_eng, manager, finops, and security."
  }
}

variable "break_glass_members" {
  description = <<-EOT
    Principals that hold organization-level admin outside the IdP, for when
    federation is the thing that broke. Every action they take raises an alert.
    user:you@example.com form. Empty means the alert watches nothing.
  EOT
  type        = list(string)
  default     = []
}

variable "manage_billing_iam" {
  description = "Grant the finops and manager personas their billing-account roles. Needs sa-terraform to hold billing.admin on the account, so off unless the account is dedicated to the landing zone."
  type        = bool
  default     = false
}

variable "enable_pam" {
  description = "Create Privileged Access Manager entitlements for approver-gated, time-boxed prod write."
  type        = bool
  default     = true
}

variable "pam_approvers" {
  description = "Principals who approve prod elevation. Empty means the security persona approves."
  type        = list(string)
  default     = []
}

# ---- logging, detect, cost ---------------------------------------------------

variable "enable_scc_notifications" {
  description = "Create the Security Command Center notification config (sa-terraform holds securitycenter.admin at the org)."
  type        = bool
  default     = true
}

variable "enable_network_log_sink" {
  description = "Also route VPC flow logs and firewall logs to the central log bucket. Off by default: it is the ingestion-cost line item. Run scripts/estimate-netlog-cost.sh first."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email for the org-admin and CIS log-metric alerts, and for essential contacts. Empty skips the channel and the contacts."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Partition expiry on the audit dataset and retention on the log bucket. Bounds both retention and storage cost."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days >= 1 && var.log_retention_days <= 3650
    error_message = "log_retention_days must be between 1 and 3650."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly budget for the whole billing account, in whole dollars."
  type        = number
  default     = 25
}

variable "sandbox_budget_usd" {
  description = "Monthly budget scoped to the sandbox project alone."
  type        = number
  default     = 5
}

variable "budget_thresholds" {
  description = "Fractions of the budget that trigger an actual-spend alert."
  type        = list(number)
  default     = [0.5, 0.9, 1.0]
}


# ---- compute baseline ----------------------------------------------------------

variable "vend_image_project" {
  description = <<-EOT
    Vend the golden image project (core folder). It holds the hardened image
    family, the Artifact Registry Ubuntu mirror, and the private bake VPC, and
    it is what compute.trustedImageProjects admits. Off means no image
    allowlist is enforced at all, not an allowlist with nothing in it.
  EOT
  type        = bool
  default     = true
}

variable "bake_source_image_project" {
  description = "Public image project Packer hardens from. Admitted only inside the image project."
  type        = string
  default     = "ubuntu-os-cloud"
}
