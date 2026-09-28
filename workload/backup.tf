# Isolated, immutable backups: Backup and DR backup vault.
#
# Cloud SQL's own automated backups and PITR (sql.tf) live with the instance
# and are deleted by whoever can delete the instance. A backup vault is the
# isolation layer on top: backups are stored in Google-managed storage outside
# the project, and the enforced minimum retention means nobody, the project
# owner and sa-terraform included, can delete a backup before it elapses. That
# is Vault Lock on AWS Backup and immutable vaults on Azure Backup.

resource "google_backup_dr_backup_vault" "sql" {
  count = var.enable_backup_vault ? 1 : 0

  project         = local.project
  location        = var.region
  backup_vault_id = "bv-${var.env}-sql"
  description     = "Immutable vault for the ${var.env} Cloud SQL instance."

  backup_minimum_enforced_retention_duration = var.backup_vault_min_retention

  # Demo teardown: an empty vault can be deleted even though it enforces
  # retention. A vault holding backups still cannot be, until they age out.
  ignore_inactive_datasources   = true
  ignore_backup_plan_references = true
  allow_missing                 = true
  backup_retention_inheritance  = "INHERIT_VAULT_RETENTION"
  access_restriction            = "WITHIN_ORGANIZATION"
}

resource "google_backup_dr_backup_plan" "sql" {
  count = var.enable_backup_vault ? 1 : 0

  project        = local.project
  location       = var.region
  backup_plan_id = "bp-${var.env}-sql-daily"
  resource_type  = "sqladmin.googleapis.com/Instance"
  backup_vault   = google_backup_dr_backup_vault.sql[0].id

  backup_rules {
    rule_id               = "daily"
    backup_retention_days = 7

    standard_schedule {
      recurrence_type  = "DAILY"
      hourly_frequency = 0
      time_zone        = "UTC"

      backup_window {
        start_hour_of_day = 3
        end_hour_of_day   = 7
      }
    }
  }
}

resource "google_backup_dr_backup_plan_association" "sql" {
  count = var.enable_backup_vault && var.associate_sql_with_vault ? 1 : 0

  project                    = local.project
  location                   = var.region
  backup_plan_association_id = "bpa-${var.env}-sql"
  resource                   = "projects/${local.project}/instances/${google_sql_database_instance.primary.name}"
  resource_type              = "sqladmin.googleapis.com/Instance"
  backup_plan                = google_backup_dr_backup_plan.sql[0].name
}
