#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

: "${DIST_DIR:?DIST_DIR is required}"
: "${GCLOUD_PROJECT:?GCLOUD_PROJECT is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"
: "${APTLY_GPG_KEY_ID:?APTLY_GPG_KEY_ID is required}"

PACKAGE_NAME="${PACKAGE_NAME:-${GITHUB_REPOSITORY:-}}"
PACKAGE_NAME="${PACKAGE_NAME##*/}"
APTLY_DISTRIBUTIONS="${APTLY_DISTRIBUTIONS:-bookworm}"
APTLY_COMPONENT="${APTLY_COMPONENT:-main}"
APTLY_ARCHITECTURES="${APTLY_ARCHITECTURES:-amd64,arm64}"
APTLY_PUBLISH_PREFIX="${APTLY_PUBLISH_PREFIX:-.}"
APTLY_ORIGIN="${APTLY_ORIGIN:-libops}"
APTLY_LABEL="${APTLY_LABEL:-$PACKAGE_NAME}"
APTLY_PUBLIC_KEY_NAME="${APTLY_PUBLIC_KEY_NAME:-${PACKAGE_NAME}-archive-keyring}"
APTLY_GPG_PRIVATE_KEY_SECRET="${APTLY_GPG_PRIVATE_KEY_SECRET:-aptly-gpg-private-key}"
APTLY_GPG_PASSPHRASE_SECRET="${APTLY_GPG_PASSPHRASE_SECRET:-aptly-gpg-passphrase}"
RPM_REPOSITORY_PATH="${RPM_REPOSITORY_PATH:-rpm}"
PACKAGE_REPO_STAGE_DIR="${PACKAGE_REPO_STAGE_DIR:-$(mktemp -d)}"
APTLY_ROOT_DIR="${APTLY_ROOT_DIR:-$(mktemp -d)}"
GNUPGHOME="${GNUPGHOME:-$(mktemp -d)}"
MERGED_DIST_DIR="$(mktemp -d)"
LOCK_TIMEOUT_SECONDS="${LOCK_TIMEOUT_SECONDS:-600}"
LOCK_POLL_SECONDS="${LOCK_POLL_SECONDS:-5}"
LOCK_OWNER="${LOCK_OWNER:-$(hostname)-$$-$(date -u +%s)}"

cleanup() {
  release_lock
  if [[ "${PACKAGE_REPO_STAGE_DIR}" == /tmp/* ]]; then
    rm -rf "$PACKAGE_REPO_STAGE_DIR"
  fi
  if [[ "${APTLY_ROOT_DIR}" == /tmp/* ]]; then
    rm -rf "$APTLY_ROOT_DIR"
  fi
  if [[ "${GNUPGHOME}" == /tmp/* ]]; then
    rm -rf "$GNUPGHOME"
  fi
  if [[ "${MERGED_DIST_DIR}" == /tmp/* ]]; then
    rm -rf "$MERGED_DIST_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$PACKAGE_REPO_STAGE_DIR" "$APTLY_ROOT_DIR" "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

destination="gs://${GCS_BUCKET}"
if [ -n "${GCS_BUCKET_PREFIX:-}" ]; then
  destination="${destination}/${GCS_BUCKET_PREFIX#/}"
fi
lock_path="${destination%/}/.publish.lock"
lock_generation_file="$(mktemp)"

describe_lock() {
  gcloud storage objects describe "$lock_path" --format="value(generation,update_time)" 2>/dev/null
}

release_lock() {
  if [ -f "$lock_generation_file" ]; then
    local generation
    generation="$(cat "$lock_generation_file" 2>/dev/null || true)"
    if [ -n "$generation" ]; then
      gcloud storage rm "$lock_path" --if-generation-match="$generation" >/dev/null 2>&1 || true
    fi
    rm -f "$lock_generation_file"
  fi
}

acquire_lock() {
  local details generation update_time age now
  while true; do
    if printf '%s\n' "$LOCK_OWNER" | gcloud storage cp - "$lock_path" --if-generation-match=0 >/dev/null 2>&1; then
      details="$(describe_lock)"
      generation="$(printf '%s\n' "$details" | awk '{print $1}')"
      printf '%s' "$generation" >"$lock_generation_file"
      return 0
    fi

    details="$(describe_lock)"
    generation="$(printf '%s\n' "$details" | awk '{print $1}')"
    update_time="$(printf '%s\n' "$details" | awk '{print $2}')"

    if [ -n "$generation" ] && [ -n "$update_time" ]; then
      now="$(date -u +%s)"
      age="$(python3 - "$update_time" "$now" <<'PY'
from datetime import datetime
import sys
updated = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
now = int(sys.argv[2])
print(max(0, now - int(updated.timestamp())))
PY
)"
      if [ "$age" -ge "$LOCK_TIMEOUT_SECONDS" ]; then
        gcloud storage rm "$lock_path" --if-generation-match="$generation" >/dev/null 2>&1 || true
        sleep 1
        continue
      fi
    fi

    sleep "$LOCK_POLL_SECONDS"
  done
}

acquire_lock

gcloud storage rsync \
  --recursive \
  "$destination" \
  "$PACKAGE_REPO_STAGE_DIR" >/dev/null 2>&1 || true

mkdir -p "$MERGED_DIST_DIR"
find "$PACKAGE_REPO_STAGE_DIR" -type f \( -name "*.deb" -o -name "*.rpm" \) -exec cp {} "$MERGED_DIST_DIR"/ \;
find "$DIST_DIR" -maxdepth 1 -type f \( -name "*.deb" -o -name "*.rpm" \) -exec cp {} "$MERGED_DIST_DIR"/ \;

mapfile -t deb_packages < <(find "$MERGED_DIST_DIR" -maxdepth 1 -type f -name "*.deb" -print | sort)
mapfile -t rpm_packages < <(find "$MERGED_DIST_DIR" -maxdepth 1 -type f -name "*.rpm" -print | sort)

if [ ${#deb_packages[@]} -eq 0 ] && [ ${#rpm_packages[@]} -eq 0 ]; then
  echo "No .deb or .rpm packages found in $DIST_DIR"
  exit 1
fi

private_key_file="$(mktemp "${RUNNER_TEMP:-/tmp}/aptly-private-key.XXXXXX")"
passphrase_file_secret="$(mktemp "${RUNNER_TEMP:-/tmp}/aptly-passphrase.XXXXXX")"

gcloud secrets versions access latest \
  --project="$GCLOUD_PROJECT" \
  --secret="$APTLY_GPG_PRIVATE_KEY_SECRET" \
  >"$private_key_file"

gcloud secrets versions access latest \
  --project="$GCLOUD_PROJECT" \
  --secret="$APTLY_GPG_PASSPHRASE_SECRET" \
  >"$passphrase_file_secret"

gpg --batch --import "$private_key_file"

if [ ${#deb_packages[@]} -gt 0 ]; then
  IFS=',' read -r -a architecture_list <<<"$APTLY_ARCHITECTURES"
  architecture_json=""
  for architecture in "${architecture_list[@]}"; do
    architecture="${architecture// /}"
    if [ -n "$architecture" ]; then
      if [ -n "$architecture_json" ]; then
        architecture_json+=", "
      fi
      architecture_json+="\"$architecture\""
    fi
  done

  if [ -z "$architecture_json" ]; then
    echo "APTLY_ARCHITECTURES must contain at least one architecture"
    exit 1
  fi

  cat >"$APTLY_ROOT_DIR/aptly.conf" <<EOF
{
  "rootDir": "$APTLY_ROOT_DIR",
  "architectures": [$architecture_json],
  "gpgDisableSign": false,
  "downloadConcurrency": 4,
  "downloadSpeedLimit": 0
}
EOF

  passphrase_file="$APTLY_ROOT_DIR/gpg-passphrase"
  cp "$passphrase_file_secret" "$passphrase_file"
  chmod 600 "$passphrase_file"

  repo_name_base="${APTLY_LABEL//[^a-zA-Z0-9._-]/-}"

  for distribution in $APTLY_DISTRIBUTIONS; do
    repo_name="${repo_name_base}-${distribution}"
    snapshot_name="${repo_name}-snapshot"

    aptly -config="$APTLY_ROOT_DIR/aptly.conf" repo create \
      -distribution="$distribution" \
      -component="$APTLY_COMPONENT" \
      "$repo_name"

    aptly -config="$APTLY_ROOT_DIR/aptly.conf" repo add "$repo_name" "${deb_packages[@]}"
    aptly -config="$APTLY_ROOT_DIR/aptly.conf" snapshot create "$snapshot_name" from repo "$repo_name"
    aptly -config="$APTLY_ROOT_DIR/aptly.conf" publish snapshot \
      -batch \
      -architectures="$APTLY_ARCHITECTURES" \
      -component="$APTLY_COMPONENT" \
      -distribution="$distribution" \
      -origin="$APTLY_ORIGIN" \
      -label="$APTLY_LABEL" \
      -gpg-key="$APTLY_GPG_KEY_ID" \
      -passphrase-file="$passphrase_file" \
      "$snapshot_name" \
      "$APTLY_PUBLISH_PREFIX"
  done

  cp -R "$APTLY_ROOT_DIR/public/." "$PACKAGE_REPO_STAGE_DIR/"
fi

gpg --batch --yes --armor --export "$APTLY_GPG_KEY_ID" >"$PACKAGE_REPO_STAGE_DIR/${APTLY_PUBLIC_KEY_NAME}.asc"
gpg --batch --yes --output "$PACKAGE_REPO_STAGE_DIR/${APTLY_PUBLIC_KEY_NAME}.gpg" --export "$APTLY_GPG_KEY_ID"

if [ ${#rpm_packages[@]} -gt 0 ]; then
  rpm_dir="$PACKAGE_REPO_STAGE_DIR/${RPM_REPOSITORY_PATH#/}"
  mkdir -p "$rpm_dir"
  cp "${rpm_packages[@]}" "$rpm_dir/"
  createrepo_c --update "$rpm_dir"
  gpg --batch --yes --armor --detach-sign \
    --output "$rpm_dir/repodata/repomd.xml.asc" \
    "$rpm_dir/repodata/repomd.xml"
fi

gcloud storage rsync \
  --recursive \
  --delete-unmatched-destination-objects \
  "$PACKAGE_REPO_STAGE_DIR" \
  "$destination"

while IFS= read -r -d '' staged_file; do
  relative_path="${staged_file#"$PACKAGE_REPO_STAGE_DIR"/}"
  object_path="${destination%/}/${relative_path}"
  cache_control="no-store"

  case "$relative_path" in
    *.deb|*.rpm|*.apk)
      cache_control="public,max-age=31536000,immutable"
      ;;
  esac

  gcloud storage objects update "$object_path" --cache-control="$cache_control" >/dev/null
done < <(find "$PACKAGE_REPO_STAGE_DIR" -type f -print0)
