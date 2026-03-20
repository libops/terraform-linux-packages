#!/usr/bin/env bash

set -euo pipefail

: "${GCLOUD_PROJECT:?GCLOUD_PROJECT is required}"
: "${APTLY_GPG_NAME:?APTLY_GPG_NAME is required}"
: "${APTLY_GPG_EMAIL:?APTLY_GPG_EMAIL is required}"

APTLY_GPG_PRIVATE_KEY_SECRET="${APTLY_GPG_PRIVATE_KEY_SECRET:-aptly-gpg-private-key}"
APTLY_GPG_PASSPHRASE_SECRET="${APTLY_GPG_PASSPHRASE_SECRET:-aptly-gpg-passphrase}"
APTLY_GPG_KEY_EXPIRE="${APTLY_GPG_KEY_EXPIRE:-2y}"
APTLY_GPG_ARTIFACTS_DIR="${APTLY_GPG_ARTIFACTS_DIR:-/workspace/terraform-linux-packages/.out/gpg}"

if [ -z "${APTLY_GPG_PASSPHRASE:-}" ]; then
  if [ -t 0 ]; then
    printf 'Enter package signing key passphrase: ' >&2
    IFS= read -r -s APTLY_GPG_PASSPHRASE
    printf '\n' >&2
  else
    IFS= read -r APTLY_GPG_PASSPHRASE
  fi
fi

: "${APTLY_GPG_PASSPHRASE:?APTLY_GPG_PASSPHRASE is required via stdin or environment}"

GNUPGHOME="$(mktemp -d)"
KEY_PARAMS="$(mktemp)"
PRIVATE_KEY_FILE="$(mktemp)"
PASSPHRASE_FILE="$(mktemp)"
mkdir -p "$APTLY_GPG_ARTIFACTS_DIR"

cleanup() {
  rm -rf "$GNUPGHOME" "$KEY_PARAMS" "$PRIVATE_KEY_FILE" "$PASSPHRASE_FILE"
}
trap cleanup EXIT

chmod 700 "$GNUPGHOME"
export GNUPGHOME

printf '%s' "$APTLY_GPG_PASSPHRASE" >"$PASSPHRASE_FILE"

cat >"$KEY_PARAMS" <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${APTLY_GPG_NAME}
Name-Email: ${APTLY_GPG_EMAIL}
Expire-Date: ${APTLY_GPG_KEY_EXPIRE}
Passphrase: ${APTLY_GPG_PASSPHRASE}
%commit
EOF

gpg --batch --generate-key "$KEY_PARAMS"

KEY_ID="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^sec:/ { print $5; exit }')"
FINGERPRINT="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/ { print $10; exit }')"

if [ -z "$KEY_ID" ]; then
  echo "failed to derive generated key id" >&2
  exit 1
fi

gpg --batch --pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE" \
  --armor --export-secret-keys "$KEY_ID" >"$PRIVATE_KEY_FILE"

printf '%s' "$APTLY_GPG_PASSPHRASE" | gcloud secrets versions add \
  "$APTLY_GPG_PASSPHRASE_SECRET" \
  --project="$GCLOUD_PROJECT" \
  --data-file=-

gcloud secrets versions add \
  "$APTLY_GPG_PRIVATE_KEY_SECRET" \
  --project="$GCLOUD_PROJECT" \
  --data-file="$PRIVATE_KEY_FILE"

REVOCATION_SOURCE="$GNUPGHOME/openpgp-revocs.d/${FINGERPRINT}.rev"
REVOCATION_TARGET="$APTLY_GPG_ARTIFACTS_DIR/${FINGERPRINT}.rev"
if [ -f "$REVOCATION_SOURCE" ]; then
  cp "$REVOCATION_SOURCE" "$REVOCATION_TARGET"
  chmod 600 "$REVOCATION_TARGET"
fi

echo "Created and uploaded package signing key: $KEY_ID"
if [ -f "$REVOCATION_TARGET" ]; then
  echo "Saved revocation certificate to: $REVOCATION_TARGET"
fi
echo "Run: make sync-aptly-gpg-key-id"
