# terraform-linux-packages

Terraform for a dedicated Google Cloud project that serves Linux packages from a public GCS bucket behind HTTPS, with GitHub Actions write access via Workload Identity Federation.

## GitHub Access Model

Only the repositories listed in `github_repositories` receive:

- `LIBOPS_PACKAGES_GCLOUD_OIDC_POOL`
- `LIBOPS_PACKAGES_GCLOUD_PROJECT`
- `LIBOPS_PACKAGES_GCLOUD_REGION`
- `LIBOPS_PACKAGES_GSA`
- `LIBOPS_PACKAGES_GCS_BUCKET`
- `LIBOPS_PACKAGES_PACKAGE_REPO_URL`
- `LIBOPS_PACKAGES_APTLY_GPG_KEY_ID`
- `LIBOPS_PACKAGES_APTLY_GPG_PRIVATE_KEY_SECRET`
- `LIBOPS_PACKAGES_APTLY_GPG_PASSPHRASE_SECRET`

If `github_actors` is non-empty, the Workload Identity provider also restricts access to those actors. Every token must additionally contain a `job_workflow_ref` from `approved_job_workflow_refs`. The approved value includes the reusable workflow repository, file, and exact 40-character commit SHA; branch and tag identities are rejected. Repository, optional actor, and exact workflow identity must all match.

`libops/sitectl-isle` is intentionally absent from the default publisher allowlist until its v1 release. When the applied `github_repositories` value also omits it, the plan removes that repository's package-publisher WIF binding and managed Actions variables; it does not alter the repository itself.

### Rotating an approved publisher workflow

`approved_job_workflow_refs` must cover both active publication paths:

- `libops/terraform-linux-packages/.github/workflows/reusable-goreleaser.yaml@<sha>` for the direct core release workflow
- `libops/.github/.github/workflows/sitectl-plugin-goreleaser.yaml@<sha>` for the shared plugin release workflow

Workflow identity changes and WIF changes cannot be made atomically across repositories. Use this sequence so existing releases remain authorized without granting a mutable identity:

1. Merge the replacement reusable workflow and record its exact merge commit SHA.
2. Add its exact `job_workflow_ref` to `approved_job_workflow_refs` in the applied `terraform.tfvars`, alongside every currently active SHA.
3. Run `terraform plan` and verify that the Workload Identity provider condition adds only the intended exact identity, then apply.
4. Update direct or plugin caller workflows to pin the newly approved SHA and verify a package publication.
5. Remove the superseded workflow identity from `approved_job_workflow_refs` and apply again only after every caller has migrated.

For the shared plugin path, merge the shared workflow first, approve its resulting exact SHA here, and only then update plugin callers. This variable is required and intentionally has no Terraform default. The example values are migration anchors for the currently active direct and shared workflows; the applied `terraform.tfvars` must be updated after each workflow merge.

## Usage

1. Export credentials for both providers:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/admin-creds.json
export GITHUB_TOKEN=ghp_xxx
```

2. Review and copy the example variables:

```bash
cp terraform.tfvars.example terraform.tfvars
```

3. Initialize and apply:

```bash
terraform init
terraform plan
terraform apply
```

4. Add the Aptly GPG material out of band after Terraform creates the Secret Manager containers:

```bash
make create-aptly-gpg-key
make sync-aptly-gpg-key-id
```

`make create-aptly-gpg-key` prompts for the passphrase without echoing it and saves the revocation certificate under `.out/gpg/`.

5. Delegate the reported DNS name servers for the package subdomain, for example `packages.libops.io`, from the parent DNS zone.

## Publishing

This repo includes a local publishing path that uses the same validation and repository-building logic as GitHub Actions.

Prerequisites:

- `gh` authenticated for the source GitHub repository
- `docker`
- `gcloud` authenticated for Secret Manager and GCS on the host

By default the local targets use the published tooling image `ghcr.io/libops/terraform-linux-packages:main`.
To rebuild that image locally instead, run:

```bash
make package-tools-image-local
```

Example:

```bash
make package GITHUB_REPOSITORY=libops/sitectl PACKAGE_NAME=sitectl RELEASE_VERSION=v1.2.3
```

The rolling `sitectl` channel has a publisher-owned mandatory exclusion for `sitectl-isle` until its v1 release. Callers cannot disable that policy. Only the core `sitectl` channel owner may use `EXCLUDED_PACKAGE_NAMES` to request comma- or whitespace-separated canonical lowercase package names in addition to the mandatory policy; plugin publishers cannot remove other packages:

```bash
make package \
  GITHUB_REPOSITORY=libops/sitectl \
  PACKAGE_NAME=sitectl \
  RELEASE_VERSION=v1.2.3 \
  EXCLUDED_PACKAGE_NAMES="sitectl-preview"
```

Every publication validates the current package name and all current `.deb` and `.rpm` artifacts before using Google Cloud. An excluded current package or artifact fails closed. After the publisher acquires the channel lock, it synchronizes an exact local snapshot that deletes destination-only stage files, and the complete existing repository must sync successfully; a failed or partial sync stops publication before signing-key access or metadata upload. The exact snapshot prevents a local or retried run from resurrecting stale artifacts. The publisher removes excluded historical artifacts from the staged repository, rebuilds and uploads replacement APT/RPM metadata, and only then deletes the excluded GCS objects. Keeping the exclusion in every publication makes interrupted cleanup self-healing: later publications rediscover and retry any unreferenced object that was not deleted.

When invoked by the core channel owner, the reusable GoReleaser workflow accepts additional exclusions through its `excluded-package-names` input; plugin package names are rejected if they request any addition. GoReleaser runs in a job without OIDC permission. A dependent publication job checks out the exact commit that defines the called workflow, validates the mandatory policy, and builds a local package-tools image from that checkout before cloud authentication. Credentialed publication uses a direct environment-reading wrapper, verifies the unchanged local image ID, and never invokes GNU Make or pulls the mutable `main` image.

That target will:

- download the `.deb` and `.rpm` release assets with `gh`
- pull the published Linux tooling image if needed
- fetch the GPG key material from Secret Manager inside the container
- rebuild the Debian and RPM repository metadata inside the container
- sync package assets to the package bucket prefix for that package
- upload repository metadata with `Cache-Control: no-store` and invalidate the Cloud CDN cache for that package prefix

On macOS, this avoids needing native installs of `aptly` or `createrepo_c`.

To print or sync the signing key ID from Secret Manager:

```bash
make print-aptly-gpg-key-id
make sync-aptly-gpg-key-id
```

## Notes

- The managed SSL certificate will stay in provisioning until the delegated package subdomain resolves to the created load balancer IP.
- The bucket is public so `apt` and other package managers can fetch package metadata and artifacts without authentication.
- This stack grants the GitHub service account bucket-level `roles/storage.objectAdmin` for syncing package repositories and a custom role with `compute.urlMaps.get` and `compute.urlMaps.invalidateCache` for Cloud CDN invalidation.
- Cloud CDN uses origin cache headers. Package assets are uploaded as long-lived immutable objects, while mutable repository metadata is uploaded as `no-store`.
- Terraform creates the Secret Manager secret containers, but it does not write the private key or passphrase into Terraform state.

## libops setup

Below are the commands ran to get `packages.libops.io` setup using this repo

publish the latest version for our utils
```bash
terraform init
terraform apply
make create-aptly-gpg-key GCLOUD_PROJECT=libops-linux-packages
make sync-aptly-gpg-key-id
terraform apply
make package \
  GITHUB_REPOSITORY=libops/sitectl \
  PACKAGE_NAME=sitectl \
  RELEASE_VERSION=v0.10.1
make package \
  GITHUB_REPOSITORY=libops/sitectl-drupal \
  PACKAGE_NAME=sitectl-drupal \
  RELEASE_VERSION=v0.0.4
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.2.4 |
| <a name="requirement_github"></a> [github](#requirement\_github) | 6.12.1 |
| <a name="requirement_google"></a> [google](#requirement\_google) | 7.35.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_github.libops"></a> [github.libops](#provider\_github.libops) | 6.12.1 |
| <a name="provider_google"></a> [google](#provider\_google) | 7.35.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [github_actions_variable.aptly_gpg_key_id](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [github_actions_variable.aptly_gpg_passphrase_secret](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [github_actions_variable.aptly_gpg_private_key_secret](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [github_actions_variable.bucket](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [github_actions_variable.gsa](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [github_actions_variable.oidc](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [github_actions_variable.package_url](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [github_actions_variable.project](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [github_actions_variable.region](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/resources/actions_variable) | resource |
| [google_compute_backend_bucket.packages](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/compute_backend_bucket) | resource |
| [google_compute_global_address.packages](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/compute_global_address) | resource |
| [google_compute_global_forwarding_rule.packages_https](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/compute_global_forwarding_rule) | resource |
| [google_compute_managed_ssl_certificate.packages](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/compute_managed_ssl_certificate) | resource |
| [google_compute_target_https_proxy.packages](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/compute_target_https_proxy) | resource |
| [google_compute_url_map.packages](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/compute_url_map) | resource |
| [google_dns_managed_zone.packages](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/dns_managed_zone) | resource |
| [google_dns_record_set.packages_a](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/dns_record_set) | resource |
| [google_iam_workload_identity_pool.pool](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/iam_workload_identity_pool) | resource |
| [google_iam_workload_identity_pool_provider.github](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/iam_workload_identity_pool_provider) | resource |
| [google_project.project](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/project) | resource |
| [google_project_iam_custom_role.cdn_cache_invalidator](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/project_iam_custom_role) | resource |
| [google_project_iam_member.github_cdn_cache_invalidator](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/project_iam_member) | resource |
| [google_project_service.service](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/project_service) | resource |
| [google_secret_manager_secret.aptly_passphrase](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret.aptly_private_key](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/secret_manager_secret) | resource |
| [google_secret_manager_secret_iam_member.github_aptly_passphrase_accessor](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_secret_manager_secret_iam_member.github_aptly_private_key_accessor](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/secret_manager_secret_iam_member) | resource |
| [google_service_account.github](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/service_account) | resource |
| [google_service_account_iam_member.oidc_user](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/service_account_iam_member) | resource |
| [google_storage_bucket.packages](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/storage_bucket) | resource |
| [google_storage_bucket_iam_member.github_writer](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/storage_bucket_iam_member) | resource |
| [google_storage_bucket_iam_member.public_read](https://registry.terraform.io/providers/hashicorp/google/7.35.0/docs/resources/storage_bucket_iam_member) | resource |
| [github_repository.repo](https://registry.terraform.io/providers/integrations/github/6.12.1/docs/data-sources/repository) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_approved_job_workflow_refs"></a> [approved\_job\_workflow\_refs](#input\_approved\_job\_workflow\_refs) | Exact reusable-workflow identities allowed to publish packages. Keep active direct and shared workflow SHAs during migrations; branch and tag refs are rejected. | `set(string)` | n/a | yes |
| <a name="input_aptly_gpg_key_id"></a> [aptly\_gpg\_key\_id](#input\_aptly\_gpg\_key\_id) | GPG key ID Aptly uses to sign the published repository. | `string` | `""` | no |
| <a name="input_aptly_gpg_passphrase_secret_id"></a> [aptly\_gpg\_passphrase\_secret\_id](#input\_aptly\_gpg\_passphrase\_secret\_id) | Secret Manager secret ID that stores the Aptly GPG key passphrase. | `string` | `"aptly-gpg-passphrase"` | no |
| <a name="input_aptly_gpg_private_key_secret_id"></a> [aptly\_gpg\_private\_key\_secret\_id](#input\_aptly\_gpg\_private\_key\_secret\_id) | Secret Manager secret ID that stores the armored Aptly private key. | `string` | `"aptly-gpg-private-key"` | no |
| <a name="input_billing_account"></a> [billing\_account](#input\_billing\_account) | Google Cloud billing account ID. | `string` | n/a | yes |
| <a name="input_bucket_location"></a> [bucket\_location](#input\_bucket\_location) | Bucket location. | `string` | `"US"` | no |
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | Name of the public package bucket. | `string` | `"libops-linux-packages"` | no |
| <a name="input_dns_zone_dns_name"></a> [dns\_zone\_dns\_name](#input\_dns\_zone\_dns\_name) | DNS suffix managed by the zone, with trailing dot. | `string` | `"packages.libops.io."` | no |
| <a name="input_dns_zone_name"></a> [dns\_zone\_name](#input\_dns\_zone\_name) | Cloud DNS managed zone name. | `string` | `"packages-libops-io"` | no |
| <a name="input_github_actors"></a> [github\_actors](#input\_github\_actors) | Optional GitHub actors allowed to use the provider. Leave empty to allow any actor from the approved repositories. | `set(string)` | `[]` | no |
| <a name="input_github_owner"></a> [github\_owner](#input\_github\_owner) | GitHub organization that owns the repositories allowed to publish packages. | `string` | `"libops"` | no |
| <a name="input_github_repositories"></a> [github\_repositories](#input\_github\_repositories) | Full GitHub repository names allowed to impersonate the publishing service account. | `set(string)` | <pre>[<br/>  "libops/sitectl",<br/>  "libops/sitectl-app-tmpl",<br/>  "libops/sitectl-archivesspace",<br/>  "libops/sitectl-drupal",<br/>  "libops/sitectl-libops",<br/>  "libops/sitectl-ojs",<br/>  "libops/sitectl-omeka-classic",<br/>  "libops/sitectl-omeka-s",<br/>  "libops/sitectl-wp"<br/>]</pre> | no |
| <a name="input_org_id"></a> [org\_id](#input\_org\_id) | Google Cloud organization ID. | `string` | n/a | yes |
| <a name="input_package_domain"></a> [package\_domain](#input\_package\_domain) | Fully qualified domain name that will serve the package repository. | `string` | `"packages.libops.io"` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | Google Cloud project ID. | `string` | `"libops-linux-packages"` | no |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Google Cloud project display name. | `string` | `"libops-linux-packages"` | no |
| <a name="input_region"></a> [region](#input\_region) | Default Google Cloud region. | `string` | `"us-east5"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_aptly_gpg_passphrase_secret_id"></a> [aptly\_gpg\_passphrase\_secret\_id](#output\_aptly\_gpg\_passphrase\_secret\_id) | Secret Manager secret ID for the Aptly key passphrase. |
| <a name="output_aptly_gpg_private_key_secret_id"></a> [aptly\_gpg\_private\_key\_secret\_id](#output\_aptly\_gpg\_private\_key\_secret\_id) | Secret Manager secret ID for the armored Aptly private key. |
| <a name="output_bucket_name"></a> [bucket\_name](#output\_bucket\_name) | Package bucket name. |
| <a name="output_dns_name_servers"></a> [dns\_name\_servers](#output\_dns\_name\_servers) | Name servers assigned to the managed zone. Delegate the zone at your registrar or parent DNS. |
| <a name="output_github_service_account_email"></a> [github\_service\_account\_email](#output\_github\_service\_account\_email) | Service account email used by GitHub Actions. |
| <a name="output_package_url"></a> [package\_url](#output\_package\_url) | Public HTTPS package repository URL. |
| <a name="output_project_id"></a> [project\_id](#output\_project\_id) | Google Cloud project ID. |
| <a name="output_workload_identity_provider"></a> [workload\_identity\_provider](#output\_workload\_identity\_provider) | Full Workload Identity Provider resource name for GitHub Actions auth. |
<!-- END_TF_DOCS -->
