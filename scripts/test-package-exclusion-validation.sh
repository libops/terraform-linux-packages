#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
validator="$repo_root/scripts/validate-package-exclusions.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/package-exclusion-validation.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

PACKAGE_NAME=sitectl \
EXCLUDED_PACKAGE_NAMES=$'sitectl-isle, sitectl-preview\nsitectl-isle' \
  bash "$validator" >"$tmp/allowed.log"
grep -Fq \
  "Package sitectl is allowed; effective exclusions: sitectl-isle sitectl-preview" \
  "$tmp/allowed.log"

GITHUB_REPOSITORY=libops/sitectl \
EXCLUDED_PACKAGE_NAMES= \
  bash "$validator" >"$tmp/repository-fallback.log"
grep -Fq "Package sitectl is allowed" "$tmp/repository-fallback.log"

if PACKAGE_NAME=sitectl-isle \
  EXCLUDED_PACKAGE_NAMES= \
  bash "$validator" >"$tmp/excluded.log" 2>&1; then
  printf 'Excluded PACKAGE_NAME unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq \
  "PACKAGE_NAME 'sitectl-isle' is excluded from Linux package publication" \
  "$tmp/excluded.log"

if PACKAGE_NAME=sitectl-isle \
  EXCLUDED_PACKAGE_NAMES=sitectl-preview \
  bash "$validator" >"$tmp/mandatory-exclusion.log" 2>&1; then
  printf 'Caller override disabled the publisher-mandatory exclusion\n' >&2
  exit 1
fi
grep -Fq \
  "PACKAGE_NAME 'sitectl-isle' is excluded from Linux package publication" \
  "$tmp/mandatory-exclusion.log"

if PACKAGE_NAME=sitectl-drupal \
  EXCLUDED_PACKAGE_NAMES=sitectl \
  bash "$validator" >"$tmp/non-owner-exclusion.log" 2>&1; then
  printf 'Plugin package unexpectedly received channel-wide exclusion authority\n' >&2
  exit 1
fi
grep -Fq \
  "Only the 'sitectl' channel owner may request additional package exclusions" \
  "$tmp/non-owner-exclusion.log"

if PACKAGE_NAME=sitectl \
  EXCLUDED_PACKAGE_NAMES='sitectl-isle,../../escape' \
  bash "$validator" >"$tmp/invalid-exclusion.log" 2>&1; then
  printf 'Invalid excluded package name unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq "Invalid excluded package name: ../../escape" "$tmp/invalid-exclusion.log"

if PACKAGE_NAME=libops/sitectl \
  EXCLUDED_PACKAGE_NAMES=sitectl-isle \
  bash "$validator" >"$tmp/repository-package-name.log" 2>&1; then
  printf 'Repository-shaped PACKAGE_NAME unexpectedly passed validation\n' >&2
  exit 1
fi
grep -Fq \
  "PACKAGE_NAME must be a canonical package name, not a repository path" \
  "$tmp/repository-package-name.log"
