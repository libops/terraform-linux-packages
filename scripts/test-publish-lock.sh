#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/package-lock-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/dist" "$tmp/stage"
state_file="$tmp/cp-count"
printf '0\n' >"$state_file"

cat >"$tmp/bin/gcloud" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

state_file="${MOCK_GCLOUD_STATE:?}"
case "$*" in
  "storage cp - gs://test-bucket/sitectl/.publish.lock --if-generation-match=0")
    count="$(cat "$state_file")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$state_file"
    if [ "$count" -eq 1 ]; then
      echo "ERROR: (gcloud.storage.cp) HTTPError 412: At least one of the pre-conditions you specified did not hold." >&2
      exit 1
    fi
    ;;
  "storage objects describe gs://test-bucket/sitectl/.publish.lock --format=value(generation,update_time)")
    if [ "$(cat "$state_file")" -ge 2 ]; then
      printf '12345\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S+0000)"
    fi
    ;;
  "storage rsync --recursive --delete-unmatched-destination-objects gs://test-bucket/sitectl "*)
    ;;
  "storage rm gs://test-bucket/sitectl/.publish.lock --if-generation-match=12345")
    ;;
  *)
    echo "Unexpected gcloud invocation: $*" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$tmp/bin/gcloud"

log="$tmp/publisher.log"
if PATH="$tmp/bin:$PATH" \
  MOCK_GCLOUD_STATE="$state_file" \
  DIST_DIR="$tmp/dist" \
  GCLOUD_PROJECT=test-project \
  GCS_BUCKET=test-bucket \
  GCS_BUCKET_PREFIX=sitectl \
  PACKAGE_NAME=sitectl-test \
  PACKAGE_REPO_STAGE_DIR="$tmp/stage" \
  APTLY_GPG_KEY_ID=test-key \
  LOCK_POLL_SECONDS=0 \
  LOCK_HEARTBEAT_SECONDS=0 \
  LOCK_TIMEOUT_SECONDS=10 \
  bash "$repo_root/scripts/publish-package-repo.sh" >"$log" 2>&1; then
  echo "Lock regression fixture unexpectedly published an empty repository" >&2
  exit 1
fi

grep -Fq "Publish lock changed during acquisition" "$log"
grep -Fq "Acquired publish lock generation 12345" "$log"
grep -Fq "No .deb or .rpm packages found" "$log"
if grep -Fq "Unable to create or inspect publish lock" "$log"; then
  cat "$log" >&2
  exit 1
fi
test "$(cat "$state_file")" = "2"
