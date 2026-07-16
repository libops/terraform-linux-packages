#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=package-exclusions.sh
source "$script_dir/package-exclusions.sh"

prepare_package_exclusions
printf 'Package %s is allowed; effective exclusions: %s\n' \
  "$PACKAGE_NAME" "${excluded_package_names[*]}"
