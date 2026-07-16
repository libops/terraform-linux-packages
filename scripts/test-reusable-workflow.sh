#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/reusable-goreleaser.yaml"

require_text() {
  local text="$1"
  if ! grep -Fq -- "$text" "$workflow"; then
    printf 'Reusable release workflow must contain: %s\n' "$text" >&2
    return 1
  fi
}

forbid_text() {
  local text="$1"
  if grep -Fq -- "$text" "$workflow"; then
    printf 'Reusable release workflow must not contain: %s\n' "$text" >&2
    return 1
  fi
}

require_text "excluded-package-names:"
require_text 'default: ""'
require_text "permissions: {}"
require_text "publish-linux-packages:"
require_text "needs: goreleaser"
require_text 'repository: ${{ job.workflow_repository }}'
require_text 'ref: ${{ job.workflow_sha }}'
require_text 'EXCLUDED_PACKAGE_NAMES: ${{ inputs.excluded-package-names }}'
require_text 'PACKAGE_NAME: ${{ inputs.package-name }}'
require_text 'GCS_BUCKET_PREFIX: ${{ inputs.package-repo-prefix }}'
require_text "run: bash scripts/validate-package-exclusions.sh"
require_text "name: Build exact package tools image"
require_text 'PACKAGE_PUBLISHER_SHA: ${{ job.workflow_sha }}'
require_text 'image="libops/terraform-linux-packages:publisher-${PACKAGE_PUBLISHER_SHA}"'
require_text 'docker build --tag "$image" .'
require_text 'EXPECTED_PACKAGE_TOOLS_IMAGE_ID: ${{ steps.package-tools.outputs.image-id }}'
require_text "run: bash scripts/publish-release-from-environment.sh"
require_text "persist-credentials: false"

forbid_text "ref: 72d2f0c3b01e5e396d6db074108b95e95eedf4d4"
forbid_text "ref: main"
forbid_text "make package"
forbid_text "terraform-linux-packages:main"
forbid_text "docker pull"

goreleaser_line="$(grep -n 'name: Run GoReleaser' "$workflow" | cut -d: -f1)"
checkout_line="$(grep -n 'name: Checkout Package Publisher' "$workflow" | cut -d: -f1)"
validation_line="$(grep -n 'name: Validate Linux package exclusions' "$workflow" | cut -d: -f1)"
build_line="$(grep -n 'name: Build exact package tools image' "$workflow" | cut -d: -f1)"
auth_line="$(grep -n 'name: Authenticate to Google Cloud' "$workflow" | cut -d: -f1)"
publish_line="$(grep -n 'name: Publish Linux package repository' "$workflow" | cut -d: -f1)"
if [ "$goreleaser_line" -ge "$checkout_line" ] ||
  [ "$checkout_line" -ge "$validation_line" ] ||
  [ "$validation_line" -ge "$build_line" ] ||
  [ "$build_line" -ge "$auth_line" ] ||
  [ "$auth_line" -ge "$publish_line" ]; then
  printf 'Exact publisher checkout, validation, and image build must run after GoReleaser and before cloud authentication\n' >&2
  exit 1
fi

goreleaser_job="$(
  sed -n '/^  goreleaser:/,/^  publish-linux-packages:/p' "$workflow"
)"
if grep -Fq "id-token: write" <<<"$goreleaser_job"; then
  printf 'Caller-controlled GoReleaser job must not receive OIDC token permission\n' >&2
  exit 1
fi
publisher_job="$(
  sed -n '/^  publish-linux-packages:/,$p' "$workflow"
)"
grep -Fq "contents: read" <<<"$publisher_job"
grep -Fq "id-token: write" <<<"$publisher_job"
