#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$repo_root/packaging/Info.plist")"

grep -Fq "\"version\":\"$version\"" \
  "$repo_root/Sources/QuotaTempoCore/CodexAdapter.swift"
grep -Fq "placeholder: $version" \
  "$repo_root/.github/ISSUE_TEMPLATE/bug_report.yml"
grep -Fq "placeholder: $version" \
  "$repo_root/.github/ISSUE_TEMPLATE/public_beta_feedback.yml"
grep -Fq "## $version " "$repo_root/CHANGELOG.md"

printf 'version_consistency_test=PASS\nversion=%s\n' "$version"
