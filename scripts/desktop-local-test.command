#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$root/dist/desktop-local-probe/QuotaTempoDesktopLocalProbe"
if [[ ! -x "$binary" ]]; then
  printf '%s\n' 'The local diagnostic has not been built. No access was attempted.'
  exit 1
fi
codesign --verify --strict \
  -R='identifier "co.ishikawa.QuotaTempo.DesktopLocalProbe" and anchor apple generic and certificate leaf[subject.OU] = "9AQKR642UU"' \
  "$binary"
"$binary" --consent-desktop-read-only \
  --acknowledge-provider-permission-unconfirmed --request-keychain-access
