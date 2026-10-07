# Consumed by workload/ through terraform_remote_state.

output "vpcs" {
  description = "Per-VPC network, subnet, and firewall policy, keyed like the governance host map (plus sandbox)."
  value = {
    for k, v in local.vpcs : k => {
      project         = v.project
      env             = v.env
      restricted      = v.restricted
      network         = google_compute_network.vpc[k].id
      network_name    = google_compute_network.vpc[k].name
      subnet          = google_compute_subnetwork.workload[k].id
      subnet_name     = google_compute_subnetwork.workload[k].name
      subnet_cidr     = v.subnet
      firewall_policy = google_compute_network_firewall_policy.vpc[k].name
      psa_range       = v.restricted ? "10.${v.octet}.16.0/20" : null
      control_plane   = "10.${v.octet}.144.0/28"
    }
  }
}

output "psa_connections" {
  description = "Private services access connections (restricted tier). Cloud SQL private IP depends on these."
  value       = { for k, c in google_service_networking_connection.psa : k => c.id }
}

output "perimeter" {
  description = "VPC-SC perimeter name, or null."
  value       = one(google_access_context_manager_service_perimeter.restricted[*].name)
}

output "access_policy_id" {
  description = "Org access policy number (created here unless access_policy_name was supplied)."
  value       = local.access_policy_id
}

output "probe" {
  description = "Probe VM for make test, or null."
  value = length(local.probe) == 0 ? null : {
    name    = google_compute_instance.probe["probe"].name
    zone    = google_compute_instance.probe["probe"].zone
    project = google_compute_instance.probe["probe"].project
  }
}

output "org_firewall_policy" {
  description = "Org-level hierarchical firewall policy ID."
  value       = google_compute_firewall_policy.org.name
}

output "quarantine_tags" {
  description = "Secure tag value per restricted VPC (tagValues/ID). The incident handler binds it to a VM to isolate it."
  value       = { for k, v in google_tags_tag_value.quarantine : k => v.id }
}
