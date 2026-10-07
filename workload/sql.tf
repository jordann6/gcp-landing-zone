# Data tier: Cloud SQL for PostgreSQL, regional HA, private IP only, CMEK, with
# a cross-region read replica as the DR target.
#
#   RPO  zonal failure: 0 (synchronous replication to the standby zone)
#        regional loss: seconds (asynchronous replica in var.replica_region)
#   RTO  zonal failure: about a minute (automatic failover, same IP)
#        regional loss: minutes (promote the replica; a manual, deliberate act)
#
# Active-passive only, per the design doc: active-active across regions buys
# nothing this demo can show and costs consistency.

resource "random_id" "sql" {
  byte_length = 2
}

resource "google_sql_database_instance" "primary" {
  # checkov:skip=CKV_GCP_6: ENCRYPTED_ONLY enforces TLS on every connection;
  # the check accepts only client-certificate mode, which is the Cloud SQL Auth
  # Proxy / connector path (IAM DB auth) and the production upgrade here.
  # checkov:skip=CKV_GCP_79: POSTGRES_17, the newest major version validated for
  # this build; the check expects 18 as soon as it exists.
  project          = local.project
  name             = "pg-${var.env}-${random_id.sql.hex}"
  region           = var.region
  database_version = "POSTGRES_17"

  encryption_key_name = google_kms_crypto_key.workload["sql"].id
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.sql_tier
    edition           = "ENTERPRISE"
    availability_type = "REGIONAL"
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = true

    # Set explicitly: Cloud SQL labels are not visible to custom constraints, so
    # the review-time OPA rule is what holds cost_center here.
    user_labels = local.labels

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = local.vpc.network
      allocated_ip_range                            = "psa-${var.env}"
      ssl_mode                                      = "ENCRYPTED_ONLY"
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "04:00"
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 7
      }
    }

    maintenance_window {
      day          = 7
      hour         = 5
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = false
      record_client_address   = false
    }

    # CIS Google Cloud 6.2.x logging flags. Written out rather than generated
    # with a dynamic block, because the static scanners cannot see inside one
    # and would report every flag as missing.
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_duration"
      value = "on"
    }
    database_flags {
      name  = "log_hostname"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_min_messages"
      value = "error"
    }
    database_flags {
      name  = "log_min_error_statement"
      value = "error"
    }
    database_flags {
      name  = "log_temp_files"
      value = "0"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "-1"
    }
    database_flags {
      name  = "log_statement"
      value = "ddl"
    }
    database_flags {
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }
    database_flags {
      name  = "pgaudit.log"
      value = "ddl,role"
    }
  }

  depends_on = [
    google_kms_crypto_key_iam_member.workload,
    data.terraform_remote_state.network,
  ]
}

resource "google_sql_database_instance" "replica" {
  # checkov:skip=CKV_GCP_6: ENCRYPTED_ONLY enforces TLS on every connection;
  # the check accepts only client-certificate mode, which is the Cloud SQL Auth
  # Proxy / connector path (IAM DB auth) and the production upgrade here.
  # checkov:skip=CKV_GCP_79: POSTGRES_17, the newest major version validated for
  # this build; the check expects 18 as soon as it exists.
  count = var.enable_cross_region_replica ? 1 : 0

  project              = local.project
  name                 = "pg-${var.env}-${random_id.sql.hex}-dr"
  region               = var.replica_region
  database_version     = "POSTGRES_17"
  master_instance_name = google_sql_database_instance.primary.name

  encryption_key_name = google_kms_crypto_key.sql_replica[0].id
  deletion_protection = var.deletion_protection

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = var.sql_tier
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_autoresize   = true
    user_labels       = merge(local.labels, { role = "dr-replica" })

    ip_configuration {
      ipv4_enabled       = false
      private_network    = local.vpc.network
      allocated_ip_range = "psa-${var.env}"
      ssl_mode           = "ENCRYPTED_ONLY"
    }

    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_duration"
      value = "on"
    }
    database_flags {
      name  = "log_hostname"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_min_messages"
      value = "error"
    }
    database_flags {
      name  = "log_min_error_statement"
      value = "error"
    }
    database_flags {
      name  = "log_temp_files"
      value = "0"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "-1"
    }
    database_flags {
      name  = "log_statement"
      value = "ddl"
    }
    database_flags {
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }
    database_flags {
      name  = "pgaudit.log"
      value = "ddl,role"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.sql_replica]
}

resource "google_sql_database" "app" {
  project  = local.project
  instance = google_sql_database_instance.primary.name
  name     = "app"
}

# The password is never in Terraform. This creates the user and nothing else;
# scripts/set-db-password.sh sets the password in Cloud SQL and adds it to the
# Secret Manager shell in one step, so the value exists only in those two
# places, and the app reads it through Workload Identity (workload_identity.tf).
resource "google_sql_user" "app" {
  project  = local.project
  instance = google_sql_database_instance.primary.name
  name     = "app"

  lifecycle {
    ignore_changes = [password]
  }
}
