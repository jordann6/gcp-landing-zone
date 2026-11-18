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

variable "rate_limit_per_minute" {
  description = "Requests per client IP per minute before Cloud Armor answers 429."
  type        = number
  default     = 60
}

variable "waf_sensitivity" {
  description = "Preconfigured WAF sensitivity (1 is the fewest false positives, 4 the most coverage)."
  type        = number
  default     = 1
}
