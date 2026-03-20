provider "google" {
  project = var.project_id
  region  = var.region
}

provider "github" {
  owner = var.github_owner
  alias = "libops"
}

resource "google_project" "project" {
  name            = var.project_name
  project_id      = var.project_id
  org_id          = var.org_id
  billing_account = var.billing_account

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  project_id              = google_project.project.project_id
  project_num             = google_project.project.number
  repos                   = toset(var.github_repositories)
  actors                  = toset(var.github_actors)
  repos_with_aptly_key_id = var.aptly_gpg_key_id != "" ? local.repos : toset([])
  default_services = toset([
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])
  repository_condition = length(local.repos) > 0 ? format(
    "(%s)",
    join(" || ", [for repo in local.repos : "assertion.repository == '${repo}'"]),
  ) : "false"
  actor_condition = length(local.actors) > 0 ? format(
    "(%s)",
    join(" || ", [for actor in local.actors : "assertion.actor == '${actor}'"]),
  ) : "true"
  provider_attribute_condition = "${local.repository_condition} && ${local.actor_condition}"
}

# =============================================================================
# GCLOUD PROJECT
# =============================================================================

resource "google_project_service" "service" {
  for_each = local.default_services
  project  = local.project_id
  service  = each.value

  disable_on_destroy = false
}

resource "google_service_account" "github" {
  project      = local.project_id
  account_id   = "github-packages"
  display_name = "GitHub package publisher"

  depends_on = [google_project_service.service]
}

# =============================================================================
# GCS BUCKET for packages
# =============================================================================

resource "google_storage_bucket" "packages" {
  project                     = local.project_id
  name                        = var.bucket_name
  location                    = var.bucket_location
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"

  versioning {
    enabled = false
  }

  depends_on = [google_project_service.service]
}

resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.packages.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "github_writer" {
  bucket = google_storage_bucket.packages.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.github.email}"
}

# =============================================================================
# GPG SIGNING KEY
# =============================================================================

resource "google_secret_manager_secret" "aptly_private_key" {
  project   = local.project_id
  secret_id = var.aptly_gpg_private_key_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.service]
}

resource "google_secret_manager_secret" "aptly_passphrase" {
  project   = local.project_id
  secret_id = var.aptly_gpg_passphrase_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.service]
}

resource "google_secret_manager_secret_iam_member" "github_aptly_private_key_accessor" {
  project   = local.project_id
  secret_id = google_secret_manager_secret.aptly_private_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.github.email}"
}

resource "google_secret_manager_secret_iam_member" "github_aptly_passphrase_accessor" {
  project   = local.project_id
  secret_id = google_secret_manager_secret.aptly_passphrase.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.github.email}"
}

# =============================================================================
# GITHUB ACTIONS WIP
# =============================================================================

resource "google_iam_workload_identity_pool" "pool" {
  project                   = local.project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  description               = "OIDC pool for GitHub Actions package publishing"

  depends_on = [google_project_service.service]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project = local.project_id

  workload_identity_pool_id          = google_iam_workload_identity_pool.pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"
  description                        = "GitHub identity pool provider for syncing package repositories"
  attribute_condition                = local.provider_attribute_condition
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "oidc_user" {
  for_each = local.repos

  service_account_id = google_service_account.github.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.repository/${each.value}"
}

# =============================================================================
# TLS + DNS for GCS BUCKET
# =============================================================================

resource "google_compute_global_address" "packages" {
  project = local.project_id
  name    = "packages-ip"

  depends_on = [google_project_service.service]
}

resource "google_compute_backend_bucket" "packages" {
  project     = local.project_id
  name        = "packages-backend"
  bucket_name = google_storage_bucket.packages.name
  enable_cdn  = true
}

resource "google_compute_managed_ssl_certificate" "packages" {
  project = local.project_id
  name    = "packages-cert"

  managed {
    domains = [var.package_domain]
  }
}

resource "google_compute_url_map" "packages" {
  project         = local.project_id
  name            = "packages-url-map"
  default_service = google_compute_backend_bucket.packages.id
}

resource "google_compute_target_https_proxy" "packages" {
  project          = local.project_id
  name             = "packages-https-proxy"
  url_map          = google_compute_url_map.packages.id
  ssl_certificates = [google_compute_managed_ssl_certificate.packages.id]
}

resource "google_compute_global_forwarding_rule" "packages_https" {
  project               = local.project_id
  name                  = "packages-https"
  ip_address            = google_compute_global_address.packages.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.packages.id
  load_balancing_scheme = "EXTERNAL"
}

resource "google_dns_managed_zone" "packages" {
  project     = local.project_id
  name        = var.dns_zone_name
  dns_name    = var.dns_zone_dns_name
  description = "DNS zone for Linux package publishing"

  depends_on = [google_project_service.service]
}

resource "google_dns_record_set" "packages_a" {
  project      = local.project_id
  managed_zone = google_dns_managed_zone.packages.name
  name         = "${var.package_domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.packages.address]
}


# =============================================================================
# Set GitHub Actions vars/secrets
# =============================================================================

data "github_repository" "repo" {
  provider  = github.libops
  for_each  = local.repos
  full_name = each.value
}

resource "github_actions_variable" "oidc" {
  provider      = github.libops
  for_each      = local.repos
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_GCLOUD_OIDC_POOL"
  value         = google_iam_workload_identity_pool_provider.github.name
}

resource "github_actions_variable" "project" {
  provider      = github.libops
  for_each      = local.repos
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_GCLOUD_PROJECT"
  value         = local.project_id
}

resource "github_actions_variable" "region" {
  provider      = github.libops
  for_each      = local.repos
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_GCLOUD_REGION"
  value         = var.region
}

resource "github_actions_variable" "gsa" {
  provider      = github.libops
  for_each      = local.repos
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_GSA"
  value         = google_service_account.github.email
}

resource "github_actions_variable" "bucket" {
  provider      = github.libops
  for_each      = local.repos
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_GCS_BUCKET"
  value         = google_storage_bucket.packages.name
}

resource "github_actions_variable" "package_url" {
  provider      = github.libops
  for_each      = local.repos
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_PACKAGE_REPO_URL"
  value         = "https://${var.package_domain}"
}

resource "github_actions_variable" "aptly_gpg_key_id" {
  provider      = github.libops
  for_each      = local.repos_with_aptly_key_id
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_APTLY_GPG_KEY_ID"
  value         = var.aptly_gpg_key_id
}

resource "github_actions_variable" "aptly_gpg_private_key_secret" {
  provider      = github.libops
  for_each      = local.repos
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_APTLY_GPG_PRIVATE_KEY_SECRET"
  value         = google_secret_manager_secret.aptly_private_key.secret_id
}

resource "github_actions_variable" "aptly_gpg_passphrase_secret" {
  provider      = github.libops
  for_each      = local.repos
  repository    = data.github_repository.repo[each.value].name
  variable_name = "LIBOPS_PACKAGES_APTLY_GPG_PASSPHRASE_SECRET"
  value         = google_secret_manager_secret.aptly_passphrase.secret_id
}
