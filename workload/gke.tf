# Private GKE cluster on the restricted Shared VPC.
#
# The EKS/AKS paved-road contract, GCP-native:
#   private API          IP endpoint is private-only; operators reach the API
#                        through the DNS endpoint, which is IAM-authenticated
#                        and exposes no IP (no authorized-network list to keep
#                        current, no bastion)
#   private nodes        no external IPs (also enforced by the custom constraint)
#   envelope encryption  application-layer secrets encryption with Cloud KMS
#   workload identity    pods authenticate as themselves, no node credentials
#   network policy       Dataplane V2 (eBPF, Cilium-based) enforces NetworkPolicy
#                        natively, default-deny applied from k8s/
#   admission            Binary Authorization rejects unattested images
#   supply chain         nodes pull only from Artifact Registry through the PSC
#                        endpoint; the NGFW egress rule blocks public registries

resource "google_service_account" "nodes" {
  project      = local.project
  account_id   = "sa-gke-nodes"
  display_name = "GKE nodes (least privilege)"
  description  = "Node identity. Logging, metrics, and registry read only; pods never see it (GKE_METADATA)."
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/autoscaling.metricsWriter",
  ])

  project = local.project
  role    = each.value
  member  = google_service_account.nodes.member
}

resource "google_container_cluster" "paved_road" {
  # checkov:skip=CKV_GCP_12: NetworkPolicy is enforced by Dataplane V2
  # (datapath_provider = ADVANCED_DATAPATH), which this check does not recognize;
  # it looks only for the legacy Calico network_policy block.
  # checkov:skip=CKV_GCP_65: Google Groups for RBAC needs a Cloud Identity
  # directory, which this org does not have; humans federate through the
  # workforce pool instead (terraform/identity.tf).
  project  = local.project
  name     = "gke-${var.env}"
  location = var.zone

  network    = local.vpc.network
  subnetwork = local.vpc.subnet

  deletion_protection      = var.deletion_protection
  remove_default_node_pool = true
  initial_node_count       = 1

  # Set explicitly, not only through provider default_labels: the custom
  # constraint custom.gkeRequireCostCenterLabel reads resourceLabels on the
  # create request and rejects the cluster without cost_center.
  resource_labels = local.labels

  release_channel {
    channel = "REGULAR"
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Dataplane V2: eBPF datapath with NetworkPolicy enforcement built in. No
  # Calico add-on to run, and policy decisions are logged.
  datapath_provider = "ADVANCED_DATAPATH"

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = local.vpc.control_plane

    master_global_access_config {
      enabled = false
    }
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  # An empty authorized-networks block with the private endpoint means the IP
  # endpoint answers only inside the VPC. Operator access is the DNS endpoint.
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false
  }

  workload_identity_config {
    workload_pool = "${local.project}.svc.id.goog"
  }

  database_encryption {
    state    = "ENCRYPTED"
    key_name = google_kms_crypto_key.workload["gke-secrets"].id
  }

  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  enable_shielded_nodes       = true
  enable_intranode_visibility = true

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }

  # The default pool is created and removed immediately; it still needs a
  # CMEK boot disk and the node SA, or prod's restrictNonCmekServices rejects
  # the cluster create before the removal ever happens.
  node_config {
    service_account   = google_service_account.nodes.email
    boot_disk_kms_key = google_kms_crypto_key.workload["gke-disk"].id
    oauth_scopes      = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    # GKE now reports application-layer secrets encryption on new clusters as
    # ALL_OBJECTS_ENCRYPTION_ENABLED, a value the provider does not accept in
    # config (only ENCRYPTED or DECRYPTED). Same encryption, new name; without
    # this every plan re-sends ENCRYPTED. key_name is still tracked.
    ignore_changes = [node_config, database_encryption[0].state]
  }

  depends_on = [
    google_kms_crypto_key_iam_member.workload,
    google_binary_authorization_policy.cluster,
  ]
}

resource "google_container_node_pool" "default" {
  project  = local.project
  name     = "pool-default"
  location = var.zone
  cluster  = google_container_cluster.paved_road.name

  node_count = var.node_count

  node_config {
    machine_type      = var.node_machine_type
    disk_size_gb      = 50
    disk_type         = "pd-balanced"
    boot_disk_kms_key = google_kms_crypto_key.workload["gke-disk"].id
    image_type        = "COS_CONTAINERD"

    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Pods get the GKE metadata server, which serves only their own Workload
    # Identity token. Without this a pod reads the node's credentials directly.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    labels = { cost_center = var.cost_center, environment = var.env }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  lifecycle {
    ignore_changes = [node_config[0].kubelet_config, version]
  }
}
