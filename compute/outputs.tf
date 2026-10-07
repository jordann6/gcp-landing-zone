output "management_vm" {
  description = "Read by scripts/test-compute.sh."
  value = {
    name            = google_compute_instance.mgmt.name
    zone            = google_compute_instance.mgmt.zone
    project         = local.project
    image           = local.image
    service_account = google_service_account.mgmt.email
  }
}

output "patch_deployment" {
  description = "OS Config patch deployment name."
  value       = google_os_config_patch_deployment.mgmt.name
}
