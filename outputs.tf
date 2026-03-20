output "project_id" {
  description = "Google Cloud project ID."
  value       = google_project.project.project_id
}

output "bucket_name" {
  description = "Package bucket name."
  value       = google_storage_bucket.packages.name
}

output "package_url" {
  description = "Public HTTPS package repository URL."
  value       = "https://${var.package_domain}"
}

output "github_service_account_email" {
  description = "Service account email used by GitHub Actions."
  value       = google_service_account.github.email
}

output "workload_identity_provider" {
  description = "Full Workload Identity Provider resource name for GitHub Actions auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "aptly_gpg_private_key_secret_id" {
  description = "Secret Manager secret ID for the armored Aptly private key."
  value       = google_secret_manager_secret.aptly_private_key.secret_id
}

output "aptly_gpg_passphrase_secret_id" {
  description = "Secret Manager secret ID for the Aptly key passphrase."
  value       = google_secret_manager_secret.aptly_passphrase.secret_id
}

output "dns_name_servers" {
  description = "Name servers assigned to the managed zone. Delegate the zone at your registrar or parent DNS."
  value       = google_dns_managed_zone.packages.name_servers
}
