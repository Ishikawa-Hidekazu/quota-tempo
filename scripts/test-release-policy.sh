#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="$repo_root/scripts/check-release-policy.sh"
identity="$repo_root/scripts/check-release-identity.sh"

"$policy" rc.7 ad-hoc false false
"$policy" stable developer-id false false
"$policy" stable developer-id true true

if "$policy" stable ad-hoc false false 2>/dev/null; then exit 1; fi
if "$policy" stable developer-id false true 2>/dev/null; then exit 1; fi
if "$policy" rc.7 developer-id false true 2>/dev/null; then exit 1; fi

"$identity" \
  developer-id \
  co.ishikawa.QuotaTempo \
  9AQKR642UU \
  co.ishikawa.QuotaTempo \
  co.ishikawa.QuotaTempo \
  9AQKR642UU \
  co.ishikawa.QuotaTempo \
  9AQKR642UU
"$identity" \
  ad-hoc \
  co.ishikawa.QuotaTempo \
  none \
  co.ishikawa.QuotaTempo \
  co.ishikawa.QuotaTempo \
  none \
  co.ishikawa.QuotaTempo \
  none

if "$identity" developer-id com.example.Wrong 9AQKR642UU \
  co.ishikawa.QuotaTempo co.ishikawa.QuotaTempo 9AQKR642UU \
  co.ishikawa.QuotaTempo 9AQKR642UU 2>/dev/null
then
  exit 1
fi
if "$identity" developer-id co.ishikawa.QuotaTempo WRONGTEAM \
  co.ishikawa.QuotaTempo co.ishikawa.QuotaTempo 9AQKR642UU \
  co.ishikawa.QuotaTempo 9AQKR642UU 2>/dev/null
then
  exit 1
fi
if "$identity" developer-id co.ishikawa.QuotaTempo 9AQKR642UU \
  co.ishikawa.QuotaTempo co.ishikawa.QuotaTempo WRONGTEAM \
  co.ishikawa.QuotaTempo 9AQKR642UU 2>/dev/null
then
  exit 1
fi
if "$identity" developer-id co.ishikawa.QuotaTempo 9AQKR642UU \
  co.ishikawa.QuotaTempo co.ishikawa.QuotaTempo 9AQKR642UU \
  com.example.Wrong 9AQKR642UU 2>/dev/null
then
  exit 1
fi

printf 'release_policy_test=PASS\n'
