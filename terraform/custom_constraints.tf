# Custom org policy constraints.
#
# The predefined constraints cover the platform's own shape (external IPs,
# locations, keys). Custom constraints extend the same enforcement to a
# resource's fields, in CEL, evaluated by the API at CREATE and UPDATE. They are
# how GCP answers two things the other clouds solve differently:
#
#   Tag enforcement. AWS uses a tag policy plus an SCP condition; Azure uses a
#   Deny policy on missing tags. GCP has no predefined "require label", so a
#   custom constraint rejects a GKE cluster that arrives without a cost_center
#   label. Spend that cannot be allocated never exists. Cloud SQL does not
#   expose its labels to custom constraints, so SQL labels are enforced in
#   review by policy/gcp_lz.rego instead of at the API.
#
#   Paved-road invariants. A GKE cluster with public nodes, or a Cloud SQL
#   instance with a public IP, is rejected at the API, not caught in review, and
#   not left to whoever writes the next one.
#
# Attached at the org so a cluster in a project outside the landing zone is
# still governed.

locals {
  custom_constraints = {
    gkeRequirePrivateNodes = {
      display_name   = "GKE clusters must use private nodes"
      description    = "Rejects a cluster whose nodes would receive external IPs."
      resource_types = ["container.googleapis.com/Cluster"]
      condition      = "resource.privateClusterConfig.enablePrivateNodes == true"
    }
    gkeRequireCostCenterLabel = {
      display_name   = "GKE clusters must carry a cost_center label"
      description    = "Spend that cannot be allocated to a cost centre is rejected at creation."
      resource_types = ["container.googleapis.com/Cluster"]
      condition      = "'cost_center' in resource.resourceLabels"
    }
    sqlRequirePrivateIp = {
      display_name   = "Cloud SQL instances must not have a public IP"
      description    = "Rejects an instance with a public IPv4 address. Access is private IP over the Shared VPC only."
      resource_types = ["sqladmin.googleapis.com/Instance"]
      condition      = "resource.settings.ipConfiguration.ipv4Enabled == false"
    }
  }
}

resource "google_org_policy_custom_constraint" "this" {
  for_each = var.enable_custom_constraints ? local.custom_constraints : {}

  name           = "custom.${each.key}"
  parent         = "organizations/${var.org_id}"
  display_name   = each.value.display_name
  description    = each.value.description
  action_type    = "ALLOW"
  condition      = each.value.condition
  method_types   = ["CREATE", "UPDATE"]
  resource_types = each.value.resource_types
}

resource "google_org_policy_policy" "custom" {
  for_each = google_org_policy_custom_constraint.this

  name   = "organizations/${var.org_id}/policies/${each.value.name}"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}
