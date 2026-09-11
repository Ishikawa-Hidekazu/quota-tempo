#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qa_root="$(mktemp -d /tmp/quota-tempo-menu-refresh.XXXXXX)"
qa_app="$qa_root/QuotaTempoQA.app"
qa_store="$qa_root/store"
qa_pid=""

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  if [[ -n "$qa_pid" ]] && kill -0 "$qa_pid" 2>/dev/null; then
    kill "$qa_pid" 2>/dev/null || true
    wait "$qa_pid" 2>/dev/null || true
  fi
  if [[ "$qa_root" == /tmp/quota-tempo-menu-refresh.* ]]; then
    find "$qa_root" -depth -delete
  fi
}
trap cleanup EXIT

command -v jq >/dev/null || {
  echo "jq is required for the isolated menu-bar refresh test." >&2
  exit 2
}

mkdir -p "$qa_store"
"$repo_root/scripts/build-app-bundle.sh" "$qa_app" >/dev/null

# Give the QA instance its own process and bundle identity so it cannot attach
# to or read the owner's installed QuotaTempo instance.
mv "$qa_app/Contents/MacOS/QuotaTempo" "$qa_app/Contents/MacOS/QuotaTempoQA"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable QuotaTempoQA' \
  "$qa_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier co.ishikawa.QuotaTempo.QA' \
  "$qa_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName QuotaTempoQA' \
  "$qa_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName QuotaTempoQA' \
  "$qa_app/Contents/Info.plist"
codesign --force --deep --sign - --timestamp=none "$qa_app" >/dev/null

now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
reset_epoch="$(($(date +%s) + 302400))"
reset_iso="$(date -u -r "$reset_epoch" '+%Y-%m-%dT%H:%M:%SZ')"

jq -n --arg now "$now_iso" \
  '{provider:"codex",source:"codexAppServer",capturedAt:$now,weekly:null,fiveHour:null,sourceState:"observationSucceeded"}' \
  > "$qa_store/codex.json"
jq -n --arg now "$now_iso" \
  '{provider:"claude",source:"claudeDesktopHistory",capturedAt:$now,weekly:{remainingPercent:85,durationSeconds:604800,resetAt:null},fiveHour:null,sourceState:"observationSucceeded"}' \
  > "$qa_store/claude.json"

"$qa_app/Contents/MacOS/QuotaTempoQA" \
  --provider-disabled \
  -menuBarDisplayMode full \
  --storage-directory "$qa_store" \
  >/dev/null 2>&1 &
qa_pid=$!

menu_title() {
  osascript - "$qa_pid" <<'APPLESCRIPT'
on run argv
  set targetPid to item 1 of argv as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPid
    tell targetProcess to return title of every menu bar item of menu bar 2
  end tell
end run
APPLESCRIPT
}

initial=""
for _ in {1..80}; do
  kill -0 "$qa_pid" 2>/dev/null || {
    echo "The isolated menu-bar process exited before accessibility discovery." >&2
    exit 1
  }
  initial="$(menu_title 2>/dev/null || true)"
  [[ -n "$initial" ]] && break
  sleep 0.25
done
printf 'initial=%s\n' "$initial"
if [[ "$initial" != *'Cl W85/P— —'* ]]; then
  echo "The isolated menu-bar item did not reach the expected initial state." >&2
  exit 1
fi

updated="$qa_store/.claude.updated.json"
jq --arg reset "$reset_iso" '.weekly.resetAt=$reset' \
  "$qa_store/claude.json" > "$updated"
mv "$updated" "$qa_store/claude.json"

current="$initial"
for elapsed in {1..40}; do
  sleep 2
  current="$(menu_title 2>/dev/null || true)"
  if [[ "$current" == *'Cl W85/P50 ↑35'* ]]; then
    printf 'updated=%s\n' "$current"
    printf 'elapsed_seconds=%s\n' "$((elapsed * 2))"
    printf 'no_click_auto_refresh=PASS\n'
    exit 0
  fi
done

printf 'final=%s\n' "$current"
printf 'no_click_auto_refresh=FAIL\n'
exit 1
