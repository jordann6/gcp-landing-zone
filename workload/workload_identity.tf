# Workload Identity: pods authenticate as their Kubernetes service account.
#
# IAM is granted directly to the KSA's principal, with no Google service
# account in between and no key anywhere. That is Workload Identity Federation
# for GKE in its current form: the grant names
#   principal://iam.googleapis.com/projects/<num>/locations/global/workloadIdentityPools/<project>.svc.id.goog/subject/ns/<ns>/sa/<ksa>
# and only a pod running as that KSA, in that namespace, on a cluster in this
# project's pool, can present the token. It is IRSA on EKS and federated
# credentials on AKS.
#
# Two consumers:
#   app/app                               the workload: reads its DB password
#                                         and connects to Cloud SQL
#   external-secrets/external-secrets     External Secrets Operator, which syncs
#                                         the same secret into a Kubernetes
#                                         Secret for apps that expect one

locals {
  wi_pool = "principal://iam.googleapis.com/projects/${local.number}/locations/global/workloadIdentityPools/${local.project}.svc.id.goog/subject"

  wi_principals = {
    app = "${local.wi_pool}/ns/app/sa/app"
    eso = "${local.wi_pool}/ns/external-secrets/sa/external-secrets"
  }
}

resource "google_secret_manager_secret_iam_member" "db_password" {
  for_each = local.wi_principals

  project   = local.project
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

resource "google_project_iam_member" "app_sql_client" {
  project = local.project
  role    = "roles/cloudsql.client"
  member  = local.wi_principals["app"]
}
