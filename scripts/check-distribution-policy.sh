#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 CHANNEL SIGNING NOTARIZED" >&2
  exit 2
fi

channel="$1"
signing="$2"
notarized="$3"

if [[ "$channel" != stable ]]; then
  echo "Distribution metadata must use the stable channel." >&2
  exit 2
fi
if [[ "$signing" != developer-id ]]; then
  echo "Distribution metadata must use Developer ID signing." >&2
  exit 2
fi
if [[ "$notarized" != true ]]; then
  echo "Distribution metadata must be notarized." >&2
  exit 2
fi

echo "distribution_policy=PASS"
