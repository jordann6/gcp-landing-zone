variable "org_id" {
  description = "Numeric GCP organization ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{10,14}$", var.org_id))
    error_message = "org_id must be the numeric organization ID, not the domain name."
  }
}

variable "billing_account" {
  description = "Billing account ID in XXXXXX-XXXXXX-XXXXXX form."
  type        = string

  validation {
    condition     = can(regex("^[A-F0-9]{6}-[A-F0-9]{6}-[A-F0-9]{6}$", var.billing_account))
    error_message = "billing_account must look like 0X0X0X-0X0X0X-0X0X0X."
  }
}

variable "name_prefix" {
  description = "Prefix for generated project IDs."
  type        = string
  default     = "jn-lz"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,10}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits, and hyphens, 3 to 11 characters."
  }
}

variable "state_bucket_location" {
  description = "Location for the Terraform state bucket."
  type        = string
  default     = "US"
}

variable "force_destroy_state" {
  description = "Allow destroy to delete the state bucket with objects in it. Set true only for final teardown."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to the seed project."
  type        = map(string)
  default = {
    managed-by  = "terraform"
    project     = "gcp-landing-zone"
    owner       = "jordan"
    cost_center = "cc-0001"
  }
}

variable "operators" {
  description = "Principals allowed to impersonate sa-terraform (user:you@example.com). The only standing human grant in the landing zone."
  type        = list(string)
  default     = []
}

variable "github_repository" {
  description = "owner/repo whose Actions runs may federate into the seed project."
  type        = string
  default     = "jordann6/gcp-landing-zone"
}

variable "github_apply_environments" {
  description = "GitHub environments whose jobs may impersonate sa-terraform. Each must carry a required reviewer."
  type        = list(string)
  default     = ["prod-apply", "destroy"]
}
