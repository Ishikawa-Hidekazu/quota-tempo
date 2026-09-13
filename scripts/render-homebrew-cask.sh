#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 RELEASE_DIRECTORY OUTPUT_FILE" >&2
  exit 2
fi

release_dir="$1"
output="$2"
metadata="$release_dir/RELEASE-METADATA.json"
test -f "$metadata"
if [[ -e "$output" || -L "$output" ]]; then
  echo "Output already exists: $output" >&2
  exit 2
fi

archive="$(plutil -extract archive raw -o - "$metadata")"
release_version="$(plutil -extract release_version raw -o - "$metadata")"
channel="$(plutil -extract channel raw -o - "$metadata")"
test "$channel" = stable
sha256="$(awk -v file="$archive" '$2 == file { print $1; exit }' "$release_dir/SHA256SUMS")"
test -n "$sha256"

mkdir -p "$(dirname "$output")"
cat > "$output" <<EOF
cask "quotatempo" do
  version "$release_version"
  sha256 "$sha256"

  url "https://github.com/Ishikawa-Hidekazu/quota-tempo/releases/download/v#{version}/QuotaTempo-#{version}-macOS.zip"
  name "QuotaTempo"
  desc "Weekly AI capacity planner for Codex and Claude"
  homepage "https://ishikawa.co/en/projects/"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "QuotaTempo.app"

  zap trash: [
    "~/Library/Application Support/QuotaTempo",
    "~/Library/Preferences/co.ishikawa.QuotaTempo.plist",
  ]
end
EOF

printf 'homebrew_cask_render=PASS\noutput=%s\n' "$output"
