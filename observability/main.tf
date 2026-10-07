# Operational observability: the ops half that terraform/monitoring.tf (security
# alerts) does not cover. Mirrors aws-landing-zone/observability.
#
#   scope.tf    one Cloud Monitoring metrics scope in the logging project over
#               the prod host and app projects (AWS: OAM sink + links)
#   alerts.tf   GKE, Cloud SQL, Cloud NAT, firewall-deny and management VM
#               alert policies on a separate ops channel (AWS: central alarms)
#   security.tf SCC findings to the same channel (AWS: GuardDuty/Security Hub
#               HIGH to SNS)
#
# Reads the other roots' state, owns none of their resources.

locals {
  gov = data.terraform_remote_state.governance.outputs

  logging_project = local.gov.logging_project_id
  app             = local.gov.app_projects["app-${var.env}"]
  host            = local.gov.host_projects[local.app.host]

  # Projects whose metrics the logging project reads.
  monitored = {
    app  = local.app.project_id
    host = local.host.project_id
  }
}

data "terraform_remote_state" "governance" {
  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "landing-zone/governance"
    impersonate_service_account = var.terraform_service_account
  }
}

data "terraform_remote_state" "incident" {
  count = var.enable_incident_channel ? 1 : 0

  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "landing-zone/incident"
    impersonate_service_account = var.terraform_service_account
  }
}
