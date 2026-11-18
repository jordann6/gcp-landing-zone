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
  description = "Environment whose app project, secret and database the rotator acts on."
  type        = string
  default     = "prod"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "image" {
  description = "Rotator image by digest (written to image.auto.tfvars by scripts/build-run-image.sh rotation secret-rotator). Empty means only the identities exist."
  type        = string
  default     = ""
}

variable "sql_user" {
  description = "Cloud SQL built-in user whose password the rotator owns."
  type        = string
  default     = "app"
}
