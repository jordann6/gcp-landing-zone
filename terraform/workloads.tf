# Vended workload projects.
#
# Two projects through the same factory, differing only in which folder they
# land in. That is the whole demonstration: nonprod and prod are governed
# differently without either one carrying its own policy code, because policy
# comes from placement.

module "nonprod_app" {
  source = "./modules/project-factory"

  name            = "app-nonprod"
  name_prefix     = var.name_prefix
  folder_id       = google_folder.nonprod.name
  billing_account = var.billing_account
  environment     = "nonprod"
  labels          = var.labels

  shared_vpc_host_project = google_compute_shared_vpc_host_project.host.project

  apis = [
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

module "prod_app" {
  source = "./modules/project-factory"

  name            = "app-prod"
  name_prefix     = var.name_prefix
  folder_id       = google_folder.prod.name
  billing_account = var.billing_account
  environment     = "prod"
  labels          = var.labels

  shared_vpc_host_project = google_compute_shared_vpc_host_project.host.project

  apis = [
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

# Subnet-level access rather than project-level network admin. A service project
# team can use this subnet and nothing else, which is the least-privilege form
# of Shared VPC and the reason to prefer it over granting network roles broadly.
resource "google_compute_subnetwork_iam_member" "nonprod_subnet_user" {
  project    = module.network_project.project_id
  region     = google_compute_subnetwork.workload.region
  subnetwork = google_compute_subnetwork.workload.name
  role       = "roles/compute.networkUser"
  member     = "serviceAccount:${module.nonprod_app.project_number}-compute@developer.gserviceaccount.com"
}
