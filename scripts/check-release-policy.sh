#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 CHANNEL SIGNING NOTARIZED REQUIRE_NOTARIZED" >&2
  exit 2
fi

channel="$1"
signing="$2"
notarized="$3"
require_notarized="$4"

if [[ ! "$channel" =~ ^(stable|rc\.[1-9][0-9]*)$ ]]; then exit 2; fi
if [[ ! "$signing" =~ ^(ad-hoc|developer-id)$ ]]; then exit 2; fi
if [[ ! "$notarized" =~ ^(true|false)$ ]]; then exit 2; fi
if [[ ! "$require_notarized" =~ ^(true|false)$ ]]; then exit 2; fi

# A stable intermediate must be Developer ID signed before notarization, but it
# is expected to remain notarized=false until the separate notarization step.
if [[ "$channel" == "stable" ]]; then
  test "$signing" = "developer-id"
fi

# Only the final public-artifact verification requires the stapled state.
if [[ "$require_notarized" == true ]]; then
  test "$signing" = "developer-id"
  test "$notarized" = "true"
fi
