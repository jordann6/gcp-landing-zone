output "address" {
  description = "Reserved global address: its name goes in the Ingress annotation, its IP is what clients hit."
  value = {
    name = google_compute_global_address.edge.name
    ip   = google_compute_global_address.edge.address
  }
}

output "security_policy" {
  description = "Cloud Armor policy name, referenced by the BackendConfig."
  value       = google_compute_security_policy.edge.name
}

output "project_id" {
  value = local.project
}
