#!/usr/bin/env bash

set -euo pipefail

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
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"

swift build --package-path "$repo_root" -c release
build_dir="$(swift build --package-path "$repo_root" -c release --show-bin-path)"

install -m 644 "$repo_root/packaging/Info.plist" "$stage/Contents/Info.plist"
install -m 644 "$repo_root/THIRD_PARTY_NOTICES.md" "$stage/Contents/Resources/THIRD_PARTY_NOTICES.md"
install -m 644 "$repo_root/LICENSE" "$stage/Contents/Resources/LICENSE"
install -m 644 "$repo_root/PRIVACY.md" "$stage/Contents/Resources/PRIVACY.md"
install -m 644 "$repo_root/SUPPORT.md" "$stage/Contents/Resources/SUPPORT.md"
install -m 644 "$repo_root/UPDATES.md" "$stage/Contents/Resources/UPDATES.md"
install -m 755 "$build_dir/QuotaTempo" "$binary_stage/QuotaTempo"
strip -x "$binary_stage/QuotaTempo"
codesign --force --sign - --timestamp=none "$binary_stage/QuotaTempo"
install -m 755 "$binary_stage/QuotaTempo" "$stage/Contents/MacOS/QuotaTempo"
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
