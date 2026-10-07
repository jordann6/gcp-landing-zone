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
  description = "Environment whose app project and restricted host project are monitored."
  type        = string
  default     = "prod"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "ops_alert_email" {
  description = "Email for operational alerts (GKE, Cloud SQL, NAT, firewall, management VM). Separate from the security channel in terraform/monitoring.tf. Empty skips the channel and the policies have no recipient."
  type        = string
  default     = ""
}

variable "mgmt_vm_name" {
  description = "Management VM the uptime and patch alerts watch (compute output). Set enable_mgmt_vm_alerts=false when compute is not deployed."
  type        = string
  default     = "prod-mgmt"
}

variable "enable_mgmt_vm_alerts" {
  description = "Alert on management VM uptime and OS Config failures. The VM is hourly, so turn this off when compute is down or the uptime alert fires on purpose."
  type        = bool
  default     = true
}

variable "enable_scc_alerts" {
  description = "Alert when a finding reaches the SCC Pub/Sub topic. Needs enable_scc_notifications in terraform/, and SCC org activation, which is console-only (no CLI or API path exists), so this defaults off."
  type        = bool
  default     = false
}

variable "egress_deny_threshold" {
  description = "Denied egress connections per 5 minutes that count as a spike."
  type        = number
  default     = 20
}

variable "enable_incident_channel" {
  description = "Also publish the GKE node-not-ready and Cloud SQL down alerts to the incident handler's topic. Needs the incident root deployed first (its ops-alerts topic and Monitoring's publish grant)."
  type        = bool
  default     = false
}
