# Privacy

QuotaTempo is a local macOS menu-bar app. It has no telemetry, analytics, account system, advertising identifier, or remote license check.

## Data read

- Codex: rate-limit metadata returned by the installed official `codex app-server` process.
- Claude: only the recognized usage fields in `~/Library/Application Support/Claude/plan-usage-history.json` and the `cachedUsageUtilization` subtree in `~/.claude.json`. Other fields in those files are not decoded or retained. The V1 release path does not launch Claude CLI as a fallback.

QuotaTempo does not open browser cookie databases, Keychain items, provider authentication files, prompts, transcripts, or session contents. Provider-owned processes remain subject to their providers' own privacy terms and network behavior.

## Data stored

QuotaTempo writes only a schema version plus normalized provider, percentage, duration, reset, capture-time, freshness, acquisition-state, stable error-code, and Codex executable source/version fields under:

```text
~/Library/Application Support/QuotaTempo/
```

Raw provider responses, raw executable-version output, local executable paths, and raw Claude source files are not copied there. Snapshot reads and writes are size-bounded, reject symlinks and non-regular files, and validate provider/source, time-window, and acquisition-state relationships before a record is used. The data stays on the Mac unless the user backs up or shares that directory through another service.
QuotaTempo creates its Application Support directory with owner-only `0700` permissions and normalized snapshot files with `0600` permissions.

The selected menu-bar display mode, enabled-provider choices, and first-run-guide completion are stored through macOS preferences for bundle identifier `co.ishikawa.QuotaTempo`, normally represented under `~/Library/Preferences/`. No provider percentage, reset timestamp, credential, or session data is stored in those preferences. The optional login item is managed by macOS and is never enabled automatically.

Choosing **Copy diagnostics** writes a support-safe report to the macOS clipboard. It contains the QuotaTempo and operating-system versions, enabled providers, normalized source kinds, Codex executable source class and normalized semantic version when available, freshness, source state, and stable acquisition error codes. It excludes quota percentages, reset and capture timestamps, local paths, raw version output, credentials, raw provider data, prompts, transcripts, and session content. Clipboard retention is controlled by macOS and any clipboard tools installed by the user.

## Update checks

Sparkle checks the official HTTPS appcast at `ishikawa.co` at most once per day after the user enables automatic checks. Installing an update downloads the signed archive referenced by that feed from the official GitHub Release. QuotaTempo disables Sparkle system profiling and does not attach quota values, reset times, provider data, diagnostics, credentials, or usage analytics. As with any HTTPS request, the servers and network providers involved may receive ordinary request metadata such as an IP address and user agent.

## Removal

Turn off **Launch at login** if enabled, quit QuotaTempo, remove `QuotaTempo.app`, and optionally remove the QuotaTempo Application Support directory and the `co.ishikawa.QuotaTempo` macOS preference to erase its normalized observations, display mode, provider choices, and guide completion. Removing QuotaTempo does not alter Codex or Claude authentication.

## Upstream compatibility

Some provider interfaces and local usage structures are not stable public APIs. QuotaTempo validates recognized shapes and fails closed when they change. Users should verify this policy again before enabling a future adapter or distribution channel.
