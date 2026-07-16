#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# shellcheck source=package-exclusions.sh
source "$script_dir/package-exclusions.sh"

require_nonempty() {
  local name="$1"
  local value="${!name:-}"

  if [ -z "$value" ]; then
    printf '%s is required\n' "$name" >&2
    return 1
  fi
}

require_single_line() {
  local name="$1"
  local value="${!name:-}"

  require_nonempty "$name"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    printf '%s must be a single-line value\n' "$name" >&2
    return 1
  fi
}

require_uint() {
  local name="$1"
  local value="${!name:-}"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf '%s must be an unsigned integer\n' "$name" >&2
    return 1
  fi
}

require_single_line GITHUB_REPOSITORY
if [[ ! "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  printf 'GITHUB_REPOSITORY must be an owner/repository name\n' >&2
  exit 1
fi

prepare_package_exclusions
if [ "${GITHUB_REPOSITORY##*/}" != "$PACKAGE_NAME" ]; then
  printf 'PACKAGE_NAME must match the source repository name for credentialed publication\n' >&2
  exit 1
fi

require_single_line RELEASE_VERSION
if [[ ! "$RELEASE_VERSION" =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][A-Za-z0-9._+-]+)?$ ]]; then
  printf 'RELEASE_VERSION must be an exact semantic version\n' >&2
  exit 1
fi

for required_name in \
  GCLOUD_PROJECT \
  GCS_BUCKET \
  GCS_BUCKET_PREFIX \
  APTLY_GPG_KEY_ID \
  APTLY_GPG_PRIVATE_KEY_SECRET \
  APTLY_GPG_PASSPHRASE_SECRET \
  APTLY_LABEL \
  APTLY_PUBLIC_KEY_NAME \
  PACKAGE_TOOLS_IMAGE \
  EXPECTED_PACKAGE_TOOLS_IMAGE_ID \
  PACKAGE_PUBLISHER_SHA; do
  require_single_line "$required_name"
done

if [[ ! "$GCS_BUCKET_PREFIX" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]; then
  printf 'GCS_BUCKET_PREFIX must be a repository-relative object prefix\n' >&2
  exit 1
fi
IFS='/' read -r -a bucket_prefix_segments <<<"$GCS_BUCKET_PREFIX"
for bucket_prefix_segment in "${bucket_prefix_segments[@]}"; do
  if [ "$bucket_prefix_segment" = "." ] || [ "$bucket_prefix_segment" = ".." ]; then
    printf 'GCS_BUCKET_PREFIX must not contain dot path segments\n' >&2
    exit 1
  fi
done
if [[ ! "$APTLY_PUBLIC_KEY_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  printf 'APTLY_PUBLIC_KEY_NAME must be a canonical file stem\n' >&2
  exit 1
fi
if [[ ! "$APTLY_GPG_PRIVATE_KEY_SECRET" =~ ^[A-Za-z0-9_-]+$ ]] ||
  [[ ! "$APTLY_GPG_PASSPHRASE_SECRET" =~ ^[A-Za-z0-9_-]+$ ]]; then
  printf 'Aptly Secret Manager IDs must contain only letters, numbers, underscores, and hyphens\n' >&2
  exit 1
fi
if [[ ! "$PACKAGE_PUBLISHER_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'PACKAGE_PUBLISHER_SHA must be an exact lowercase 40-character commit SHA\n' >&2
  exit 1
fi

expected_package_tools_image="libops/terraform-linux-packages:publisher-${PACKAGE_PUBLISHER_SHA}"
if [ "$PACKAGE_TOOLS_IMAGE" != "$expected_package_tools_image" ]; then
  printf 'Credentialed publication requires the exact local package-tools image %s\n' \
    "$expected_package_tools_image" >&2
  exit 1
fi
if [[ ! "$EXPECTED_PACKAGE_TOOLS_IMAGE_ID" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf 'EXPECTED_PACKAGE_TOOLS_IMAGE_ID must be an exact sha256 image ID\n' >&2
  exit 1
fi

actual_package_tools_image_id="$(
  docker image inspect --format '{{.Id}}' "$PACKAGE_TOOLS_IMAGE"
)"
if [ "$actual_package_tools_image_id" != "$EXPECTED_PACKAGE_TOOLS_IMAGE_ID" ]; then
  printf 'Local package-tools image ID changed: expected %s, got %s\n' \
    "$EXPECTED_PACKAGE_TOOLS_IMAGE_ID" "$actual_package_tools_image_id" >&2
  exit 1
fi

LOCK_TIMEOUT_SECONDS="${LOCK_TIMEOUT_SECONDS:-7200}"
LOCK_STALE_SECONDS="${LOCK_STALE_SECONDS:-600}"
LOCK_POLL_SECONDS="${LOCK_POLL_SECONDS:-5}"
LOCK_HEARTBEAT_SECONDS="${LOCK_HEARTBEAT_SECONDS:-60}"
for integer_name in \
  LOCK_TIMEOUT_SECONDS \
  LOCK_STALE_SECONDS \
  LOCK_POLL_SECONDS \
  LOCK_HEARTBEAT_SECONDS; do
  require_uint "$integer_name"
done

DIST_DIR="${DIST_DIR:-$repo_root/.dist/$PACKAGE_NAME/$RELEASE_VERSION}"
PACKAGE_REPO_STAGE_DIR="$(
  realpath -m "${PACKAGE_REPO_STAGE_DIR:-$repo_root/.out/$PACKAGE_NAME/$RELEASE_VERSION}"
)"
DIST_DIR="$(realpath -m "$DIST_DIR")"

case "$DIST_DIR" in
  "$repo_root"/*) ;;
  *)
    printf 'DIST_DIR must resolve inside the exact publisher checkout\n' >&2
    exit 1
    ;;
esac
case "$PACKAGE_REPO_STAGE_DIR" in
  "$repo_root"/*) ;;
  *)
    printf 'PACKAGE_REPO_STAGE_DIR must resolve inside the exact publisher checkout\n' >&2
    exit 1
    ;;
esac

mkdir -p "$DIST_DIR" "$PACKAGE_REPO_STAGE_DIR"

GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
RELEASE_VERSION="$RELEASE_VERSION" \
DIST_DIR="$DIST_DIR" \
PACKAGE_NAME="$PACKAGE_NAME" \
  /bin/bash "$script_dir/download-release-assets.sh"

credential_file="${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-${GOOGLE_APPLICATION_CREDENTIALS:-}}"
if [ -z "$credential_file" ] || [ ! -f "$credential_file" ]; then
  printf 'Credentialed publication requires an existing Google credential file\n' >&2
  exit 1
fi
credential_file="$(realpath -e "$credential_file")"

docker_args=(
  run
  --rm
  --volume "$repo_root:/workspace/terraform-linux-packages:ro"
  --volume "$DIST_DIR:$DIST_DIR:ro"
  --volume "$PACKAGE_REPO_STAGE_DIR:$PACKAGE_REPO_STAGE_DIR"
  --volume "$credential_file:$credential_file:ro"
  --env "GOOGLE_APPLICATION_CREDENTIALS=$credential_file"
  --env "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=$credential_file"
  --env "GCLOUD_PROJECT=$GCLOUD_PROJECT"
  --env "GCS_BUCKET=$GCS_BUCKET"
  --env "GCS_BUCKET_PREFIX=$GCS_BUCKET_PREFIX"
  --env "DIST_DIR=$DIST_DIR"
  --env "PACKAGE_NAME=$PACKAGE_NAME"
  --env "APTLY_GPG_KEY_ID=$APTLY_GPG_KEY_ID"
  --env "APTLY_GPG_PRIVATE_KEY_SECRET=$APTLY_GPG_PRIVATE_KEY_SECRET"
  --env "APTLY_GPG_PASSPHRASE_SECRET=$APTLY_GPG_PASSPHRASE_SECRET"
  --env "APTLY_LABEL=$APTLY_LABEL"
  --env "APTLY_PUBLIC_KEY_NAME=$APTLY_PUBLIC_KEY_NAME"
  --env "LOCK_TIMEOUT_SECONDS=$LOCK_TIMEOUT_SECONDS"
  --env "LOCK_STALE_SECONDS=$LOCK_STALE_SECONDS"
  --env "LOCK_POLL_SECONDS=$LOCK_POLL_SECONDS"
  --env "LOCK_HEARTBEAT_SECONDS=$LOCK_HEARTBEAT_SECONDS"
  --env "EXCLUDED_PACKAGE_NAMES=${EXCLUDED_PACKAGE_NAMES:-}"
  --env "PACKAGE_REPO_STAGE_DIR=$PACKAGE_REPO_STAGE_DIR"
  "$PACKAGE_TOOLS_IMAGE"
  /bin/bash
  /workspace/terraform-linux-packages/scripts/publish-package-repo.sh
)

docker "${docker_args[@]}"
