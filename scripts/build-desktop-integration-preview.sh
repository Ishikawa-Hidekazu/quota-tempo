#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
usage() {
  printf '%s\n' \
    'Usage: build-desktop-integration-preview.sh [output.app] [--sign-identity "Developer ID Application: Name (TEAMID)"] [--team-id TEAMID]' \
    'Local preview only. Default signing is ad-hoc; Developer ID requires both options.' \
    'Never launches, installs, notarizes, or approves a release.'
}
invalid_arguments() {
  echo "$1" >&2
  usage >&2
  exit 2
}
if [[ $# -eq 1 && "$1" == --help ]]; then
  usage
  exit 0
fi
output="$repo_root/dist/QuotaTempoDesktopIntegration.app"
output_set=false
sign_identity=""
team_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign-identity|--team-id)
      option="$1"
      [[ $# -ge 2 ]] || invalid_arguments 'Signing options require a value.'
      [[ -n "${2//[[:space:]]/}" && "$2" != -* && ! "$2" =~ [[:cntrl:]] ]] \
        || invalid_arguments 'Signing option values must be nonblank and valid.'
      if [[ "$option" == --sign-identity ]]; then
        [[ -z "$sign_identity" ]] || invalid_arguments 'Duplicate --sign-identity.'
        sign_identity="$2"
      else
        [[ -z "$team_id" ]] || invalid_arguments 'Duplicate --team-id.'
        team_id="$2"
      fi
      shift 2
      ;;
    --)
      shift
      [[ $# -eq 1 && "$output_set" == false ]] \
        || invalid_arguments 'Provide exactly one output path after --.'
      output="$1"
      output_set=true
      shift
      ;;
    -*) invalid_arguments 'Unknown option.' ;;
    *)
      [[ "$output_set" == false ]] || invalid_arguments 'Only one output path is allowed.'
      output="$1"
      output_set=true
      shift
      ;;
  esac
done
[[ -n "${output//[[:space:]]/}" && ! "$output" =~ [[:cntrl:]] ]] \
  || invalid_arguments 'Output path must be nonblank and contain no control characters.'
if [[ -n "$sign_identity" || -n "$team_id" ]]; then
  [[ -n "$sign_identity" && -n "$team_id" ]] \
    || invalid_arguments '--sign-identity and --team-id must be supplied together.'
  [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] \
    || invalid_arguments 'Team ID must contain exactly 10 uppercase letters or digits.'
  identity_prefix='Developer ID Application: '
  identity_suffix=" ($team_id)"
  [[ "$sign_identity" == "$identity_prefix"*"$identity_suffix" ]] \
    || invalid_arguments 'Use a full Developer ID Application identity matching --team-id.'
  identity_name="${sign_identity#"$identity_prefix"}"
  identity_name="${identity_name%"$identity_suffix"}"
  [[ -n "$identity_name" && "$identity_name" != [[:space:]]* && "$identity_name" != *[[:space:]] ]] \
    || invalid_arguments 'Developer ID Application identity must include a nonblank name.'
fi
if [[ "$output" != /* ]]; then output="$(pwd)/$output"; fi
if [[ -e "$output" || -L "$output" ]]; then
  echo 'Use a new output path. Existing apps are never replaced.' >&2
  exit 2
fi
mkdir -p "$(dirname "$output")"
stage="$(mktemp -d "$(dirname "$output")/.DesktopIntegration.XXXXXX")"
output_created=false
cleanup() {
  rm -rf "$stage"
  if [[ "$output_created" == true ]]; then rm -rf "$output"; fi
}
trap cleanup EXIT
scratch="$repo_root/.build/desktop-integration"
QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW=1 \
  swift build --package-path "$repo_root" --scratch-path "$scratch" --product QuotaTempo
build_dir="$(QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW=1 \
  swift build --package-path "$repo_root" --scratch-path "$scratch" --show-bin-path)"
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
signing=ad-hoc
sign_args=(--force --sign - --timestamp=none)
if [[ -n "$sign_identity" ]]; then
  signing=developer-id
  sign_args=(--force --options runtime --sign "$sign_identity" --timestamp)
  sparkle="$stage/Contents/Frameworks/Sparkle.framework"
  # Match package-release.sh: sign inside-out and retain Downloader's entitlements.
  codesign "${sign_args[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
  codesign "${sign_args[@]}" --preserve-metadata=entitlements \
    "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  codesign "${sign_args[@]}" "$sparkle/Versions/B/Autoupdate"
  codesign "${sign_args[@]}" "$sparkle/Versions/B/Updater.app"
  codesign "${sign_args[@]}" "$sparkle"
fi
codesign "${sign_args[@]}" "$stage/Contents/MacOS/QuotaTempo"
codesign "${sign_args[@]}" "$stage"
codesign --verify --deep --strict "$stage"
if [[ "$signing" == developer-id ]]; then
  # Validate the actual certificate chain and team, not just the requested name.
  requirement='=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
  requirement+=' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
  requirement+=" and certificate leaf[subject.OU] = \"$team_id\""
  requirement+=' and identifier "co.ishikawa.QuotaTempo.DesktopIntegrationPreview"'
  codesign --verify --strict --test-requirement "$requirement" "$stage"
fi
# Reserve the final path atomically, including when another build finishes first.
mkdir "$output"
output_created=true
mv "$stage/Contents" "$output/Contents"
rmdir "$stage"
trap - EXIT
printf 'Built local integration preview: %s\nsigning=%s\nnotarized=false\nNot launched, installed, notarized, or release-approved.\n' \
  "$output" "$signing"
