#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 NOTARIZED_RELEASE_DIRECTORY OUTPUT_DIRECTORY" >&2
  exit 2
fi

input="$1"
output="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
metadata="$input/RELEASE-METADATA.json"
tool="$repo_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
key_account="ed25519"

test -f "$metadata"
test -x "$tool"
if [[ -e "$output" || -L "$output" ]]; then
  echo "Output already exists: $output" >&2
  exit 2
fi

archive="$(plutil -extract archive raw -o - "$metadata")"
release_version="$(plutil -extract release_version raw -o - "$metadata")"
channel="$(plutil -extract channel raw -o - "$metadata")"
signing="$(plutil -extract signing raw -o - "$metadata")"
notarized="$(plutil -extract notarized raw -o - "$metadata")"
"$repo_root/scripts/check-distribution-policy.sh" "$channel" "$signing" "$notarized"
"$repo_root/scripts/verify-release.sh" "$input" --skip-launch --require-notarized

stage="$(mktemp -d "$(dirname "$output")/.quota-tempo-appcast.stage.XXXXXX")"
trap 'if [[ "$stage" == */.quota-tempo-appcast.stage.* ]]; then /bin/rm -rf -- "$stage"; fi' EXIT

cp -p "$input/$archive" "$stage/$archive"
"$tool" \
  --account "$key_account" \
  --download-url-prefix \
  "https://github.com/Ishikawa-Hidekazu/quota-tempo/releases/download/v$release_version/" \
  --link "https://github.com/Ishikawa-Hidekazu/quota-tempo" \
  --maximum-versions 3 \
  --maximum-deltas 0 \
  "$stage"

test -f "$stage/appcast.xml"
grep -q 'sparkle:edSignature=' "$stage/appcast.xml"
grep -q "QuotaTempo-$release_version-macOS.zip" "$stage/appcast.xml"
mv "$stage" "$output"
stage=""
printf 'appcast_generation=PASS\noutput=%s\n' "$output"
