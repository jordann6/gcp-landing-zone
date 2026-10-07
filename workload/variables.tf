variable "seed_project_id" {
  description = "Seed project (bootstrap output). Quota project for every call."
  type        = string
}

variable "terraform_service_account" {
  description = "sa-terraform email (bootstrap output). This root applies as it."
  type        = string
}

variable "state_bucket" {
  description = "State bucket (bootstrap output), read for the governance and network outputs."
  type        = string
}

variable "env" {
  description = "Environment the paved road lands in. Must have a restricted host in the governance root."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "Primary region: GKE, the Cloud SQL primary, and the keys that protect them."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = <<-EOT
    GKE zone. Zonal on purpose: the GKE free tier covers the management fee for
    one zonal cluster per billing account, so the control plane costs nothing for
    the demo. A regional control plane is the production setting and is not
    covered. The data tier is regional (HA) regardless.
  EOT
  type        = string
  default     = "us-central1-a"
}

variable "replica_region" {
  description = "Region for the Cloud SQL cross-region read replica (the DR target)."
  type        = string
  default     = "us-east1"
}

variable "node_count" {
  description = "Nodes in the single node pool."
  type        = number
  default     = 2
}

variable "node_machine_type" {
  description = "Node machine type."
  type        = string
  default     = "e2-standard-2"
}

variable "sql_tier" {
  description = "Cloud SQL machine tier. HA needs a dedicated-core tier; shared-core is not covered by the SLA."
  type        = string
  default     = "db-custom-1-3840"
}

variable "enable_cross_region_replica" {
  description = "Create the cross-region read replica. Roughly doubles the data tier's hourly cost again; it is the DR half of the failover demo."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Cloud SQL and GKE deletion protection. Off for the demo so make destroy can finish; on in production."
  type        = bool
  default     = false
}

variable "binauthz_enforcement" {
  description = "Binary Authorization enforcement mode for the cluster's policy."
  type        = string
  default     = "ENFORCED_BLOCK_AND_AUDIT_LOG"

  validation {
    condition     = contains(["ENFORCED_BLOCK_AND_AUDIT_LOG", "DRYRUN_AUDIT_LOG_ONLY"], var.binauthz_enforcement)
    error_message = "binauthz_enforcement must be ENFORCED_BLOCK_AND_AUDIT_LOG or DRYRUN_AUDIT_LOG_ONLY."
  }
}

variable "enable_backup_vault" {
  description = "Create the Backup and DR backup vault (enforced minimum retention) and a Cloud SQL backup plan."
  type        = bool
  default     = true
}

variable "associate_sql_with_vault" {
  description = <<-EOT
    Attach the Cloud SQL instance to the vault's backup plan. Off by default:
    once a vault holds a backup, the enforced retention blocks deleting the vault
    until the backup ages out, which strands a destroy for that window (the
    same trap the Azure zone hit with its Always-On soft delete). Turn on for a
    run where you can wait out backup_vault_min_retention.
  EOT
  type        = bool
  default     = false
}

variable "backup_vault_min_retention" {
  description = "Enforced minimum retention on the backup vault. Backups cannot be deleted, by anyone, before this elapses."
  type        = string
  default     = "86400s"
}

variable "cost_center" {
  description = "cost_center label. The custom org policy constraints reject GKE and Cloud SQL without it."
  type        = string
  default     = "cc-0001"
}

variable "owner" {
  description = "owner label."
  type        = string
  default     = "jordan"
}

variable "enable_ubuntu_node_pool" {
  description = "Add a one-node UBUNTU_CONTAINERD pool that proves ubuntu-os-gke-cloud is in the trusted image allowlist. Hourly; the compute-baseline session turns it on."
  type        = bool
  default     = false
}
