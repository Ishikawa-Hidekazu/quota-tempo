#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$repo_root/docs/assets"
tmp="$(mktemp -d /tmp/quota-tempo-fixtures.XXXXXX)"

cleanup() {
  if [[ "$tmp" == /tmp/quota-tempo-fixtures.* ]]; then /bin/rm -rf -- "$tmp"; fi
}
trap cleanup EXIT

mkdir -p "$output_dir"

render_fixture() {
  local fixture="$1"
  local language="$2"
  local filename="$3"
  local view_mode="${4:-main}"
  local first="$tmp/first-$filename"
  local second="$tmp/second-$filename"

  swift run --package-path "$repo_root" QuotaTempoFixtureRenderer \
    --fixture "$fixture" \
    --language "$language" \
    --view-mode "$view_mode" \
    --output "$first"
  swift run --package-path "$repo_root" QuotaTempoFixtureRenderer \
    --fixture "$fixture" \
    --language "$language" \
    --view-mode "$view_mode" \
    --output "$second"
  cmp "$first" "$second"
  mv "$first" "$output_dir/$filename"
}

render_fixture baseline en fixture-menu-en.png
render_fixture baseline ja fixture-menu-ja.png
render_fixture baseline en fixture-onboarding-en.png onboarding
render_fixture baseline ja fixture-onboarding-ja.png onboarding
render_fixture one-provider en fixture-menu-codex-only.png
render_fixture degraded ja fixture-menu-ja-degraded.png
render_fixture live-adapters en live-adapter-mvp.png

echo "Rendered fixture-only proof images in $output_dir"
