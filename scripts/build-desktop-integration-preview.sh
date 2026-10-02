#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$repo_root/dist/QuotaTempoDesktopIntegration.app}"
if [[ $# -gt 1 || -e "$output" || -L "$output" ]]; then
  echo 'Use a new output path. Existing apps are never replaced.' >&2
  exit 2
fi
mkdir -p "$(dirname "$output")"
stage="$(mktemp -d "$(dirname "$output")/.DesktopIntegration.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
export QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW=1
scratch="$repo_root/.build/desktop-integration"
swift build --package-path "$repo_root" --scratch-path "$scratch" --product QuotaTempo
build_dir="$(swift build --package-path "$repo_root" --scratch-path "$scratch" --show-bin-path)"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources" "$stage/Contents/Frameworks"
install -m 755 "$build_dir/QuotaTempo" "$stage/Contents/MacOS/QuotaTempo"
install_name_tool -add_rpath @executable_path/../Frameworks "$stage/Contents/MacOS/QuotaTempo"
ditto "$build_dir/Sparkle.framework" "$stage/Contents/Frameworks/Sparkle.framework"
install -m 644 "$repo_root/packaging/Info.plist" "$stage/Contents/Info.plist"
for command in \
  'Set :CFBundleIdentifier co.ishikawa.QuotaTempo.DesktopIntegrationPreview' \
  'Set :CFBundleName QuotaTempoDesktopIntegration' \
  'Set :CFBundleDisplayName QuotaTempo Desktop Integration' \
  'Set :QTReleaseChannel desktop-integration-preview' \
  'Delete :CFBundleIconFile' 'Delete :SUFeedURL' 'Delete :SUPublicEDKey'; do
  /usr/libexec/PlistBuddy -c "$command" "$stage/Contents/Info.plist"
done
for document in PRIVACY.md LICENSE UPDATES.md SUPPORT.md THIRD_PARTY_NOTICES.md; do
  install -m 644 "$repo_root/$document" "$stage/Contents/Resources/$document"
done
install -m 644 "$scratch/artifacts/sparkle/Sparkle/LICENSE" \
  "$stage/Contents/Resources/SPARKLE-LICENSE"
mkdir -p "$stage/Contents/Resources/QuotaTempoCoreResources"
cp -R "$repo_root/Sources/QuotaTempoCore/Resources/en.lproj" \
  "$stage/Contents/Resources/QuotaTempoCoreResources/"
cp -R "$repo_root/Sources/QuotaTempoCore/Resources/ja.lproj" \
  "$stage/Contents/Resources/QuotaTempoCoreResources/"
codesign --force --sign - --timestamp=none "$stage/Contents/MacOS/QuotaTempo"
codesign --force --sign - --timestamp=none "$stage"
codesign --verify --deep --strict "$stage"
mv "$stage" "$output"
trap - EXIT
printf 'Built local integration preview: %s\nNot launched, installed, notarized, or release-approved.\n' "$output"
