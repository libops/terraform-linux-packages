#!/usr/bin/env bash

# Shared validation for local and GitHub Actions package publication.
# shellcheck shell=bash

package_name_is_valid() {
  local package_name="$1"

  [[ "$package_name" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]
}

readonly -a publisher_mandatory_excluded_package_names=()

append_excluded_package_name() {
  local package_name="$1"
  local existing_package_name

  for existing_package_name in "${excluded_package_names[@]}"; do
    if [ "$existing_package_name" = "$package_name" ]; then
      return 0
    fi
  done
  excluded_package_names+=("$package_name")
}

parse_excluded_package_names() {
  local line package_name
  local -a line_package_names=()

  excluded_package_names=()
  EXCLUDED_PACKAGE_NAMES="${EXCLUDED_PACKAGE_NAMES:-}"

  for package_name in "${publisher_mandatory_excluded_package_names[@]}"; do
    if ! package_name_is_valid "$package_name"; then
      printf 'Invalid publisher-mandatory excluded package name: %s\n' "$package_name" >&2
      return 1
    fi
    append_excluded_package_name "$package_name"
  done

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//,/ }"
    read -r -a line_package_names <<<"$line"
    for package_name in "${line_package_names[@]}"; do
      if ! package_name_is_valid "$package_name"; then
        printf 'Invalid excluded package name: %s\n' "$package_name" >&2
        return 1
      fi

      append_excluded_package_name "$package_name"
    done
  done <<<"$EXCLUDED_PACKAGE_NAMES"
}

is_excluded_package_name() {
  local package_name="$1"
  local excluded_package_name

  for excluded_package_name in "${excluded_package_names[@]}"; do
    if [ "$excluded_package_name" = "$package_name" ]; then
      return 0
    fi
  done

  return 1
}

prepare_package_exclusions() {
  local requested_package_name="${PACKAGE_NAME:-}"

  if [ -z "$requested_package_name" ]; then
    requested_package_name="${GITHUB_REPOSITORY:-}"
    requested_package_name="${requested_package_name##*/}"
  elif [[ "$requested_package_name" == */* ]]; then
    printf 'PACKAGE_NAME must be a canonical package name, not a repository path: %s\n' \
      "$requested_package_name" >&2
    return 1
  fi

  if [ -z "$requested_package_name" ]; then
    printf 'PACKAGE_NAME could not be determined\n' >&2
    return 1
  fi
  if ! package_name_is_valid "$requested_package_name"; then
    printf 'Invalid PACKAGE_NAME: %s\n' "$requested_package_name" >&2
    return 1
  fi

  PACKAGE_NAME="$requested_package_name"
  parse_excluded_package_names

  if is_excluded_package_name "$PACKAGE_NAME"; then
    printf "PACKAGE_NAME '%s' is excluded from Linux package publication\n" \
      "$PACKAGE_NAME" >&2
    return 1
  fi

  if [ -n "${EXCLUDED_PACKAGE_NAMES:-}" ] && [ "$PACKAGE_NAME" != "sitectl" ]; then
    printf "Only the 'sitectl' channel owner may request additional package exclusions\n" >&2
    return 1
  fi
}
