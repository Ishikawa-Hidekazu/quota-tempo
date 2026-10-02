# Privacy

QuotaTempo is a local macOS menu-bar app. It has no telemetry, analytics, account system, advertising identifier, or remote license check.

## Data read

- Codex: rate-limit metadata returned by the installed official `codex app-server` process.
- Claude: only the recognized usage fields and organization UUID in `~/Library/Application Support/Claude/plan-usage-history.json`, `lastKnownAccountUuid` in the adjacent Desktop `config.json`, plus `cachedUsageUtilization`, `oauthAccount.accountUuid`, and `oauthAccount.organizationUuid` in `~/.claude.json`. The UUIDs are used only to derive one-way SHA-256 account-owner, principal, and organization fingerprints; the raw values are not retained. A Desktop observation inherits an exact cached reset only when the current Desktop account, Claude Code account, organization, and quota window agree. Other fields in those files are not decoded or retained. QuotaTempo can launch the already-installed, already-signed-in Claude Code CLI in a bounded pseudo-terminal, enter `/usage`, and read only the session and all-model weekly percentages and reset times from its rendered panel. It first uses a complete recent local observation. Automatic refresh is scheduled every 15 minutes with a 14-minute jitter guard; explicit **Refresh** invokes it immediately. QuotaTempo does not copy the raw terminal output to its store or diagnostics.

The released local/CLI acquisition path does not open browser cookie databases, Keychain items, provider authentication files, prompts, transcripts, or session contents. It disables tools, hooks, MCP configuration, user setting sources, Remote Control startup, and auto-update for the probe, caps its runtime and output, requests a normal CLI exit, and terminates discovered child processes afterward. The provider-owned CLI still uses its existing sign-in, contacts Anthropic for current usage, and may update its own local usage or session metadata; its own privacy terms and network behavior apply.

The local/CLI adapter in this source branch additionally validates the observation's
`cachedUsageUtilization.accountUuid` against the current account before assigning
ownership. A mismatched cache is excluded; missing ownership cannot justify a
Desktop reset join. When the browser route is not connected, its minute clock
also rereads these same allowlisted local sources. This does not introduce a new
file, permission, provider request, or CLI process, and does not relabel the data
as newly captured.

## Isolated Desktop acquisition experiment

`QuotaTempoDesktopCandidate` and the manually built `QT Desktop` helper are not
included in the released application, updater or installer. Running that helper
requires explicit local-experiment consent. That consent is not a claim of
provider permission or public-release readiness.

Unlike the released local/CLI path above, the experiment reads Claude Desktop's
local account configuration and encrypted authentication cache, its selected
organization from the Desktop cookie store, and the matching Claude Safe Storage
Keychain item. Reads are bounded and prompt-suppressed during automatic polling.
It does not modify those stores, export authentication, inspect conversations or
prompts, launch a browser or CLI, or refresh provider credentials itself.

The helper uses the selected Desktop authentication only to verify the account
and organization and obtain usage from the provider. Sensitive values remain in
process memory; raw bodies, headers, identities, credentials and credential hashes
are not written to logs or normalized snapshots. The local preview displays
quota values and records only fixed diagnostic categories, capture/backoff times
and boolean availability metadata. It does not persist observations. The candidate
now stores a size-bounded `desktop-throttle.json` in the isolated preview's private
`~/Library/Application Support/QuotaTempoDesktopPreview` directory, with
owner-only permissions and a process-lifetime lock. The lock contains only a
one-byte initialization marker to detect checkpoint loss after restart. The
checkpoint's allowlisted fields are
schema version, checkpoint/attempt times, local and provider wait deadlines,
failure count, an interrupted-attempt deadline, an unsupported-wait flag, a
fixed authentication-refusal category, and the refused lease's expiry timestamp.
The expiry is only evidence of change when different; equality never establishes
an account identity. A legacy or equal-expiry refusal can be checked through an
explicit one-attempt action, with a persisted 15-minute floor and all known
provider deadlines preserved. Automatic polling does not invoke that action.
No identity, ownership fingerprint, credential revision or usage value is stored
there. Provider requests stop while the checkpoint cannot be validated or saved.
The crash boundary between an HTTP response and its durable checkpoint still
needs acceptance. The isolated helper has an explicit offline scheduling-repair
command: it requires the same exclusive lock, preserves valid records, leaves
unused stores uninitialized, refuses unknown schema versions, and repairs a lost/corrupt record into a stopped state
with a 15-minute floor. It makes no provider request and does not repair permissions.
Restart safety therefore remains a release gate. Public integration must include consent,
revocation, recovery and an updated privacy contract before this path can be shipped.
The service requires an explicit scheduling store; it cannot silently operate
without persistence. A restored finite provider wait remains binding, even when
it spans years. The preview identifies the provider wait and its next permitted
time; repair and recheck cannot erase it. Ordinary successful polling waits five
minutes, with a 60-second minimum for verified context renewal/account changes
or an upcoming reset. These exceptions never shorten a provider/failure wait.

## Experimental opt-in browser connection

The development browser bridge is separate from the released local/CLI acquisition path. Installing its Chrome extension and native-host registration does not sign you in. After you explicitly connect a Claude tab, an isolated content script requests account, organization, and aggregate usage metadata from the same `https://claude.ai` origin. Chrome supplies its existing session normally; the extension does not access cookie values, cookie databases, authentication storage, or Keychain. No page text, conversation, prompt, or transcript is inspected.

These web routes are not a stable third-party API. The extension validates the account before and after each usage request, requires an unambiguous organization, and pins the selected account. It sends only normalized percentages, provider-reported reset timestamps, capture time, stable status codes, a random installation identifier, and one-way ownership fingerprints to the local native host. The browser observation is used whole; its reset is never merged with Desktop or CLI observations. The app identifies this source as **Claude browser connection**, which can represent a different account from Claude Desktop.

Polling requires a Claude tab in the connected Chrome profile. It runs no more frequently than every five minutes, backs off after failures, and does not open or foreground a tab. The extension stores connection metadata and ownership fingerprints in `chrome.storage.local`, not Chrome Sync. The native host stores its origin allowlist and normalized connection record in `QuotaTempo/BrowserBridge` under Application Support. A Chrome Native Messaging manifest links the installed extension to the bundled host executable. There is no listening network port, telemetry, or outbound transfer to QuotaTempo servers. Claude's own privacy terms and ordinary network metadata apply to its web requests.

## Data stored

QuotaTempo writes only a schema version plus normalized provider, percentage, duration, reset, capture-time, freshness, acquisition-state, stable error-code, Codex executable source/version fields, and optional one-way Claude ownership fingerprints under:

```text
~/Library/Application Support/QuotaTempo/
```

Raw provider responses, raw executable-version output, local executable paths, account or organization UUIDs, and raw Claude source files are not copied there. The fingerprints are lowercase SHA-256 digests used only to prevent reset metadata from being combined across Claude accounts. Snapshot reads and writes are size-bounded, reject symlinks and non-regular files, and validate provider/source, time-window, and acquisition-state relationships before a record is used. The data stays on the Mac unless the user backs up or shares that directory through another service.
QuotaTempo creates its Application Support directory with owner-only `0700` permissions and normalized snapshot files with `0600` permissions.

The selected menu-bar display mode, enabled-provider choices, and first-run-guide completion are stored through macOS preferences for bundle identifier `co.ishikawa.QuotaTempo`, normally represented under `~/Library/Preferences/`. No provider percentage, reset timestamp, credential, or session data is stored in those preferences. The optional login item is managed by macOS and is never enabled automatically.

Choosing **Copy diagnostics** writes a support-safe report to the macOS clipboard. It contains the QuotaTempo and operating-system versions, enabled providers, normalized source kinds, Codex executable source class and normalized semantic version when available, freshness, source state, and stable acquisition error codes. It excludes quota percentages, reset and capture timestamps, local paths, raw version output, credentials, raw provider data, prompts, transcripts, and session content. Clipboard retention is controlled by macOS and any clipboard tools installed by the user.

## Update checks

Sparkle checks the official HTTPS appcast at `ishikawa.co` at most once per day after the user enables automatic checks. Installing an update downloads the signed archive referenced by that feed from the official GitHub Release. QuotaTempo disables Sparkle system profiling and does not attach quota values, reset times, provider data, diagnostics, credentials, or usage analytics. As with any HTTPS request, the servers and network providers involved may receive ordinary request metadata such as an IP address and user agent.

## Removal

Turn off **Launch at login** if enabled, quit QuotaTempo, remove `QuotaTempo.app`, and optionally remove the QuotaTempo Application Support directory and the `co.ishikawa.QuotaTempo` macOS preference to erase its normalized observations, display mode, provider choices, and guide completion. Removing QuotaTempo does not alter Codex or Claude authentication.

For the experimental browser bridge, **Disconnect browser** in QuotaTempo's Claude details revokes the local connection even if the extension was removed. After confirmation, it clears browser quota/ownership fields and rejects late messages under the same lock used by the native host. Local metadata can then be displayed as a separate source, without inheriting browser resets or triggering a live request. Claude sign-in is unchanged. If the extension is still running, it stops when the host next rejects that connection; an in-flight or next scheduled observation can still run because the app cannot push a notification to Chrome. Disable/disconnect the extension directly to stop it there immediately. Reconnect preserves its saved provider wait.

To remove the bridge installation, disable or remove the extension and use `node scripts/install-browser-bridge.mjs --remove --apply` from the source checkout. This removes only its recognized native-messaging manifest, host configuration, and normalized browser observation. It does not erase local Codex/Claude observations or change either provider's sign-in. `--remove` without `--apply` is a dry run. Stop browser-bridge activity before removal; the script refuses unsafe paths and reports an incomplete rollback or cleanup explicitly.

## Upstream compatibility

Some provider interfaces and local usage structures are not stable public APIs. QuotaTempo validates recognized shapes and fails closed when they change. Users should verify this policy again before enabling a future adapter or distribution channel.
