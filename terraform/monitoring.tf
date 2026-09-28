# Org-admin hardening and CIS log-metric alerts.
#
# The most powerful principals in the org are the ones least able to be
# prevented from doing things, so the control on them is detection: every use
# of break-glass, every change to org IAM, org policy, the VPC-SC perimeter, or
# hierarchical firewall policy raises an alert. The CIS 2.x log-metric controls
# ride on the same mechanism.
#
# Metrics count against the org log bucket (logging.tf), so one definition sees
# every project in the org, including ones vended after the metric exists.

locals {
  break_glass_emails = [for m in var.break_glass_members : trimprefix(m, "user:")]

  log_alerts = merge(
    {
      org-iam-change = {
        description = "IAM policy changed at the organization."
        filter      = "protoPayload.methodName=\"SetIamPolicy\" AND protoPayload.resourceName=~\"^organizations/\""
      }
      org-policy-change = {
        description = "Organization policy created, changed, or deleted anywhere in the hierarchy."
        filter      = "protoPayload.serviceName=\"orgpolicy.googleapis.com\" AND protoPayload.methodName=~\"(Create|Update|Delete)Policy\""
      }
      vpc-sc-change = {
        description = "VPC Service Controls perimeter or access level changed."
        filter      = "protoPayload.serviceName=\"accesscontextmanager.googleapis.com\" AND protoPayload.methodName=~\"(Create|Update|Delete|Replace|Commit)\""
      }
      firewall-policy-change = {
        description = "Hierarchical or network firewall policy changed."
        filter      = "protoPayload.methodName=~\"compute\\.(firewallPolicies|networkFirewallPolicies)\\.(insert|patch|delete|addRule|patchRule|removeRule|addAssociation|removeAssociation)\""
      }

      # CIS Google Cloud Foundations 2.x, section 2 log-metric controls.
      cis-2-4-project-ownership = {
        description = "CIS 2.4: project ownership assignment or change."
        filter      = "(protoPayload.serviceName=\"cloudresourcemanager.googleapis.com\") AND (ProjectOwnership OR projectOwnerInvitee) OR (protoPayload.serviceData.policyDelta.bindingDeltas.action=\"REMOVE\" AND protoPayload.serviceData.policyDelta.bindingDeltas.role=\"roles/owner\") OR (protoPayload.serviceData.policyDelta.bindingDeltas.action=\"ADD\" AND protoPayload.serviceData.policyDelta.bindingDeltas.role=\"roles/owner\")"
      }
      cis-2-5-audit-config = {
        description = "CIS 2.5: audit configuration change."
        filter      = "protoPayload.methodName=\"SetIamPolicy\" AND protoPayload.serviceData.policyDelta.auditConfigDeltas:*"
      }
      cis-2-6-custom-role = {
        description = "CIS 2.6: custom role change."
        filter      = "resource.type=\"iam_role\" AND (protoPayload.methodName=\"google.iam.admin.v1.CreateRole\" OR protoPayload.methodName=\"google.iam.admin.v1.DeleteRole\" OR protoPayload.methodName=\"google.iam.admin.v1.UpdateRole\")"
      }
      cis-2-7-vpc-firewall = {
        description = "CIS 2.7: VPC firewall rule change."
        filter      = "resource.type=\"gce_firewall_rule\" AND (protoPayload.methodName:\"compute.firewalls.patch\" OR protoPayload.methodName:\"compute.firewalls.insert\" OR protoPayload.methodName:\"compute.firewalls.delete\")"
      }
      cis-2-8-vpc-route = {
        description = "CIS 2.8: VPC route change."
        filter      = "resource.type=\"gce_route\" AND (protoPayload.methodName:\"compute.routes.delete\" OR protoPayload.methodName:\"compute.routes.insert\")"
      }
      cis-2-9-vpc-network = {
        description = "CIS 2.9: VPC network change."
        filter      = "resource.type=\"gce_network\" AND (protoPayload.methodName:\"compute.networks.insert\" OR protoPayload.methodName:\"compute.networks.patch\" OR protoPayload.methodName:\"compute.networks.delete\" OR protoPayload.methodName:\"compute.networks.removePeering\" OR protoPayload.methodName:\"compute.networks.addPeering\")"
      }
      cis-2-10-storage-iam = {
        description = "CIS 2.10: Cloud Storage IAM permission change."
        filter      = "resource.type=\"gcs_bucket\" AND protoPayload.methodName=\"storage.setIamPermissions\""
      }
      cis-2-11-sql-config = {
        description = "CIS 2.11: Cloud SQL instance configuration change."
        filter      = "protoPayload.methodName=\"cloudsql.instances.update\""
      }
    },
    length(local.break_glass_emails) == 0 ? {} : {
      break-glass-used = {
        description = "A break-glass principal made an API call. Every use is an incident until explained."
        filter      = join(" OR ", [for e in local.break_glass_emails : "protoPayload.authenticationInfo.principalEmail=\"${e}\""])
      }
    },
  )
}

resource "google_logging_metric" "alert" {
  for_each = local.log_alerts

  project     = module.logging_project.project_id
  name        = each.key
  description = each.value.description
  filter      = each.value.filter
  bucket_name = google_logging_project_bucket_config.org.id

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email == "" ? 0 : 1

  project      = module.logging_project.project_id
  display_name = "Landing zone security alerts"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_alert_policy" "log" {
  # Keyed on the static map, not on google_logging_metric.alert: a resource
  # object's keys are unknown during import and a partial apply.
  for_each = local.log_alerts

  project      = module.logging_project.project_id
  display_name = each.key
  combiner     = "OR"

  conditions {
    display_name = each.value.description

    condition_threshold {
      # Monitoring requires a resource.type clause. These metrics are scoped
      # to the org-audit log bucket, and a bucket-scoped metric reports every
      # matching entry against the bucket itself (logging_bucket), whatever
      # the entry's own resource was, so this type drops nothing.
      filter          = "metric.type = \"logging.googleapis.com/user/${google_logging_metric.alert[each.key].name}\" AND resource.type = \"logging_bucket\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = google_monitoring_notification_channel.email[*].id

  documentation {
    content   = each.value.description
    mime_type = "text/markdown"
  }
}

# Essential contacts: where Google sends security, technical, and billing
# notices for the org. Unset, they go to whoever happens to hold org admin,
# which is the break-glass account and exactly who should not be the inbox.
resource "google_essential_contacts_contact" "org" {
  count = var.alert_email == "" ? 0 : 1

  parent                              = "organizations/${var.org_id}"
  email                               = var.alert_email
  language_tag                        = "en-US"
  notification_category_subscriptions = ["SECURITY", "TECHNICAL", "BILLING", "LEGAL", "SUSPENSION"]
}
