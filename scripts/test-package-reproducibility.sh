#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_channel="$(tr -d '[:space:]' < "$repo_root/packaging/release-channel.txt")"
if [[ "$release_channel" == "stable" ]]; then
  printf 'package_reproducibility=SKIP\nreason=stable-requires-owner-managed-developer-id\n'
  exit 0
fi

tmp="$(mktemp -d /tmp/quota-tempo-reproducibility.XXXXXX)"
trap 'if [[ "$tmp" == /tmp/quota-tempo-reproducibility.* ]]; then /bin/rm -rf -- "$tmp"; fi' EXIT

first="$tmp/first"
second="$tmp/second"
"$repo_root/scripts/package-release.sh" "$first"
"$repo_root/scripts/package-release.sh" "$second"

first_archive="$(plutil -extract archive raw -o - "$first/RELEASE-METADATA.json")"
second_archive="$(plutil -extract archive raw -o - "$second/RELEASE-METADATA.json")"
first_sha="$(shasum -a 256 "$first/$first_archive" | awk '{print $1}')"
second_sha="$(shasum -a 256 "$second/$second_archive" | awk '{print $1}')"

if [[ "$first_archive" != "$second_archive" || "$first_sha" != "$second_sha" ]]; then
  echo "Repeated packaging in the same clean checkout was not byte-identical." >&2
  exit 1
fi

printf 'package_reproducibility=PASS\nscope=same-clean-checkout\nsha256=%s\n' "$first_sha"
