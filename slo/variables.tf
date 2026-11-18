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
  type    = string
  default = "prod"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "image" {
  description = "orders-api image by digest (written to image.auto.tfvars by scripts/build-run-image.sh slo orders-api). Empty means the service, SLO and alerts are not created yet."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Where burn-rate pages go. Lives in the gitignored terraform.tfvars."
  type        = string
}

variable "slo_goal" {
  description = "Fraction of requests that must succeed over the rolling window."
  type        = number
  default     = 0.99
}

variable "slo_window_days" {
  type    = number
  default = 28
}
