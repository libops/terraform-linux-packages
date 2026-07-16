#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/package-lock-env-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/dist" "$tmp/gcloud" "$tmp/stage"

cat >"$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
  exit 0
fi

if [ "${1:-}" != "run" ]; then
  printf 'Unexpected docker invocation: %s\n' "$*" >&2
  exit 1
fi

printf '%s\n' "$@" >"${MOCK_DOCKER_ARGS:?}"
MOCK
chmod +x "$tmp/bin/docker"

PATH="$tmp/bin:$PATH" \
MOCK_DOCKER_ARGS="$tmp/docker-args" \
make --no-print-directory -C "$repo_root" publish-package-repo \
  PACKAGE_NAME=sitectl-test \
  RELEASE_VERSION=v1.2.3 \
  GCLOUD_PROJECT=test-project \
  GCS_BUCKET=test-bucket \
  APTLY_GPG_KEY_ID=test-key \
  DIST_DIR="$tmp/dist" \
  PACKAGE_REPO_STAGE_DIR="$tmp/stage" \
  HOST_GCLOUD_CONFIG="$tmp/gcloud" \
  PACKAGE_TOOLS_IMAGE=test-image \
  LOCK_TIMEOUT_SECONDS=7200 \
  LOCK_STALE_SECONDS=900 \
  LOCK_POLL_SECONDS=7 \
  LOCK_HEARTBEAT_SECONDS=30

for expected in \
  LOCK_TIMEOUT_SECONDS=7200 \
  LOCK_STALE_SECONDS=900 \
  LOCK_POLL_SECONDS=7 \
  LOCK_HEARTBEAT_SECONDS=30 \
  EXCLUDED_PACKAGE_NAMES=; do
  if ! grep -Fxq "$expected" "$tmp/docker-args"; then
    printf 'Docker invocation did not forward %s\n' "$expected" >&2
    exit 1
  fi
done

injection_marker="$tmp/exclusion-input-was-executed"
if PATH="$tmp/bin:$PATH" \
  EXCLUDED_PACKAGE_NAMES="sitectl-isle\"; touch $injection_marker; #" \
  make --no-print-directory -C "$repo_root" validate-package-exclusions \
    PACKAGE_NAME=sitectl >"$tmp/invalid-exclusion.log" 2>&1; then
  printf 'Invalid Make exclusion input unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq "Invalid excluded package name" "$tmp/invalid-exclusion.log"
if [ -e "$injection_marker" ]; then
  printf 'Make exclusion input executed as shell code\n' >&2
  exit 1
fi
