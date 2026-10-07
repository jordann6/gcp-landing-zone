# Project vending.
#
# Every project in the landing zone goes through modules/project-factory, so no
# project exists without a folder, a billing link, data-access audit logging,
# and the default network suppressed. The maps below are the whole inventory;
# the vend flags in var.environments decide which of them are instantiated.
#
# Shared VPC: one host project per environment and tier (base, and for prod a
# separate restricted host that sits inside the VPC Service Controls
# perimeter). Workload teams get a service project that consumes a subnet it
# does not own. Separate host projects for base and restricted is the
# foundations-blueprint layout, and it matters: VPC-SC decides "inside" by
# project, so a base VPC in the same project as a restricted one would be
# inside the perimeter too.

locals {
  hosts = merge(
    {
      for env, e in var.environments : "net-${env}" => {
        env        = env
        restricted = false
      } if e.base
    },
    {
      for env, e in var.environments : "net-${env}-r" => {
        env        = env
        restricted = true
      } if e.restricted
    },
  )

  # A service project attaches to exactly one host, so the app project goes to
  # the restricted host where one exists: the sensitive tier is the one the
  # workload root builds on.
  apps = {
    for env, e in var.environments : "app-${env}" => {
      env  = env
      host = e.restricted ? "net-${env}-r" : "net-${env}"
    } if e.app
  }

  host_apis = [
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    # GKE in a service project creates its firewall rules and reads subnets as
    # the host project's GKE service agent, which only exists once the API is on.
    "container.googleapis.com",
    "dns.googleapis.com",
    "servicenetworking.googleapis.com",
    "serviceusage.googleapis.com",
  ]

  app_apis = [
    "artifactregistry.googleapis.com",
    "backupdr.googleapis.com",
    "binaryauthorization.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "containeranalysis.googleapis.com",
    "containerscanning.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    # The management VM is patched by OS Config and reached over IAP + OS Login.
    "iap.googleapis.com",
    "oslogin.googleapis.com",
    "osconfig.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ]
}

# ---- core ---------------------------------------------------------------------

module "logging_project" {
  source = "./modules/project-factory"

  name            = "logging"
  name_prefix     = var.name_prefix
  folder_id       = google_folder.core.name
  billing_account = var.billing_account
  environment     = "shared"

  apis = [
    "bigquery.googleapis.com",
    "cloudasset.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]
}

module "hub_project" {
  source = "./modules/project-factory"
  count  = var.vend_hub ? 1 : 0

  name            = "net-hub"
  name_prefix     = var.name_prefix
  folder_id       = google_folder.core.name
  billing_account = var.billing_account
  environment     = "shared"

  apis = [
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

# The golden image project. It owns the hardened image family, the Artifact
# Registry Ubuntu mirror the bake and the patch runs read from, and the private
# bake VPC. It is the only project trustedImageProjects admits for VMs (see
# org_policies.tf), and the only one whose own policy still admits the stock
# Ubuntu image Packer hardens from.
module "image_project" {
  source = "./modules/project-factory"
  count  = var.vend_image_project ? 1 : 0

  name            = "images"
  name_prefix     = var.name_prefix
  folder_id       = google_folder.core.name
  billing_account = var.billing_account
  environment     = "shared"

  apis = [
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "oslogin.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

# ---- workloads ------------------------------------------------------------------

module "host" {
  source   = "./modules/project-factory"
  for_each = local.hosts

  name            = each.key
  name_prefix     = var.name_prefix
  folder_id       = google_folder.env[each.value.env].name
  billing_account = var.billing_account
  environment     = each.value.env
  apis            = local.host_apis
}

resource "google_compute_shared_vpc_host_project" "host" {
  for_each = local.hosts

  project = module.host[each.key].project_id
}

module "app" {
  source   = "./modules/project-factory"
  for_each = local.apps

  name            = each.key
  name_prefix     = var.name_prefix
  folder_id       = google_folder.env[each.value.env].name
  billing_account = var.billing_account
  environment     = each.value.env
  apis            = local.app_apis

  attach_shared_vpc       = true
  shared_vpc_host_project = google_compute_shared_vpc_host_project.host[each.value.host].project
}

# ---- sandbox --------------------------------------------------------------------

module "sandbox_project" {
  source = "./modules/project-factory"
  count  = var.vend_sandbox ? 1 : 0

  name            = "sandbox"
  name_prefix     = var.name_prefix
  folder_id       = google_folder.sandbox.name
  billing_account = var.billing_account
  environment     = "sandbox"

  apis = [
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}
