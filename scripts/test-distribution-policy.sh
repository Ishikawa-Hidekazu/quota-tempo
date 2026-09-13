#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="$repo_root/scripts/check-distribution-policy.sh"

expect_rejected() {
  if "$policy" "$@" >/dev/null 2>&1; then
    echo "Unexpected distribution policy pass: $*" >&2
    exit 1
  fi
}

test "$("$policy" stable developer-id true)" = "distribution_policy=PASS"
expect_rejected rc.20 developer-id true
expect_rejected stable ad-hoc true
expect_rejected stable developer-id false

echo "distribution_policy_test=PASS"
