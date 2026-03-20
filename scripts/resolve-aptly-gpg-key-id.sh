#!/usr/bin/env bash

set -euo pipefail

: "${GCLOUD_PROJECT:?GCLOUD_PROJECT is required}"

APTLY_GPG_PRIVATE_KEY_SECRET="${APTLY_GPG_PRIVATE_KEY_SECRET:-aptly-gpg-private-key}"
GNUPGHOME="$(mktemp -d)"
PRIVATE_KEY_FILE="$(mktemp)"

cleanup() {
  rm -rf "$GNUPGHOME" "$PRIVATE_KEY_FILE"
}
trap cleanup EXIT

chmod 700 "$GNUPGHOME"
export GNUPGHOME

gcloud secrets versions access latest \
  --project="$GCLOUD_PROJECT" \
  --secret="$APTLY_GPG_PRIVATE_KEY_SECRET" \
  >"$PRIVATE_KEY_FILE"

gpg --batch --import "$PRIVATE_KEY_FILE" >/dev/null 2>&1

gpg --batch --with-colons --list-secret-keys | awk -F: '/^sec:/ { print $5; exit }'
