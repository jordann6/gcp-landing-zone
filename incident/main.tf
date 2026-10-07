# Incident wiring: findings and alerts to a private, authenticated handler.
#
#   SCC finding   scc-findings topic ---push---> /scc  quarantine the mgmt VM
#   Ops alert     Monitoring channel -> ops-alerts ---push---> /ops
#                                                      GKE node pool resize,
#                                                      Cloud SQL failover
#
# Private by construction. Ingress is INTERNAL_ONLY (Pub/Sub push is an allowed
# internal source), the only invoker is the push identity, and nothing holds
# allUsers or allAuthenticatedUsers. The service runs in the logging project,
# next to the topics, outside the VPC-SC perimeter. Compute, GKE and Cloud Run
# are not restricted services, so quarantine and resize cross freely; Cloud SQL
# is, so network/ admits sa-incident to sqladmin (enable_incident_access).
#
# Destructive actions default to dry-run (var.dry_run). No third-party secret is
# needed, so there is no Secret Manager shell here: the record of what ran is
# the handler's structured log plus the existing ops email on the same alerts.

locals {
  gov = data.terraform_remote_state.governance.outputs
  net = data.terraform_remote_state.network.outputs
  wl  = data.terraform_remote_state.workload.outputs

  logging_project = local.gov.logging_project_id
  logging_number  = local.gov.logging_project_number
  app             = local.gov.app_projects["app-${var.env}"]
  app_project     = local.app.project_id
  tag_value       = local.net.quarantine_tags[local.app.host]
  deploy          = var.image != ""
}

# Every API this root touches is also enabled on the seed (bootstrap), which is
# the quota project for each call.
resource "google_project_service" "logging" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    # Calls the handler makes bill to its own project, so the API it calls in the
    # app project must be enabled here too.
    "sqladmin.googleapis.com",
  ])

  project            = local.logging_project
  service            = each.value
  disable_on_destroy = false
}

# ---- image repository ---------------------------------------------------------

resource "google_artifact_registry_repository" "incident" {
  # checkov:skip=CKV_GCP_84: the repository holds one small image built from
  # this repo. The telemetry key is not granted to Artifact Registry.
  project       = local.logging_project
  location      = var.region
  repository_id = "incident"
  format        = "DOCKER"
  description   = "Incident handler image (incident/app)."

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 5
    }
  }

  depends_on = [google_project_service.logging]
}

# ---- identities ---------------------------------------------------------------

resource "google_service_account" "incident" {
  project      = local.logging_project
  account_id   = "sa-incident"
  display_name = "Incident handler (runtime)"
  depends_on   = [google_project_service.logging]
}

# Pub/Sub signs its push with this identity. It can invoke the one service and
# do nothing else.
resource "google_service_account" "invoker" {
  project      = local.logging_project
  account_id   = "sa-incident-invoker"
  display_name = "Incident handler (Pub/Sub push identity)"
  depends_on   = [google_project_service.logging]
}

resource "google_service_account_iam_member" "pubsub_signs_push" {
  service_account_id = google_service_account.invoker.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${local.logging_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# ---- what the handler may do, in the app project ------------------------------
#
# Three custom roles, one per runbook, so a reader can see each action's whole
# permission surface. They are project-scoped: the handler's label and name
# guards decide which instance, the role decides nothing outside the app project.

resource "google_project_iam_custom_role" "quarantine" {
  project     = local.app_project
  role_id     = "lzIncidentQuarantine"
  title       = "Incident: quarantine a VM"
  description = "Tag, label, snapshot, stop and detach the service account of a VM."
  permissions = [
    "compute.disks.createSnapshot",
    "compute.disks.get",
    "compute.disks.setLabels",
    "compute.instances.createTagBinding",
    "compute.instances.get",
    "compute.instances.listTagBindings",
    "compute.instances.setLabels",
    "compute.instances.setServiceAccount",
    "compute.instances.stop",
    "compute.snapshots.create",
    "compute.snapshots.get",
    "compute.snapshots.setLabels",
    "compute.zoneOperations.get",
  ]
}

resource "google_project_iam_custom_role" "gke_resize" {
  project     = local.app_project
  role_id     = "lzIncidentGkeResize"
  title       = "Incident: resize a GKE node pool"
  description = "Read a node pool and set its size."
  permissions = [
    "compute.instanceGroupManagers.get",
    "container.clusters.get",
    "container.clusters.update",
    "container.operations.get",
  ]
}

resource "google_project_iam_custom_role" "sql_failover" {
  project     = local.app_project
  role_id     = "lzIncidentSqlFailover"
  title       = "Incident: fail over Cloud SQL"
  description = "Read an instance and fail it over."
  permissions = [
    "cloudsql.instances.failover",
    "cloudsql.instances.get",
  ]
}

resource "google_project_iam_custom_role" "secret_age" {
  project     = local.app_project
  role_id     = "lzIncidentSecretAge"
  title       = "Incident: read secret version metadata"
  description = "List secrets and their versions (names, state, create time). No value access."
  permissions = [
    "secretmanager.secrets.list",
    "secretmanager.versions.list",
  ]
}

resource "google_project_iam_member" "incident" {
  for_each = {
    secret_age   = google_project_iam_custom_role.secret_age.name
    quarantine   = google_project_iam_custom_role.quarantine.name
    gke_resize   = google_project_iam_custom_role.gke_resize.name
    sql_failover = google_project_iam_custom_role.sql_failover.name
  }

  project = local.app_project
  role    = each.value
  member  = google_service_account.incident.member
}

# Binding the quarantine tag needs tagUser on that one tag value, and the
# create-binding permission on the instance (the custom role above).
resource "google_tags_tag_value_iam_member" "incident" {
  tag_value = local.tag_value
  role      = "roles/resourcemanager.tagUser"
  member    = google_service_account.incident.member
}

# ---- topics -------------------------------------------------------------------

data "google_kms_crypto_key" "telemetry" {
  name     = "telemetry"
  key_ring = "projects/${local.logging_project}/locations/${var.region}/keyRings/telemetry"
}

resource "google_pubsub_topic" "ops_alerts" {
  project      = local.logging_project
  name         = "ops-alerts"
  kms_key_name = data.google_kms_crypto_key.telemetry.id
}

# The grant that lets Monitoring publish to this topic lives in observability/,
# after the channel that creates Monitoring's notification service agent.

# ---- the service --------------------------------------------------------------

resource "google_cloud_run_v2_service" "incident" {
  count = local.deploy ? 1 : 0

  project             = local.logging_project
  name                = "incident-handler"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  deletion_protection = false

  template {
    service_account = google_service_account.incident.email
    timeout         = "300s"

    # One instance at a time: a quarantine must not race itself on redelivery.
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      env {
        name  = "DRY_RUN"
        value = tostring(var.dry_run)
      }
      env {
        name  = "APP_PROJECT_ID"
        value = local.app_project
      }
      env {
        name  = "APP_PROJECT_NUMBER"
        value = tostring(local.app.number)
      }
      env {
        name  = "QUARANTINE_LABEL"
        value = var.quarantine_label
      }
      env {
        name  = "QUARANTINE_TAG_VALUE"
        value = local.tag_value
      }
      env {
        name  = "GKE_CLUSTER"
        value = local.wl.cluster.name
      }
      env {
        name  = "GKE_LOCATION"
        value = local.wl.cluster.location
      }
      env {
        name  = "GKE_NODE_POOL"
        value = var.gke_node_pool
      }
      env {
        name  = "GKE_MAX_NODES"
        value = tostring(var.gke_max_nodes)
      }
      env {
        name  = "SECRET_MAX_AGE_DAYS"
        value = tostring(var.secret_max_age_days)
      }
      env {
        name  = "SQL_FAILOVER_LIVE"
        value = tostring(var.sql_failover_live)
      }
      env {
        name  = "SQL_INSTANCE"
        value = local.wl.sql.primary
      }
    }
  }

  depends_on = [
    google_project_iam_member.incident,
    google_tags_tag_value_iam_member.incident,
  ]
}

# The one invoker. Granted on this service only, never project-wide, never to
# allUsers or allAuthenticatedUsers.
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  count = local.deploy ? 1 : 0

  project  = local.logging_project
  location = var.region
  name     = google_cloud_run_v2_service.incident[0].name
  role     = "roles/run.invoker"
  member   = google_service_account.invoker.member
}

# ---- push subscriptions -------------------------------------------------------

locals {
  routes = {
    scc = { topic = local.gov.findings_topic, path = "/scc" }
    ops = { topic = google_pubsub_topic.ops_alerts.id, path = "/ops" }
  }
}

resource "google_pubsub_subscription" "incident" {
  for_each = local.deploy ? local.routes : {}

  project = local.logging_project
  name    = "incident-${each.key}"
  topic   = each.value.topic

  # A quarantine stops a VM, which can take a minute or two.
  ack_deadline_seconds       = 300
  message_retention_duration = "86400s"

  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.incident[0].uri}${each.value.path}"

    oidc_token {
      service_account_email = google_service_account.invoker.email
      audience              = google_cloud_run_v2_service.incident[0].uri
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.invoker,
    google_service_account_iam_member.pubsub_signs_push,
  ]
}

# ---- secret age check ---------------------------------------------------------
#
# Daily. The second job exists so the alert can be proved without waiting 90
# days: its body sets the limit to -1, so every secret with a value is "stale".
# Its yearly schedule never fires on its own; make test-secrets runs it.

resource "google_cloud_scheduler_job" "secret_age" {
  for_each = local.deploy ? {
    daily = { schedule = "0 6 * * *", limit = var.secret_max_age_days }
    proof = { schedule = "0 0 1 1 *", limit = -1 }
  } : {}

  project   = local.logging_project
  region    = var.region
  name      = "secret-age-${each.key}"
  schedule  = each.value.schedule
  time_zone = "UTC"

  description = each.key == "proof" ? "Proof run for the stale-secret alert (limit -1). Run by make test-secrets, never on a schedule." : "Flag any secret whose newest enabled version is older than ${var.secret_max_age_days} days."

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_v2_service.incident[0].uri}/secret-age"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode(jsonencode({ max_age_days = each.value.limit }))

    oidc_token {
      service_account_email = google_service_account.invoker.email
      audience              = google_cloud_run_v2_service.incident[0].uri
    }
  }

  depends_on = [google_cloud_run_v2_service_iam_member.invoker]
}
