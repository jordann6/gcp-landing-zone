# Every resource here must trip a rule in policy/gcp_lz.rego. If this file ever
# passes, the rules have gone vacuous (a rule whose first line stops matching the
# input shape returns no violations, which looks exactly like a clean run).

resource "google_project" "default_vpc" {
  name                = "bad"
  project_id          = "bad"
  auto_create_network = true
}

resource "google_compute_network" "auto" {
  name                    = "auto"
  auto_create_subnetworks = true
}

resource "google_compute_subnetwork" "no_pga" {
  name          = "no-pga"
  network       = "auto"
  ip_cidr_range = "10.9.0.0/24"
}

resource "google_container_cluster" "bare" {
  name     = "bare"
  location = "us-central1-a"

  private_cluster_config {
    enable_private_nodes = false
  }
}

resource "google_container_node_pool" "default_sa" {
  name    = "default-sa"
  cluster = "bare"

  node_config {
    workload_metadata_config {
      mode = "GCE_METADATA"
    }
  }
}

resource "google_sql_database_instance" "weak" {
  name             = "weak"
  database_version = "POSTGRES_16"

  settings {
    tier = "db-custom-1-3840"

    backup_configuration {
      enabled = false
    }

    ip_configuration {
      ipv4_enabled = false
      ssl_mode     = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    }
  }
}

resource "google_secret_manager_secret" "auto" {
  secret_id = "auto"

  replication {
    auto {}
  }
}
