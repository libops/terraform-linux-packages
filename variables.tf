variable "github_owner" {
  description = "GitHub organization that owns the repositories allowed to publish packages."
  type        = string
  default     = "libops"
}

variable "github_repositories" {
  description = "Full GitHub repository names allowed to impersonate the publishing service account."
  type        = set(string)
  default = [
    "libops/sitectl",
    "libops/sitectl-app-tmpl",
    "libops/sitectl-archivesspace",
    "libops/sitectl-drupal",
    "libops/sitectl-libops",
    "libops/sitectl-ojs",
    "libops/sitectl-omeka-classic",
    "libops/sitectl-omeka-s",
    "libops/sitectl-wp",
  ]
}

variable "github_actors" {
  description = "Optional GitHub actors allowed to use the provider. Leave empty to allow any actor from the approved repositories."
  type        = set(string)
  default     = []
}

variable "approved_job_workflow_refs" {
  description = "Exact reusable-workflow identities allowed to publish packages. Keep active direct and shared workflow SHAs during migrations; branch and tag refs are rejected."
  type        = set(string)

  validation {
    condition = length(var.approved_job_workflow_refs) > 0 && alltrue([
      for workflow_ref in var.approved_job_workflow_refs :
      can(regex("^libops/(terraform-linux-packages|[.]github)/[.]github/workflows/(reusable-goreleaser|sitectl-plugin-goreleaser)[.]ya?ml@[0-9a-f]{40}$", workflow_ref))
    ])
    error_message = "approved_job_workflow_refs must contain one or more exact 40-character SHA identities for the LibOps direct or shared package publisher workflow."
  }
}

variable "project_name" {
  description = "Google Cloud project display name."
  type        = string
  default     = "libops-linux-packages"
}

variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
  default     = "libops-linux-packages"
}

variable "org_id" {
  description = "Google Cloud organization ID."
  type        = string
}

variable "billing_account" {
  description = "Google Cloud billing account ID."
  type        = string
}

variable "region" {
  description = "Default Google Cloud region."
  type        = string
  default     = "us-east5"
}

variable "bucket_name" {
  description = "Name of the public package bucket."
  type        = string
  default     = "libops-linux-packages"
}

variable "bucket_location" {
  description = "Bucket location."
  type        = string
  default     = "US"
}

variable "package_domain" {
  description = "Fully qualified domain name that will serve the package repository."
  type        = string
  default     = "packages.libops.io"
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone name."
  type        = string
  default     = "packages-libops-io"
}

variable "dns_zone_dns_name" {
  description = "DNS suffix managed by the zone, with trailing dot."
  type        = string
  default     = "packages.libops.io."
}

variable "aptly_gpg_key_id" {
  description = "GPG key ID Aptly uses to sign the published repository."
  type        = string
  default     = ""
}

variable "aptly_gpg_private_key_secret_id" {
  description = "Secret Manager secret ID that stores the armored Aptly private key."
  type        = string
  default     = "aptly-gpg-private-key"
}

variable "aptly_gpg_passphrase_secret_id" {
  description = "Secret Manager secret ID that stores the Aptly GPG key passphrase."
  type        = string
  default     = "aptly-gpg-passphrase"
}
