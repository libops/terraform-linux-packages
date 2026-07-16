#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

for allowlist_file in "$repo_root/variables.tf" "$repo_root/terraform.tfvars.example"; do
  if grep -Fq '"libops/sitectl-isle"' "$allowlist_file"; then
    printf 'Pre-v1 sitectl-isle must not be in the package-publisher allowlist: %s\n' \
      "$allowlist_file" >&2
    exit 1
  fi
  grep -Fq '"libops/sitectl"' "$allowlist_file"
done
