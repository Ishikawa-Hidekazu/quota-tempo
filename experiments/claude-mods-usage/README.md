# Claude Mods comparison-only usage probe

## Current Product Status

[QuotaTempo 0.1.12](https://github.com/Ishikawa-Hidekazu/quota-tempo/releases/tag/v0.1.12),
from source checkpoint `52f4dea`, includes native Claude Code usage comparison
and the immutable bundled plugin 0.0.4 in normal product builds.
For product setup, consent, project-local management and removal, use the
[Claude Code usage guide](../../docs/claude-code-usage.md).

Existing Codex and Claude acquisition remains enabled. Comparison remains
separate from Automatic and Desktop acquisition and never changes W/P or
planning. It does not establish account identity or provider observation time.

## Historical Experiment And Preview Checkpoints

The records below describe earlier experiment and preview checkpoints.
Statements about Code being excluded from normal artifacts, the published app
remaining 0.1.11, or public integration being unaccepted apply to those historical
checkpoints, not the 0.1.12 release. Preview and headless commands below are
developer references, not product setup instructions.

Experimental and **not connected to the shipped app**. The pure producer has
an original Mods adapter, a metadata-only receiver and a bounded comparison observer.
The separate Code comparison preview includes native bundled-plugin staging and
comparison controls; normal release targets and artifacts exclude Code implementation and
plugin material. This onboarding stages a package and prepares connection
arguments, not an installed plugin.
Loading the source alone installs nothing into the user's Claude setup.
The optional local-marketplace trial below changes plugin settings only when
explicitly invoked. No production source, preference, snapshot, scheduling
checkpoint or account binding is changed. Version 0.0.4 includes a vendored,
pinned cryptographic bundle; installed plugins do not fetch dependencies.

This implements the official quota shape
`{ rateLimits: [{ kind, percentUsed, resetsAt? }] }`. The adapter observes
`session.measure`; it does not poll `$.session.usage()` or treat another cached
read as a fresh upstream observation. The standalone CLI outputs comparisons,
not a `ProviderSnapshot` or a shipped-app source.

## Historical schema-1 adapter and receiver

This section describes the developer file experiment, not the native connection
or a fallback for failed native requests. The current native contract is below.

- Loading the mod only registers `/quotatempo-probe`. It does not read files or
  quota data until an explicit `connect <prepared absolute directory>` command.
- `receiver.mjs prepare` creates a **new**, owner-only directory and a small
  `probe-grant.json` with a nonsecret connection UUID, purpose and creation time.
  Existing directories are never taken over. Connect must occur within 15 minutes.
- Connect reads only that grant and path metadata. Each connection creates a new
  random stream label and a separate `stream-<UUID>.json`. These labels are not
  account IDs, proof of identity, or authentication tokens. Multiple Code sessions
  never share a file; the receiver requires an explicitly chosen stream.
- No initial cached value is exported. Each measured event exports the pure
  producer's allowlisted fields. No transcript, model, account, organization,
  context usage, arbitrary error text, credentials or cookies are copied.
- There is no timer, network, subprocess, configuration mutation or extra model
  turn. The adapter calls only `clock.now`, `command.register`, `fs.exists`,
  `fs.read`, `fs.stat` and `fs.write`.
- Disconnect and session end write an empty invalidation after pending delivery.
  Reconnecting creates a new stream. Delivery failure stops exporting without
  retrying quota data and attempts one empty invalidation when safe. If that
  invalidation cannot be written, a previous comparison can remain
  visible until expiry. It is never declared current provider truth.
- Connection generations fence delayed connects after disconnect, end or reload.
  During a pending export the adapter retains at most one latest measurement,
  then drains it serially; a later invalid measurement cannot be dropped simply
  because an earlier valid value is being written. The mods API object is not
  stored in that pending slot.
- The receiver checks schema, binding, ordering, clock regression, time horizons,
  five-minute local tuple age, reset expiry, file size/type/ownership and symlinks.
  Same-value reads retain `firstSeenAt`, so they cannot renew comparison age.
- Results always report `identity: unverified`, `sourceCapturedAt: null`,
  `automaticSelectionEligible: false` and `planningEligible: false`. An account
  switch with identical quota values **cannot be detected** through this API.
  Unknown fields and model-scoped/unsupported windows are rejected rather than
  silently borrowing another quota. Planning `P` is intentionally withheld.
- Mods `fs.write` is not atomic and cannot set POSIX permissions. The enclosing
  directory must be owner-only (0700); files may be 0600 or 0644 but must not be
  group/other-writable. A partial JSON read fails closed. Same-user malicious
  filesystem races are not claimed solved by this prototype.
  The official `FsStat` API does not expose POSIX ownership, mode or inode.
  The writer cannot independently detect a post-connect chmod or same-path
  directory replacement. Native reader rejection is not writer protection;
  resolving this boundary is required before general distribution.
- `createComparisonReceiver()` maintains a per-process sequence watermark.
  `receiver.mjs inspect` is a **one-shot** diagnostic, not durable ingestion:
  restarting it does not preserve replay state. The standalone receiver has no automatic directory scan,
  cross-stream selection, cleanup, source promotion or fallback exists.
- `observe.mjs` retains that watermark in one process, reads only the chosen
  grant and stream, and emits changed comparison states. Repeated reads of the
  same file do not become new observations. Missing/partial files clear the view;
  the same old file cannot restore it. New, increasing sequences may recover it.
  Grant replacement stops the runner instead of choosing another connection.
  Expiry clears the values even when the file stops changing. The live runner
  samples its clock after file I/O, so a delayed read cannot use a pre-reset time.

## Historical native app integration checkpoint (2026-10-06)

The separate Code comparison preview uses `DESKTOP_INTEGRATION_PREVIEW` and now
contains a **Claude Code usage** disclosure, separate from the main Claude row.
Explicit consent verifies and stages its bundled plugin in private app-owned
Application Support, then prepares a fresh 0700 `/private/tmp/qtc-<UUID>` directory,
0600 metadata-only grant and Unix socket. It does not install a plugin, connect
Code, activate an app or request a model turn. The app shows connection arguments
separately from a collapsed setup/management section containing the package
identity, location and a pinned setup guide. It no longer offers Desktop
marketplace/install commands that navigate to the wrong settings screen.
Use the explicit local-scope CLI management procedure instead, and verify
loading before connecting. Staging,
command copying and a connected handshake are not installation or measurement receipts.
Preparation expires after 15 minutes without a stream.

### Desktop onboarding route mismatch (2026-10-06)

User-provided screenshots after the c564881 startup correction show that the
window renders and plugin 0.0.4 stages successfully. The first copied
`/plugin marketplace add <local directory>` command opens Desktop's plugin
settings browser. Its Add marketplace dialog offers curated sources and
GitHub/Git repositories, not a local-directory selector. No marketplace addition,
installation, active-session loading or live measurement was confirmed.
Do not keep navigating this dialog, upload the package, invent a Git URL for its
local path, or treat the displayed command as an executed installation.

This was an onboarding-instruction defect, not a provider authentication failure.
The revised controls remove those navigation commands and their unsupported
local-only installation-panel instructions. This corrects the misleading UI;
it does not implement a public installer. Native onboarding acceptance remains HOLD.
For this local trial, use `manage-code-comparison-plugin.mjs` below with a
compatible explicitly selected CLI, an explicitly selected project, local scope,
and that project's Code sessions closed. Do not upgrade the normal CLI or switch
to user/project scope to work around the issue. The normal CLI observed on this
Mac reports 2.1.267, below the management tool's 2.1.287 minimum; the separately
verified trial CLI reports 2.1.289. Neither version check installs anything or
establishes Desktop loading.

After installation, start the selected Code session and verify command loading.
Only then prepare a fresh connection in the app; previously displayed connection
arguments can expire after 15 minutes and must not be reused after expiry.
Use the registered `/quotatempo-probe` command in Code's input, not Desktop's
plugin settings. Run `status`; its fixed disconnected response establishes
command execution, not a connection or quota measurement. If it is registered,
do not reinstall. Select that command again and supply the app's newly prepared
`connect <directory> <public key>` arguments. Connection arguments are hidden
after the handshake or expiry; a stale preparation must be replaced, not recopied.

The coordinating run has user-reported fixed `status` and successful connected
responses for the unmodified 0.0.4 plugin. This advances command and handshake
acceptance only. A subsequent user-provided native screenshot shows both weekly
and five-hour remaining values, their resets and the Code observation time. This
accepts unmodified-plugin measurement receipt/display for this local trial, not
account identity, provider freshness or final distribution. The active
session's genuine README review and subsequent normal work may produce
`session.measure` events. Do not submit a dummy request just to provoke quota
data, reread a provider cache, or promise that idle waiting will produce an event.

Primary references: [install from your shell](https://code.claude.com/docs/en/discover-plugins#install-from-your-shell)
and [Desktop shared configuration](https://code.claude.com/docs/en/desktop#shared-configuration).

Version 0.0.4 performs an encrypted schema-3 Unix HTTP handshake first; the app distinguishes
**Connected; waiting for measurement** from **Waiting for connection**. After one
normal measurement it shows weekly/five-hour remaining values and exact resets.
Quota payloads remain in memory, with no filesystem export or TCP fallback.
Multiple streams stop comparison rather than
guessing or merging. No provider directory, cache, transcript, account identifier
or credential is read. Polling every two seconds samples in-memory comparison
state and validates only the app's own grant and socket.
The controller never modifies `ProviderSnapshot`, W/P, source preferences or
planning. Closing the app or disabling Claude does not restore comparison
consent or observations on restart.

Malformed messages or unsafe local paths, clock regression, stale tuples and passed resets
clear visible values. Replay and first-seen watermarks remain in memory even
after a failed read. Disconnect revokes the exact grant before scoped cleanup;
unknown files are preserved and incomplete cleanup is reported, without blocking
a newly consented connection. Disabling Claude and normal app termination close
the receiver synchronously. Shared preparation gates prevent a delayed reply
from leaving a connectable grant. Forced termination can leave quota-free grant
and socket paths behind, never resumed automatically. The plugin checks the
unchanged grant before each request and stops on uncertain delivery without replay.

This implements native ingestion and bundled onboarding, not merely a CLI trial,
but it is not a released or account-identity-verified feature. No existing trial
installation is upgraded automatically; earlier caches remain historical until
explicitly updated and reloaded. Remaining gates include live Code acceptance
with a final release candidate and final public distribution.
Chat/Cowork-only support and provider account identity remain unproven; this path
must not become Automatic or a planning source.

Current 0.0.4 validation reported by the coordinating run: official 2.1.289 plugin
validation and **29 runtime tests PASS**; **83 Node probe tests PASS**. These are
isolated/synthetic compatibility results, not live-account acquisition evidence.
The earlier preview Swift run passed **902 tests / 46 suites**, including the
opt-in official-engine native wire test and the existing expected browser
watchdog issue. The latest full preview run passed **905 tests / 46 suites**;
the official-engine opt-in fixture was not re-executed in that run. The four
earlier package failures came from Foundation rewriting
POSIX paths to symlink aliases; the corrected paths retain the strict no-symlink
and ancestor-permission checks. Earlier full-suite counts below are historical.

Both macOS CI runs at `1809254` failed in integration-test fixtures, despite
passing locally. Global provider-process shutdown fixtures could terminate a
different suite's process, and synchronous IPC barriers occupied Swift's
cooperative executor. The corrected fixtures share a serialized parent suite;
blocking socket and semaphore work runs on Dispatch queues. Clock-ordering
assertions exercise the production bridge directly, with explicit bounded
fixture deadlines. Product timers, guards and shutdown behavior are unchanged.
The focused regression run passed **132 tests / 4 suites**. Remote CI acceptance
of this correction remains separate from these local results.

Both macOS CI jobs at `71f5224` failed the same offscreen English expired-state
assertion: hiding obsolete connection arguments reduced the sampled dark-pixel
count below an absolute 300-pixel threshold. The screenshot was nonblank. The
revised raster check uses visible coverage greater than 1% of sampled image area,
with explicit empty/sparse rejection and scale-independence regressions; it does
not claim to detect missing content or overlapping text. The full 905-test local
preview run passed with the existing known browser-watchdog issue. Corrected
remote CI acceptance remains pending.

### Finder startup failure and regression gate

The `ce19e67` candidate's macOS CI and CodeQL succeeded, but real Finder launches
on October 6 at 17:24 JST crashed twice before scene creation. Its defaults getter
force-unwrapped `UserDefaults(suiteName:)` with the preview's own bundle ID.
[Apple disallows that suite name](https://developer.apple.com/documentation/foundation/userdefaults/init(suitename:)).
The Code preview now uses `.standard`, isolated by its unique bundle identifier;
the legacy Desktop-preview suite and normal application's behavior are retained.

Earlier resource validation returned before app composition and could not detect
this startup error. A separate, preview-only startup validation entry point now
exercises the production defaults getter and real app initializer, injecting a
fresh preference suite and private support directory. Provider acquisition is
disabled; `App.main()` is not called. The signed Developer ID candidate passed
all **7 cases / zero skips**, with complete temporary cleanup. **19 harness
regressions** and **5 Swift startup tests** also passed. This is initialization
acceptance, not Finder/window acceptance or live Code usage. Do not reuse the
crashing `ce19e67` preview. The corrected commit needs its own CI and native
workflow acceptance.

```bash
node scripts/test-code-comparison-startup.mjs --app /private/tmp/CodeComparisonPreview.app
```

The startup harness denies network access and reads/writes under the normal
HOME. It intentionally rejects apps under HOME, including Downloads; use an
explicitly verified private temporary build. Each child has a fresh HOME, and
only bounded, recognized results authorize adoption and cleanup of its private
outputs. Its fixed result reports `guiStarted: false` and `liveCodeAccepted: false`.

The checksum-pinned, signature-verified official 2.1.289 engine sent encrypted
synthetic usage over its real HTTP Unix-socket API to the native receiver. No
authentication or model request was used. Of eight private plugin copies, only
`hooks/register.mjs` was mechanically instrumented for a test-only immediate
command; the other seven stayed byte-identical. This proves isolated wire
interoperability, not unmodified-plugin live usage, another runtime's
compatibility, provider freshness or account identity. The production plugin was
not changed by the test.

Both ad-hoc and Developer ID local previews passed the headless bundled-resource
validation command. This is separate from Code UI acceptance and notarization.
The signed-resource harness passed all **11 cases with no skips**: clean and
ad-hoc controls, tampered resource rejection, self-consistent re-signing with an
altered manifest rejected by the compiled pin, a world-writable ancestor and
six malformed argument variants. All disposable copies were cleaned; the
installed app, preferences and normal Code configuration were not modified.

```bash
node scripts/test-code-comparison-signed-package.mjs --app /absolute/CodeComparisonPreview.app
```

This harness runs only the reserved headless validation entry point. It does
not open a window, install a plugin, read account authentication or acquire real
usage. A skipped required case is incomplete, never PASS.

This table records the pre-0.1.12 preview checkpoint.

| Historical preview verification | Result | Boundary |
| --- | --- | --- |
| Default Swift graph | PASS, 764 tests / 30 suites | Existing expected browser watchdog issue |
| Preview Swift graph | PASS, 905 tests / 46 suites | Same expected watchdog issue; prior 902-test run separately exercised opt-in official-engine wire |
| Node metadata, packaging and helper regressions | PASS, 288 tests | No live account acquisition |
| Official 2.1.289 plugin validator / runtime | PASS / 29 tests | HTTP fixtures in `plugin test` |
| Signed resource rejection harness | PASS, 11 cases / zero skips | Disposable copies; no Code UI or authentication |
| Signed app initialization harness | PASS, 7 cases / zero skips; 19 harness regressions | Defaults getter and isolated app composition; no GUI startup |
| Preview builder | PASS, 21 cases | Synthetic builder fixtures |
| Compiled-artifact isolation | PASS, 588 regressions and two actual normal bundles | Code comparison implementation excluded from normal artifacts |
| Manifest isolation | PASS, 13 positive / 328 negative cases | Preview-only app and test graph |
| Crypto bundle reproducibility, format and release policies | PASS | Published app version remains 0.1.11 |
| Unmodified 0.0.4 native measurement/display | User screenshot confirmed | Local trial only; identity/provider freshness unverified |
| Final public integration and distribution | NOT ACCEPTED | No public enablement or release claim |

Historical file-transport checkpoint: 48 native tests across decoding, secure temporary-file
transport, controller lifecycle, app wiring and offscreen UI passed. The complete
default Swift suite passed 812 tests / 34 suites and the local integration suite
passed 857 tests / 39 suites, both including the existing expected watchdog
issue. Both English and Japanese 580px offscreen renders were checked
visually and by nonblank-pixel assertions; this is not OS-dialog acceptance.
At that historical checkpoint, 65 Node regressions and three official 2.1.289 runtime tests passed, with the
runtime isolated in an empty HOME and network denied. Independent rereview found
no new P1/P2 in the corrected scope while keeping the production gates above
open. Local app packaging is ad-hoc signed, not public notarization or installation.

## Versioned packaging and project-local management

### Historical plaintext Unix IPC checkpoint (2026-10-06)

The following counts and blocker describe version 0.0.3. The schema-3 transport
below supersedes this endpoint-authentication blocker; it does not retroactively
turn these tests into real-Code or public distribution acceptance.

- Native regressions: 60 tests / 6 suites passed, including actual plugin-to-Swift
  Unix-socket round trips with synthetic quotas and zero quota-file writes.
- Full Swift: default 824 tests / 35 suites; integration 869 / 40, both passed
  with the existing intentionally recorded browser-watchdog issue.
- Node: 209 tests passed across producer, protocol/hook/observer, packaging and
  management. Official 2.1.289 validation and 10 runtime tests passed with empty
  HOME, normal-home access and networking denied; HTTP calls there are stubs.
- Native OFF/disconnect/quit fence preparation before the actor hop and reject
  stale tickets before touching a newer connection. Clock sampling is serialized
  with state updates; both interleavings have arrival-barrier regressions.
- Plugin disconnect waits for pending handshake cleanup. Delivery/clock errors
  retain only a control binding for explicit disconnect, never quota for replay.
  Unconfirmed control requests have fixed failure output, not a success claim.
- English/Japanese offscreen renders cover connection wait, measurement wait,
  received values and expiry. These are not foreground UI or OS-dialog tests.
- A fresh local ad-hoc app bundle and immutable 0.0.3 plugin package were built
  and verified. Neither was installed, launched, notarized or published. The
  user's existing trial cache, released app and production configuration are untouched.

Independent rereview confirmed the native lifecycle P2 fixes. The known
endpoint-authentication P1 remains open: native client UID checks do not prove
the server's identity to Mods. This checkpoint is **NOT_READY for public
enablement**. Next acceptance requires channel-bound endpoint authentication,
no-quota-leak replacement tests before/after handshake, native installation and
onboarding, and the existing signed-distribution gates. Do not promote comparison
values into Automatic, W/P or planning while account and provider freshness are unverified.

Version 0.0.2 includes the revised hook, not the earlier installed trial cache.
Version 0.0.3 adds Unix HTTP; the old schema-1 file route remains explicitly
experimental and is not prepared by the native app. The official API lacks a
server-identity primitive: socket replacement before or after handshake can
redirect plaintext quota to a forged server. Native client-UID/inode checks
protect the genuine receiver, not this outgoing path. Public enablement therefore
remains blocked on endpoint authentication; no confidentiality guarantee is made.
Developer tooling supports packaging and official CLI lifecycle operations;
it is not yet a public app installer. Applying it is **local-trial-only** while
the writer permission/identity boundary above remains unresolved.

### Encrypted native transport (0.0.4, schema 3)

The copied native command is `connect <prepared absolute directory> <app public key>`.
The public key is copied from the app, never discovered in the writable grant.
Each request uses a new RFC 9180 HPKE context with
X25519/HKDF-SHA-256/ChaCha20-Poly1305, bound to the connection, stream, unique
request and operation. Successful replies prove possession of a derived response
key. Replays, malformed bindings and plaintext schema-2 grants are rejected.
Replacing the socket before or after handshake does not expose quota plaintext
to the replacement server. Keys and quota payloads are not exported to files.
There is no TCP or plaintext fallback. Trust in the app, copied command, plugin
and Code runtime remains necessary; this is not protection against total
same-user compromise.

Swift CryptoKit and the pinned JavaScript bundle interoperate over the actual
local socket in synthetic tests. The cryptographic bundle is reproducible from
`crypto-build/package-lock.json`; `node crypto-build/build.mjs --check` verifies
the vendored output and notices after an install with lifecycle scripts disabled.
The runtime bundle has no filesystem, network or subprocess imports.
Only allowlisted usage is encrypted; model, account and session content stay out.

The official Mods HTTP API has no documented timeout, abort field or pre-read
response cap. The probe enforces bounded caller deadlines; these must not be
described as host HTTP cancellation.
Uncertain delivery stops exporting, ignores late replies and never retries quota.
Its buffered-response resource limits are an unverified host assumption.

Package a new destination from the repository root:

```sh
node scripts/package-code-comparison-plugin.mjs pack --source "$PWD/experiments/claude-mods-usage" --destination /absolute/private/path/plugin-v0.0.4
node scripts/package-code-comparison-plugin.mjs verify --directory /absolute/private/path/plugin-v0.0.4
```

The current package contains exactly eight payload files: the two plugin manifests, hooks manifest/module,
producer, protocol, transport crypto and third-party notices, plus its quota-free
integrity manifest. Tests, observers,
user state and repository documents are not copied. Default developer packaging gets a fresh
`quotatempo-code-<UUID>` marketplace name rather than taking over the old trial
marketplace. Directories are 0700 and files 0600. Symlinks, nonregular files,
extra packaged files, changed permissions and hash mismatches fail verification.
Hashes detect changes; they are not a signature or source-trust decision.

The native 0.0.4 release is an explicit exception to that fresh-UUID default:
`quotatempo-code-d276298d-6c66-477a-8c58-cf2b5d8e6104` is its fixed namespace, with
compiled manifest SHA-256 pin
`22024700344b34c645f47906425d90a375a46e14c1e3e17c90a729393215766c`.
The separate preview builder passes the fixed namespace to the packager and
requires the actual manifest digest to equal the compiled pin; it does not
rewrite Swift source while building. Rebuilding the same immutable 0.0.4 payload
therefore keeps the same plugin identity. This does not change the packager's
default behavior or authorize replacement of an existing installation.

Native onboarding verifies the enclosing bundle signature before and after
staging, binds the copied manifest and payload bytes to the compiled pin and
requires exact inventory, bounded sizes, hashes and no symlinks. It writes to a
unique private `.stage-<UUID>`, verifies and fsyncs it, then publishes with
`RENAME_EXCL`; existing final directories are verified only, never repaired or
overwritten. Cleanup is limited to the current stage's recorded identities;
unknown stale stages remain quota-free and are not automatically deleted.
Installed-app staging does not require Node or automatically invoke a CLI.
Ad-hoc preview signing provides local integrity, not public publisher trust.
Preview preferences and observations are isolated from the normal app, and
provider acquisition is disabled in this Code-only preview.

Use an **absolute, non-symlink compatible CLI executable**, a deliberately chosen
local project and a new receipt directory whose existing parent is private (0700).
The CLI must report Claude Code 2.1.287 or later in the 2.1 series. The tool does
not upgrade or replace an incompatible normal CLI. These example paths are
placeholders, not commands to run against an arbitrary working project:

```sh
node scripts/manage-code-comparison-plugin.mjs install --project /absolute/path/trial-project --cli /absolute/path/claude --package /absolute/private/path/plugin-v0.0.4 --receipt /absolute/private/path/install-receipt
```

Without `--apply`, this validates and returns the exact argument-vector plan,
but does not invoke Claude or create a receipt. To apply the reviewed plan, close
the selected project's Code sessions and add all three explicit flags:
`--apply --local-trial --code-sessions-closed`. CLI manager operations use local
scope; they do not submit a model turn, read provider files through the tool,
connect the probe or establish runtime loading. Claude can maintain its own
global plugin cache. Start the selected Code session afterward and verify the
fixed disconnected status before explicitly connecting a fresh grant.

Use the same project/CLI/package/receipt arguments with `update`, `disable`, `enable` or
`uninstall`. `update` against the same immutable package refreshes that exact
installed ID. For a genuinely higher package version, pass its new package path:
the tool adds/installs the new unique ID, preserves disabled state, then uninstalls
the old local ID. It does not update another project's old package in place.
`uninstall` retains plugin data and never removes global marketplaces or package
directories because other usage cannot be proven absent. These operations require
the same explicit flags and closed-session acknowledgement.

The private `.quotatempo-code-plugin-management` directory in the chosen project
is the canonical operation journal; do not commit, move or delete it while an
operation is unresolved. The separate private receipt records the old/new
package bindings, active binding, exact target IDs and stage results. Both are
quota-free metadata. Changing the receipt cannot bypass a pending operation;
missing canonical state stops management. Checkpoints and directory renames are
synced before mutations. A CLI deadline forcibly stops its process group and
checks exit; unconfirmed termination retains the lock. Filesystem calls stuck
inside the OS and detached grandchildren are not claimed universally cancellable.
Any failed or uncertain operation returns a fixed stop status, without storing
stdout/stderr or automatically repeating, undoing or globally pruning anything.
Operator reconciliation of `attentionRequired` remains a manual developer task,
not a finished public recovery UI.

An isolated test with the verified official 2.1.289 binary passed package
validation, install, exact-ID refresh, disable, staged higher-version update and
uninstall. The fixture's higher version is synthetic, not a release. Networking
and the normal HOME were denied; no provider, real project or installed CLI
was changed. Reproduce only with the verified binary explicitly supplied:

```sh
node scripts/test-code-comparison-plugin-lifecycle.mjs /absolute/path/to/verified/claude
node --test scripts/package-code-comparison-plugin.test.mjs scripts/manage-code-comparison-plugin.test.mjs
```

This is supported CLI lifecycle evidence, not proof of native installation.
Bundled native staging is implemented; complete native QA, live-account acceptance
with the revised plugin and signed public distribution remain open.
Official [CLI management](https://code.claude.com/docs/en/plugins/cli-reference)
and [loading/scope](https://code.claude.com/docs/en/discover-plugins) contracts
define when a plugin becomes available; a successful installation is not proof
of command interception or received measurements.

Historical lifecycle checkpoint: 98 packaging, 28 management and 65 producer/transport
regressions passed (191 total). Independent rereview found no remaining P1/P2
in the corrected management scope. The isolated official CLI executed 15 bounded
commands across the six lifecycle checks, all passing after the final fixes.
Release and distribution policy checks also passed. Swift application code did
not change in this lifecycle increment; the earlier native QA checkpoint is not
a new end-to-end acceptance of the packaged plugin.

## Historical schema-1 bounded local trial

The preparation, file export and installed-trial commands in this section record
the earlier schema-1 route. They are not the current schema-3 native onboarding
or encrypted wire acceptance procedure.

Only use an existing, authorized local Code session on a compatible host. Terminal
Mods require Claude Code 2.1.287+; this prototype was tested with the official
2.1.289 harness. The Desktop app bundles a separate Code runtime. Code-tab support
does not establish ordinary Chat/Cowork support, availability while Code is closed,
or identity compatibility with the existing Desktop connection.

From the repository root, prepare a new scratch directory:

```sh
node experiments/claude-mods-usage/receiver.mjs prepare /private/tmp/quotatempo-mods-compare-new
```

For a terminal trial, load this local folder into a new session with
`claude --plugin-dir /absolute/path/to/quota-tempo-public/experiments/claude-mods-usage`.
This is not a marketplace installation. One Desktop Code local-project trial
has passed command interception and quota transport; see the checkpoint below.
That result does not establish support for other hosts or Chat/Cowork.
In that session explicitly run:

```text
/quotatempo-probe connect /private/tmp/quotatempo-mods-compare-new
/quotatempo-probe status
```

Use the stream UUID returned by the command to inspect the next normal measured
event. Do not force a model request just to populate the probe:

```sh
node experiments/claude-mods-usage/receiver.mjs inspect /private/tmp/quotatempo-mods-compare-new <stream-UUID>
```

For a bounded, read-only comparison while working normally, use a second terminal:

```sh
node experiments/claude-mods-usage/observe.mjs /private/tmp/quotatempo-mods-compare-new <stream-UUID> 600
```

This checks the selected metadata files every two seconds, outputs JSON only when
the state changes, and stops on disconnect, grant replacement, Ctrl-C or ten
minutes. Duration can be 1 through 1800 seconds. It creates no daemon, scheduler,
provider requests or evidence files. The monotonic deadline bounds the loop, not
a filesystem operation stuck inside the OS. All output remains comparison-only;
silence does not mean successful upstream acquisition.

Finish with `/quotatempo-probe disconnect`, exit that test session, and remove
only the chosen scratch directory after retaining any desired quota-only evidence.
No user plugin settings, production QuotaTempo state or system CLI is replaced.

### Optional Desktop local-project trial

Desktop uses its own Code runtime; its application version is not proof of the
Code engine's version or successful module loading. Do not install this into a
working project such as a game/bot session or at user/project scope. First create
a separate empty test project. From a shell in that directory, the supported
plugin-manager commands are:

```sh
claude plugin marketplace add /absolute/path/to/experiments/claude-mods-usage --scope local
claude plugin install quotatempo-usage-probe@quotatempo-local-probe --scope local
```

Open **only that test directory** as a local Code project in Desktop, confirm the
probe loads, and explicitly connect using a newly prepared comparison directory.
No model turn is submitted by installation or by the probe's connect command.
If the command does not appear, stop: installation is not proof of runtime support.
Global plugin caches/registries can be maintained by Claude even for a local-scope
install, but the probe must be enabled only for the chosen test project.

Exit the test Code session before cleanup. From the same test directory:

```sh
claude plugin uninstall quotatempo-usage-probe@quotatempo-local-probe --scope local
claude plugin marketplace remove quotatempo-local-probe --scope local
```

Do not remove a marketplace used by another project. Keep the source folder until
cleanup completes. No Desktop authentication, installed app, Keychain permission,
production QuotaTempo preference or other project's settings should be modified.
Instructions alone are not native acceptance evidence. The checkpoint below
separates the one observed Desktop trial from remaining acceptance checks.

### Operator checklist and expected results

1. Prepare a **new** absolute directory with `receiver.mjs prepare`, using the
   command above. Expected result: `status: prepared`. Connect within 15 minutes.
   Preparation creates a 0700 directory and a 0600 grant. Do not use an existing
   directory, a symlink, a path containing `.`/`..`, or a directory whose ownership
   or permissions have changed. On fixed connection failure, stop and resolve
   these conditions; never retry against account/cache files.
2. In the **local Code session**, select `quotatempo-probe` from
   **+ > Slash commands** and append `status`. Expected response after the plugin
   name: `QuotaTempo probe disconnected.` If absent or handled as ordinary model
   text, stop without connecting. Chat and Cowork are outside this Code-mod trial.
3. Select the same command and append `connect <prepared absolute directory>`.
   Expected response starts `Comparison-only probe connected.` and supplies
   `Stream: <UUID>`. This confirms activation, **not received values**. There is
   no quota-selection UI: five-hour and seven-day windows are allowlisted. The
   receiver operator selects only this returned stream, not another session.
4. `session.measure` fires after a turn and when a plan-limit percentage changes.
   Connect/status need no model request. Idle waiting alone does not guarantee
   an event. Continue genuine work within the trial boundaries, such as reviewing
   these instructions, only when useful; do not send a dummy quota-population turn.
5. Output is `<directory>/stream-<UUID>.json`. The receiver operator runs `inspect`
   or bounded `observe` above using the returned UUID. `comparison_only` with quota
   rows means validated metadata arrived. Waiting, an absent file, timeout or empty
   rows do not mean capture succeeded. A reread does not renew freshness. The
   operator reads only this export and grant, not provider caches or transcripts.
6. Select the command and append `disconnect`. Expected response:
   `QuotaTempo probe disconnected. No product source was changed.` The operator
   checks invalidation, stops observers and removes only this output directory.
   Removing output is not plugin uninstallation and does not change the product.

Session end invalidates an active stream when its hook runs; reload also stops
the active connection. A new module begins disconnected. A crash or forced
termination cannot guarantee an invalidation write: explicitly disconnect rather
than relying on closing a tab. Old comparison values expire and are never promoted.
For reconnecting, prepare a fresh directory. Then close the trial Code session
normally; archiving is not required and is not plugin removal. Local settings
remain until the uninstall/remove commands above are run from the same project,
after the trial session ends. Never remove a marketplace used by another project.

### Desktop loading checkpoint (2026-10-06)

The first local Desktop trial did **not** intercept
`/quotatempo-probe status`: it reached the model as ordinary text. No probe
connection, quota export or reset capture was established. Local enablement
and an installed copy are not proof that the running Desktop session loaded it.
The five checked manifest/module/producer/protocol files in the installed cache
matched the trial source.

The running Desktop Code engine was 2.1.288. A full, signature-verified copy of
that engine passed three official runtime tests and returned the fixed
`QuotaTempo probe disconnected.` response through both inline loading and a
local-marketplace installation in an empty-HOME, network-denied environment.
This verifies the adapter and isolated CLI loader, not the Desktop UI path or
live provider data. The system CLI remains 2.1.267. The exact Desktop failure
cause is unresolved; do not infer a version deficiency or override host policy.

For one targeted UI check, use the trial session's **+ > Slash commands** menu
described in the [official Desktop reference](https://code.claude.com/docs/en/desktop#use-skills).
If `quotatempo-probe` appears, select it so it is highlighted, append `status`,
and submit once. If it is absent, do not submit the raw command again or create
a model-driven substitute. Report only its absence; an own-plugin loading
error may be checked separately without reading session/debug log bodies.
Menu selection is a diagnostic hypothesis, not a confirmed fix. Do not connect
until the fixed status response is confirmed in Desktop.

The subsequent user-reported Desktop check returned the fixed
`QuotaTempo probe disconnected.` response after selecting the command from the
menu. Command interception is now confirmed by that user report, not by direct
agent UI observation. This does not establish why the first submission fell
through, or prove connection, quota transport or live reset capture. The next
step is an explicit connection to a newly prepared private comparison directory,
followed by a normal measured event; do not force a model request for quota data.

The user subsequently reported the fixed comparison-only connected response.
Connection activation is user-confirmed; it is not evidence of quota reception.
The [official event reference](https://code.claude.com/docs/en/plugins/mods/reference#session)
describes `session.measure` as firing after a turn and when a plan limit's
percent used changes. A connect/status command alone is not an acceptance
requirement for an export. Absence of an export cannot distinguish an event
that has not fired from a handler or transport failure without further evidence.
Continue with normal Code work, not an artificial quota-population turn.

A bounded 90-second agent-side observation of the explicitly selected stream
finished without an export file or quota values. It reported
`waiting_for_measurement`, then `observation_timed_out`; the observer exited.
The private directory's safety checks passed. This is a pending live-capture
check, not a successful capture or a proven event/transport failure. The probe
was not disconnected by that read-only observer, and no recurring monitor was
created. At that checkpoint, a normal turn and explicit disconnect were pending.

After a genuine trial-README review turn, the agent read only the chosen grant
and allowlisted export through the receiver. It returned `comparison_only` with
both five-hour and seven-day rows and exact future reset timestamps. This is the
first directly observed live quota-transport success for this Desktop Code trial;
user percentages and stream labels are not committed here. No reset was
extrapolated. It does not prove provider freshness, account binding, Chat-only
support, persistent idle updates or eligibility for product planning.
At that capture checkpoint, provider-display comparison and explicit disconnect
were pending; the shipped app was unchanged.

The user then ran explicit disconnect and reported its fixed response. The
agent's receiver directly returned `disconnected` with both quota windows null.
Only the selected trial's private grant and stream output were removed after
checking directory ownership, permissions and exact file names/types. The bounded
observers had exited; no monitor remains. Command interception, live transport,
unchanged reread behavior and disconnect invalidation have passed in this one
Code trial. The trial project and locally enabled plugin remain available, but
the probe is disconnected; their removal is separate from output cleanup. No
production setting or other project's plugin configuration was changed.
Provider-display comparison, account binding, Chat-only support and product
integration remain unverified. Another connection needs a fresh prepared path.

## API

- `normalizeUsage(usage, readAt)` is pure. Pass a plain data object and a local
  ISO timestamp. It returns a frozen, allowlisted result.
- `createUsageProducer({ getUsage, clock, sink })` returns `{ poll() }`.
  `getUsage()` may return data or a promise. `clock()` synchronously returns an
  ISO string, sampled after the getter resolves. `sink(result)` may be async.
  All three callbacks are required; construction performs no work.
- `await producer.poll()` performs one read and one sink call, then returns the
  same frozen result. It does not retry. Concurrent calls reject with the fixed
  error `poll_in_progress`, including while the sink is pending.

The pure producer imports nothing and has no process, file, network, command, or
default-clock access. The caller controls the injected capabilities. The adapter
uses the same pure logic with an event value; unit tests use fake callbacks.

## Fixed output

The pure producer result remains schema 1; this is distinct from the current
schema-3 grant and encrypted wire envelope.
Every result contains only `schemaVersion: 1`, `status`, `reason`, `readAt`, and
`rateLimits`. Status is `valid`, `invalid`, or `unavailable`; reason is null or a
fixed code defined in the producer, never raw input/error text.

Normalized rows contain only `kind`, `percentUsed`, and `resetsAt`. Producer rows
also contain `firstSeenAt` and `lastReadAt`. Unknown input fields are ignored
without enumeration, evaluation, or copying. Session/account identifiers, paths,
models, arbitrary text, and upstream freshness fields never enter the output.
Known fields must be own data properties. Outputs do not retain input objects.

- Accept one or two unique kinds: `five_hour` and `seven_day`, in that output
  order. Empty arrays, duplicates, unknown kinds, malformed rows, or more than
  two rows invalidate the entire read.
- Percentages must be finite numbers in the inclusive range 0 through 100.
  There is no coercion, clamping, rounding, or estimation.
- Although `resetsAt` is optional in the input contract, every accepted row must
  supply a strictly future reset relative to `readAt`. Missing, empty, malformed,
  or expired resets invalidate the entire read. No prior reset is borrowed.
- Timestamps require a four-digit calendar year, valid date, `T`, seconds, and
  `Z` or a numeric offset. Fractional seconds may have one to three digits.
  Date-only/local times, calendar rollover, leap seconds, `24:00`, unknown
  `-00:00` offsets, and finer precision are rejected, not guessed or truncated.
  Valid instants are normalized to UTC milliseconds with a four-digit year.
- A valid subset remains a subset: a five-hour row alone never supplies a weekly
  quota or reset. Invalid reads and omitted kinds clear prior continuity.

## Observation boundaries

`readAt` and `lastReadAt` are local read times, **not server freshness**.
`firstSeenAt` is the first local read of the current unchanged `(kind,
percentUsed, resetsAt)` tuple within uninterrupted valid reads. Identical polls
retain it, including reordered rows and equivalent timestamp spellings. A
percentage change or reset change starts a new local tuple. Equal timestamps
are allowed, so `firstSeenAt` is not a unique event ID.

A changed reset replaces old window continuity even when percentage usage is
unchanged. Identical data becomes invalid once its reset expires. No reset
extrapolation, counter-based freshness, server observation timestamp, ownership
proof, or account continuity is claimed. Identical tuples could be stale or
belong to different accounts; the producer cannot distinguish them. `valid`
means schema/time checks passed, **not verified exact provider truth** and not
permission to use this data as shipped-app freshness or planning evidence.

Getter/clock failures emit a fixed `unavailable` result with no quota rows.
Invalid clocks fail validation; clock regressions fail closed and never lower
the local watermark. Sink failures reject with `sink_failed` without the original
error or cause. Local continuity is committed before sink delivery: a sink can
accept data and then throw, so delivery is uncertain and there is no automatic
replay. Consumers must replace/invalidate prior display state on an empty result,
not retain it as a current observation.

State is bounded to two rows, one watermark, and one in-flight poll, in memory
only. Restarting creates new local first-seen times, not refreshed server data.
A pending pure-producer callback has no built-in timeout or cancellation. The
current encrypted hook separately enforces caller deadlines without claiming
host-side cancellation. Plain data inputs are expected; this is
not a sandbox for hostile executable JavaScript or Proxy traps.

## Verification

From the repository root, using only Node's built-in test runner:

```sh
node --test experiments/claude-mods-usage/producer.test.mjs experiments/claude-mods-usage/probe.test.mjs experiments/claude-mods-usage/observe.test.mjs
```

The producer tests use only inline data and fake callbacks. Probe tests also
exercise real temporary owner-only fixture directories, malformed/partial files,
symlinks and permission rejection. No real provider input or production store is
read. At the historical file-transport checkpoint, all 65 Node tests passed;
the current probe suite has 83 passing tests as reported above. These
commands do not start Swift or installed apps.

On an isolated compatible runtime, the official harness commands are:

```sh
claude plugin validate experiments/claude-mods-usage
claude plugin test experiments/claude-mods-usage
```

The official harness stubs host filesystem, HTTP and clock operations; no provider,
model or normal-home store action occurs behind those stubs. Historical validation and three
schema-1 runtime tests passed on 2.1.289 with networking denied, an empty temporary HOME
and protected local state paths denied. The official downloaded binary matched
SHA-256 `03d66745e3bb69ec727d66023696f3820bc0a00a8a5ba725eb6706d0c67cbe69`
and passed macOS code-signature verification. The normal CLI was 2.1.267 at that checkpoint.
No normal CLI or installed app was replaced. This is harness compatibility, not a real
Desktop subscription acquisition or native UI acceptance result.

For the current encrypted schema-3 fixtures, the bounded helper also verifies the exact
official binary checksum/signature, runs in an empty HOME and denies access to
normal HOME and networking:

```sh
node scripts/test-code-comparison-mods-runtime.mjs --cli /absolute/path/to/verified-2.1.289-claude
```

It does not download or install a CLI. The final current runtime suite passed
29 cases; its HTTP stubs establish API/crypto compatibility, not a real
engine-to-native wire connection. The earlier 10-case schema-2 result is historical.

The same protected, empty-HOME runtime also handled the actual
`-p '/quotatempo-probe status' --plugin-dir ... --strict-mcp-config` command,
returning the disconnected state without login or a model request. Local-scope
marketplace registration, installation, uninstallation and removal succeeded in
that isolated test project. This establishes command loading and plugin-manager
compatibility on 2.1.289, not live quota capture or Desktop Code acceptance.

One local Desktop Code trial passed loading, live quota transport and disconnect;
see the dated checkpoint above. Native-app acceptance of the new integration,
provider freshness, same-account proof and signed-distribution acceptance remain unverified.
Do not auto-promote this comparison into the shipped Desktop connection.

## Sources and safety disposition

Original implementation; no WeekToken code or assets were copied. References:
[WeekToken](https://github.com/3dnow/claude-mods/tree/98e2d7a9efaa2c708ca832774289bf50348c789b/weektoken),
[official Mods API](https://code.claude.com/docs/en/plugins/mods/reference),
[official test kit](https://code.claude.com/docs/en/plugins/mods/test), and
[official runtime manifest](https://downloads.claude.ai/claude-code-releases/2.1.289/manifest.json).

Safety disposition: **try-in-sandbox** for the original quota-only probe and
official test kit; **not approved for automatic production ingestion**. Mods have
Claude Code's general access; this adapter's narrow call list is not an OS sandbox.
The third-party WeekToken plugin was not installed: its cache/history reads and
manual CLI refresh are unnecessary for this trial. No provider permission or
universal Desktop-only support is inferred from successful harness tests.
