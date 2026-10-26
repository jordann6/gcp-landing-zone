output "network_id" {
  description = "Proof VPC; present after a CI apply, gone after a CI destroy."
  value       = google_compute_network.ci.id
}
