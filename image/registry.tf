# The package source: Artifact Registry remote repositories over the Ubuntu
# archive, one per suite.
#
# The bake VM and the management VM both install and patch from these, through
# Private Google Access (bake) or the PSC endpoint (prod), so neither needs a
# route to archive.ubuntu.com. The remote repository fetches from upstream and
# caches; Artifact Registry is the only thing in the landing zone that talks to
# the Ubuntu archive.
#
# Clients read through apt-transport-artifact-registry (ar+https). That package
# is itself on the internet, so packer/ uploads a copy pinned by SHA256 from the
# workstation rather than opening egress to fetch it.

resource "google_artifact_registry_repository" "ubuntu" {
  # checkov:skip=CKV_GCP_84: CMEK is required in the prod folder only; this
  # project is in core, and a remote cache of a public archive holds nothing
  # that a customer-managed key would protect.
  for_each = toset(var.ubuntu_suites)

  project       = local.project
  location      = var.region
  repository_id = "ubuntu-${each.value}"
  description   = "Remote cache of the Ubuntu archive, suite ${each.value}."
  format        = "APT"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = "archive.ubuntu.com ${each.value}"

    apt_repository {
      public_repository {
        repository_base = "UBUNTU"
        repository_path = "ubuntu/dists/${each.value}"
      }
    }
  }
}
