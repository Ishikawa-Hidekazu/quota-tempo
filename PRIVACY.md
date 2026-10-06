# Privacy

QuotaTempo is a local macOS menu-bar app. It has no telemetry, analytics, account system, advertising identifier, or remote license check.

## Data read

The default Claude source is **Automatic**, the local/CLI path below. The optional
**Claude Desktop** connection has a different access boundary described
in its own section. It starts disabled and requires explicit consent and macOS
permission. This connection was introduced in version 0.1.10; an older installed
release does not gain it from this document.

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

## Unreleased Claude Code comparison integration

The local integration build includes a separate, explicitly prepared comparison
with an already authorized Claude Code trial plugin. This does not change the
released Automatic or Desktop sources. The normal distribution UI does not
offer this connection yet; it is not enabled or restored automatically.

After consent, the app creates a fresh 0700 `qtc-<UUID>` directory in `/private/tmp`,
a 0600 metadata-only grant and a 0600 Unix socket. Connection and stream
UUIDs are random labels, not account IDs or authentication tokens. Code must be
connected explicitly. The app never installs a plugin, switches apps, sends a
model request or reads provider caches, transcripts or authentication for this
comparison. The schema-3 plugin sends only encrypted, allowlisted usage metadata directly to
the local app, not to TCP or a provider. There is no file-transport fallback.
Multiple streams are rejected, not merged. Values never affect W/P or planning.
Local exporter time is not a verified provider observation time.

Usage remains in memory; the grant contains no quota values. The app checks the
grant/directory/socket identity and permissions, the connecting client UID,
bounded HTTP framing, ordering and expiry. The UI samples the in-memory state
every two seconds. Disconnect closes the receiver immediately and removes the
exact grant and socket; unknown
files are not deleted. Cleanup failure is reported separately from usable values
and does not prevent newly consenting to another connection. Normal termination
revokes grants and sockets through gates shared with preparation, including a
preparation reply not yet returned to the UI. A crash can leave quota-free grant
and socket paths behind; they are not resumed or reused automatically.

Version 0.0.4 pins the app's ephemeral X25519 public key in the copied connection
command, not in the mutable grant. Each request uses a fresh RFC 9180 HPKE context
(X25519/HKDF-SHA-256/ChaCha20-Poly1305); connection, stream, request and operation
are bound to the encryption context. The app proves successful receipt using a
derived response key. Replaced endpoints receive ciphertext and cannot forge an
accepted response. Private keys and usage remain in memory; the app never writes
private keys, quota values or response keys to the grant. Replays are rejected.
The grant is checked before each request, but it is not treated as an identity
proof. This does not protect against a compromised trusted app, plugin or Code
runtime, or an attacker able to alter the copied command. The old plaintext
schema-2 route is rejected. Schema-1 remains a separate developer experiment;
the native UI never prepares its grants or falls back to it.

The plugin includes pinned MIT-licensed cryptographic dependencies as a local
bundle with third-party notices. It does not download dependencies at runtime.
The Code-only preview can explicitly stage eight bundled plugin files plus a
quota-free checksum manifest in private, app-owned storage. It checks the running
app's signature, the sealed resources and a manifest digest compiled into the
executable. Existing or unknown staged files are never overwritten or repaired.
This preparation is not proof that Code installed, enabled or loaded the plugin.
Installation, local project scope and reload remain explicit Code operations.
The release-specific native package identity is immutable across identical
rebuilds; developer packages otherwise receive fresh marketplace UUIDs.
The official Mods HTTP API buffers responses and exposes no documented HTTP
cancellation or pre-read size limit. A caller deadline is not proof that the
host's underlying request was cancelled; uncertain requests are not replayed.
Native distribution and real-Code acceptance remain required before public
enablement of this additional source.

Developer-only packaging and management tools now support a versioned,
allowlisted plugin package and explicit project-local install, refresh, staged
update, disable, re-enable and uninstall. They are not invoked by the app. Applying them
requires an explicit local-trial acknowledgement and confirmation that the
selected project's Code sessions are closed. No model request, account switch,
normal CLI upgrade or broad plugin cleanup is performed. The official CLI may
maintain its own global cache even when local scope is selected.

Each developer package has a unique marketplace name. A private management journal below
the chosen project (`.quotatempo-code-plugin-management`) and a separately chosen
private receipt contain package paths, hashes, versions, project filesystem
identity and operation stages only. They contain no quota values or authentication.
CLI output is discarded, except bounded version parsing. Uncertain operations
stop without automatic replay; changing the receipt cannot bypass that stop.
Updates preserve disabled state, and uninstall is limited to the exact managed
local plugin ID. Marketplace registrations, package directories and plugin data
are retained rather than deleting material potentially used elsewhere. This is
isolated CLI acceptance, not general-distribution or native app acceptance.

## Opt-in Claude Desktop connection

Version 0.1.10 introduced `QuotaTempoDesktopCandidate` only in the main app,
behind **Claude Desktop** source selection and explicit consent. The
default source remains Automatic.
Provider changes may prevent QuotaTempo from retrieving usage data.
The standalone `QT Desktop` helper and headless acceptance mode remain local test
tools, not publicly distributed entry points.

Unlike the Automatic local/CLI path above, this connection reads Claude Desktop's
local account configuration and encrypted authentication cache, its selected
organization from the Desktop cookie store, and the matching Claude Safe Storage
Keychain item. Reads are bounded and prompt-suppressed during automatic polling.
It does not modify those stores, export authentication, inspect conversations or
prompts, launch a browser or CLI, or refresh provider credentials itself.

The connection uses the selected Desktop authentication only to verify the account
and organization and obtain usage from the provider. Sensitive values remain in
process memory; raw bodies, headers, identities, credentials and credential hashes
are not written to logs or normalized snapshots. The app displays
quota values and records only fixed diagnostic categories, capture/backoff times
and boolean availability metadata. It does not persist Desktop observations. It
stores a size-bounded `desktop-throttle.json` in the shared private
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
The app exposes consent, disconnect, bounded recheck and offline scheduling repair.
The service requires an explicit scheduling store; it cannot silently operate
without persistence. A restored finite provider wait remains binding, even when
it spans years. The app identifies the provider wait and its next permitted
time; repair and recheck cannot erase it. Ordinary successful polling waits five
minutes, with a 60-second minimum for verified context renewal/account changes
or an upcoming reset. These exceptions never shorten a provider/failure wait.

The normal app does not import the separate preview's consent. Source selection
and consent use the normal app's own preferences. Choosing Desktop first cancels
Automatic acquisition and excludes local, CLI and browser observations from the
Claude row, even when the Desktop connection is disconnected or unavailable.
Choosing Automatic revokes Desktop consent and clears its in-memory observation
before starting Automatic acquisition. Switching sources never combines values.
Selecting Desktop does not disconnect a separately running browser extension;
use the extension's Disconnect control to stop its independent polling.
Old consent must be durably revoked before a new Desktop selection is saved.
If revocation cannot be saved, Automatic remains selected and the app reports
the storage problem rather than allowing a restart to reuse old consent.
The connection starts disconnected until explicit consent,
then stores only the accepted consent revision in its local preferences so the
same connection scope can resume after application restarts. Earlier per-launch
consent is not upgraded automatically; a changed scope requires new consent.
The preference contains no credential, account identifier, observation, or reset.
It provides disconnect, bounded recheck and offline repair controls. Disconnect,
turning Claude off, and repair revoke remembered consent. Storage failures stop
the connection and visibly report that persistence could not be confirmed.
A failure to open scheduling storage, including a lock held by another preview,
returns to a disconnected state and revokes remembered consent. A later explicit
connection may reopen storage; polling never silently retries initialization.
When noninteractive access reports that macOS permission is missing, the app
offers a separate, explicit **Allow macOS access** action. Only that user action
may show the system Keychain dialog for the specific Claude Safe Storage item.
No ACL is changed programmatically. Background startup, timers, wake and Recheck
never prompt. The local permission action exposes only success/failure, discards
key material and verifies that a subsequent noninteractive read works at that
moment. This does not prove a permanent OS grant or access after a restart;
missing permission still requires a new explicit user action. Cancellation
or connection revocation cannot approve a late result. OS approval never clears
provider refusal or retry deadlines.
The dialog requires **Always Allow** for background operation. One-time **Allow**
does not complete this connection because it does not authorize the subsequent
noninteractive read. Always Allow grants this app ongoing access to the Claude
Safe Storage protection key. Disconnecting or turning Claude off stops usage
acquisition and automatic reconnection but does not revoke that macOS grant.
The [Desktop connection removal section](#desktop-connection-removal) below explains
how to remove only QuotaTempo's trusted-app entry through Keychain Access
without revealing or deleting Claude's protection key. QuotaTempo does not
perform this operating-system permission change on the user's behalf.
Disconnect clears in-memory observations; repair disconnects first and never
erases a known provider deadline. The connection does not silently fall back from
Desktop to a CLI or browser account or persist Desktop observations. Its scheduling metadata
shares the existing helper's `QuotaTempoDesktopPreview` directory and lifetime
lock: switching UIs cannot erase a known provider wait or run two Desktop clients
against independent schedules. A custom `--storage-directory` disables all provider
acquisition and is reserved for synthetic QA. The normal app retains its separate,
opt-in login item and signed updater regardless of the selected Claude source.

The local **Desktop integration preview**, built with
`QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW=1`, has a separate app identifier,
preferences and `QuotaTempoIntegrationPreview` directory for non-Desktop state.
It remains Desktop-only, has no updater or login item, and is rejected by public
distribution packaging. Other shipped executables do not contain Desktop
authentication readers. The same scheduling allowlist and locking rules apply.

The signed integration preview also has an explicit, bounded headless acceptance
mode. It requires the exact command-line consent and acknowledgement arguments
documented in [README](README.md#build-and-test), uses the same controller and scheduling namespace, and never
initializes the application UI or persists that process-only consent. It does not
request Keychain permission, recheck a refused credential, repair state, start
the CLI/browser or fall back to another account. Output is limited to fixed
statuses, validated quota/plan values, exact reset and capture times, next-update
time and counters. It stops on permission/provider/storage failures. This is
private acceptance evidence, not telemetry or a public-release approval.

## Experimental opt-in browser connection

The development browser bridge is separate from the released local/CLI acquisition path. Installing its Chrome extension and native-host registration does not sign you in. After you explicitly connect a Claude tab, an isolated content script requests account, organization, and aggregate usage metadata from the same `https://claude.ai` origin. Chrome supplies its existing session normally; the extension does not access cookie values, cookie databases, authentication storage, or Keychain. No page text, conversation, prompt, or transcript is inspected.

Provider changes may prevent QuotaTempo from retrieving usage data. The extension validates the account before and after each usage request, requires an unambiguous organization, and pins the selected account. It sends only normalized percentages, provider-reported reset timestamps, capture time, stable status codes, a random installation identifier, and one-way ownership fingerprints to the local native host. The browser observation is used whole; its reset is never merged with Desktop or CLI observations. The app identifies this source as **Claude browser connection**, which can represent a different account from Claude Desktop.

Polling requires a Claude tab in the connected Chrome profile. It runs no more frequently than every five minutes, backs off after failures, and does not open or foreground a tab. The extension stores connection metadata and ownership fingerprints in `chrome.storage.local`, not Chrome Sync. The native host stores its origin allowlist and normalized connection record in `QuotaTempo/BrowserBridge` under Application Support. A Chrome Native Messaging manifest links the installed extension to the bundled host executable. There is no listening network port, telemetry, or outbound transfer to QuotaTempo servers. Claude's own privacy terms and ordinary network metadata apply to its web requests.

## Data stored

QuotaTempo writes only a schema version plus normalized provider, percentage, duration, reset, capture-time, freshness, acquisition-state, stable error-code, Codex executable source/version fields, and optional one-way Claude ownership fingerprints under:

```text
~/Library/Application Support/QuotaTempo/
```

Raw provider responses, raw executable-version output, local executable paths, account or organization UUIDs, and raw Claude source files are not copied there. The fingerprints are lowercase SHA-256 digests used only to prevent reset metadata from being combined across Claude accounts. Snapshot reads and writes are size-bounded, reject symlinks and non-regular files, and validate provider/source, time-window, and acquisition-state relationships before a record is used. The data stays on the Mac unless the user backs up or shares that directory through another service.
QuotaTempo creates its Application Support directory with owner-only `0700` permissions and normalized snapshot files with `0600` permissions.

The selected menu-bar display mode, enabled-provider choices, Claude source choice, Desktop consent revision, and first-run-guide completion are stored through macOS preferences for bundle identifier `co.ishikawa.QuotaTempo`, normally represented under `~/Library/Preferences/`. No provider percentage, reset timestamp, credential, or session data is stored in those preferences. The optional login item is managed by macOS and is never enabled automatically.

Choosing **Copy diagnostics** writes a support-safe report to the macOS clipboard. It contains the QuotaTempo and operating-system versions, enabled providers, normalized source kinds, Codex executable source class and normalized semantic version when available, freshness, source state, and stable acquisition error codes. It excludes quota percentages, reset and capture timestamps, local paths, raw version output, credentials, raw provider data, prompts, transcripts, and session content. Clipboard retention is controlled by macOS and any clipboard tools installed by the user.

## Update checks

Sparkle checks the official HTTPS appcast at `ishikawa.co` at most once per day after the user enables automatic checks. Installing an update downloads the signed archive referenced by that feed from the official GitHub Release. QuotaTempo disables Sparkle system profiling and does not attach quota values, reset times, provider data, diagnostics, credentials, or usage analytics. As with any HTTPS request, the servers and network providers involved may receive ordinary request metadata such as an IP address and user agent.

## Removal

Turn off **Launch at login** if enabled, quit QuotaTempo, remove `QuotaTempo.app`, and optionally remove the QuotaTempo Application Support directory and the `co.ishikawa.QuotaTempo` macOS preference to erase its normalized observations, display mode, provider choices, and guide completion. Removing QuotaTempo does not alter Codex or Claude authentication.

For the experimental browser bridge, **Disconnect browser** in QuotaTempo's Claude details revokes the local connection even if the extension was removed. After confirmation, it clears browser quota/ownership fields and rejects late messages under the same lock used by the native host. Local metadata can then be displayed as a separate source, without inheriting browser resets or triggering a live request. Claude sign-in is unchanged. If the extension is still running, it stops when the host next rejects that connection; an in-flight or next scheduled observation can still run because the app cannot push a notification to Chrome. Disable/disconnect the extension directly to stop it there immediately. Reconnect preserves its saved provider wait.

To remove the bridge installation, disable or remove the extension and use `node scripts/install-browser-bridge.mjs --remove --apply` from the source checkout. This removes only its recognized native-messaging manifest, host configuration, and normalized browser observation. It does not erase local Codex/Claude observations or change either provider's sign-in. `--remove` without `--apply` is a dry run. Stop browser-bridge activity before removal; the script refuses unsafe paths and reports an incomplete rollback or cleanup explicitly.

<a id="desktop-preview-removal"></a>

### Desktop connection removal

These steps apply to the opt-in Desktop connection and any separately installed
Desktop preview or local test helper. Automatic acquisition does not request
this Keychain access. Do not perform removal during an ongoing acceptance test
unless revocation is the specific test being performed.

Choose **Disconnect**, turn off **Launch at login** if enabled, then choose
**Quit QuotaTempo**. Quit any older preview or `QT Desktop` test helper as well.
Disconnect clears the in-memory observation and remembered connection
consent, not macOS permissions.

A scheduling-store initialization failure also revokes remembered consent,
including a temporary failure during startup. After the underlying storage
problem is resolved, use **Connect Desktop** and consent again. Do not delete
the scheduling record or lock to bypass a wait or an active preview.

macOS permission is separate from QuotaTempo's consent. **Always Allow** can
leave a trusted-app entry after you disconnect or remove the app. Apple describes
the per-item controls in
[Allow apps to access your keychain](https://support.apple.com/guide/mac-help/allow-apps-to-access-your-keychain-kychn002/mac).
The steps below target QuotaTempo's grant only; macOS labels can vary.

1. Open **Keychain Access** yourself and select the **login** keychain. Locate
   the item named **Claude Safe Storage**. Do not select **Show password**.
2. Open the item's information and its **Access Control** tab.
3. In the trusted-app list, select only an entry you can identify as your
   QuotaTempo app, Desktop preview or old `QT Desktop` helper. Remove it using the
   list's remove control (usually a minus button). Repeat for other copies of
   these apps that you have authorized. Leave Claude and other apps intact.
4. Keep **Confirm before allowing access** selected and save the change. If
   macOS asks for authentication, enter it only in the system dialog, never in
   a chat, command, screenshot, or support report.

If the item, app entry, or removal control cannot be identified, stop instead
of deleting an item or changing unrelated entries. If **Allow all applications
to access this item** is selected, removing an individual entry is not sufficient;
stop and review that broader permission separately. Do not enable that setting.
Do not delete **Claude Safe Storage**, reset a keychain, change its password,
or remove Claude's authentication files as part of uninstalling QuotaTempo.

After quitting all copies and reviewing their grants, move only the
QuotaTempo app bundles you installed to the Trash. Leave Claude itself
installed. App deletion alone does not revoke a saved macOS grant.

The bounded scheduling records and preferences described above
contain no credentials. Retain scheduling records if you plan to reconnect or
reinstall; deleting them is not a supported way to clear a provider's wait
deadline. A future installation is not guaranteed to inherit or lose a
particular macOS permission: verify the new copy's state explicitly before
allowing background use.

## Upstream compatibility

Provider changes may prevent QuotaTempo from retrieving usage data. QuotaTempo validates recognized shapes and fails closed when they change. Users should verify this policy again before enabling a future adapter or distribution channel.
