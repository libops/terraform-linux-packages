#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${ROOT_DIR}/Dockerfile"
WORKFLOW="${ROOT_DIR}/.github/workflows/build-push.yaml"
SHARED_PUBLISHER_SHA="a86300fb8020d0f7141bb9f833d89b5dbd7aa4d7"

require_text() {
  local value="$1"
  if ! grep -Fq -- "$value" "$WORKFLOW"; then
    printf 'image workflow must contain: %s\n' "$value" >&2
    return 1
  fi
}

forbid_text() {
  local value="$1"
  if grep -Fq -- "$value" "$WORKFLOW"; then
    printf 'image workflow must not contain: %s\n' "$value" >&2
    return 1
  fi
}

require_text "pull_request:"
require_text "if: github.event_name == 'pull_request'"
require_text "if: github.ref == 'refs/heads/main'"
require_text "Build native image without credentials"
require_text "libops/.github/.github/workflows/build-push.yaml@${SHARED_PUBLISHER_SHA}"
require_text 'ref: ${{ github.sha }}'
require_text "expected-main-sha: \${{ github.ref == 'refs/heads/main' && github.sha || '' }}"
require_text "scan: true"
require_text "sign: true"
require_text "certificate-identity: https://github.com/libops/.github/.github/workflows/build-push.yaml@${SHARED_PUBLISHER_SHA}"
require_text "packages: write"
require_text "id-token: write"

forbid_text "build-push.yaml@main"
forbid_text "build-push-ghcr.yaml"
forbid_text "secrets: inherit"
forbid_text "docker-registry:"
forbid_text "additional-gar-registry:"

grep -Fq 'CLOUDSDK_STORAGE_USE_GCLOUD_CRC32C=false' "$DOCKERFILE"
grep -Fq 'cryptography==48.0.1' "$DOCKERFILE"
grep -Fq 'rm -f /usr/lib/google-cloud-sdk/bin/gcloud-crc32c' "$DOCKERFILE"
