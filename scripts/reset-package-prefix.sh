#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf 'Usage: %s --bucket BUCKET --prefix PACKAGE --apply\n' "${0##*/}" >&2
  printf 'Deletes one complete package prefix so its latest release can be republished cleanly.\n' >&2
}

bucket=""
prefix=""
apply=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bucket) bucket="${2:-}"; shift 2 ;;
    --prefix) prefix="${2:-}"; shift 2 ;;
    --apply) apply=true; shift ;;
    *) usage; exit 2 ;;
  esac
done

if [[ ! "$bucket" =~ ^[a-z0-9][a-z0-9._-]{1,221}[a-z0-9]$ ]]; then
  printf 'Refusing unsafe bucket name: %s\n' "$bucket" >&2
  exit 2
fi
if [[ ! "$prefix" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  printf 'Refusing unsafe package prefix: %s\n' "$prefix" >&2
  exit 2
fi

target="gs://${bucket}/${prefix}"
printf 'Package prefix selected for complete reset: gs://%s/%s/\n' "$bucket" "$prefix"
if [ "$apply" != true ]; then
  printf 'Dry run only. Re-run with --apply to delete this prefix.\n'
  exit 0
fi

gcloud storage rm --recursive "$target"
printf 'Deleted gs://%s/%s/. Republish the latest %s release now.\n' \
  "$bucket" "$prefix" "$prefix"
