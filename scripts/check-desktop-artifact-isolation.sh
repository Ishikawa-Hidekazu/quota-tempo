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
required_code_refusal=(
  '--code-comparison-startup-validation'
  '--code-comparison-package-validation'
  '{"status":"startupValidationNotIncluded","passed":false}'
  '{"status":"codePackageValidationNotIncluded","passed":false}'
)
required_code_inclusion=(
  'CodeComparisonIPCBridge'
  'CodeComparisonEncryption'
  'CodeComparisonPluginPackage'
  'CodeUsageComparisonController'
  'CodeUsageComparisonControls'
  'QuotaTempo.CodeComparison.IPC'
  'QuotaTempo.CodeComparison.response.v3'
)
require_main_markers 'Public Code refusal' "${required_code_refusal[@]}"
require_main_markers 'Code comparison inclusion' "${required_code_inclusion[@]}"

# Public resources have bundle modes, not the installer's owner-only modes.
# Pin the captured manifest bytes independently of its self-reported hashes.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --input-type=module - "$app" "$repo_root" <<'JS'
import { constants, lstatSync, readdirSync, openSync, fstatSync, readFileSync, readSync, closeSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
const app = process.argv[2], root = process.argv[3];
const files = ['.claude-plugin/plugin.json', '.claude-plugin/marketplace.json', 'hooks/hooks.json',
  'hooks/register.mjs', 'producer.mjs', 'protocol.mjs', 'transport-crypto.mjs', 'THIRD_PARTY_NOTICES.txt'];
const tools = ['manage-code-comparison-plugin.mjs', 'package-code-comparison-plugin.mjs'];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
function reject() { throw new Error('invalid_public_code_resources'); }
function directory(path) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || (stat.mode & 0o7777) !== 0o755) reject();
}
function regular(path, limit = 262144) {
  const before = lstatSync(path);
  if (!before.isFile() || before.nlink !== 1 || (before.mode & 0o7777) !== 0o644 || before.size > limit) reject();
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const opened = fstatSync(fd);
    if (opened.dev !== before.dev || opened.ino !== before.ino || opened.size !== before.size) reject();
    const bytes = Buffer.alloc(limit + 1);
    let length = 0;
    // Bound reads even if a same-UID writer changes the file after lstat.
    while (length < bytes.length) {
      const count = readSync(fd, bytes, length, bytes.length - length, length);
      if (!count) break;
      length += count;
    }
    const after = fstatSync(fd), named = lstatSync(path);
    for (const info of [after, named]) {
      if (info.dev !== before.dev || info.ino !== before.ino || info.size !== before.size
        || info.mode !== before.mode || info.nlink !== 1 || info.mtimeMs !== before.mtimeMs
        || info.ctimeMs !== before.ctimeMs) reject();
    }
    if (length !== before.size || length > limit) reject();
    return bytes.subarray(0, length);
  } finally { closeSync(fd); }
}
function inventory(path, expected) {
  directory(path);
  const actual = readdirSync(path);
  if (actual.length !== expected.length || actual.some(name => !expected.includes(name))) reject();
}
const native = readFileSync(join(root, 'Sources/QuotaTempoApp/CodeComparisonPluginPackage.swift'), 'utf8');
function constant(name, pattern) {
  const matches = [...native.matchAll(new RegExp('^  static let ' + name + '[ \\t]*=[ \\t]*(?:\\r?\\n[ \\t]*)?"([^"\\r\\n]*)"[ \\t]*$', 'gm'))];
  if (matches.length !== 1 || !pattern.test(matches[0][1])) reject();
  return matches[0][1];
}
const digest = constant('nativeManifestDigest', /^[0-9a-f]{64}$/);
const marketplace = constant('nativeMarketplaceName', /^quotatempo-code-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
directory(app); directory(join(app, 'Contents')); directory(join(app, 'Contents/Resources'));
const plist = spawnSync('plutil', ['-convert', 'json', '-o', '-', '--', '-'], {
  input: regular(join(app, 'Contents/Info.plist'), 65536), encoding: 'utf8', timeout: 10000, maxBuffer: 131072,
});
if (plist.error || plist.signal || plist.status !== 0) reject();
const info = JSON.parse(plist.stdout);
if (info.CFBundleIdentifier !== 'co.ishikawa.QuotaTempo' || info.QTCodeComparisonPluginBundled !== true
  || info.QTCodeComparisonManifestDigest !== digest || !/^(development|stable|rc\.[1-9][0-9]*)$/.test(info.QTReleaseChannel ?? '')) reject();
if (info.QTCodeComparisonSigningMode === 'developer-id') {
  if (info.QTCodeComparisonSigningTeam !== '9AQKR642UU') reject();
} else if (info.QTCodeComparisonSigningMode !== 'local-ad-hoc'
  || Object.hasOwn(info, 'QTCodeComparisonSigningTeam') || info.QTReleaseChannel === 'stable') reject();
const packageRoot = join(app, 'Contents/Resources/CodeComparisonPlugin');
inventory(packageRoot, ['.claude-plugin', 'hooks', 'quotatempo-package.json', ...files.filter(file => !file.includes('/'))]);
inventory(join(packageRoot, '.claude-plugin'), ['plugin.json', 'marketplace.json']);
inventory(join(packageRoot, 'hooks'), ['hooks.json', 'register.mjs']);
const bytes = regular(join(packageRoot, 'quotatempo-package.json'), 16384);
if (hash(bytes) !== digest) reject();
const manifest = JSON.parse(bytes.toString('utf8'));
if (manifest.schemaVersion !== 1 || manifest.purpose !== 'quotatempo-code-comparison-plugin'
  || manifest.releaseVersion !== '0.0.4'
  || Object.keys(manifest.files ?? {}).sort().join('\n') !== [...files].sort().join('\n')) reject();
for (const file of files) if (hash(regular(join(packageRoot, file))) !== manifest.files[file]) reject();
const plugin = JSON.parse(regular(join(packageRoot, files[0])).toString('utf8'));
const market = JSON.parse(regular(join(packageRoot, files[1])).toString('utf8'));
if (plugin.name !== 'quotatempo-usage-probe' || plugin.version !== '0.0.4' || market.name !== marketplace
  || market.metadata?.version !== '0.0.4' || market.plugins?.length !== 1
  || market.plugins[0].name !== plugin.name || market.plugins[0].source !== './') reject();
const toolRoot = join(app, 'Contents/Resources/CodePluginTools');
inventory(toolRoot, tools);
for (const tool of tools) if (hash(regular(join(toolRoot, tool))) !== hash(readFileSync(join(root, 'scripts', tool)))) reject();
JS

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
code_comparison_markers=(
  -e 'CodeComparison'
  -e 'CodeUsageComparison'
  -e 'CodeComparisonStartupValidation'
  -e 'startupValidated'
  -e 'QuotaTempo.CodeComparison'
  -e 'quotatempo-mods-comparison'
  -e 'quotatempo-usage-probe'
  -e 'quotatempo-code-comparison-plugin'
  -e 'quotatempo-code-plugin-management'
  -e 'probe-grant.json'
  -e 'bridge.sock'
)
code_preview_only=(
  -e 'CodeComparisonStartupValidation'
  -e 'CodeComparisonPackageValidation'
  -e 'CodeComparisonOfficialWireTests'
  -e 'startupValidated'
  -e 'startupValidationDeadlineExceeded'
  -e 'packageValidationDeadlineExceeded'
  -e 'packageValidated'
)

files="$(mktemp "${TMPDIR:-/tmp}/quota-tempo-artifact-isolation.XXXXXX")"
trap 'rm -f -- "$files"' EXIT
# Top-level documentation (notably PRIVACY.md) legitimately names the candidate.
# Include non-executable plugin resources, directories and symlinks, while keeping
# ordinary browser JSON/JS and descriptive documents outside the code scan.
# Materialize find output so enumeration failures propagate before inspection.
find "$app/Contents" \( \
  \( \( -type f -o -type l \) \( \
    -path '*/Contents/MacOS/*' -o -path '*.framework/*' \
    -o -perm -100 -o -perm -010 -o -perm -001 \
    -o -name '*.dylib' -o -name '*.so' -o -name '*.a' -o -name '*.o' \
  \) \) -o \( \
    -name '.claude-plugin' -o -path '*/.claude-plugin/*' \
    -o -name 'CodeComparisonPlugin' -o -path '*/CodeComparisonPlugin/*' \
    -o -name 'CodePluginTools' -o -path '*/CodePluginTools/*' \
    -o -name 'plugin.json' -o -name 'marketplace.json' -o -name 'quotatempo-package.json' \
    -o -path '*/hooks/hooks.json' -o -name '*.mjs' \
    -o -name '.quotatempo-code-plugin-management' -o -path '*/.quotatempo-code-plugin-management/*' \
    -o -name 'probe-grant.json' -o -name 'bridge.sock' \
    -o -name 'CodeComparison' -o -name 'CodeComparisonIPC' -o -name 'CodeComparisonPlugins' \
    -o -name '*.swift' -o -name 'test-code-comparison-*' -o -name 'official-ipc-client*' \
    -o -name 'node_modules' -o -name 'crypto-build' -o -name '.git' \
  \) \) -print0 > "$files"
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
  case "$artifact" in
    "$app/Contents/Resources/CodeComparisonPlugin"|"$app/Contents/Resources/CodeComparisonPlugin/"* \
      |"$app/Contents/Resources/CodePluginTools"|"$app/Contents/Resources/CodePluginTools/"*)
      # Only the exact inventory already verified above is exempted.
      continue
      ;;
    */.claude-plugin|*/.claude-plugin/*|*/CodeComparisonPlugin|*/CodeComparisonPlugin/*|*/plugin.json|*/marketplace.json \
      |*/CodePluginTools|*/CodePluginTools/* \
      |*/quotatempo-package.json|*/hooks/hooks.json|*.mjs \
      |*/.quotatempo-code-plugin-management|*/.quotatempo-code-plugin-management/* \
      |*/probe-grant.json|*/bridge.sock|*.swift|*/test-code-comparison-*|*/official-ipc-client* \
      |*/CodeComparison|*/CodeComparisonIPC|*/CodeComparisonPlugins \
      |*/node_modules|*/crypto-build|*/.git)
      echo "Code comparison plugin material found in bundle: $artifact" >&2
      exit 2
      ;;
  esac
  if [[ -d "$artifact" ]]; then continue; fi
  if [[ ! -f "$artifact" ]]; then
    echo "Unable to inspect compiled artifact: $artifact" >&2
    exit 2
  fi
  code_forbidden=("${code_preview_only[@]}")
  if [[ "$artifact" != "$binary" ]]; then code_forbidden+=("${code_comparison_markers[@]}"); fi
  if grep -aF "${code_forbidden[@]}" "$artifact" >/dev/null; then
    echo "Code comparison implementation found in compiled artifact: $artifact" >&2
    exit 2
  else
    status=$?
    if [[ "$status" -ne 1 ]]; then
      echo "Unable to inspect Code comparison artifact (grep status $status): $artifact" >&2
      exit 2
    fi
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
