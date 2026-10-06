#!/usr/bin/env bash

set -euo pipefail

if [[ "${QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW:-}" == 1 ]]; then
  echo 'Desktop integration preview cannot be packaged as a distribution app.' >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$repo_root/dist/QuotaTempo.app}"
parent="$(dirname "$output")"

if [[ -e "$output" || -L "$output" ]]; then
  echo "Output already exists: $output" >&2
  exit 2
fi

mkdir -p "$parent"
stage="$(mktemp -d "$parent/.QuotaTempo.app.stage.XXXXXX")"
binary_stage="$(mktemp -d "$parent/.QuotaTempo.binaries.stage.XXXXXX")"
trap 'rm -rf "$stage" "$binary_stage"' EXIT
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources" "$stage/Contents/Frameworks"

swift build --package-path "$repo_root" -c release
build_dir="$(swift build --package-path "$repo_root" -c release --show-bin-path)"

install -m 644 "$repo_root/packaging/Info.plist" "$stage/Contents/Info.plist"
install -m 644 "$repo_root/THIRD_PARTY_NOTICES.md" "$stage/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 644 "$repo_root/LICENSE" "$stage/Contents/Resources/LICENSE"
install -m 644 "$repo_root/PRIVACY.md" "$stage/Contents/Resources/PRIVACY.md"
install -m 644 "$repo_root/SUPPORT.md" "$stage/Contents/Resources/SUPPORT.md"
install -m 644 "$repo_root/UPDATES.md" "$stage/Contents/Resources/UPDATES.md"
install -m 644 "$repo_root/.build/artifacts/sparkle/Sparkle/LICENSE" \
  "$stage/Contents/Resources/SPARKLE-LICENSE"
# Package immutable Code resources while they still have private staging modes.
# The app never executes the optional Node tools; users invoke them explicitly.
node --input-type=module - "$repo_root" "$stage" <<'JS'
import { readFileSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = realpathSync(process.argv[2]);
const stage = realpathSync(process.argv[3]);
const source = readFileSync(join(root, 'Sources/QuotaTempoApp/CodeComparisonPluginPackage.swift'), 'utf8');
function constant(name, pattern) {
  const matches = [...source.matchAll(new RegExp('^  static let ' + name + '[ \\t]*=[ \\t]*(?:\\r?\\n[ \\t]*)?"([^"\\r\\n]*)"[ \\t]*$', 'gm'))];
  if (matches.length !== 1 || !pattern.test(matches[0][1])) throw new Error('native_package_pin_unset_or_invalid');
  return matches[0][1];
}
const marketplaceName = constant('nativeMarketplaceName', /^quotatempo-code-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
const digest = constant('nativeManifestDigest', /^[0-9a-f]{64}$/);
const { packPlugin, verifyPackage } = await import(pathToFileURL(join(root, 'scripts/package-code-comparison-plugin.mjs')));
const destination = join(stage, 'Contents/Resources/CodeComparisonPlugin');
await packPlugin({ source: join(root, 'experiments/claude-mods-usage'), destination, marketplaceName });
const result = await verifyPackage(destination);
if (result.version !== '0.0.4' || result.packageDigest !== digest || result.marketplaceName !== marketplaceName)
  throw new Error('public_code_package_pin_mismatch');
JS
manifest_digest="$(shasum -a 256 "$stage/Contents/Resources/CodeComparisonPlugin/quotatempo-package.json" | awk '{print $1}')"
plist=/usr/libexec/PlistBuddy
[[ "$("$plist" -c 'Print :QTCodeComparisonManifestDigest' "$stage/Contents/Info.plist")" == "$manifest_digest" ]]
[[ "$("$plist" -c 'Print :QTCodeComparisonPluginBundled' "$stage/Contents/Info.plist")" == true ]]
mkdir -p "$stage/Contents/Resources/CodePluginTools"
for tool in manage-code-comparison-plugin.mjs package-code-comparison-plugin.mjs; do
  install -m 644 "$repo_root/scripts/$tool" "$stage/Contents/Resources/CodePluginTools/$tool"
done
install -m 755 "$build_dir/QuotaTempo" "$binary_stage/QuotaTempo"
strip -x "$binary_stage/QuotaTempo"
install_name_tool -add_rpath @executable_path/../Frameworks "$binary_stage/QuotaTempo"
codesign --force --sign - --timestamp=none --identifier co.ishikawa.QuotaTempo "$binary_stage/QuotaTempo"
install -m 755 "$binary_stage/QuotaTempo" "$stage/Contents/MacOS/QuotaTempo"
install -m 755 "$build_dir/QuotaTempoBrowserHost" "$binary_stage/QuotaTempoBrowserHost"
strip -x "$binary_stage/QuotaTempoBrowserHost"
codesign --force --sign - --timestamp=none "$binary_stage/QuotaTempoBrowserHost"
install -m 755 "$binary_stage/QuotaTempoBrowserHost" "$stage/Contents/MacOS/QuotaTempoBrowserHost"
ditto "$build_dir/Sparkle.framework" "$stage/Contents/Frameworks/Sparkle.framework"
mkdir -p "$stage/Contents/Resources/QuotaTempoCoreResources"
cp -R "$repo_root/Sources/QuotaTempoCore/Resources/en.lproj" \
  "$stage/Contents/Resources/QuotaTempoCoreResources/en.lproj"
cp -R "$repo_root/Sources/QuotaTempoCore/Resources/ja.lproj" \
  "$stage/Contents/Resources/QuotaTempoCoreResources/ja.lproj"
swift "$repo_root/scripts/generate-app-icon.swift" \
  "$stage/Contents/Resources/QuotaTempo.icns"
/usr/bin/find "$stage" -type d -exec chmod 755 {} +
/usr/bin/find "$stage/Contents/Resources" -type f -exec chmod 644 {} +

(
  cd "$stage"
  find Contents -type f ! -name SHA256SUMS -print \
    | LC_ALL=C sort \
    | while IFS= read -r file; do
        shasum -a 256 "$file"
      done > Contents/Resources/SHA256SUMS
  chmod 644 Contents/Resources/SHA256SUMS
)

mv "$stage" "$output"
rm -rf "$binary_stage"
trap - EXIT
printf 'Built %s\n' "$output"
