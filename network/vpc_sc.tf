# VPC Service Controls around the restricted tier.
#
# IAM answers "may this identity call this API". A perimeter answers a question
# IAM cannot: "may this call cross this boundary". A stolen credential with
# storage.objects.get still cannot read a bucket in the perimeter from a laptop,
# because the request originates outside it. That is the data-exfiltration
# control, and it has no direct equivalent in the other two zones (the closest
# are S3/KMS resource policies with aws:SourceVpce conditions, and Azure private
# endpoints with public network access disabled).
#
# Inside: every restricted-tier host project and the app projects attached to
# them. The base tier stays outside, which is why it is a separate project.
#
# Admitted across the boundary:
#   ingress  sa-terraform, so the landing zone can still be managed. The
#            operator's own identity is deliberately NOT admitted: make test
#            proves the perimeter by reading a bucket as the operator and
#            expecting a VPC-SC denial.
#   egress   the org log sinks' writer identities, to the logging project.
#            Without this, logs from inside the perimeter stop arriving and
#            nothing reports the gap.

locals {
  create_policy    = var.enable_vpc_sc && var.access_policy_name == null
  access_policy_id = var.enable_vpc_sc ? coalesce(var.access_policy_name, try(google_access_context_manager_access_policy.org[0].name, null)) : null

  perimeter_projects = var.enable_vpc_sc ? concat(
    [for k, h in local.hosts : "projects/${h.number}" if h.restricted],
    [for k, a in local.gov.app_projects : "projects/${a.number}" if local.hosts[a.host].restricted],
  ) : []

  admin_identities = ["serviceAccount:${var.terraform_service_account}"]
}

resource "google_access_context_manager_access_policy" "org" {
  count = local.create_policy ? 1 : 0

  parent = "organizations/${local.gov.org_id}"
  title  = "lz-org-access-policy"
}

resource "google_access_context_manager_service_perimeter" "restricted" {
  count = var.enable_vpc_sc && length(local.perimeter_projects) > 0 ? 1 : 0

  parent         = "accessPolicies/${local.access_policy_id}"
  name           = "accessPolicies/${local.access_policy_id}/servicePerimeters/lz_restricted"
  title          = "lz_restricted"
  description    = "Restricted Shared VPC tier and its service projects."
  perimeter_type = "PERIMETER_TYPE_REGULAR"

  use_explicit_dry_run_spec = var.vpc_sc_dry_run

  dynamic "status" {
    for_each = var.vpc_sc_dry_run ? [] : [1]
    content {
      resources           = local.perimeter_projects
      restricted_services = var.restricted_services

      ingress_policies {
        title = "terraform-admin"
        ingress_from {
          identities = local.admin_identities
          sources {
            access_level = "*"
          }
        }
        ingress_to {
          resources = ["*"]
          dynamic "operations" {
            for_each = var.restricted_services
            content {
              service_name = operations.value
              method_selectors {
                method = "*"
              }
            }
          }
        }
      }

      egress_policies {
        title = "org-log-sinks"
        egress_from {
          identities = local.gov.sink_writer_identities
        }
        egress_to {
          resources = ["projects/${local.gov.logging_project_number}"]
          operations {
            service_name = "bigquery.googleapis.com"
            method_selectors {
              method = "*"
            }
          }
          operations {
            service_name = "logging.googleapis.com"
            method_selectors {
              method = "*"
            }
          }
        }
      }
    }
  }

  dynamic "spec" {
    for_each = var.vpc_sc_dry_run ? [1] : []
    content {
      resources           = local.perimeter_projects
      restricted_services = var.restricted_services

      ingress_policies {
        title = "terraform-admin"
        ingress_from {
          identities = local.admin_identities
          sources {
            access_level = "*"
          }
        }
        ingress_to {
          resources = ["*"]
          dynamic "operations" {
            for_each = var.restricted_services
            content {
              service_name = operations.value
              method_selectors {
                method = "*"
              }
            }
          }
        }
      }
    }
  }
}
