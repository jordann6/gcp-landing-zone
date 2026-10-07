variable "seed_project_id" {
  description = "Seed project (bootstrap output). Quota project for every call."
  type        = string
}

variable "terraform_service_account" {
  description = "sa-terraform email (bootstrap output). This root applies as it."
  type        = string
}

variable "state_bucket" {
  description = "State bucket (bootstrap output), read for the governance root's outputs."
  type        = string
}

variable "region" {
  description = "Region for subnets, NAT, and the hub."
  type        = string
  default     = "us-central1"
}

variable "operators" {
  description = <<-EOT
    Principals who run the live tests: IAP tunnel, OS Login, and read on the
    probe VM's project (read is what lets the VPC-SC test reach the perimeter
    check rather than stopping at IAM). user:you@example.com form. These are
    demo-operator grants, scoped to the one project the probe runs in.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_nat" {
  description = "Cloud NAT on each VPC. Needed for the FQDN allowlist to reach anything outside Google."
  type        = bool
  default     = true
}

variable "enable_psc" {
  description = "Private Service Connect endpoints for Google APIs, plus the private DNS zones that point at them."
  type        = bool
  default     = true
}

variable "egress_fqdn_allowlist" {
  description = <<-EOT
    Destinations workloads may reach over 443, through Cloud NGFW Standard FQDN
    objects. Everything else egressing to the internet is denied. Google APIs do
    not need to be listed: they resolve to the PSC endpoint, which is internal.
  EOT
  type        = list(string)
  default = [
    "github.com",
    "api.github.com",
    "objects.githubusercontent.com",
  ]
}

variable "enable_hybrid_placeholder" {
  description = "Create the HA VPN gateway and Cloud Router in the hub with no tunnels. The gateway is free without tunnels; it reserves the on-prem attachment point."
  type        = bool
  default     = true
}

variable "enable_vpc_sc" {
  description = "Create the VPC Service Controls perimeter around the restricted tier."
  type        = bool
  default     = true
}

variable "vpc_sc_dry_run" {
  description = "Put the perimeter in dry-run (violations logged, not blocked). Useful for a first apply; the demo runs enforced."
  type        = bool
  default     = false
}

variable "access_policy_name" {
  description = "Existing org access policy number. Null creates one. An org can have exactly one org-level access policy."
  type        = string
  default     = null
}

variable "restricted_services" {
  description = "APIs the perimeter restricts. Anything listed is unreachable from outside the perimeter except through an ingress rule."
  type        = list(string)
  default = [
    "bigquery.googleapis.com",
    "cloudkms.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ]
}

variable "enable_probe_vm" {
  description = "An e2-micro in the prod restricted VPC, reachable only over IAP, used by make test to prove the egress allowlist and the no-external-IP path."
  type        = bool
  default     = true
}


variable "image_family" {
  description = "Golden image family in the image project (packer/). The probe VM boots from it."
  type        = string
  default     = "hardened-ubuntu-2204"
}

variable "enable_incident_access" {
  description = <<-EOT
    Admit the incident handler's service account (sa-incident in the logging
    project) across the perimeter to Cloud SQL, for the failover runbook. Turn on
    only after the incident root has created the account: the perimeter rejects
    an identity that does not exist.
  EOT
  type        = bool
  default     = false
}
