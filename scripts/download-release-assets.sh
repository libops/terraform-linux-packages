#!/usr/bin/env bash

set -euxo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${RELEASE_VERSION:?RELEASE_VERSION is required}"
: "${DIST_DIR:?DIST_DIR is required}"

mkdir -p "$DIST_DIR"
find "$DIST_DIR" -maxdepth 1 -type f \( -name "*.deb" -o -name "*.rpm" \) -delete

gh release download "$RELEASE_VERSION" \
  --repo "$GITHUB_REPOSITORY" \
  --dir "$DIST_DIR" \
  --clobber \
  --pattern "*.deb" \
  --pattern "*.rpm"
