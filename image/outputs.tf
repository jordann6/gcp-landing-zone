# Read by scripts/build-image.py and by compute/ through terraform_remote_state.

output "project_id" {
  description = "Golden image project."
  value       = local.project
}

output "bake" {
  description = "Packer inputs: where the bake VM runs and as whom."
  value = {
    project         = local.project
    network         = google_compute_network.bake.name
    subnetwork      = google_compute_subnetwork.bake.name
    region          = var.region
    service_account = google_service_account.bake.email
    builder         = google_service_account.builder.email
  }
}

output "apt_mirror" {
  description = "Artifact Registry remote repositories by suite, with the ar+https base each sources line uses."
  value = {
    for s, r in google_artifact_registry_repository.ubuntu : s => {
      name = r.name
      base = "ar+https://${r.location}-apt.pkg.dev/remote/${local.project}/${r.repository_id}"
    }
  }
}
