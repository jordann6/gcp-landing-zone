# Patching: OS Config patch deployment, the GCP counterpart of the Azure
# maintenance configuration and AWS SSM Patch Manager.
#
# The agent ships in the Ubuntu image, compute.requireOsConfig keeps it on, and
# apt upgrades from the same Artifact Registry mirror the bake used, so the
# patch path needs no internet route either. Targeted by label, so a second
# management VM is patched without editing this file.
#
# Inventory reporting uses guest attributes, which the org disables
# (compute.disableGuestAttributesAccess). Patch jobs do not depend on them.

resource "google_os_config_patch_deployment" "mgmt" {
  project             = local.project
  patch_deployment_id = "mgmt-weekly"
  description         = "Weekly apt upgrade of the management VMs from the landing zone mirror."

  instance_filter {
    group_labels {
      labels = { role = "mgmt" }
    }
  }

  patch_config {
    reboot_config = "DEFAULT"

    apt {
      type = "UPGRADE"
    }
  }

  duration = "3600s"

  recurring_schedule {
    time_zone {
      id = "UTC"
    }

    time_of_day {
      hours   = var.patch_window.hour
      minutes = 0
    }

    weekly {
      day_of_week = var.patch_window.day
    }
  }
}
