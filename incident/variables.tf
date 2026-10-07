variable "seed_project_id" {
  description = "Seed project (bootstrap output). Quota project for every call."
  type        = string
}

variable "terraform_service_account" {
  description = "sa-terraform email (bootstrap output). This root applies as it."
  type        = string
}

variable "state_bucket" {
  description = "State bucket (bootstrap output), read for the other roots' outputs."
  type        = string
}

variable "env" {
  description = "Environment whose app project the handler acts on."
  type        = string
  default     = "prod"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "image" {
  description = "Handler image by digest (written to image.auto.tfvars by scripts/build-incident.sh). Empty means the repository exists but no service is deployed yet."
  type        = string
  default     = ""
}

variable "dry_run" {
  description = "When true the handler decides and logs but changes nothing. Flip to false only to prove the live path, then back."
  type        = bool
  default     = true
}

variable "gke_node_pool" {
  type    = string
  default = "pool-default"
}

variable "gke_max_nodes" {
  description = "Ceiling for the node-pool resize runbook."
  type        = number
  default     = 3
}

variable "quarantine_label" {
  description = "key=value a VM must carry to be quarantine-eligible. The management VM is labeled role=mgmt in compute/."
  type        = string
  default     = "role=mgmt"
}

variable "sql_failover_live" {
  description = "Let the Cloud SQL runbook really fail the primary over. Separate from dry_run because a failover is an outage; it stays a dry run unless this is true."
  type        = bool
  default     = false
}

variable "secret_max_age_days" {
  description = "A secret whose newest enabled version is older than this is reported by the daily age check."
  type        = number
  default     = 90
}
