#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 RELEASE_DIRECTORY [--skip-launch] [--require-notarized]" >&2
  exit 2
fi

release_dir="$1"
shift
skip_launch=false
require_notarized=false
for option in "$@"; do
  case "$option" in
    --skip-launch)
      if [[ "$skip_launch" == true ]]; then
        echo "Duplicate option: --skip-launch" >&2
        exit 2
      fi
      skip_launch=true
      ;;
    --require-notarized)
      if [[ "$require_notarized" == true ]]; then
        echo "Duplicate option: --require-notarized" >&2
        exit 2
      fi
      require_notarized=true
      ;;
    *)
      echo "Usage: $0 RELEASE_DIRECTORY [--skip-launch] [--require-notarized]" >&2
      exit 2
      ;;
  esac
done
metadata="$release_dir/RELEASE-METADATA.json"
tmp="$(mktemp -d /tmp/quota-tempo-verify.XXXXXX)"
pid=""

cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  if [[ "$tmp" == /tmp/quota-tempo-verify.* ]]; then /bin/rm -rf -- "$tmp"; fi
}
trap cleanup EXIT

test -f "$metadata"
plutil -convert xml1 -o /dev/null "$metadata"
archive="$(plutil -extract archive raw -o - "$metadata")"
product="$(plutil -extract product raw -o - "$metadata")"
version="$(plutil -extract version raw -o - "$metadata")"
release_version="$(plutil -extract release_version raw -o - "$metadata")"
channel="$(plutil -extract channel raw -o - "$metadata")"
build="$(plutil -extract build raw -o - "$metadata")"
minimum_macos="$(plutil -extract minimum_macos raw -o - "$metadata")"
expected_architectures="$(plutil -extract architectures raw -o - "$metadata")"
metadata_bundle_identifier="$(plutil -extract bundle_identifier raw -o - "$metadata")"
metadata_team_identifier="$(plutil -extract team_identifier raw -o - "$metadata")"
commit="$(plutil -extract commit raw -o - "$metadata")"
signing="$(plutil -extract signing raw -o - "$metadata")"
notarized="$(plutil -extract notarized raw -o - "$metadata")"

test "$product" = "QuotaTempo"
test "$release_version" = "$version" || test "$release_version" = "$version-$channel"
if [[ "$channel" == "stable" ]]; then test "$release_version" = "$version"; fi
if [[ ! "$build" =~ ^[1-9][0-9]*$ ]]; then exit 2; fi
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then exit 2; fi
"$(dirname "$0")/check-release-policy.sh" \
  "$channel" "$signing" "$notarized" "$require_notarized"
test "$archive" = "QuotaTempo-$release_version-macOS.zip"
test -f "$release_dir/$archive"

archive_entries="$(unzip -Z1 "$release_dir/$archive")"
if printf '%s\n' "$archive_entries" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "Archive contains an unsafe path." >&2
  exit 2
fi

(
  cd "$release_dir"
  shasum -a 256 -c SHA256SUMS
)
ditto -x -k "$release_dir/$archive" "$tmp"
app="$tmp/QuotaTempo.app"
test -d "$app"
while IFS= read -r link; do
  case "$link" in
    "$app/Contents/Frameworks/Sparkle.framework/"*) ;;
    *)
      echo "App contains an unexpected symbolic link: $link" >&2
      exit 2
      ;;
  esac
  target="$(readlink "$link")"
  if [[ "$target" == /* || "/$target/" == *"/../"* ]]; then
    echo "App contains an unsafe symbolic link: $link -> $target" >&2
    exit 2
  fi
done < <(find "$app" -type l -print)
codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$app/Contents/MacOS/QuotaTempo"
codesign --verify --deep --strict --verbose=2 "$app/Contents/Frameworks/Sparkle.framework"
test "$product" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = "$build"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" = "$minimum_macos"
test "$(/usr/libexec/PlistBuddy -c 'Print :QTReleaseChannel' "$app/Contents/Info.plist")" = "$channel"
test "$(/usr/libexec/PlistBuddy -c 'Print :QTSourceCommit' "$app/Contents/Info.plist")" = "$commit"
test "$(lipo -archs "$app/Contents/MacOS/QuotaTempo")" = "$expected_architectures"
test -f "$app/Contents/Resources/QuotaTempo.icns"
test -f "$app/Contents/Resources/LICENSE"
test -f "$app/Contents/Resources/PRIVACY.md"
test -f "$app/Contents/Resources/SUPPORT.md"
test -f "$app/Contents/Resources/UPDATES.md"
test -f "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$app/Contents/Resources/SPARKLE-LICENSE"
test -f "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist")" = \
  "https://ishikawa.co/downloads/quotatempo/appcast.xml"
expected_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  "$(dirname "$0")/../packaging/Info.plist")"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" = \
  "$expected_public_key"
test "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableSystemProfiling' "$app/Contents/Info.plist")" = false
test "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$app/Contents/Info.plist")" = false
test "$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$app/Contents/Info.plist")" = false
otool -l "$app/Contents/MacOS/QuotaTempo" \
  | grep -q 'path @executable_path/../Frameworks'
test ! -e "$app/Contents/Resources/SHA256SUMS"
test ! -e "$app/Contents/Resources/codex.json"
test ! -e "$app/Contents/Resources/claude.json"
test ! -e "$app/Contents/Resources/QuotaTempoCoreResources/Fixtures"
test ! -e "$app/Contents/Helpers"
test "$(stat -f '%Lp' "$app/Contents/Info.plist")" = 644
test "$(stat -f '%Lp' "$app/Contents/MacOS/QuotaTempo")" = 755
if find "$app" -type d ! -perm 755 -print -quit | grep -q .; then
  echo "App contains a directory without mode 755." >&2
  exit 2
fi
if find "$app/Contents/Resources" -type f ! -perm 644 -print -quit | grep -q .; then
  echo "App contains a resource without mode 644." >&2
  exit 2
fi

signature_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
nested_signature_details="$(codesign -dv --verbose=4 "$app/Contents/MacOS/QuotaTempo" 2>&1)"
if [[ "$signing" == "ad-hoc" ]]; then
  printf '%s\n' "$signature_details" | grep -q '^Signature=adhoc$'
  printf '%s\n' "$nested_signature_details" | grep -q '^Signature=adhoc$'
  test "$notarized" = "false"
else
  printf '%s\n' "$signature_details" | grep -q '^Authority=Developer ID Application:'
  printf '%s\n' "$nested_signature_details" | grep -q '^Authority=Developer ID Application:'
  if [[ "$notarized" == "true" ]]; then
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
  fi
fi

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

plist_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
outer_code_identifier="$(signature_value Identifier "$signature_details")"
nested_code_identifier="$(signature_value Identifier "$nested_signature_details")"
outer_team_identifier="$(normalize_team_identifier "$(signature_value TeamIdentifier "$signature_details")")"
nested_team_identifier="$(normalize_team_identifier "$(signature_value TeamIdentifier "$nested_signature_details")")"

"$(dirname "$0")/check-release-identity.sh" \
  "$signing" \
  "$metadata_bundle_identifier" \
  "$metadata_team_identifier" \
  "$plist_bundle_identifier" \
  "$outer_code_identifier" \
  "$outer_team_identifier" \
  "$nested_code_identifier" \
  "$nested_team_identifier"

binary="$app/Contents/MacOS/QuotaTempo"
if LC_ALL=C grep -a -m 1 -E '/Users/[^/]+/|/home/[^/]+/' "$binary" >/dev/null; then
  echo "App binary contains a developer home path: $binary" >&2
  exit 2
fi

if [[ "$skip_launch" == false ]]; then
  open -n "$app" --args --provider-disabled --exercise-provider-triggers \
    --storage-directory "$tmp/store"
  sleep 2
  canonical_app="$(cd "$(dirname "$app")" && pwd -P)/$(basename "$app")"
  pid="$(pgrep -f "^$canonical_app/Contents/MacOS/QuotaTempo" | head -n 1)"
  test -n "$pid"
  test ! -e "$tmp/store/codex.json"
  test ! -e "$tmp/store/claude.json"
  kill "$pid"
  pid=""
fi

printf 'release_verification=PASS\narchive=%s\nrelease_version=%s\nminimum_macos=%s\narchitectures=%s\nprovider_trigger_test=%s\n' \
  "$archive" "$release_version" "$minimum_macos" "$expected_architectures" \
  "$([[ "$skip_launch" == false ]] && printf PASS || printf SKIP)"
