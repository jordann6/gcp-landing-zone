# Artifact Registry: the only image source.
#
#   apps       standard repo for images this org builds
#   dockerhub  remote repo, a pull-through cache of Docker Hub
#   docker     virtual repo over both, the single URL workloads reference
#
# Nodes cannot reach Docker Hub directly: the default internet route exists only
# for NAT, and the NGFW egress policy denies every destination not on the FQDN
# allowlist. The cache is the only way a public image arrives, which means it
# is scanned (Artifact Analysis) and pinned by digest in the cache before any
# node runs it. This is the ECR pull-through cache in the AWS zone and the ACR
# cache rules in the Azure zone.

resource "google_artifact_registry_repository" "apps" {
  project       = local.project
  location      = var.region
  repository_id = "apps"
  description   = "Images built by this org."
  format        = "DOCKER"
  kms_key_name  = google_kms_crypto_key.workload["registry"].id

  docker_config {
    immutable_tags = true
  }

  depends_on = [google_kms_crypto_key_iam_member.workload]
}

resource "google_artifact_registry_repository" "dockerhub" {
  project       = local.project
  location      = var.region
  repository_id = "dockerhub"
  description   = "Pull-through cache of Docker Hub."
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  kms_key_name  = google_kms_crypto_key.workload["registry"].id

  remote_repository_config {
    description = "Docker Hub"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  # A cache that keeps every layer ever pulled is a slow cost leak.
  cleanup_policies {
    id     = "expire-unused"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.workload]
}

resource "google_artifact_registry_repository" "docker" {
  project       = local.project
  location      = var.region
  repository_id = "docker"
  description   = "Virtual repo: org images first, then the Docker Hub cache."
  format        = "DOCKER"
  mode          = "VIRTUAL_REPOSITORY"
  kms_key_name  = google_kms_crypto_key.workload["registry"].id

  virtual_repository_config {
    upstream_policies {
      id         = "apps"
      repository = google_artifact_registry_repository.apps.id
      priority   = 100
    }
    upstream_policies {
      id         = "dockerhub"
      repository = google_artifact_registry_repository.dockerhub.id
      priority   = 50
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.workload]
}

resource "google_artifact_registry_repository_iam_member" "nodes" {
  for_each = {
    apps      = google_artifact_registry_repository.apps.name
    dockerhub = google_artifact_registry_repository.dockerhub.name
    docker    = google_artifact_registry_repository.docker.name
  }

  project    = local.project
  location   = var.region
  repository = each.value
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.nodes.member
}
