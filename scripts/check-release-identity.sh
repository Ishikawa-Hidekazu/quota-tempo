#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 8 ]]; then
  echo "Usage: $0 SIGNING METADATA_BUNDLE_ID METADATA_TEAM_ID PLIST_BUNDLE_ID OUTER_CODE_ID OUTER_TEAM_ID NESTED_CODE_ID NESTED_TEAM_ID" >&2
  exit 2
fi

signing="$1"
metadata_bundle_id="$2"
metadata_team_id="$3"
plist_bundle_id="$4"
outer_code_id="$5"
outer_team_id="$6"
nested_code_id="$7"
nested_team_id="$8"

expected_bundle_id="co.ishikawa.QuotaTempo"
expected_team_id="9AQKR642UU"

if [[ ! "$signing" =~ ^(ad-hoc|developer-id)$ ]]; then
  echo "Invalid signing class: $signing" >&2
  exit 2
fi

for actual_bundle_id in \
  "$metadata_bundle_id" \
  "$plist_bundle_id" \
  "$outer_code_id" \
  "$nested_code_id"
do
  if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
    echo "Release bundle identity does not match the pinned product identity." >&2
    exit 2
  fi
done

if [[ "$signing" == "developer-id" ]]; then
  for actual_team_id in "$metadata_team_id" "$outer_team_id" "$nested_team_id"; do
    if [[ "$actual_team_id" != "$expected_team_id" ]]; then
      echo "Developer ID team does not match the pinned release team." >&2
      exit 2
    fi
  done
else
  for actual_team_id in "$metadata_team_id" "$outer_team_id" "$nested_team_id"; do
    if [[ "$actual_team_id" != "none" ]]; then
      echo "Ad-hoc releases must not record a Developer ID team." >&2
      exit 2
    fi
  done
fi
