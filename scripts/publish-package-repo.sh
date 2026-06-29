#!/usr/bin/env bash

set -Eeuxo pipefail
shopt -s nullglob

: "${DIST_DIR:?DIST_DIR is required}"
: "${GCLOUD_PROJECT:?GCLOUD_PROJECT is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"
: "${APTLY_GPG_KEY_ID:?APTLY_GPG_KEY_ID is required}"

PACKAGE_NAME="${PACKAGE_NAME:-${GITHUB_REPOSITORY:-}}"
PACKAGE_NAME="${PACKAGE_NAME##*/}"
if [ -z "$PACKAGE_NAME" ]; then
  echo "PACKAGE_NAME could not be determined"
  exit 1
fi
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
PACKAGE_ASSET_CACHE_CONTROL="${PACKAGE_ASSET_CACHE_CONTROL:-public,max-age=31536000,immutable}"
PACKAGE_METADATA_CACHE_CONTROL="${PACKAGE_METADATA_CACHE_CONTROL:-no-store,max-age=0}"
CDN_URL_MAP="${CDN_URL_MAP:-packages-url-map}"
CDN_INVALIDATE_CACHE="${CDN_INVALIDATE_CACHE:-true}"
PACKAGE_REPO_STAGE_DIR="${PACKAGE_REPO_STAGE_DIR:-$(mktemp -d)}"
APTLY_ROOT_DIR="${APTLY_ROOT_DIR:-$(mktemp -d)}"
GNUPGHOME="${GNUPGHOME:-$(mktemp -d)}"
MERGED_DIST_DIR="$(mktemp -d)"
LOCK_TIMEOUT_SECONDS="${LOCK_TIMEOUT_SECONDS:-600}"
LOCK_POLL_SECONDS="${LOCK_POLL_SECONDS:-5}"
LOCK_OWNER="${LOCK_OWNER:-$(hostname)-$$-$(date -u +%s)}"
current_step="initializing"
private_key_file=""
passphrase_file_secret=""
lock_error_file=""

log_step() {
  current_step="$1"
  printf '==> %s\n' "$current_step"
}

on_error() {
  local status=$?
  printf 'ERROR: %s failed at %s:%s while running: %s\n' \
    "$current_step" "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" "${BASH_LINENO[0]:-?}" "$BASH_COMMAND" >&2
  exit "$status"
}

cleanup() {
  release_lock
  if [ -n "${private_key_file:-}" ]; then
    rm -f "$private_key_file"
  fi
  if [ -n "${passphrase_file_secret:-}" ]; then
    rm -f "$passphrase_file_secret"
  fi
  if [ -n "${lock_error_file:-}" ]; then
    rm -f "$lock_error_file"
  fi
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
trap on_error ERR
trap cleanup EXIT

log_step "Preparing package repository workspace"
mkdir -p "$PACKAGE_REPO_STAGE_DIR" "$APTLY_ROOT_DIR" "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

destination="gs://${GCS_BUCKET}"
if [ -n "${GCS_BUCKET_PREFIX:-}" ]; then
  destination="${destination}/${GCS_BUCKET_PREFIX#/}"
fi
lock_path="${destination%/}/.publish.lock"
lock_generation_file="$(mktemp)"
lock_error_file="$(mktemp)"

describe_lock() {
  gcloud storage objects describe "$lock_path" --format="value(generation,update_time)" 2>/dev/null || true
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
  log_step "Acquiring publish lock at $lock_path"
  while true; do
    : >"$lock_error_file"
    if printf '%s\n' "$LOCK_OWNER" | gcloud storage cp - "$lock_path" --if-generation-match=0 >/dev/null 2>"$lock_error_file"; then
      details="$(describe_lock)"
      generation="$(printf '%s\n' "$details" | awk '{print $1}')"
      if [ -z "$generation" ]; then
        printf 'Acquired publish lock at %s, but could not resolve its generation\n' "$lock_path" >&2
        return 1
      fi
      printf '%s' "$generation" >"$lock_generation_file"
      printf 'Acquired publish lock generation %s\n' "$generation"
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
        printf 'Removing stale publish lock generation %s at %s\n' "$generation" "$lock_path"
        gcloud storage rm "$lock_path" --if-generation-match="$generation" >/dev/null 2>&1 || true
        sleep 1
        continue
      fi
      printf 'Publish lock is held by another process; waiting %ss (age %ss, timeout %ss)\n' "$LOCK_POLL_SECONDS" "$age" "$LOCK_TIMEOUT_SECONDS"
    else
      printf 'Unable to create or inspect publish lock at %s\n' "$lock_path" >&2
      if [ -s "$lock_error_file" ]; then
        cat "$lock_error_file" >&2
      fi
      return 1
    fi

    sleep "$LOCK_POLL_SECONDS"
  done
}

is_deferred_repository_metadata_path() {
  local relative_path="$1"

  case "$relative_path" in
    dists/*|Packages|Packages.*|Release|Release.gpg|InRelease|*/repodata/*)
      return 0
      ;;
  esac

  return 1
}

metadata_upload_order() {
  local relative_path="$1"

  case "$relative_path" in
    by-hash/*|*/by-hash/*)
      printf '010\n'
      ;;
    */repodata/repomd.xml.asc)
      printf '055\n'
      ;;
    */repodata/repomd.xml)
      printf '050\n'
      ;;
    */repodata/*)
      printf '020\n'
      ;;
    Packages|Packages.*|*/Packages|*/Packages.*)
      printf '030\n'
      ;;
    Release.gpg|*/Release.gpg)
      printf '045\n'
      ;;
    Release|*/Release)
      printf '050\n'
      ;;
    InRelease|*/InRelease)
      printf '060\n'
      ;;
    dists/*)
      printf '025\n'
      ;;
    *)
      printf '040\n'
      ;;
  esac
}

cache_control_for_path() {
  local relative_path="$1"

  case "$relative_path" in
    *.deb|*.rpm|*.apk|by-hash/*|*/by-hash/*)
      printf '%s\n' "$PACKAGE_ASSET_CACHE_CONTROL"
      ;;
    *)
      printf '%s\n' "$PACKAGE_METADATA_CACHE_CONTROL"
      ;;
  esac
}

upload_staged_file() {
  local relative_path="$1"
  local staged_file object_path cache_control

  staged_file="$PACKAGE_REPO_STAGE_DIR/$relative_path"
  object_path="${destination%/}/$relative_path"
  cache_control="$(cache_control_for_path "$relative_path")"

  gcloud storage cp \
    --cache-control="$cache_control" \
    "$staged_file" \
    "$object_path" \
    >/dev/null
}

upload_deferred_repository_metadata() {
  local staged_file relative_path ordered_metadata_file order

  ordered_metadata_file="$(mktemp)"
  while IFS= read -r -d '' staged_file; do
    relative_path="${staged_file#"$PACKAGE_REPO_STAGE_DIR"/}"
    if is_deferred_repository_metadata_path "$relative_path"; then
      order="$(metadata_upload_order "$relative_path")"
      printf '%s\t%s\n' "$order" "$relative_path" >>"$ordered_metadata_file"
    fi
  done < <(find "$PACKAGE_REPO_STAGE_DIR" -type f -print0)

  if [ -s "$ordered_metadata_file" ]; then
    while IFS=$'\t' read -r _order relative_path; do
      upload_staged_file "$relative_path"
    done < <(sort "$ordered_metadata_file")
  fi

  rm -f "$ordered_metadata_file"
}

write_flat_by_hash_indexes() {
  local index_name index_file digest target_dir

  target_dir="$PACKAGE_REPO_STAGE_DIR/by-hash/SHA256"
  mkdir -p "$target_dir"

  for index_name in Packages Packages.gz; do
    index_file="$PACKAGE_REPO_STAGE_DIR/$index_name"
    [ -f "$index_file" ] || continue

    digest="$(sha256sum "$index_file" | awk '{print $1}')"
    cp "$index_file" "$target_dir/$digest"
  done
}

cdn_invalidation_path() {
  local prefix="${GCS_BUCKET_PREFIX:-}"

  prefix="${prefix#/}"
  prefix="${prefix%/}"

  if [ -z "$prefix" ]; then
    printf '/*\n'
  else
    printf '/%s/*\n' "$prefix"
  fi
}

invalidate_cdn_cache() {
  local cdn_path
  local -a invalidate_args

  case "$CDN_INVALIDATE_CACHE" in
    false|False|FALSE|0|no|No|NO)
      printf 'Skipping Cloud CDN cache invalidation because CDN_INVALIDATE_CACHE=%s\n' "$CDN_INVALIDATE_CACHE"
      return 0
      ;;
  esac

  if [ -z "$CDN_URL_MAP" ]; then
    printf 'Skipping Cloud CDN cache invalidation because CDN_URL_MAP is empty\n'
    return 0
  fi

  cdn_path="$(cdn_invalidation_path)"
  invalidate_args=(
    compute
    url-maps
    invalidate-cdn-cache
    "$CDN_URL_MAP"
    --global
    --project="$GCLOUD_PROJECT"
    --path="$cdn_path"
  )

  if [ -n "${CDN_INVALIDATE_HOST:-}" ]; then
    invalidate_args+=(--host="$CDN_INVALIDATE_HOST")
  fi

  log_step "Invalidating Cloud CDN cache for $cdn_path"
  gcloud "${invalidate_args[@]}"
}

package_file_name() {
  local package_file="$1"
  local package_name=""
  local file_name file_stem

  case "$package_file" in
    *.deb)
      package_name="$(dpkg-deb -f "$package_file" Package 2>/dev/null || true)"
      ;;
    *.rpm)
      package_name="$(rpm -qp --qf '%{NAME}\n' "$package_file" 2>/dev/null || true)"
      ;;
  esac

  if [ -n "$package_name" ]; then
    printf '%s\n' "$package_name"
    return 0
  fi

  file_name="${package_file##*/}"
  case "$file_name" in
    *.deb)
      printf '%s\n' "${file_name%%_*}"
      ;;
    *.rpm)
      file_stem="${file_name%.rpm}"
      file_stem="${file_stem%.*}"
      file_stem="${file_stem%-*}"
      printf '%s\n' "${file_stem%-[0-9]*}"
      ;;
  esac
}

stage_package_artifacts() {
  find "$DIST_DIR" -maxdepth 1 -type f \( -name "*.deb" -o -name "*.rpm" \) -exec cp {} "$PACKAGE_REPO_STAGE_DIR"/ \;
}

current_package_names=()

append_current_package_name() {
  local package_name="$1"
  local current_package_name

  [ -n "$package_name" ] || return 0

  for current_package_name in "${current_package_names[@]}"; do
    if [ "$current_package_name" = "$package_name" ]; then
      return 0
    fi
  done

  current_package_names+=("$package_name")
}

collect_current_package_names() {
  local package_file

  current_package_names=()

  while IFS= read -r -d '' package_file; do
    append_current_package_name "$(package_file_name "$package_file")"
  done < <(find "$DIST_DIR" -maxdepth 1 -type f \( -name "*.deb" -o -name "*.rpm" \) -print0)

  if [ ${#current_package_names[@]} -eq 0 ]; then
    append_current_package_name "$PACKAGE_NAME"
  fi
}

is_current_package_name() {
  local package_name="$1"
  local current_package_name

  [ -n "$package_name" ] || return 1

  for current_package_name in "${current_package_names[@]}"; do
    if [ "$current_package_name" = "$package_name" ]; then
      return 0
    fi
  done

  return 1
}

prune_stage_package_history() {
  local staged_package package_name

  collect_current_package_names

  while IFS= read -r -d '' staged_package; do
    package_name="$(package_file_name "$staged_package")"
    if is_current_package_name "$package_name"; then
      rm -f "$staged_package"
    fi
  done < <(find "$PACKAGE_REPO_STAGE_DIR" -type f \( -name "*.deb" -o -name "*.rpm" \) -print0)
}

prune_stage_release_history() {
  local entry release_name

  for entry in "$PACKAGE_REPO_STAGE_DIR"/*; do
    [ -d "$entry" ] || continue
    release_name="${entry##*/}"
    if [[ "$release_name" =~ ^v?[0-9]+(\.[0-9]+){1,2}([-.+~][A-Za-z0-9._~+-]+)?$ ]]; then
      rm -rf "$entry"
    fi
  done
}

acquire_lock

log_step "Syncing existing package repository from $destination"
gcloud storage rsync \
  --recursive \
  "$destination" \
  "$PACKAGE_REPO_STAGE_DIR" || {
    printf 'No existing repository state was synced from %s; continuing with current release artifacts.\n' "$destination" >&2
  }
rm -f "$PACKAGE_REPO_STAGE_DIR/.publish.lock"

log_step "Pruning stale package artifacts"
prune_stage_release_history
prune_stage_package_history
stage_package_artifacts

log_step "Collecting package artifacts"
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

log_step "Loading aptly GPG key from Secret Manager"
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
  log_step "Publishing APT repository"
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

  cat >"$APTLY_ROOT_DIR/aptly.conf" <<APTLYCONF
{
  "rootDir": "$APTLY_ROOT_DIR",
  "architectures": [$architecture_json],
  "gpgDisableSign": false,
  "downloadConcurrency": 4,
  "downloadSpeedLimit": 0
}
APTLYCONF

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

  while IFS= read -r existing_public_path; do
    rm -rf "${PACKAGE_REPO_STAGE_DIR:?}/${existing_public_path#"$APTLY_ROOT_DIR/public"/}"
  done < <(find "$APTLY_ROOT_DIR/public" -mindepth 1 -maxdepth 1)

  cp -R "$APTLY_ROOT_DIR/public/." "$PACKAGE_REPO_STAGE_DIR/"

  # Generate flat repository (supports "deb URL ./" apt sources, distribution-agnostic)
  flat_packages_file="$PACKAGE_REPO_STAGE_DIR/Packages"
  (cd "$PACKAGE_REPO_STAGE_DIR" && dpkg-scanpackages --multiversion pool) \
    > "$flat_packages_file"
  gzip -k -f "$flat_packages_file"
  write_flat_by_hash_indexes

  flat_release_file="$PACKAGE_REPO_STAGE_DIR/Release"
  {
    echo "Origin: ${APTLY_ORIGIN}"
    echo "Label: ${APTLY_LABEL}"
    echo "Acquire-By-Hash: yes"
    echo "Architectures: ${APTLY_ARCHITECTURES//,/ }"
    echo "Components: ${APTLY_COMPONENT}"
    echo "Date: $(date -Ru)"
    echo "MD5Sum:"
    for _f in Packages Packages.gz; do
      [ -f "$PACKAGE_REPO_STAGE_DIR/$_f" ] || continue
      printf " %s %16d %s\n" \
        "$(md5sum "$PACKAGE_REPO_STAGE_DIR/$_f" | cut -d' ' -f1)" \
        "$(stat -c%s "$PACKAGE_REPO_STAGE_DIR/$_f")" \
        "$_f"
    done
    echo "SHA256:"
    for _f in Packages Packages.gz; do
      [ -f "$PACKAGE_REPO_STAGE_DIR/$_f" ] || continue
      printf " %s %16d %s\n" \
        "$(sha256sum "$PACKAGE_REPO_STAGE_DIR/$_f" | cut -d' ' -f1)" \
        "$(stat -c%s "$PACKAGE_REPO_STAGE_DIR/$_f")" \
        "$_f"
    done
  } > "$flat_release_file"

  gpg --batch --yes \
    --passphrase-file "$passphrase_file" \
    --pinentry-mode loopback \
    -u "$APTLY_GPG_KEY_ID" \
    --armor --detach-sign \
    --output "${flat_release_file}.gpg" \
    "$flat_release_file"

  gpg --batch --yes \
    --passphrase-file "$passphrase_file" \
    --pinentry-mode loopback \
    -u "$APTLY_GPG_KEY_ID" \
    --clearsign \
    --output "$PACKAGE_REPO_STAGE_DIR/InRelease" \
    "$flat_release_file"
fi

log_step "Exporting repository public key"
gpg --batch --yes --armor --export "$APTLY_GPG_KEY_ID" >"$PACKAGE_REPO_STAGE_DIR/${APTLY_PUBLIC_KEY_NAME}.asc"
gpg --batch --yes --output "$PACKAGE_REPO_STAGE_DIR/${APTLY_PUBLIC_KEY_NAME}.gpg" --export "$APTLY_GPG_KEY_ID"

if [ ${#rpm_packages[@]} -gt 0 ]; then
  log_step "Publishing RPM repository"
  rpm_dir="$PACKAGE_REPO_STAGE_DIR/${RPM_REPOSITORY_PATH#/}"
  rm -rf "$rpm_dir"
  mkdir -p "$rpm_dir"
  cp "${rpm_packages[@]}" "$rpm_dir/"
  createrepo_c --update "$rpm_dir"
  gpg --batch --yes \
    --passphrase-file "$passphrase_file_secret" \
    --pinentry-mode loopback \
    -u "$APTLY_GPG_KEY_ID" \
    --armor --detach-sign \
    --output "$rpm_dir/repodata/repomd.xml.asc" \
    "$rpm_dir/repodata/repomd.xml"
fi

log_step "Uploading package assets to $destination"
mutable_metadata_exclude_regex='^[.]publish[.]lock$|(^|/)dists/|^(InRelease|Release|Release[.]gpg|Packages([.].*)?)$|(^|/)repodata/'
gcloud storage rsync \
  --recursive \
  --exclude="$mutable_metadata_exclude_regex" \
  --cache-control="$PACKAGE_ASSET_CACHE_CONTROL" \
  "$PACKAGE_REPO_STAGE_DIR" \
  "$destination"

log_step "Uploading repository metadata to $destination"
upload_deferred_repository_metadata

log_step "Updating cache-control metadata"
while IFS= read -r -d '' staged_file; do
  relative_path="${staged_file#"$PACKAGE_REPO_STAGE_DIR"/}"
  object_path="${destination%/}/${relative_path}"
  cache_control="$(cache_control_for_path "$relative_path")"

  gcloud storage objects update "$object_path" --cache-control="$cache_control" >/dev/null
done < <(find "$PACKAGE_REPO_STAGE_DIR" -type f -print0)

invalidate_cdn_cache

printf 'Published package repository to %s\n' "$destination"
