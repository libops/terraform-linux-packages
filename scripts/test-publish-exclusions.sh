#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/package-publish-rolling-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/dist" "$tmp/stage"
printf 'current rpm package\n' >"$tmp/dist/sitectl-1.0.0-1.x86_64.rpm"
printf 'stale local state\n' >"$tmp/stage/stale-0.1.0.rpm"

cat >"$tmp/bin/gcloud" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "$@" >>"${MOCK_GCLOUD_LOG:?}"
printf '\n' >>"$MOCK_GCLOUD_LOG"
case "$*" in
  "storage cp - gs://test-bucket/sitectl/.publish.lock --if-generation-match=0") cat >/dev/null ;;
  "storage objects describe gs://test-bucket/sitectl/.publish.lock --format=value(generation,update_time)")
    printf '12345\t2026-01-01T00:00:00+0000\n' ;;
  "storage rsync --recursive --checksums-only gs://test-bucket/sitectl "*)
    stage_dir="$6"
    find "$stage_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    printf 'previous core rpm\n' >"$stage_dir/sitectl-0.9.0-1.x86_64.rpm"
    printf 'current plugin rpm\n' >"$stage_dir/sitectl-drupal-x86_64.rpm"
    ;;
  "storage rsync --recursive --checksums-only --cache-control="*)
    asset_dir="$6"
    find "$asset_dir" -type f -printf 'ASSET %P\n' >>"$MOCK_GCLOUD_LOG"
    ;;
  "storage rsync --recursive --checksums-only --delete-unmatched-destination-objects --exclude="*)
    stage_dir="$7"
    find "$stage_dir" -type f -printf 'MIRROR %P\n' >>"$MOCK_GCLOUD_LOG"
    ;;
  "storage cp --cache-control="*) ;;
  "secrets versions access latest "*) printf 'test secret\n' ;;
  "storage rm gs://test-bucket/sitectl/.publish.lock --if-generation-match=12345") ;;
  *) printf 'Unexpected gcloud invocation: %s\n' "$*" >&2; exit 1 ;;
esac
MOCK

cat >"$tmp/bin/rpm" <<'MOCK'
#!/usr/bin/env bash
case "${*: -1}" in
  *sitectl-isle-*) printf 'sitectl-isle\n' ;;
  *sitectl-drupal-*) printf 'sitectl-drupal\n' ;;
  *) printf 'sitectl\n' ;;
esac
MOCK

cat >"$tmp/bin/gpg" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output="$2"; shift 2; else shift; fi
done
if [ -n "$output" ]; then printf 'signature\n' >"$output"; else printf 'public key\n'; fi
MOCK

cat >"$tmp/bin/createrepo_c" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
repository_dir="${*: -1}"
mkdir -p "$repository_dir/repodata"
find "$repository_dir" -maxdepth 1 -name '*.rpm' -printf '%f\n' >"$repository_dir/repodata/primary.xml"
printf 'repository metadata\n' >"$repository_dir/repodata/repomd.xml"
MOCK
chmod +x "$tmp/bin/"*

gcloud_log="$tmp/gcloud.log"
PATH="$tmp/bin:$PATH" \
  MOCK_GCLOUD_LOG="$gcloud_log" \
  DIST_DIR="$tmp/dist" \
  GCLOUD_PROJECT=test-project \
  GCS_BUCKET=test-bucket \
  GCS_BUCKET_PREFIX=sitectl \
  PACKAGE_NAME=sitectl \
  PACKAGE_REPO_STAGE_DIR="$tmp/stage" \
  APTLY_GPG_KEY_ID=test-key \
  CDN_INVALIDATE_CACHE=false \
  LOCK_HEARTBEAT_SECONDS=0 \
  bash "$repo_root/scripts/publish-package-repo.sh"

grep -Fq 'ASSET sitectl-x86_64.rpm' "$gcloud_log"
grep -Fq 'ASSET sitectl-drupal-x86_64.rpm' "$gcloud_log"
grep -Fq 'ASSET rpm/sitectl-x86_64.rpm' "$gcloud_log"
grep -Fq 'ASSET rpm/sitectl-drupal-x86_64.rpm' "$gcloud_log"
if grep -Fq 'stale-0.1.0.rpm' "$gcloud_log"; then
  printf 'Stale local state reached the rolling publication\n' >&2
  exit 1
fi
if grep -Fq 'MIRROR sitectl-0.9.0-1.x86_64.rpm' "$gcloud_log"; then
  printf 'Superseded core package survived the rolling publication\n' >&2
  exit 1
fi
grep -Fq 'storage rsync --recursive --checksums-only gs://test-bucket/sitectl' "$gcloud_log"
grep -Fq 'storage rsync --recursive --checksums-only --delete-unmatched-destination-objects' "$gcloud_log"

mkdir -p "$tmp/rejected-dist" "$tmp/rejected-stage"
printf 'excluded artifact\n' >"$tmp/rejected-dist/sitectl-isle-1.0.0-1.x86_64.rpm"
: >"$tmp/rejected-gcloud.log"
if PATH="$tmp/bin:$PATH" \
  MOCK_GCLOUD_LOG="$tmp/rejected-gcloud.log" \
  DIST_DIR="$tmp/rejected-dist" \
  GCLOUD_PROJECT=test-project \
  GCS_BUCKET=test-bucket \
  GCS_BUCKET_PREFIX=sitectl \
  PACKAGE_NAME=sitectl \
  EXCLUDED_PACKAGE_NAMES=sitectl-isle \
  PACKAGE_REPO_STAGE_DIR="$tmp/rejected-stage" \
  APTLY_GPG_KEY_ID=test-key \
  LOCK_HEARTBEAT_SECONDS=0 \
  bash "$repo_root/scripts/publish-package-repo.sh"; then
  printf 'Excluded current release artifact unexpectedly reached publication\n' >&2
  exit 1
fi
test ! -s "$tmp/rejected-gcloud.log"
