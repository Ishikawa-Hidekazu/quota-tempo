#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$repo_root/dist/release}"
if [[ "$output" != /* ]]; then output="$(pwd)/$output"; fi
sign_identity="${2:--}"
tmp="$(mktemp -d /tmp/quota-tempo-release.XXXXXX)"
app="$tmp/QuotaTempo.app"
stage=""

cleanup() {
  if [[ "$tmp" == /tmp/quota-tempo-release.* ]]; then /bin/rm -rf -- "$tmp"; fi
  if [[ -n "$stage" && "$stage" == */.quota-tempo-release.stage.* ]]; then
    /bin/rm -rf -- "$stage"
  fi
}
trap cleanup EXIT

if [[ -e "$output" || -L "$output" ]]; then
  echo "Output already exists: $output" >&2
  exit 2
fi
if [[ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "Release packaging requires a clean worktree." >&2
  exit 2
fi

release_channel="$(tr -d '[:space:]' < "$repo_root/packaging/release-channel.txt")"
if [[ ! "$release_channel" =~ ^(stable|rc\.[1-9][0-9]*)$ ]]; then
  echo "Invalid release channel: $release_channel" >&2
  exit 2
fi
if [[ "$release_channel" == "stable" && "$sign_identity" == "-" ]]; then
  echo "Stable packaging requires a Developer ID Application identity." >&2
  exit 2
fi

output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
stage="$(mktemp -d "$output_parent/.quota-tempo-release.stage.XXXXXX")"

"$repo_root/scripts/build-app-bundle.sh" "$app"
(
  cd "$app"
  shasum -a 256 -c Contents/Resources/SHA256SUMS
)

# The development inventory includes Mach-O files that signing changes. Public
# release integrity is therefore recorded beside the final archive instead.
rm "$app/Contents/Resources/SHA256SUMS"
commit="$(git -C "$repo_root" rev-parse HEAD)"
/usr/libexec/PlistBuddy -c "Set :QTReleaseChannel $release_channel" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :QTSourceCommit $commit" "$app/Contents/Info.plist"
sign_args=(--force --options runtime --sign "$sign_identity")
if [[ "$sign_identity" == "-" ]]; then
  sign_args+=(--timestamp=none)
else
  sign_args+=(--timestamp)
fi
sparkle="$app/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
codesign "${sign_args[@]}" --preserve-metadata=entitlements \
  "$sparkle/Versions/B/XPCServices/Downloader.xpc"
codesign "${sign_args[@]}" "$sparkle/Versions/B/Autoupdate"
codesign "${sign_args[@]}" "$sparkle/Versions/B/Updater.app"
codesign "${sign_args[@]}" "$sparkle"
codesign "${sign_args[@]}" "$app/Contents/MacOS/QuotaTempo"
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$app/Contents/MacOS/QuotaTempo"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")"
architectures="$(lipo -archs "$app/Contents/MacOS/QuotaTempo")"
release_version="$version"
if [[ "$release_channel" != "stable" ]]; then
  release_version="$version-$release_channel"
fi
archive="QuotaTempo-${release_version}-macOS.zip"
signing="developer-id"
if [[ "$sign_identity" == "-" ]]; then signing="ad-hoc"; fi

signature_value() {
  local field="$1"
  local details="$2"
  awk -v prefix="$field=" \
    'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' \
    <<< "$details"
}

normalize_team_identifier() {
  local value="$1"
  if [[ -z "$value" || "$value" == "not set" ]]; then
    printf 'none\n'
  else
    printf '%s\n' "$value"
  fi
}

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
outer_signature_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
nested_signature_details="$(codesign -dv --verbose=4 "$app/Contents/MacOS/QuotaTempo" 2>&1)"
outer_code_identifier="$(signature_value Identifier "$outer_signature_details")"
nested_code_identifier="$(signature_value Identifier "$nested_signature_details")"
outer_team_identifier="$(normalize_team_identifier "$(signature_value TeamIdentifier "$outer_signature_details")")"
nested_team_identifier="$(normalize_team_identifier "$(signature_value TeamIdentifier "$nested_signature_details")")"
team_identifier="$outer_team_identifier"

"$repo_root/scripts/check-release-identity.sh" \
  "$signing" \
  "$bundle_identifier" \
  "$team_identifier" \
  "$bundle_identifier" \
  "$outer_code_identifier" \
  "$outer_team_identifier" \
  "$nested_code_identifier" \
  "$nested_team_identifier"

# Normalize filesystem timestamps and write entries in a stable order. The app
# contains only Sparkle's relative framework symlinks and no required extended
# attributes, so Zip preserves the signed bundle while avoiding ditto's
# run-specific AppleDouble metadata. Ad-hoc RC builds from the same commit are
# therefore byte-identical.
find "$app" ! -type l -exec touch -t 200001010000 {} +
find "$app" -type l -exec touch -h -t 200001010000 {} +
(
  cd "$tmp"
  find QuotaTempo.app -print | LC_ALL=C sort | zip -X -y -q "$stage/$archive" -@
)
(
  cd "$stage"
  shasum -a 256 "$archive" > SHA256SUMS
)
cat > "$stage/RELEASE-METADATA.json" <<EOF
{
  "product": "QuotaTempo",
  "version": "$version",
  "release_version": "$release_version",
  "channel": "$release_channel",
  "build": "$build",
  "minimum_macos": "$minimum_macos",
  "architectures": "$architectures",
  "bundle_identifier": "$bundle_identifier",
  "team_identifier": "$team_identifier",
  "commit": "$commit",
  "signing": "$signing",
  "notarized": false,
  "archive": "$archive"
}
EOF

"$repo_root/scripts/verify-release.sh" "$stage" --skip-launch
mv "$stage" "$output"
stage=""
printf 'release_package=PASS\noutput=%s\narchive=%s\nsigning=%s\nnotarized=false\n' \
  "$output" "$archive" "$signing"
