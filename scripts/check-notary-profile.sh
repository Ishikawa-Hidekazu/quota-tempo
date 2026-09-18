#!/usr/bin/env bash

set -euo pipefail

profile="quotatempo-release"
if xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null 2>&1; then
  printf 'notary_profile=PASS\nprofile=%s\n' "$profile"
else
  printf 'Notary profile %s could not be validated. Check connectivity and Keychain setup before creating new credentials.\n' "$profile" >&2
  exit 1
fi
