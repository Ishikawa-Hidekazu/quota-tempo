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

# Keep reserved-argument refusal mandatory even though the normal app now
# includes the runtime opt-in feature. Headless acceptance remains preview-only.
required_refusal=(
  '--desktop-acceptance'
  '--consent-desktop-read-only'
  '--acknowledge-provider-permission-unconfirmed'
  '{"status":"desktopAcceptanceNotIncluded","passed":false}'
)
# Long runtime strings survive Swift small-string encoding and symbol stripping.
# Require the connection, consent, identity and transport paths in the main app.
required_inclusion=(
  'DesktopConnectionController'
  'DesktopIntegrationControls'
  'desktopConnection.consentRevision'
  'QuotaTempo-DesktopCandidate/'
  'quotatempo.desktop.account.v1:'
  'Claude Safe Storage'
  'https://api.anthropic.com/api/oauth/profile'
  'https://api.anthropic.com/api/oauth/usage'
)
require_main_markers() {
  local label="$1" marker status
  shift
  for marker in "$@"; do
    # Do not use -q/-m: read the entire file, including late I/O failures.
    if grep -aF -e "$marker" "$binary" >/dev/null; then
      continue
    else
      status=$?
      if [[ "$status" -eq 1 ]]; then
        echo "$label marker missing: $marker" >&2
      else
        echo "Unable to inspect $label (grep status $status)." >&2
      fi
      exit 2
    fi
  done
}
require_main_markers 'Public Desktop refusal' "${required_refusal[@]}"
require_main_markers 'Desktop connection inclusion' "${required_inclusion[@]}"

# Stable module/type names plus runtime identifiers, not mutable UI copy.
# A stripped candidate still carries runtime strings; an unstripped leak can
# also be found by its Swift mangled symbols without depending on nm output.
candidate_markers=(
  -e 'QuotaTempoDesktopCandidate'
  -e 'DesktopConnectionController'
  -e 'DesktopIntegrationControls'
  -e 'DesktopAcceptanceCommand'
  -e 'DesktopUsageHTTPTransport'
  -e 'DesktopCredentialLease'
  -e 'desktopConnection.consentRevision'
  -e 'QuotaTempo-DesktopCandidate/'
  -e 'quotatempo.desktop.account.v1:'
  -e 'Claude Safe Storage'
  -e 'https://api.anthropic.com/api/oauth/profile'
  -e 'https://api.anthropic.com/api/oauth/usage'
)
# Shared DesktopPreviewServing/Presentation and the persisted scheduling
# namespace are not preview entry points. Do not forbid those shared names.
preview_only=(
  -e 'DesktopAcceptanceCommand'
  -e 'DesktopAcceptanceRunner'
  -e 'DesktopAcceptanceConnecting'
  -e 'DesktopCandidateLocalProbe'
  -e 'DesktopPreviewApplication'
  -e 'DesktopPreviewModel'
  -e 'DesktopPreviewMenu'
  -e 'DesktopPreviewInstanceLock'
  -e 'DesktopPreviewTermination'
  -e 'desktop-local-preview'
  -e 'desktop-preview.lock'
  -e 'QuotaTempo.preview-termination'
  -e 'QuotaTempo Desktop Preview'
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
seen_main=false
seen_host=false
while true; do
  artifact=''
  if ! IFS= read -r -d '' artifact; then
    if [[ -n "$artifact" ]]; then
      echo 'Incomplete compiled artifact listing.' >&2
      exit 2
    fi
    break
  fi
  forbidden=("${preview_only[@]}")
  if [[ "$artifact" == "$binary" ]]; then
    seen_main=true
    label='Desktop preview-only implementation'
  else
    forbidden+=("${candidate_markers[@]}")
    label='Desktop candidate or preview-only implementation'
    if [[ "$artifact" == "$app/Contents/MacOS/QuotaTempoBrowserHost" ]]; then
      seen_host=true
    fi
  fi
  if grep -aF "${forbidden[@]}" "$artifact" >/dev/null; then
    echo "$label found in compiled artifact: $artifact" >&2
    exit 2
  else
    status=$?
    if [[ "$status" -ne 1 ]]; then
      echo "Unable to inspect compiled artifact (grep status $status): $artifact" >&2
      exit 2
    fi
  fi
done < "$files"
if [[ "$seen_main" != true || "$seen_host" != true ]]; then
  echo 'Required executables missing from compiled artifact listing.' >&2
  exit 2
fi

rm -f -- "$files"
trap - EXIT
printf 'desktop_compiled_artifact_isolation=PASS\n'
