#!/usr/bin/env bash

set -euo pipefail

skip_launch=false
if [[ $# -eq 1 && "$1" == "--skip-launch" ]]; then
  skip_launch=true
elif [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--skip-launch]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d /tmp/quota-tempo-bundle-test.XXXXXX)"
first="$tmp/first/QuotaTempo.app"
second="$tmp/second/QuotaTempo.app"
pid=""

cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  if [[ "$tmp" == /tmp/quota-tempo-bundle-test.* ]]; then /bin/rm -rf -- "$tmp"; fi
}
trap cleanup EXIT

"$repo_root/scripts/build-app-bundle.sh" "$first"
"$repo_root/scripts/build-app-bundle.sh" "$second"

test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$first/Contents/Info.plist")" = true
test -x "$first/Contents/MacOS/QuotaTempo"
test -d "$first/Contents/Resources/QuotaTempoCoreResources"
test ! -e "$first/Contents/Resources/QuotaTempoCoreResources/Fixtures"
test ! -e "$first/Contents/Helpers"
test -f "$first/Contents/Resources/QuotaTempo.icns"
test -f "$first/Contents/Resources/THIRD_PARTY_NOTICES.md"
test -f "$first/Contents/Resources/LICENSE"
test -f "$first/Contents/Resources/PRIVACY.md"
test -f "$first/Contents/Resources/SUPPORT.md"
test -f "$first/Contents/Resources/UPDATES.md"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$first/Contents/Info.plist")" = "QuotaTempo"
test ! -e "$first/Contents/Resources/QuotaTempo_QuotaTempoCore.bundle"
test "$(stat -f '%Lp' "$first/Contents/Info.plist")" = 644
test "$(stat -f '%Lp' "$first/Contents/Resources/THIRD_PARTY_NOTICES.md")" = 644
test "$(stat -f '%Lp' "$first/Contents/Resources/LICENSE")" = 644
test "$(stat -f '%Lp' "$first/Contents/Resources/PRIVACY.md")" = 644
test "$(stat -f '%Lp' "$first/Contents/Resources/SUPPORT.md")" = 644
test "$(stat -f '%Lp' "$first/Contents/Resources/UPDATES.md")" = 644
test "$(stat -f '%Lp' "$first/Contents/MacOS/QuotaTempo")" = 755
if find "$first" -type d ! -perm 755 -print -quit | grep -q .; then
  echo "Bundle contains a directory without mode 755." >&2
  exit 2
fi
if find "$first/Contents/Resources" -type f ! -perm 644 -print -quit | grep -q .; then
  echo "Bundle contains a resource without mode 644." >&2
  exit 2
fi
diff -u "$first/Contents/Resources/SHA256SUMS" "$second/Contents/Resources/SHA256SUMS"

binary="$first/Contents/MacOS/QuotaTempo"
if LC_ALL=C grep -a -m 1 -E '/Users/[^/]+/|/home/[^/]+/' "$binary" >/dev/null; then
  echo "Bundle binary contains a developer home path: $binary" >&2
  exit 2
fi

(
  cd "$first"
  shasum -a 256 -c Contents/Resources/SHA256SUMS
) >/dev/null

if [[ "$skip_launch" == false ]]; then
  open -n "$first" --args --provider-disabled --exercise-provider-triggers \
    --present-application-window \
    -hasCompletedOnboarding false \
    -menuBarDisplayMode iconOnly \
    --storage-directory "$tmp/store"
  sleep 2
  canonical_first="$(cd "$(dirname "$first")" && pwd -P)/$(basename "$first")"
  pid="$(pgrep -f "^$canonical_first/Contents/MacOS/QuotaTempo" | head -n 1)"
  test -n "$pid"
  window_title="$(osascript - "$pid" <<'APPLESCRIPT'
on run argv
  set targetPid to item 1 of argv as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPid
    tell targetProcess to return title of every window
  end tell
end run
APPLESCRIPT
)"
  [[ "$window_title" == *QuotaTempo* ]]
  test ! -e "$tmp/store/codex.json"
  test ! -e "$tmp/store/claude.json"
  kill "$pid"
  pid=""
  trigger_result="PASS"
else
  trigger_result="SKIP"
fi

printf 'app_bundle_test=PASS\nartifact=%s\nprovider_trigger_test=%s\napplication_window_test=%s\nprovider_record_absent=true\n' \
  "$first" "$trigger_result" "$trigger_result"
cleanup
trap - EXIT
test ! -e "$tmp"
printf 'temp_cleanup=PASS\n'
