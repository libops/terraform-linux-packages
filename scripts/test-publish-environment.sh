#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/package-publish-environment-test.XXXXXX")"
publisher_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
image="libops/terraform-linux-packages:publisher-${publisher_sha}"
image_id="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
dist_dir="$repo_root/.dist/publish-environment-test/v1.2.3"
stage_dir="$repo_root/.out/publish-environment-test/v1.2.3"
trap 'rm -rf "$tmp" "$dist_dir" "$stage_dir"' EXIT

mkdir -p "$tmp/bin"
printf 'test credentials\n' >"$tmp/google-credentials.json"

cat >"$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

download_dir=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--dir" ]; then
    download_dir="$2"
    shift 2
    continue
  fi
  shift
done
test -n "$download_dir"
mkdir -p "$download_dir"
printf 'mock deb\n' >"$download_dir/sitectl_1.2.3_amd64.deb"
printf 'mock rpm\n' >"$download_dir/sitectl-1.2.3-1.x86_64.rpm"
MOCK

cat >"$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

case "${1:-} ${2:-}" in
  "image inspect")
    printf '%s\n' "${MOCK_IMAGE_ID:?}"
    ;;
  "run --rm")
    printf '%s\n' "$@" >"${MOCK_DOCKER_ARGS:?}"
    ;;
  *)
    printf 'Unexpected docker invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$tmp/bin/gh" "$tmp/bin/docker"

marker="$tmp/make-function-executed"
injected_label="\$(shell touch $marker)"
PATH="$tmp/bin:$PATH" \
MOCK_IMAGE_ID="$image_id" \
MOCK_DOCKER_ARGS="$tmp/docker-args" \
GITHUB_REPOSITORY=libops/sitectl \
PACKAGE_NAME=sitectl \
RELEASE_VERSION=v1.2.3 \
GCLOUD_PROJECT=test-project \
GCS_BUCKET=test-bucket \
GCS_BUCKET_PREFIX=sitectl \
APTLY_GPG_KEY_ID=test-key \
APTLY_GPG_PRIVATE_KEY_SECRET=aptly-gpg-private-key \
APTLY_GPG_PASSPHRASE_SECRET=aptly-gpg-passphrase \
APTLY_LABEL="$injected_label" \
APTLY_PUBLIC_KEY_NAME=sitectl-archive-keyring \
EXCLUDED_PACKAGE_NAMES=sitectl-preview \
LOCK_TIMEOUT_SECONDS=7200 \
DIST_DIR="$dist_dir" \
PACKAGE_REPO_STAGE_DIR="$stage_dir" \
PACKAGE_TOOLS_IMAGE="$image" \
EXPECTED_PACKAGE_TOOLS_IMAGE_ID="$image_id" \
PACKAGE_PUBLISHER_SHA="$publisher_sha" \
CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$tmp/google-credentials.json" \
  bash "$repo_root/scripts/publish-release-from-environment.sh"

if [ -e "$marker" ]; then
  printf 'Caller-controlled environment input executed as a GNU Make function\n' >&2
  exit 1
fi
grep -Fxq "APTLY_LABEL=$injected_label" "$tmp/docker-args"
grep -Fxq "EXCLUDED_PACKAGE_NAMES=sitectl-preview" "$tmp/docker-args"
if grep -Fxq "pull" "$tmp/docker-args"; then
  printf 'Credentialed publication attempted to pull a mutable package-tools image\n' >&2
  exit 1
fi

if PATH="$tmp/bin:$PATH" \
  MOCK_IMAGE_ID="$image_id" \
  GITHUB_REPOSITORY=libops/sitectl \
  PACKAGE_NAME=sitectl \
  RELEASE_VERSION=v1.2.3 \
  GCLOUD_PROJECT=test-project \
  GCS_BUCKET=test-bucket \
  GCS_BUCKET_PREFIX=sitectl \
  APTLY_GPG_KEY_ID=test-key \
  APTLY_GPG_PRIVATE_KEY_SECRET=aptly-gpg-private-key \
  APTLY_GPG_PASSPHRASE_SECRET=aptly-gpg-passphrase \
  APTLY_LABEL=sitectl \
  APTLY_PUBLIC_KEY_NAME=sitectl-archive-keyring \
  PACKAGE_TOOLS_IMAGE=ghcr.io/libops/terraform-linux-packages:main \
  EXPECTED_PACKAGE_TOOLS_IMAGE_ID="$image_id" \
  PACKAGE_PUBLISHER_SHA="$publisher_sha" \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$tmp/google-credentials.json" \
  bash "$repo_root/scripts/publish-release-from-environment.sh" \
    >"$tmp/mutable-image.log" 2>&1; then
  printf 'Mutable package-tools image unexpectedly passed exact-image validation\n' >&2
  exit 1
fi
grep -Fq "requires the exact local package-tools image" "$tmp/mutable-image.log"

wrong_image_id="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
if PATH="$tmp/bin:$PATH" \
  MOCK_IMAGE_ID="$wrong_image_id" \
  GITHUB_REPOSITORY=libops/sitectl \
  PACKAGE_NAME=sitectl \
  RELEASE_VERSION=v1.2.3 \
  GCLOUD_PROJECT=test-project \
  GCS_BUCKET=test-bucket \
  GCS_BUCKET_PREFIX=sitectl \
  APTLY_GPG_KEY_ID=test-key \
  APTLY_GPG_PRIVATE_KEY_SECRET=aptly-gpg-private-key \
  APTLY_GPG_PASSPHRASE_SECRET=aptly-gpg-passphrase \
  APTLY_LABEL=sitectl \
  APTLY_PUBLIC_KEY_NAME=sitectl-archive-keyring \
  PACKAGE_TOOLS_IMAGE="$image" \
  EXPECTED_PACKAGE_TOOLS_IMAGE_ID="$image_id" \
  PACKAGE_PUBLISHER_SHA="$publisher_sha" \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$tmp/google-credentials.json" \
  bash "$repo_root/scripts/publish-release-from-environment.sh" \
    >"$tmp/image-id.log" 2>&1; then
  printf 'Changed local package-tools image ID unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq "Local package-tools image ID changed" "$tmp/image-id.log"

if PATH="$tmp/bin:$PATH" \
  MOCK_IMAGE_ID="$image_id" \
  GITHUB_REPOSITORY=libops/sitectl-drupal \
  PACKAGE_NAME=sitectl \
  RELEASE_VERSION=v1.2.3 \
  GCLOUD_PROJECT=test-project \
  GCS_BUCKET=test-bucket \
  GCS_BUCKET_PREFIX=sitectl \
  APTLY_GPG_KEY_ID=test-key \
  APTLY_GPG_PRIVATE_KEY_SECRET=aptly-gpg-private-key \
  APTLY_GPG_PASSPHRASE_SECRET=aptly-gpg-passphrase \
  APTLY_LABEL=sitectl \
  APTLY_PUBLIC_KEY_NAME=sitectl-archive-keyring \
  PACKAGE_TOOLS_IMAGE="$image" \
  EXPECTED_PACKAGE_TOOLS_IMAGE_ID="$image_id" \
  PACKAGE_PUBLISHER_SHA="$publisher_sha" \
  CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$tmp/google-credentials.json" \
  bash "$repo_root/scripts/publish-release-from-environment.sh" \
    >"$tmp/repository-mismatch.log" 2>&1; then
  printf 'Mismatched package and source repository unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq "PACKAGE_NAME must match the source repository name" "$tmp/repository-mismatch.log"
