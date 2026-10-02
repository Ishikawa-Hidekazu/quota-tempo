#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

if [[ $# -ne 1 || ! -d "$1/Contents" ]]; then
  echo "Usage: $0 APP_BUNDLE" >&2
  exit 2
fi

app="$(cd "$1" && pwd -P)"
binary="$app/Contents/MacOS/QuotaTempo"
for executable in "$binary" "$app/Contents/MacOS/QuotaTempoBrowserHost"; do
  if [[ ! -f "$executable" || ! -x "$executable" || -L "$executable" ]]; then
    echo "Missing regular bundle executable: $executable" >&2
    exit 2
  fi
done

# These long strings survive Swift small-string encoding and symbol stripping.
# Keep the public refusal separate from candidate-only implementation markers.
required=(
  '--desktop-acceptance'
  '--consent-desktop-read-only'
  '--acknowledge-provider-permission-unconfirmed'
  '{"status":"desktopAcceptanceNotIncluded","passed":false}'
)
for marker in "${required[@]}"; do
  # Do not use -q/-m: the entire file must be read, including late I/O failures.
  if grep -aF -e "$marker" "$binary" >/dev/null; then
    continue
  else
    status=$?
    if [[ "$status" -eq 1 ]]; then
      echo "Public Desktop refusal marker missing: $marker" >&2
    else
      echo "Unable to inspect public Desktop refusal (grep status $status)." >&2
    fi
    exit 2
  fi
done

# Stable module/type names plus runtime identifiers, not mutable UI copy.
# A stripped candidate still carries runtime strings; an unstripped leak can
# also be found by its Swift mangled symbols without depending on nm output.
forbidden=(
  -e 'QuotaTempoDesktopCandidate'
  -e 'DesktopConnectionController'
  -e 'DesktopIntegrationControls'
  -e 'DesktopAcceptanceCommand'
  -e 'DesktopUsageHTTPTransport'
  -e 'DesktopCredentialLease'
  -e 'desktopConnection.consentRevision'
  -e 'QuotaTempo-DesktopCandidate/'
  -e 'quotatempo.desktop.account.v1:'
)

files="$(mktemp "${TMPDIR:-/tmp}/quota-tempo-artifact-isolation.XXXXXX")"
trap 'rm -f -- "$files"' EXIT
# Top-level documentation (notably PRIVACY.md) legitimately names the candidate.
# Inspect code directories, executable files, and libraries/objects even without
# execute permission. Materialize find output so enumeration failures propagate.
find "$app/Contents" -type f \( \
  -path '*/Contents/MacOS/*' -o -path '*.framework/*' \
  -o -perm -100 -o -perm -010 -o -perm -001 \
  -o -name '*.dylib' -o -name '*.so' -o -name '*.a' -o -name '*.o' \
  \) -print0 > "$files"
if [[ ! -s "$files" ]]; then
  echo 'No compiled bundle artifacts found.' >&2
  exit 2
fi
while IFS= read -r -d '' artifact; do
  if grep -aF "${forbidden[@]}" "$artifact" >/dev/null; then
    echo "Desktop candidate implementation found in compiled artifact: $artifact" >&2
    exit 2
  else
    status=$?
    if [[ "$status" -ne 1 ]]; then
      echo "Unable to inspect compiled artifact (grep status $status): $artifact" >&2
      exit 2
    fi
  fi
done < "$files"

rm -f -- "$files"
trap - EXIT
printf 'desktop_compiled_artifact_isolation=PASS\n'
