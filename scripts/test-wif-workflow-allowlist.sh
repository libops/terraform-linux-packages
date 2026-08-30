#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
main_tf="$repo_root/main.tf"
variables_tf="$repo_root/variables.tf"
tfvars_example="$repo_root/terraform.tfvars.example"

for terraform_file in "$tfvars_example"; do
  grep -Fq \
    "libops/terraform-linux-packages/.github/workflows/reusable-goreleaser.yaml@refs/heads/main" \
    "$terraform_file"
  grep -Fq \
    "libops/.github/.github/workflows/sitectl-plugin-goreleaser.yaml@refs/heads/main" \
    "$terraform_file"
  if grep -Eq 'workflows/(reusable-goreleaser|sitectl-plugin-goreleaser)[.]ya?ml@[0-9a-f]{40}' "$terraform_file"; then
    printf 'Package publisher WIF allowlist must not copy a LibOps workflow commit: %s\n' \
      "$terraform_file" >&2
    exit 1
  fi
done

approved_variable_block="$(
  sed -n '/^variable "approved_job_workflow_refs"/,/^}/p' "$variables_tf"
)"
if grep -Eq '^[[:space:]]*default[[:space:]]*=' <<<"$approved_variable_block"; then
  printf 'Managed package publisher workflow identities must be explicitly supplied\n' >&2
  exit 1
fi
grep -Fq 'length(var.approved_job_workflow_refs) > 0' <<<"$approved_variable_block"

grep -Fq '"attribute.job_workflow_ref" = "assertion.job_workflow_ref"' "$main_tf"
grep -Fq "assertion.job_workflow_ref == '\${workflow_ref}'" "$main_tf"
grep -Fq \
  'provider_attribute_condition = "${local.repository_condition} && ${local.actor_condition} && ${local.job_workflow_ref_condition}"' \
  "$main_tf"
