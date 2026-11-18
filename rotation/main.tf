# Secret rotation: Secret Manager's SECRET_ROTATE to a new Cloud SQL password.
#
#   secret schedule (30d) -> secret-rotation topic --push--> rotator (Cloud Run)
#                                                              |-> Cloud SQL Admin: set password
#                                                              |-> Secret Manager: add version
#                                                              '-> disable older versions
#
# Inside the perimeter, deliberately. Pub/Sub under VPC-SC can create a push
# subscription only to a Cloud Run endpoint, and only in the topic's own
# perimeter, so the rotator lives in the app project next to the topic. All of
# its egress goes through the restricted Shared VPC (Direct VPC egress,
# ALL_TRAFFIC), where *.googleapis.com resolves to the PSC endpoint: its Secret
# Manager and Cloud SQL Admin calls never leave the perimeter, and no ingress
# rule is needed. Compare incident/, which runs outside the perimeter and needs
# one. ADR-0006 has the reasoning.
#
# Least privilege, split by resource:
#   Cloud SQL  a custom role with users.update and the reads the operation
#              wait needs, bound on the project (Cloud SQL has no per-instance
#              IAM)
#   Secret     a custom role with add, list, disable, bound on the one secret,
#              not the project
#   Value      no secretAccessor: the rotator writes passwords and never reads one

locals {
  gov = data.terraform_remote_state.governance.outputs
  net = data.terraform_remote_state.network.outputs
  wl  = data.terraform_remote_state.workload.outputs

  app     = local.gov.app_projects["app-${var.env}"]
  project = local.app.project_id
  number  = local.app.number
  vpc     = local.net.vpcs[local.wl.vpc_key]
  secret  = local.wl.db_secret
  deploy  = var.image != ""
}

# ---- identities ---------------------------------------------------------------

resource "google_service_account" "rotator" {
  project      = local.project
  account_id   = "sa-rotator"
  display_name = "Secret rotator (runtime)"
}

resource "google_service_account" "invoker" {
  project      = local.project
  account_id   = "sa-rotator-invoker"
  display_name = "Secret rotator (Pub/Sub push identity)"
}

resource "google_service_account_iam_member" "pubsub_signs_push" {
  service_account_id = google_service_account.invoker.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${local.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_project_iam_custom_role" "sql_password" {
  project     = local.project
  role_id     = "lzRotatorSqlPassword"
  title       = "Rotator: set a Cloud SQL user password"
  description = "Update a built-in user's password and wait for the operation."
  permissions = [
    "cloudsql.instances.get",
    "cloudsql.users.list",
    "cloudsql.users.update",
  ]
}

resource "google_project_iam_member" "sql_password" {
  project = local.project
  role    = google_project_iam_custom_role.sql_password.name
  member  = google_service_account.rotator.member
}

resource "google_project_iam_custom_role" "secret_writer" {
  project     = local.project
  role_id     = "lzRotatorSecretWriter"
  title       = "Rotator: add and retire secret versions"
  description = "Add a version, list versions, disable old ones. No value access."
  permissions = [
    "secretmanager.secrets.get",
    "secretmanager.versions.add",
    "secretmanager.versions.disable",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
  ]
}

resource "google_secret_manager_secret_iam_member" "rotator" {
  project   = local.project
  secret_id = local.secret
  role      = google_project_iam_custom_role.secret_writer.name
  member    = google_service_account.rotator.member
}

# ---- the service --------------------------------------------------------------

resource "google_cloud_run_v2_service" "rotator" {
  count = local.deploy ? 1 : 0

  project             = local.project
  name                = "secret-rotator"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  deletion_protection = false

  template {
    service_account                  = google_service_account.rotator.email
    timeout                          = "300s"
    max_instance_request_concurrency = 1

    # One rotation at a time, so two deliveries cannot interleave their
    # password and version writes.
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    vpc_access {
      egress = "ALL_TRAFFIC"
      network_interfaces {
        network    = local.vpc.network
        subnetwork = local.vpc.subnet
        tags       = ["secret-rotator"]
      }
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
        name  = "PROJECT_ID"
        value = local.project
      }
      env {
        name  = "PROJECT_NUMBER"
        value = tostring(local.number)
      }
      env {
        name  = "SECRET_ID"
        value = local.secret
      }
      env {
        name  = "SQL_INSTANCE"
        value = local.wl.sql.primary
      }
      env {
        name  = "SQL_USER"
        value = var.sql_user
      }

      # Direct VPC egress can take a while to connect on a cold start; the probe
      # keeps Pub/Sub from pushing before the container is listening.
      startup_probe {
        tcp_socket {
          port = 8080
        }
        period_seconds    = 5
        failure_threshold = 12
      }
    }
  }

  depends_on = [
    google_project_iam_member.sql_password,
    google_secret_manager_secret_iam_member.rotator,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  count = local.deploy ? 1 : 0

  project  = local.project
  location = var.region
  name     = google_cloud_run_v2_service.rotator[0].name
  role     = "roles/run.invoker"
  member   = google_service_account.invoker.member
}

# Same project as the topic, push to the service's run.app URL: the only push
# shape VPC-SC accepts inside a perimeter.
resource "google_pubsub_subscription" "rotator" {
  count = local.deploy ? 1 : 0

  project = local.project
  name    = "secret-rotator"
  topic   = local.wl.rotation_topic

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
    push_endpoint = google_cloud_run_v2_service.rotator[0].uri

    oidc_token {
      service_account_email = google_service_account.invoker.email
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.invoker,
    google_service_account_iam_member.pubsub_signs_push,
  ]
}
