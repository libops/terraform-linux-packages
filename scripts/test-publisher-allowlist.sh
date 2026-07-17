#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

for allowlist_file in "$repo_root/variables.tf" "$repo_root/terraform.tfvars.example"; do
  grep -Fq '"libops/sitectl"' "$allowlist_file"
  grep -Fq '"libops/sitectl-isle"' "$allowlist_file"
done
