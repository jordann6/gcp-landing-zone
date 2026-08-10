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
  description = "Seed project from the bootstrap layer. Holds state, Pub/Sub topics, and the quota project for API calls."
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

variable "nonprod_extra_locations" {
  description = "Extra location groups granted to nonprod only, to demonstrate a folder-level override of an inherited policy."
  type        = list(string)
  default     = ["in:eu-locations"]
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

variable "enable_scc_notifications" {
  description = "Create the Security Command Center notification config. Requires roles/securitycenter.notificationConfigEditor at the organization."
  type        = bool
  default     = true
}

variable "subnet_cidr" {
  description = "Primary range for the workload subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pod_cidr" {
  description = "Secondary range for pods, sized for a future GKE cluster."
  type        = string
  default     = "10.20.0.0/16"
}

variable "service_cidr" {
  description = "Secondary range for Kubernetes services."
  type        = string
  default     = "10.30.0.0/20"
}

variable "log_retention_days" {
  description = "Partition expiry on the audit dataset. Bounds both retention and storage cost."
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

variable "budget_thresholds" {
  description = "Fractions of the budget that trigger an actual-spend alert."
  type        = list(number)
  default     = [0.5, 0.9, 1.0]
}

variable "labels" {
  description = "Labels applied to labelable resources."
  type        = map(string)
  default = {
    managed-by = "terraform"
    project    = "gcp-landing-zone"
  }
}
