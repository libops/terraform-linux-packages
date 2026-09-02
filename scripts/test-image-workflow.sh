#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${ROOT_DIR}/Dockerfile"
WORKFLOW="${ROOT_DIR}/.github/workflows/build-push.yaml"

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
require_text "libops/.github/.github/workflows/build-push.yaml@main"
require_text 'ref: ${{ github.sha }}'
require_text "expected-main-sha: \${{ github.ref == 'refs/heads/main' && github.sha || '' }}"
require_text "sign: true"
require_text "packages: write"
require_text "id-token: write"

forbid_text "certificate-identity:"
forbid_text "build-push-ghcr.yaml"
forbid_text "secrets: inherit"
forbid_text "docker-registry:"
forbid_text "additional-gar-registry:"

if grep -Eq 'uses: libops/[^@[:space:]]+@[0-9a-fA-F]{40}' "$WORKFLOW"; then
  printf 'LibOps-owned workflow must use a managed branch or release channel\n' >&2
  exit 1
fi

grep -Fq 'CLOUDSDK_STORAGE_USE_GCLOUD_CRC32C=false' "$DOCKERFILE"
grep -Fq 'cryptography==50.0.0' "$DOCKERFILE"
grep -Fq 'msgpack==1.2.1' "$DOCKERFILE"
grep -Fq 'pyopenssl==26.4.0' "$DOCKERFILE"
grep -Fq 'setuptools==80.10.2' "$DOCKERFILE"
grep -Fq 'FROM scratch' "$DOCKERFILE"
grep -Fq 'COPY --from=build / /' "$DOCKERFILE"
grep -Fq 'python3 -m pip check' "$DOCKERFILE"
grep -Fq 'python3 -m pip uninstall --yes pip setuptools' "$DOCKERFILE"
grep -Fq 'gcloud storage --help' "$DOCKERFILE"
grep -Fq 'rm -f /usr/lib/google-cloud-sdk/bin/gcloud-crc32c' "$DOCKERFILE"
