#!/bin/bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
usage() {
  printf '%s\n' \
    'Usage: build-code-comparison-preview.sh [new-output.app] [--sign-identity "Developer ID Application: Name (TEAMID)"] [--team-id TEAMID]' \
    'Code comparison preview only; bundles plugin 0.0.4. Default signing is ad-hoc.' \
    'Never launches, installs plugins, notarizes, publishes, or changes the normal app.'
}
invalid() { echo "$1" >&2; usage >&2; exit 2; }
if [[ $# -eq 1 && "$1" == --help ]]; then usage; exit 0; fi
output="$repo_root/dist/QuotaTempoCodeComparisonPreview.app"
output_set=false
identity=''
team=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign-identity|--team-id)
      option="$1"
      [[ $# -ge 2 && -n "${2//[[:space:]]/}" && "$2" != -* && ! "$2" =~ [[:cntrl:]] ]] \
        || invalid 'Invalid signing option.'
      if [[ "$option" == --sign-identity ]]; then
        [[ -z "$identity" ]] || invalid 'Duplicate identity.'
        identity="$2"
      else
        [[ -z "$team" ]] || invalid 'Duplicate team.'
        team="$2"
      fi
      shift 2 ;;
    --)
      shift
      [[ $# -eq 1 && "$output_set" == false ]] || invalid 'Provide exactly one output.'
      output="$1"; output_set=true; shift ;;
    -*) invalid 'Unknown option.' ;;
    *)
      [[ "$output_set" == false ]] || invalid 'Provide exactly one output.'
      output="$1"; output_set=true; shift ;;
  esac
done
[[ -n "${output//[[:space:]]/}" && ! "$output" =~ [[:cntrl:]] ]] || invalid 'Invalid output.'
sign_options=()
sign_args=(--force --sign - --timestamp=none)
if [[ -n "$identity" || -n "$team" ]]; then
  [[ -n "$identity" && "$team" =~ ^[A-Z0-9]{10}$ \
    && "$identity" == 'Developer ID Application: '*" ($team)" ]] || invalid 'Identity and team must match.'
  identity_name="${identity#'Developer ID Application: '}"
  identity_name="${identity_name%" ($team)"}"
  [[ -n "${identity_name//[[:space:]]/}" && "$identity_name" != [[:space:]]* \
    && "$identity_name" != *[[:space:]] ]] || invalid 'Invalid identity name.'
  sign_options=(--sign-identity "$identity" --team-id "$team")
  sign_args=(--force --options runtime --sign "$identity" --timestamp)
fi
if [[ "$output" != /* ]]; then output="$(pwd)/$output"; fi
if [[ -e "$output" || -L "$output" ]]; then
  echo 'Use a fresh output path. Existing apps are never replaced.' >&2
  exit 2
fi
native_pin="$(node --input-type=module - "$repo_root/Sources/QuotaTempoApp/CodeComparisonPluginPackage.swift" <<'JS'
import { readFileSync } from 'node:fs';
const source = readFileSync(process.argv[2], 'utf8');
function constant(name, pattern) {
  const matches = [...source.matchAll(new RegExp('^  static let ' + name + '[ \\t]*=[ \\t]*(?:\\r?\\n[ \\t]*)?"([^"\\r\\n]*)"[ \\t]*$', 'gm'))];
  if (matches.length !== 1 || !pattern.test(matches[0][1])) throw new Error('native_package_pin_unset_or_invalid');
  return matches[0][1];
}
const name = constant('nativeMarketplaceName', /^quotatempo-code-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
const digest = constant('nativeManifestDigest', /^[0-9a-f]{64}$/);
process.stdout.write(name + ' ' + digest);
JS
)"
read -r native_marketplace native_digest <<< "$native_pin"
parent="$(dirname "$output")"
mkdir -p "$parent"
stage="$(mktemp -d "$parent/.CodeComparison.XXXXXX")"
stage_identity="$(/usr/bin/stat -f '%d:%i' "$stage")"
cleanup() {
  if [[ ! -L "$stage" && -d "$stage" \
    && "$(/usr/bin/stat -f '%d:%i' "$stage")" == "$stage_identity" ]]; then
    rm -rf -- "$stage"
  else
    echo 'Unknown staging retained; no cleanup was attempted.' >&2
  fi
}
trap cleanup EXIT
preview="$stage/CodePreview.app"
if [[ -n "$identity" ]]; then
  bash "$repo_root/scripts/build-desktop-integration-preview.sh" "$preview" "${sign_options[@]}" >/dev/null
else
  bash "$repo_root/scripts/build-desktop-integration-preview.sh" "$preview" >/dev/null
fi
package="$preview/Contents/Resources/CodeComparisonPlugin"
node "$repo_root/scripts/package-code-comparison-plugin.mjs" pack \
  --source "$repo_root/experiments/claude-mods-usage" --destination "$package" \
  --marketplace-name "$native_marketplace" >/dev/null
verify_package() {
  node --input-type=module - "$repo_root/scripts/package-code-comparison-plugin.mjs" "$package" <<'JS'
import { pathToFileURL } from 'node:url';
const { verifyPackage } = await import(pathToFileURL(process.argv[2]).href);
const result = await verifyPackage(process.argv[3]);
if (result.version !== '0.0.4') throw new Error('code_preview_requires_plugin_0_0_4');
JS
}
verify_package
manifest_digest="$(node --input-type=module - "$package/quotatempo-package.json" <<'JS'
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
process.stdout.write(createHash('sha256').update(readFileSync(process.argv[2])).digest('hex'));
JS
)"
[[ "$manifest_digest" =~ ^[0-9a-f]{64}$ ]]
[[ "$manifest_digest" == "$native_digest" ]] || { echo 'Compiled native package pin mismatch.' >&2; exit 2; }
plist=/usr/libexec/PlistBuddy
info="$preview/Contents/Info.plist"
# The Desktop builder inherits public Code metadata. Replace it with this
# preview's pinned values and types before sealing; never retain a prior team.
"$plist" -c Print "$info" >/dev/null
for key in QTCodeComparisonPluginBundled QTCodeComparisonManifestDigest \
  QTCodeComparisonSigningMode QTCodeComparisonSigningTeam; do
  if "$plist" -c "Print :$key" "$info" >/dev/null 2>&1; then
    "$plist" -c "Delete :$key" "$info"
  fi
done
for command in \
  'Set :CFBundleIdentifier co.ishikawa.QuotaTempo.CodeComparisonPreview' \
  'Set :CFBundleName QuotaTempoCodeComparisonPreview' \
  'Set :CFBundleDisplayName QuotaTempo Code Comparison Preview' \
  'Set :QTReleaseChannel code-comparison-preview' \
  'Add :QTCodeComparisonPluginBundled bool true'; do
  "$plist" -c "$command" "$info"
done
"$plist" -c "Add :QTCodeComparisonManifestDigest string $manifest_digest" "$info"
if [[ -n "$identity" ]]; then
  "$plist" -c 'Add :QTCodeComparisonSigningMode string developer-id' "$info"
  "$plist" -c "Add :QTCodeComparisonSigningTeam string $team" "$info"
else
  "$plist" -c 'Add :QTCodeComparisonSigningMode string local-ad-hoc' "$info"
fi
verify_preview() {
  "$plist" -c Print "$info" >/dev/null
  [[ "$("$plist" -c 'Print :CFBundleIdentifier' "$info")" == co.ishikawa.QuotaTempo.CodeComparisonPreview ]] || return 2
  [[ "$("$plist" -c 'Print :QTReleaseChannel' "$info")" == code-comparison-preview ]] || return 2
  [[ "$("$plist" -c 'Print :QTCodeComparisonPluginBundled' "$info")" == true ]] || return 2
  [[ "$("$plist" -c 'Print :QTCodeComparisonManifestDigest' "$info")" == "$manifest_digest" ]] || return 2
  node --input-type=module - "$package/quotatempo-package.json" "$manifest_digest" <<'JS'
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
if (createHash('sha256').update(readFileSync(process.argv[2])).digest('hex') !== process.argv[3])
  throw new Error('code_preview_manifest_pin_mismatch');
JS
  if [[ -n "$identity" ]]; then
    [[ "$("$plist" -c 'Print :QTCodeComparisonSigningMode' "$info")" == developer-id ]] || return 2
    [[ "$("$plist" -c 'Print :QTCodeComparisonSigningTeam' "$info")" == "$team" ]] || return 2
  else
    [[ "$("$plist" -c 'Print :QTCodeComparisonSigningMode' "$info")" == local-ad-hoc ]] || return 2
    if "$plist" -c 'Print :QTCodeComparisonSigningTeam' "$info" >/dev/null 2>&1; then return 2; fi
  fi
  for key in SUFeedURL SUPublicEDKey; do
    if "$plist" -c "Print :$key" "$info" >/dev/null 2>&1; then
      echo 'Code preview must not contain an updater feed or release key.' >&2
      return 2
    fi
  done
  verify_package
}
verify_preview
codesign "${sign_args[@]}" "$preview/Contents/MacOS/QuotaTempo"
codesign "${sign_args[@]}" "$preview"
codesign --verify --deep --strict "$preview"
if [[ -n "$identity" ]]; then
  requirement='=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
  requirement+=' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
  requirement+=" and certificate leaf[subject.OU] = \"$team\""
  requirement+=' and identifier "co.ishikawa.QuotaTempo.CodeComparisonPreview"'
  codesign --verify --strict --test-requirement "$requirement" "$preview"
fi
verify_preview
# Reserve exclusively only after verification; never clean up or replace an
# output that another operator may have changed. A publish failure is not ready.
mkdir "$output"
if ! mv "$preview/Contents" "$output/Contents"; then
  echo 'Output reserved but publishing failed. Do not launch it; use a fresh path.' >&2
  exit 2
fi
printf 'Built Code comparison preview: %s\nplugin=0.0.4\nnotarized=false\nNo launch, plugin install, provider request or public release performed.\n' "$output"
