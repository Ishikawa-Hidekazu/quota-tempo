#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: $0 SIGNED_RELEASE_DIRECTORY OUTPUT_DIRECTORY KEYCHAIN_PROFILE [--resume-after-accepted]" >&2
  exit 2
fi

input="$1"
output="$2"
keychain_profile="$3"
resume_after_accepted=false
if [[ $# -eq 4 ]]; then
  if [[ "$4" != "--resume-after-accepted" ]]; then
    echo "Unknown option: $4" >&2
    exit 2
  fi
  resume_after_accepted=true
fi
metadata="$input/RELEASE-METADATA.json"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d /tmp/quota-tempo-notarize.XXXXXX)"
stage=""

cleanup() {
  if [[ "$tmp" == /tmp/quota-tempo-notarize.* ]]; then /bin/rm -rf -- "$tmp"; fi
  if [[ -n "$stage" && "$stage" == */.quota-tempo-notarized.stage.* ]]; then
    /bin/rm -rf -- "$stage"
  fi
}
trap cleanup EXIT

test -f "$metadata"
if [[ -e "$output" || -L "$output" ]]; then
  echo "Output already exists: $output" >&2
  exit 2
fi

archive="$(plutil -extract archive raw -o - "$metadata")"
signing="$(plutil -extract signing raw -o - "$metadata")"
notarized="$(plutil -extract notarized raw -o - "$metadata")"
test "$signing" = "developer-id"
test "$notarized" = "false"
test -f "$input/$archive"

# Validate the signed input before the one authorized external submission.
"$repo_root/scripts/verify-release.sh" "$input" --skip-launch
if [[ "$resume_after_accepted" == false ]]; then
  xcrun notarytool submit "$input/$archive" --keychain-profile "$keychain_profile" --wait
fi

ditto -x -k "$input/$archive" "$tmp/extracted"
app="$tmp/extracted/QuotaTempo.app"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output="$output_parent/$(basename "$output")"
stage="$(mktemp -d "$output_parent/.quota-tempo-notarized.stage.XXXXXX")"
cp "$metadata" "$stage/RELEASE-METADATA.json"
plutil -replace notarized -bool true "$stage/RELEASE-METADATA.json"
plutil -convert json "$stage/RELEASE-METADATA.json"

(
  cd "$tmp/extracted"
  find QuotaTempo.app -print | LC_ALL=C sort | zip -X -q "$stage/$archive" -@
)
(
  cd "$stage"
  shasum -a 256 "$archive" > SHA256SUMS
)

"$repo_root/scripts/verify-release.sh" "$stage" --skip-launch --require-notarized
mv "$stage" "$output"
stage=""
printf 'notarized_release=PASS\noutput=%s\narchive=%s\n' "$output" "$archive"
