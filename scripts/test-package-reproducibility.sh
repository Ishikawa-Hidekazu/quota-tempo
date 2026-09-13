#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d /tmp/quota-tempo-reproducibility.XXXXXX)"
trap 'if [[ "$tmp" == /tmp/quota-tempo-reproducibility.* ]]; then /bin/rm -rf -- "$tmp"; fi' EXIT

test_repo="$repo_root"
release_channel="$(tr -d '[:space:]' < "$repo_root/packaging/release-channel.txt")"
if [[ "$release_channel" == "stable" ]]; then
  test_repo="$tmp/rc-fixture"
  git clone --quiet --no-hardlinks "$repo_root" "$test_repo"
  printf 'rc.20\n' > "$test_repo/packaging/release-channel.txt"
  git -C "$test_repo" add packaging/release-channel.txt
  git -C "$test_repo" \
    -c user.name='QuotaTempo CI' \
    -c user.email='ci@invalid.example' \
    commit --quiet -m 'Create isolated RC packaging fixture'
fi

first="$tmp/first"
second="$tmp/second"
"$test_repo/scripts/package-release.sh" "$first"
"$test_repo/scripts/package-release.sh" "$second"

first_archive="$(plutil -extract archive raw -o - "$first/RELEASE-METADATA.json")"
second_archive="$(plutil -extract archive raw -o - "$second/RELEASE-METADATA.json")"
first_sha="$(shasum -a 256 "$first/$first_archive" | awk '{print $1}')"
second_sha="$(shasum -a 256 "$second/$second_archive" | awk '{print $1}')"

if [[ "$first_archive" != "$second_archive" || "$first_sha" != "$second_sha" ]]; then
  echo "Repeated packaging in the same clean checkout was not byte-identical." >&2
  exit 1
fi

printf 'package_reproducibility=PASS\nscope=same-clean-checkout\nsha256=%s\n' "$first_sha"
