# Claude acquisition research

Research dates: 2026-09-29 and 2026-09-30. This is a source-based feasibility assessment, not a
runtime compatibility guarantee or a change to the [freshness contract](provider-freshness-contract.md).

## Requirement and status

The unresolved requirement is reliable Claude weekly remaining (`W`), today's
target remaining (`P`), and reset availability using an existing Claude Desktop
sign-in, with the standalone CLI signed out and **no new login**.

No path examined here has been independently verified against that complete guarantee.
This is not a claim that Desktop-only acquisition is technically impossible:
other applications implement active requests using Desktop authentication. The
expanded comparison below separates technical feasibility, product/security
approval, and demonstrated runtime reliability.
Desktop HTTP-cache work in Draft PR #42 remains experimental: organization-level
ownership and uncertain refresh behavior do not establish account-bound,
continuous availability. The browser extension prototype is tracked in a
separate pull request from Draft PR #42. A working browser-session bridge would
not, by itself, satisfy the Desktop-only requirement.

The currently authorized research and observation preserve these boundaries.
Studying public code that crosses them does not authorize running that code or
changing QuotaTempo's privacy contract:

- Read only allowlisted, nonsecret quota and identity metadata. Do not read,
  extract, copy, or hash tokens, cookies, credentials, or conversation transcripts.
- Do not focus, raise, navigate, reload, or otherwise manipulate apps or browsers
  to obtain a reading. Do not dump entire caches or accessibility trees.
- Keep source observation time separate from file modification and read time.
  A repeated read is not a refresh, and matching organizations are not proof of
  matching accounts.
- Never pass an estimate as an exact reset. Existing bounded estimates must stay
  explicitly labeled under the freshness contract; never chain them. When an
  account-compatible reset is unavailable, keep eligible dated `W` observations
  and withhold exact-reset-dependent planning.

## Five shipped competitors

Each release below has a public distribution asset. Source links are pinned to
the release-tag commit; binaries were not installed, executed, or independently
matched to source. These projects are implementation evidence, not endorsements.

| Project and release | Pinned implementation | Path and limitation |
| --- | --- | --- |
| Codenotch [v1.19.0][codenotch-release] | `00833690311067354c77951fcaaf6ffca774916e`, [cache reader][codenotch-source] | Reads Desktop Chromium HTTP-cache `/api/organizations/<org>/usage` responses, including query variants. Supplies percentages and reset timestamps without a new request. Its [caller][codenotch-caller] obtains the matching org from a Claude Code profile. This neither proves same-org account ownership nor forces Desktop refresh. |
| Claude Switcher [v0.6.0][switcher-release] | `ff8351eef28fade30b80f8b673b0686c0b41fb90`, [usage reader][switcher-source] | Reads each Desktop profile's `plan-usage-history.json`. Selects the latest sample's org and infers reset bounds from utilization changes. Profile separation is useful isolation, but the reader does not establish account UUID ownership or obtain exact resets. |
| claude-code-usage-bar HUD [v3.43.5][hud-release] | `b929d30a9f520773d0823bcb738059c9658f7561`, [HUD data layer][hud-source] | Reads the same Desktop history. A drop of at least 15 percentage points anchors a repeating five-hour/seven-day countdown, not a server-provided reset. The wider HUD also reads transcripts for project information, so it cannot be adopted unchanged. |
| Claude Usage Monitor [v2.2.1][monitor-release] | `9c67bc22c563f4b487cb6497237f7c3bac3173e6`, [login][monitor-login] and [API service][monitor-source] | Uses its own WKWebView login, extracts a session cookie, and requests organization usage. CLI-independent, but not a no-secret, existing-Desktop-only path. |
| claude-usage-widget [v0.1.0][widget-release] | `126bfc75b639debc07be218f2db16217bd6aa3bb`, [provider][widget-source] | Uses a user-supplied session cookie and explicit per-account requests. Disables automatic cookie sharing to prevent cross-account contamination. Useful isolation design, but outside the no-secret requirement. |

Utilization drops are especially unsafe reset anchors: Anthropic's [limit reset
documentation][limit-reset] says a user can restore usage while the usual weekly
reset day and time remain unchanged. A drop therefore does not identify the
weekly schedule. A seven-day projection is not a new exact observation.

## Additional Desktop paths

**Targeted accessibility:** Electron [documents][electron-ax] PID-based
accessibility access and an `AXManualAccessibility` toggle. Public
[`claude-auto-resume` source][ax-enumerator], pinned at
`1dcf1553e347a50ed4a882e81694f834b3d790f3`, obtains `AXWindows` without an activation
call in that function, but sets `AXEnhancedUserInterface`. Its [detector][ax-detector]
scans text across the window. Neither behavior is an acceptable unchanged
read-only quota reader. Setters change app state; broad text scans can read chat
content. [AX notifications][apple-ax] may also be unsupported by an element.
Background access does not establish that an unrendered Usage panel exists or
refreshes, or that rounded UI reset text provides an exact timestamp.

**First-party helper/IPC:** No supported external account-plus-quota-plus-refresh
interface was found in the primary documentation examined. [Electron IPC][electron-ipc]
describes communication between an application's renderer and main process, not
a general external query API. [Desktop Extensions][desktop-extensions] package
tools that Claude calls; they do not document exporting Desktop quota or identity.
This is an evidence gap, not proof that no private interface exists.

**Desktop Code statusLine:** The official [statusLine schema][statusline] includes
`rate_limits` percentages and reset epochs after the first API response for
eligible subscriptions. [Desktop documentation][desktop-code] describes shared
configuration and hooks, but does not establish that Desktop Code delivers those
quota fields or an account-bound identity to a statusLine command. This remains
a Code Local test candidate, not a demonstrated Chat/Cowork acquisition path.

## Proposed tests, not executed

Any future test requiring login changes, UI setup, configuration writes, or an
accessibility-state change needs separate authorization. The observer itself must
not manipulate the app. Do not generate model traffic merely to populate quota.

1. **Cache keys and refresh:** Compare all allowlisted usage variants, including
   the plain URL and `?skip_spend=1`; do not keep using one cached winning file.
   Compare source response times and normalized windows during foreground,
   background, minimized, Usage-panel-closed, sleep/wake, and weekly-rollover
   conditions. Reject conflicting equal-time observations. Unchanged values,
   file writes, or a successful read alone must not advance freshness.
2. **Account attribution:** Test different-org and same-org A-to-B changes,
   including delayed A responses arriving after B becomes current. Before/after
   nonsecret identity fingerprints can detect some races, but cannot prove who
   received an org-only response. Require account-bound evidence tied to the
   observation before claiming exact reset ownership. Correlated percentages or
   isolated profile paths are supporting checks, not substitutes.
3. **Targeted AX:** With permission already granted and a user-prepared Usage
   view, first prove that role/identifier traversal can select only quota and
   identity elements without reading conversation values. Then test background
   and minimized availability, update notifications, identity changes, locales,
   timezone handling, and reset precision. If navigation, focus, setters, or
   broad text scanning are required, the strict read-only route fails.
4. **Desktop Code statusLine:** Keep the standalone CLI signed out. In a separately
   approved Code Local test, project only allowlisted quota fields from callback
   input; never retain raw input or follow transcript paths. After ordinary user
   activity, check field presence, reset precision, account attribution, idle
   refresh, and rollover. A callback firing without quota fields is not success;
   Code Local success must not be generalized to Chat or Cowork.

Until ownership and refresh are both demonstrated, retain the current uncertainty
labels and release gates rather than converting competitor heuristics into exact
`P` or reset claims.

## September 30 follow-up

An independent source review examined five additional/current release implementations.
No competitor binary was executed during this round, and no credentials or raw
provider responses were inspected.

| Project | Pinned source | Finding |
| --- | --- | --- |
| CodexBar v0.69.0 | [ClaudeUsageFetcher.swift](https://github.com/steipete/CodexBar/blob/48ded68da6932a4fe5de9037d06c4ac48bd36e90/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift#L576-L589) | OAuth, web-cookie, and CLI routes; not a nonsecret Desktop export. |
| OpenUsage v0.7.12 | [ClaudeDesktopAuthStore.swift](https://github.com/robinebers/openusage/blob/3b84fec518d5b3775adb93456fa8af7330c852d5/Sources/OpenUsage/Providers/Claude/ClaudeDesktopAuthStore.swift#L129-L170) | Reads Desktop credential/cookie stores; cannot be adopted within this product's no-secret boundary. |
| BetterClaude v0.14.1 | [Quota.swift](https://github.com/mandipadk/BetterClaude/blob/141fecb6cb80178ac4a57cd13e15f36bf82a28aa/Sources/CoworkKit/Quota/Quota.swift#L153-L172) | Reads `cachedUsageUtilization.accountUuid` and its source timestamp. Also projects elapsed weekly timing; that projection is not a new exact reset. |
| Claudius v3.0.3 | [DesktopUsageReader.swift](https://github.com/nsluke/Claudius/blob/e89a943c37fdd7162394bd82f36db77f71d05939/Claudius/DesktopUsageReader.swift#L50-L125) | Desktop history percentages, no account binding or exact reset. |
| Mikyas v0.2.0 | [desktop_usage.rs](https://github.com/MarawanEldeib/mikyas/blob/faaa9210ff2284574ea79cee65afc7bb500c5de5/crates/core/src/sources/desktop_usage.rs#L94-L126) | Filters history by organization, but does not supply an account-bound reset. |

The official [OpenTelemetry attributes](https://code.claude.com/docs/en/monitoring-usage#standard-attributes)
include `user.account_uuid`, `organization.id`, and `session.id`. Desktop Code
[documents telemetry export](https://code.claude.com/docs/en/desktop#admin-console-controls),
but the examined telemetry schema does not provide weekly reset/utilization.
Identity from one event cannot retroactively bind an org-only cache response.

The official SDK's [rate-limit event type](https://github.com/anthropics/claude-agent-sdk-python/blob/f2204bb956bab02907aaf3cb88eb9dead28eaa35/src/claude_agent_sdk/types.py#L1390-L1435)
can carry reset/utilization and a session ID, but not an account UUID or source
observation timestamp. Its [standard transport](https://github.com/anthropics/claude-agent-sdk-python/blob/f2204bb956bab02907aaf3cb88eb9dead28eaa35/src/claude_agent_sdk/_internal/transport/subprocess_cli.py#L570-L574)
starts a subprocess; it does not establish a read-only subscription to an existing
Desktop session. Repeated events are also not fresh observations: the official
[changelog](https://github.com/anthropics/claude-agent-sdk-typescript/blob/49ac9709f4e2fe001b160eac839e160f0ba36d59/CHANGELOG.md#L195-L203)
describes repeated 429 notifications for the same window.

The current [status-line contract][statusline] supports periodic callbacks and
callbacks at reset boundaries, but these rerender the supplied data; they are not
evidence of a new server fetch. It omits expired windows and documents no
account-owner field. Enabling a callback alone cannot satisfy the Desktop-only
requirement. The existing retired status-line bridge remains inactive.

A bounded metadata-only local check found recent Desktop utilization alongside
an older structured CLI cache whose weekly and five-hour reset timestamps had
both elapsed. The checked Desktop sample contained neither an account stamp nor
recognized reset fields. The cache's account stamp matched the current account,
but no recognized organization stamp was present. This explains why more frequent
reads can update `W` but cannot produce a new exact `P` from these files.
No local source contents or account identifiers are included here.

Development now checks the cache observation's own `accountUuid` before attaching
current-account ownership. A mismatch is excluded; legacy unstamped cache data
cannot supply a verified Desktop reset. The app also reads eligible local changes
on its minute clock without resolving or launching a CLI, advancing capture time,
or postponing the live-probe schedule. These are integrity and latency improvements,
not a new Desktop-only reset source.

The remaining upstream request is concrete: expose an opt-in, nonsecret local
quota record or subscription containing account and organization identity,
`utilization`, `resets_at`, and the source observation time, updated after ordinary
Desktop activity and rollover. No upstream request was sent in this round.

## Expanded Desktop-only investigation, September 30

This pass examines additional public implementations, including paths outside
the current no-secret policy. Two independent research agents cover provider
implementations and first-party integration surfaces. Source inspection is not
a live test: no competitor was executed, no authentication store was read, and
no app, browser, permission, or sign-in setting was changed.

### New implementation evidence

**OpenUsage: a shipped Desktop-authentication implementation.** Release
v0.7.12, `3b84fec518d5b3775adb93456fa8af7330c852d5`, has a
[Desktop auth reader](https://github.com/robinebers/openusage/blob/3b84fec518d5b3775adb93456fa8af7330c852d5/Sources/OpenUsage/Providers/Claude/ClaudeDesktopAuthStore.swift#L73-L170)
that decrypts Desktop's OAuth cache and obtains active-organization metadata from
its cookie store. It is not dependent on standalone CLI sign-in. A live usage
request supplies resets, not a projected date. Desktop-owned refresh tokens are
not exchanged; this still involves handling protected authentication material.
The same release already includes useful
[profile verification and post-request generation checks](https://github.com/robinebers/openusage/blob/3b84fec518d5b3775adb93456fa8af7330c852d5/Sources/OpenUsage/Providers/Claude/ClaudeProvider.swift#L368-L450).
Profile verification is conditional on expected identity being configured, so
it is not proof of unconditional account binding. These checks were also found
in inspected main `5ef840538266af4cf33e924c60bd5ff3662eda7f`.

**cc-bar: Desktop OAuth rather than the standalone CLI.** The published
[v1.1.1 release](https://github.com/nanvon/cc-bar/releases/tag/v1.1.1) resolves to
`63d0f7eb06b307177bc85be586ed32fe2e5ec997`. Its
[Desktop reader](https://github.com/nanvon/cc-bar/blob/63d0f7eb06b307177bc85be586ed32fe2e5ec997/Core/Credentials/ClaudeDesktopAuth.swift#L68-L161)
discovers an account without CLI credentials and selects an unexpired Desktop
access token with the required scope. Its
[quota client](https://github.com/nanvon/cc-bar/blob/63d0f7eb06b307177bc85be586ed32fe2e5ec997/Core/Quota/ClaudeQuotaClient.swift#L3-L29)
requests usage instead of rereading history. Protected-authentication access is
required; author comments about long token lifetimes are not service guarantees.
Do not copy account selection unchanged: `discoverAccount()` at lines 117-121
falls back from the current account's entries to **all** entries. A valid older
account can be selected when the current account has no usable entry.
QuotaTempo must instead reject missing or conflicting current identity.

**CodexBar is not equivalent to a proven Desktop-only source.** Current main
`001ed11d4d3a475809765145e36f44a756ef52ca` selects
[OAuth, then CLI, then Web for app Auto; Web, then CLI for command-line Auto](https://github.com/steipete/CodexBar/blob/001ed11d4d3a475809765145e36f44a756ef52ca/Sources/CodexBarCore/Providers/Claude/ClaudeSourcePlanner.swift#L174-L205).
The inspected sources do not establish the same Desktop OAuth-cache path as
OpenUsage/cc-bar. Its successful display is not evidence that a Desktop-only
configuration will work. Historical auth reports remain useful failure scenarios:
[CodexBar #1287](https://github.com/steipete/CodexBar/issues/1287),
[OpenUsage #1200](https://github.com/robinebers/openusage/issues/1200), and
[cc-bar #8](https://github.com/nanvon/cc-bar/issues/8) are all closed at inspection;
they are neither proof of a current defect nor proof of long-term reliability.
CodexBar's linked [PR #1539](https://github.com/steipete/CodexBar/pull/1539)
explicitly covers cookie-cache isolation tests, not the entire auth lifecycle.

**VibeMenu: another passive-cache implementation, not a new refresh mechanism.**
Inspected master `5b1588f6d6a923519d886d8e0d015e2373593356`; its published v1.0 tag
is a different commit. The
[reader](https://github.com/Kirill-Chistov/VibeMenu/blob/5b1588f6d6a923519d886d8e0d015e2373593356/Sources/VibeMenuCore/ClaudeDesktopUsageCacheReader.swift#L330-L389)
decodes compressed Desktop responses and chooses the newest decodable snapshot.
Its [design record](https://github.com/Kirill-Chistov/VibeMenu/blob/5b1588f6d6a923519d886d8e0d015e2373593356/docs/decisions/0016-claude-usage-limits.md)
describes population through Desktop's Usage view, not independent refresh.
The parser permits an mtime fallback and does not bind the snapshot to the active
account. Those are not substitutes for QuotaTempo's source-time and ownership
checks. Draft PR #42 already has zstd decoding and both window/limits payload
shapes; another decoder is not the missing root fix.

**CCDEX: fresh requests inside Desktop, but by modifying the app.** At
`0058664bd3dbed5e5900b24b71401e963cfbd686`, its
[renderer code](https://github.com/Saqoosha/CCDEX/blob/0058664bd3dbed5e5900b24b71401e963cfbd686/context-indicator.js#L19-L58)
fetches usage with the existing renderer session and reads returned resets.
It [schedules periodic requests](https://github.com/Saqoosha/CCDEX/blob/0058664bd3dbed5e5900b24b71401e963cfbd686/context-indicator.js#L425-L438).
This is not a public Desktop API: the
[patcher](https://github.com/Saqoosha/CCDEX/blob/0058664bd3dbed5e5900b24b71401e963cfbd686/patch.py#L193-L235)
disables ASAR integrity, changes the app archive, and applies an ad-hoc signature.
No GitHub release asset was present at inspection. Do not adopt this installation
path: it weakens tamper protection, depends on private preload/IPC details, and
requires patch maintenance after Claude updates.

Electron's [ASAR integrity documentation](https://www.electronjs.org/docs/latest/tutorial/asar-integrity)
confirms that this is a code-integrity security feature. Its
[extension documentation](https://www.electronjs.org/docs/latest/api/extensions)
requires the host app to load an extension into its own session. Installing an
ordinary Chrome extension does not install the bridge into Claude Desktop.
The ASAR page was also extracted with Public Source Extractor and checked against
the original; its generated summary was not treated as authority.

**UI automation is interactive, not passive telemetry.** The Windows project
`claude-desktop-auto-resume`, at `895c21740f012b5179c8a2e1d9a0d339fc177d4c`,
[focuses the window, clicks the meter, reads its panel, and sends Escape](https://github.com/MichalCholajczyk/claude-desktop-auto-resume/blob/895c21740f012b5179c8a2e1d9a0d339fc177d4c/claude_auto_continue.py#L806-L849).
This does not prove noninterfering macOS acquisition or timestamp precision.
Targeted accessibility remains a user-prepared experiment, not a fallback that
silently changes the active window.

### First-party structured usage lead

The published official [Agent SDK v0.3.277 type definition](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.277/sdk.d.ts)
contains an experimental structured `get_usage` control request, exposed as
`usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`. It can return
weekly utilization and ISO reset timestamps without parsing terminal text.
Crucially, `skipBehaviors: true` is required for a quota-only experiment: the
default behavior scans local transcripts. Do not invoke the default method.
The response may omit plan limits for non-subscription authentication or missing
scope, and its type does not prove current fetch time or account ownership.
This is a promising PTY-replacement research path, but does not establish a
supported attachment to Desktop's existing authenticated session.

The same-version [published JavaScript](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.277/sdk.mjs)
confirms that the method sends `get_usage` with `skip_behaviors: true` when
requested. Its standard transport owns a newly spawned CLI, not Desktop's
existing child. Inspecting package text does not execute it. The GitHub v0.3.277
tag is `ba8f408d24e20b0662e5833c86051316114a0972`; this does not prove npm build
identity. The [tagged changelog](https://github.com/anthropics/claude-agent-sdk-typescript/blob/ba8f408d24e20b0662e5833c86051316114a0972/CHANGELOG.md#L3-L11)
describes live-only rows for `SDKUsageReport`, which is a different result type;
do not apply that guarantee to `SDKControlGetUsageResponse`.

The SDK's [bridge types](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.277/bridge.d.ts)
also do not supply a read-only Desktop attachment: worker authentication involves
a JWT and can change the worker epoch. Do not attach to a user's existing session
or intercept its control stdin. A later PTY-alternative experiment must own its
child process, send no user/model prompt, disable behavior scanning, allowlist
quota output, and close within 30 seconds. It still needs its own valid
subscription authentication; it is not a Desktop-only workaround.

### Bounded no-secret Code Local experiment

The [statusLine contract][statusline] provides rate-limit fields, but is not proof
that Desktop Code Local invokes this callback. Conversely, headless startup alone
is not sufficient evidence that all current/future Desktop versions cannot do so.
Community claims about seeing limits inside Desktop and writing a statusLine
file are not interchangeable evidence.

After explicit configuration approval, use one test project only; do not overwrite
an existing statusLine or change global settings. Wait for ordinary user activity,
not a test prompt, `/usage` request, new login, or session restart. For at most
45 minutes/two ordinary responses, project only callback time, version, invocation
count, utilization, and reset timestamps. Never retain raw stdin, transcript paths,
account data, or message content. Attribute the callback through process executable
and parent metadata, without reading process arguments or environment values.
Remove only the configuration and files added by this experiment.

Distinguish `callbackNotObserved`, `weeklyFieldAbsent`, `expiredReset`,
`currentWeeklyReceived`, and `originUnknown`. A current reset is only an initial
capability result: same-account evidence and a new reset after natural rollover
remain required. This experiment covers Code Local, not Chat, Cowork, Cloud, or
SSH. It has not been executed.

### Approval is separate from feasibility

Reading Desktop authentication inside a future product is a different capability
from reading nonsecret quota files. It requires an explicit product decision and
user opt-in; the agent must still never receive, display, or save secret values.
The current privacy contract has not changed.

The [first-party authentication policy](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)
restricts third-party credential/session-token intermediation and directs
authentication-use questions to Anthropic. Competitor source does not establish
approval for a quota-only reader. Confirm that use case before shipping; this
report does not make a legal determination. API-key billing usage does not replace
a subscription's weekly allowance.
The [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview#get-started)
also explicitly requires prior approval for third-party products offering
claude.ai login or rate limits. Treat this as an adoption gate, not as evidence
that the code cannot technically fetch data.

Electron's [safeStorage documentation](https://www.electronjs.org/docs/latest/api/safe-storage#platform-specific-key-providers)
explains the macOS cross-application Keychain boundary and importance of consistent
code signing. Never bypass denial with another helper or repeatedly prompt from
a timer. A one-time working token is not an authentication-lifecycle solution.

### Candidate decision and acceptance criteria

The strongest active-request candidate to evaluate is **explicitly authorized,
read-only Desktop authentication**, leaving renewal to the official client.
It remains a release-gated candidate, not shipped functionality. The isolated
implementation checkpoints below distinguish code from live verification. In parallel, a
bounded Desktop Code Local statusLine experiment can test a no-secret path; it
does not cover Chat/Cowork. Passive cache improvements remain useful but cannot
alone guarantee a fresh observation. App patching, integrity disablement, debug
ports, automatic UI navigation, and renewing another client's authentication are
excluded from this proposal.

The original protected-store experiment gate required provider-permission and
product-consent decisions. The explicit local-experiment decision recorded below
supersedes the provider-permission prerequisite for that local diagnostic only,
not public distribution. The prototype must enforce:

1. **No CLI/browser dependency:** test Desktop Chat-only, Code Local, and Cowork
   separately, without a standalone CLI credential or browser bridge.
2. **Current identity only:** bind each request to its account and organization;
   reject ambiguous identity and delayed old-account responses. Do not select a
   convenient older account or infer ownership from matching percentages.
3. **Read-only lifecycle:** no refresh-token exchange or writes to Claude stores;
   no secrets or raw responses in logs. Report only eligibility, expiry state,
   request outcome, and normalized quota. Honor permission denial.
4. **Actual rollover:** receive a new server reset and fresh utilization after
   the prior reset expires. Never add seven days. Test early limit resets apart
   from the scheduled weekly reset.
5. **Recovery:** test background use, idle, sleep/wake, network loss, 401/403,
   429/Retry-After, Desktop's own credential renewal, account switching, and app
   updates. Use bounded backoff; never switch accounts to evade limits.
6. **Independent evidence:** a single fetch and synthetic tests are insufficient.
   Record source/time/ownership outcomes without identifiers or raw payloads,
   compare the official Usage display, and verify on a second Mac.

No route becomes release-ready through this report. Identity selection,
freshness, expiry, and failure handling can first be prepared with synthetic
fixtures, without protected-store access. Live Desktop-only acquisition and a
fresh weekly rollover remain separate release gates.

### First offline candidate checkpoint, September 30

At commit `ec0f7f5`, `Sources/QuotaTempoDesktopCandidate` contained the first **offline-only**
implementation of the Desktop candidate. It is a separate SwiftPM target with
no executable or library product and no application dependency. It cannot obtain
real usage: there is no credential reader, Keychain access, cookie reader,
network transport, timer, configuration change, or installed-app integration.
The current privacy contract and the permission gates above remain unchanged.

The pure decoder accepts bounded usage JSON and emits only normalized weekly
and optional five-hour windows. It rejects missing weekly resets, invalid values,
invalid calendar dates, expired resets, oversized input, and unexpected types.
It neither extrapolates reset dates nor combines observations across sources.

The coordinator prepares request admission and response acceptance separately:

| Boundary | Candidate behavior |
| --- | --- |
| Consent | No request permit before opt-in; denial cancels work and clears values. No permission prompt exists in this module. |
| Identity | Account and organization fingerprints are both required. An independently verified server profile must match the current request context. No fallback to another cached account. |
| In-flight ownership | A request records an opaque context generation. Changes revoke pending work; duplicate or late replies cannot overwrite newer work. |
| Credential lifecycle | Expiry and missing scope stop admission. A 401/403 waits for a different Desktop-managed generation rather than refreshing credentials. |
| Freshness | Success requires a recent server Date, no positive cache age, valid current resets, and receipt before the 30-second deadline. Source time is not advanced by rereads or failures. |
| Rollover | An elapsed reset is no longer displayable. Only a newly received valid reset restores the plan; no seven-day arithmetic exists. |
| Recovery | Attempts are at least 60 seconds apart. Transient errors back off to 15 minutes. Retry-After is a minimum and survives account/permission changes, including a cancelled request's late 429. Successful polling waits five minutes, or the upcoming weekly reset if earlier, without shortening a service backoff. |

That first checkpoint did not implement identity or transport. An authorized reader
must generate a new opaque revision on sign-out, account/organization switching
(including A-to-B-to-A), or credential replacement, **without exposing credentials
or credential hashes**. A revision must remain stable between actual changes;
generating a UUID on every poll would bypass authentication rejection. The future
transport must bind profile and usage requests
to that exact credential lease, reread the current context after both requests,
disable redirects and response caching, bound response bytes while receiving them,
and cancel overdue I/O. Caller-supplied metadata in synthetic tests does not prove
any of those live properties. Server clock skew and provider response headers
also require runtime verification; strict rejection is not an availability claim.

The dependency guard `scripts/test-desktop-candidate-isolation.mjs` checks the
manifest and rejects direct or transitive inclusion in any shipped product.
CI runs it alongside the candidate's synthetic tests. Do not remove this guard
or add a production caller merely because those tests pass.

Validation commands (use an already available, licensed Swift toolchain):

```bash
swift test --filter DesktopUsage
node scripts/test-desktop-candidate-isolation.mjs
xcrun swift-format lint --strict --recursive Sources Tests
```

The next integration gate at that checkpoint was to decide provider permission
and explicit product opt-in, implement the isolated boundary, and verify actual
Desktop-only acquisition. Runtime UI, natural rollover, Desktop credential
renewal, and a second Mac remain unverified. No public release or installed
preview replacement is part of this offline implementation.

### Protected boundary implementation checkpoint, September 30

The product owner explicitly approved internal Desktop-authentication handling
for an **isolated prototype**, with no secret values exposed to the agent or
logs, no credential persistence, and no changes to Claude's stores. This is
product consent only. The provider-permission decision remains unresolved; no
protected-store experiment or authenticated live request has been executed.
Both decisions are checked before the service admits a read. The default is off.

The candidate now has the following implementation, still excluded from every
shipped SwiftPM product:

- A prompt-free native Keychain boundary and bounded Electron safeStorage
  decryption. A refusal is latched until explicit approval changes. There is no
  shell credential command, interactive fallback, refresh-token model, renewal
  request, or write to Claude's stores.
- A strict current-account/current-organization selector. Only account-scoped
  cache entries for the exact API audience and profile scope are eligible.
  An ambiguous candidate is rejected, and a present invalid/deleted V2 cache
  cannot revive V1. A production-client/full-scope entry outranks old
  profile-only leftovers. The initial checkpoint rejected multiple eligible
  credentials; the October 1 correction below adds same-owner ranking while
  retaining rejection of equal-ranked conflicts.
- A lease whose descriptions and reflection are redacted. Its header setter
  accepts only fixed HTTPS GET profile/usage URLs. Credentials exist in process
  memory only; memory erasure of all Foundation/URLSession copies is **not**
  guaranteed. No plaintext file or raw response log is created.
- Fixed-origin profile-then-usage transport with the same lease. Redirects,
  cookies, persistent caches, and saved HTTP credentials are disabled. Response
  bodies are streamed with a 16-KiB limit per endpoint; error bodies are not
  retained. Profile ownership, server time, cache age, total deadline,
  cancellation, and Retry-After are checked.
- A service that connects the reader, transport, and coordinator. It rechecks
  the source lease after the requests, suppresses duplicate refreshes, cancels
  on consent withdrawal, and retains a cancelled 429's minimum wait. Source
  metadata changes invalidate in-flight values; an unchanged credential does
  not gain a new generation merely because of a temporary read failure.

The format references are pinned [OpenUsage cache selection][desktop-cache-selection],
[OpenUsage profile/usage transport][desktop-usage-client], and the cc-bar reader
linked above. Their existence establishes technical precedent, not permission
or successful runtime compatibility for this prototype.

**Known integration limits:** no application UI, timer, durable backoff,
cross-process lifecycle watcher, or executable entry point has been added.
Observed account transitions are tested; a sign-out or A-to-B-to-A transition
entirely between samples is not proven observable. Explicit owner approval does
not remove provider, natural-rollover, second-Mac, or lifecycle release gates.
Do not describe this checkpoint as Desktop-only support in public copy.

The provider inquiry is [prepared separately](desktop-provider-permission-inquiry.md),
**not sent**. No provider response or permission is implied by this implementation.

#### Current-organization reads during Desktop writes

An immutable SQLite connection can miss newer committed pages in a WAL file.
It is therefore not sufficient to open every Cookies database with
`immutable=1`. The candidate uses SQLite's native read-only `unix-none` VFS with
connection-local `locking_mode=EXCLUSIVE` when a WAL exists. This creates a
private heap WAL index instead of opening or changing the source SHM. Without
a WAL it uses immutable reads, avoiding sidecar creation. No hand-written WAL
parser or copy of the source database is used.

Synthetic probes covered an active writer, a WAL without SHM, checkpointed and
empty WALs, and normal WAL reads. The selected values included the latest WAL
commit; file contents, metadata, and directory entries were unchanged after the
reader closed. The writer could still commit during the probe. These results
apply to the tested system SQLite, not every macOS release.

The reader rejects nonempty rollback journals, orphan sidecars, unsafe paths, and source
changes observed across the query. The query is limited to the current
organization cookie, validates its host, path, UUID, and lifetime, and rejects
conflicting organizations. It does not load session cookies for HTTP requests.
Before/after metadata checks are not an atomic snapshot and do not guarantee
protection against a hostile same-user process swapping and restoring paths.
An unchanged zero-byte journal is allowed: SQLite TRUNCATE mode leaves that
file after a committed transaction. Its presence and complete stamp still
participate in the before/after checks; it is never deleted or recovered.
The initial implementation rejected this normal state and was corrected after
the owner-run diagnostic. See the October 1 live result below.

References: [SQLite WAL without shared memory](https://www.sqlite.org/wal.html#use_of_wal_without_shared_memory)
and [SQLite URI parameters](https://www.sqlite.org/uri.html). The empty-journal
behavior is documented in [SQLite locking and hot journals](https://www.sqlite.org/lockingv3.html)
and [PRAGMA journal_mode](https://www.sqlite.org/pragma.html#pragma_journal_mode).

#### Independent review corrections

The review identified three additional defects in the isolated implementation:

- `LAContext.interactionNotAllowed` alone did not cover legacy Keychain ACL
  prompts. A serialized synchronous guard now suppresses legacy interaction and
  restores the previous setting on success or failure. The legacy Security APIs
  are deprecated; their process-global setting needs coordination or a dedicated
  helper before application integration. No real Keychain query was tested.
- A 401/403 could be forgotten when the post-request source check failed. The
  coordinator now retains the refusal for the issued credential generation, and
  a temporary malformed store cannot make an unchanged credential look renewed.
- Caller cancellation did not propagate through every awaited service stage.
  The child task now covers the protected read, HTTP request, and post-read;
  late success cannot become an observation. A late 429 still preserves its
  minimum retry delay.
- A completed child result could escape after consent changed but before the
  outer actor resumed. The final return now rechecks the approval revision with
  no further suspension. Independent review confirmed the correction. That
  exact scheduler interleaving has no deterministic fixture; the existing
  cancellation/revocation fixtures cover each injectable awaited stage.

All regression fixtures use invented credentials and isolated temporary stores.
They do not establish permission, live authentication success, natural weekly
rollover, or second-Mac support.

#### Protected-boundary QA result

| Check | Result |
| --- | --- |
| Full Swift suite after final review correction | PASS, 472 tests / 17 suites |
| Independent code review | Findings corrected; final read-only re-review found no additional required change |
| Browser extension fixtures | PASS, 216 tests |
| Browser installer fixtures | PASS, 81 tests; synthetic HOME |
| Native-host integration fixtures | PASS, 7 tests; synthetic inputs |
| Strict Swift format and diff whitespace | PASS |
| Product-dependency isolation | PASS, including four intentional leak fixtures |
| Release/distribution policy | PASS |
| Bundle build/verification | PASS; launch/window/provider-trigger checks skipped; installed app unchanged |
| Protected-store access and authenticated provider request | NOT RUN |
| Real account renewal, natural weekly rollover, second Mac | NOT RUN |

The same per-command Command Line Tools setup documented below was used. No
Xcode agreement was accepted and no global toolchain setting was changed.
The legacy Keychain interaction APIs emit deprecation warnings on a fresh build;
this is documented integration debt, not a claim that they are a long-term API.
The reader, transport, and orchestration have no production caller, timer, or
executable. Passing these tests cannot change the installed application's display.

[desktop-cache-selection]: https://github.com/robinebers/openusage/blob/3b84fec518d5b3775adb93456fa8af7330c852d5/Sources/OpenUsage/Providers/Claude/ClaudeDesktopAuthStore%2BTokenCache.swift
[desktop-usage-client]: https://github.com/robinebers/openusage/blob/3b84fec518d5b3775adb93456fa8af7330c852d5/Sources/OpenUsage/Providers/Claude/ClaudeUsageClient.swift

### Explicit local Desktop experiment, September 30

The isolated diagnostic now supports explicitly authorized local testing of the
Desktop-authentication path. `localExperimentAuthorized` is separate from
`providerApproved`; local consent never asserts provider permission.
The candidate remains outside every shipped product and is still off by default.
Public distribution, natural rollover and second-Mac acceptance remain unverified.

A manually linked, locally signed diagnostic performs one bounded acquisition,
with no browser/CLI fallback, credential renewal, provider-store writes or raw
response output. Its two explicit consent arguments are required before protected
reads; the output allowlist contains only state, typed failure codes and normalized
quota values/timestamps. Normal builds and tests do not execute the live probe.

The first signed noninteractive run stopped at `permissionRequired`, with no
accepted observation or provider request. A separate metadata-only check found
the default Keychain unlocked; this is not a CLI/browser login failure. No denial
was bypassed and no automatic retry or system dialog was initiated.

The same diagnostic also offers a separate `--request-keychain-access` option for
the owner to launch manually. This permits the ordinary macOS access dialog for
the same signed helper and retains only the derived key in memory for that one
run. It does not change Keychain ACLs directly or request a Claude login. Rejection
stops the run; polling cannot invoke this mode. At this checkpoint, interactive
acceptance and actual Desktop-only usage were still pending. The subsequent
owner-run and prompt-free follow-up are recorded below.

Build locally (no protected reads or provider requests):

```bash
node scripts/build-desktop-candidate-local-probe.mjs
node scripts/test-desktop-local-probe.mjs
```

The builder uses SwiftPM's current output-file maps, not object-file globs, to
exclude artifacts left by older branches. The initial glob-based link failed
because it included obsolete cache-reader objects; no live execution occurred.
Signing is an explicit separate step. Retain the same path, signing certificate
and designated identifier across diagnostic corrections. After a rebuild,
verify the signature and check access noninteractively; never assume a previous
permission still applies or automatically invoke the interactive fallback.

The owner can manually run `scripts/desktop-local-test.command` after the exact
helper is signed and verified. The wrapper does not build, sign, change security
settings, restart an application, or write results. It verifies the signature and
invokes the explicit interactive diagnostic. This is not a production installer.

Independent lifecycle review also identified a duplicate-refresh result that
could clear a future caller's display. The service now returns an explicit
`unchangedInFlight` disposition; callers must preserve display state while the
original acquisition completes. Success, HTTP failure, credential-load failure,
retained observations and consent withdrawal have regression coverage.

At this checkpoint, two integration findings remained open: temporary Keychain
lock conditions must be distinguished from access denial without retrying a
denied ACL, and a wall-clock rollback could keep the coordinator blocked until
the earlier maximum time was reached. The rollback correction is recorded below;
temporary Keychain-lock recovery and real credential renewal remain release gates.

Validation: 483 Swift tests / 17 suites passed; strict format, release and
distribution policy, product-dependency isolation, and eight inert diagnostic
argument cases passed. Independent read-only review found no additional required
change in the diagnostic. No interactive access request was run by the agent.

### Owner-run diagnostic correction and first Desktop-only success, October 1

The owner-run helper returned `identityUnavailable` / `unavailable` after native
Keychain access. A metadata-only check identified a zero-byte rollback journal.
The reader rejected any journal, including SQLite's normal committed TRUNCATE
state. Synthetic SQLite fixtures reproduced the failure before the fix. Both
database locations now accept unchanged empty journals, while nonempty/orphan
journals, unsafe paths and concurrent mutations still fail closed. No provider
file was changed, removed, copied or recovered.

The next prompt-free run reached `selection` / `ambiguousIdentity`: organization
selection had succeeded, but multiple unexpired cache entries matched the same
account, organization, audience and required scope. The selector now ranks those
already-admitted entries by production-client/full-scope login, full scope, scope
count and finally expiry, following the pinned [OpenUsage reference][desktop-cache-selection].
Equal-ranked conflicting values are still rejected. Foreign-account and
foreign-organization entries never enter ranking, a V2 deletion cannot revive
V1, and a server-side profile match is still required before requesting usage.
There is no retry through lower-ranked credentials after an authentication refusal.

The helper now emits only fixed credential-stage and transport-stage enums in
addition to its existing normalized output. It never emits cache keys, account
identifiers, credential hashes, response bodies or headers. One network run
before these stages were added returned `invalidResponse`; its specific rejection
reason was not captured and must not be described as diagnosed or resolved.

At **2026-09-30 21:46:32 UTC (October 1 06:46:32 JST)**, the same signed helper
completed a prompt-free **Desktop-only** acquisition:

- The server profile matched the selected local account and organization.
- Valid weekly and five-hour remaining percentages, each with a future reset,
  were accepted. Account usage values are omitted from this public record.
- Accepted observation: `current`; weekly reset was **not estimated**.
- No browser/CLI fallback, extra login, secret output, provider-store write or
  credential renewal was used. Provider permission is still not claimed.

At **2026-09-30 21:51:52 UTC**, a second prompt-free invocation, after the
reported five-minute minimum, also returned `current`. Its server observation
time advanced, the five-hour balance changed, and the exact weekly reset was
confirmed again. Both invocations used only Desktop authentication. These are
two separately launched diagnostics, not an installed automatic-polling test.

This proves repeatable live Desktop-only acquisition on this Mac, not automatic product support.
The installed app and preview have not been replaced. The candidate remains
outside shipped products. Natural weekly rollover, sustained background refresh,
credential renewal, second-Mac acceptance and release gates remain open.

Validation after the corrections: **491 Swift tests / 17 suites passed**, including
the real-SQLite synthetic journal regressions, same-owner ranking and fixed-stage
diagnostics. Strict formatting, whitespace, distribution/release policies,
product isolation and eight inert helper argument cases passed. Independent
source-only review found no required correction; the reviewer did not run the
live probe. Existing legacy-Keychain API deprecation warnings remain.

### Isolated automatic Desktop preview, October 1

The same manually linked helper now has an explicitly authorized
`--menu-bar-preview` mode. It is not part of a SwiftPM product, app bundle,
installer or updater feed. It does not replace the installed QuotaTempo app.
The preview adds a separately labelled `QT Desktop` menu-bar item and displays
only Claude's Desktop-connected observation. It never falls back to a browser
or CLI. **The first custom-popover build was withdrawn after a user-reported
interaction failure; the helper is stopped.** The replacement uses a compact
native `NSMenu`, not the released app's SwiftUI view. See the incident below.

A single long-lived service handles startup, a 30-second context/acquisition tick,
wake and manual refresh. Opening the native menu does not trigger acquisition.
Network requests retain the coordinator's
five-minute interval, authentication-generation refusals and service backoff.
An independent one-second display clock expires values even while acquisition is
waiting. Display ticks never count as successful observations or invoke transport.
No login item is installed. Quitting cancels the loop and withdraws local consent.
A process-lifetime empty lock prevents duplicate preview instances. Display values
and identity bindings are not persisted by this preview.

The presentation mapper preserves the actual capture time, clears invalid,
context-changed, expired-reset or 15-minute-old observations, and never adds
seven days to a reset. It emits a dedicated `claudeDesktopDirect` source without
identity fingerprints. Desktop failures use Desktop-specific English/Japanese
copy, not instructions to log into Claude Code. A duplicate in-flight disposition
cannot erase a valid display. The mapper does not invent `lastAttemptAt` from a
display tick or a backoff deadline.

Clock rollback now discards observations and active requests, rebases only the
remaining local wait to a conservative 60-900 seconds, and can recover without
waiting for the old maximum wall clock. Provider Retry-After deadlines are never
shortened. Permission toggles no longer clear a 401/403 credential-generation
refusal. These are synthetic lifecycle fixes, not evidence of a real renewal.

Independent review corrected three preview defects: cleanup waiting indefinitely
for a reader, display time freezing during acquisition, and manual refresh being
eligible for an automatic-update QA result. The QA deadline is now independent
of actor cleanup, exit cleanup has its own hard deadline, and bounded QA disables
menu/manual/wake refresh. Another integration finding showed that reader consent
changes regenerated an unchanged credential's identity. A private in-memory,
redacted digest/revision now preserves the refusal while releasing the usable
lease; tests cover both 401/403 and actual synthetic renewal. No digest is emitted
or persisted. Independent follow-up source reviews found no remaining blocker
within these changes.

Local commands, after building and explicitly signing the same helper:

```bash
# Held pending supervised UI acceptance; do not relaunch automatically.
# Starts only the local preview; never requests an interactive Keychain prompt.
scripts/desktop-local-preview.command

# Bounded live acceptance: two distinct captures at least five minutes apart,
# with W/P/difference available, or exit with failure after 400 seconds.
dist/desktop-local-probe/QuotaTempoDesktopLocalProbe \
  --consent-desktop-read-only --acknowledge-provider-permission-unconfirmed \
  --menu-bar-preview-qa
```

The local wrapper verifies the designated signing identity. It does not build,
sign, log in, alter provider files or use the interactive diagnostic as a fallback.
The bounded live check does not open the menu or activate another application.
Its success is not evidence of a user-click menu test, sleep/wake acceptance,
natural weekly rollover, real credential renewal, or second-Mac acceptance.
Those checks, restart-safe backoff/refusal handling, temporary Keychain-lock
classification and public-release gates remain open.

Historical acquisition validation before the interaction incident:

- Final signed preview: **automatic update PASS**, with distinct server captures
  at **2026-09-30 22:18:10 UTC** and **22:23:18 UTC**, 308 seconds apart.
  Both profile verification and usage acceptance succeeded; W/P/difference were
  available through the Desktop-only normalized presentation. There was no menu,
  manual or wake refresh, browser/CLI fallback, extra login, credential renewal,
  interactive access prompt or provider-store write. Bounded QA exited normally.
- Full Swift suite: **531 tests / 20 suites PASS**, repeated with outbound network
  denied. The first network-denied driver run failed during nested SwiftPM
  manifest sandbox setup, before tests. Disabling only the nested SwiftPM sandbox
  while retaining the outer network denial allowed all tests to run and pass.
- Strict formatting, whitespace, strings parsing, release/distribution policies,
  product-dependency isolation and **16 inert helper argument cases PASS**.
- Four synthetic offscreen views (English/Japanese, current/unavailable) rendered
  and visually inspected. The unavailable copy does not direct users to CLI login.
  These images did not test the live AppKit host, placement or action delivery.
  The obsolete `--render-preview-fixtures` helper path has now been removed.
- The signed local wrapper rejects a second preview instance before constructing
  the acquisition service. Signature verification passed.
- Earlier compile-order/fixture-owner errors and one formatting finding were
  corrected before the final suite. Legacy Keychain deprecation warnings and a
  test-only weak-binding style warning remain; there were no test failures.

#### Preview interaction incident, October 1

The owner reported that clicking `QT Desktop` opened an oversized popover that
extended above the display and could not be dismissed. The exact local helper
process was identified by its executable path and terminated with SIGTERM.
The released `/Applications/QuotaTempo.app` was not stopped or replaced.

The prior automatic acquisition check disabled the click action, and the
offscreen renderer used no-op Refresh/Quit callbacks. Neither established real
interaction readiness. The custom `NSPopover`/`NSHostingController` host differed
from the released app's SwiftUI `MenuBarExtra(.window)` host. The exact AppKit
failure has not been reproduced; it must not be reported as a proven sizing-only
or focus-only root cause.

The mitigation removes that custom host entirely from the local preview:

- Native `NSMenu` only, twelve fixed rows including three commands, no custom
  views, hosted SwiftUI controls, submenus or explicit window positioning.
- Refresh, Close Menu and Quit Desktop Preview have explicit targets/selectors;
  Close and Quit remain enabled during acquisition. Actions cancel menu tracking
  before callbacks. The existing independent cleanup deadline remains in place.
- The AppKit event loop now starts from synchronous `main`, outside an existing
  async MainActor task. Only the headless one-shot path uses an async task.
- Six synthetic menu tests verify structure, action order, value replacement,
  stable item identities, failure/busy states and enabled dismissal commands.
  Tests dispatch selectors directly without opening a menu, starting AppKit,
  constructing a real acquisition service or reading protected data.

The helper remains stopped and has not been relaunched after this change.
Actual click, Escape, outside-click, screen-edge positioning and Quit acceptance
are **pending**, as is post-change live acquisition acceptance. Do not describe
the preview as interaction-tested, restart it automatically, or promote it to a
public release on the strength of headless tests. The next UI gate is one
supervised open/close/Quit check, followed by the separate acquisition gates.

Post-change validation:

| Check | Result |
| --- | --- |
| Full Swift suite | PASS, 537 tests / 21 suites; repeated with network denied |
| Native menu structural/action tests | PASS, 6 tests; no displayed menu or OS input |
| Local helper build and designated signature | PASS; not launched in authorized acquisition/preview mode |
| Inert argument validation | PASS, 17 cases, including retired renderer rejection |
| Strict formatting, whitespace, release/distribution policies | PASS |
| Product dependency isolation | PASS, actual graph and four leak fixtures |
| Independent read-only follow-up review | No new actionable hang or permission-expansion finding |
| Live menu positioning, Escape, outside-click, Quit and post-change acquisition | NOT RUN; preview remains stopped |

One isolation-check invocation initially selected an unlicensed Xcode and failed
before inspecting the package. Repeating it with the existing Command Line Tools
passed; no license or global toolchain configuration was changed. Existing legacy
Keychain deprecation warnings remain. The helper's process-level cleanup deadline
and async one-shot exits were source-reviewed, not dynamically exercised by the
six native-menu tests. No public release, installed-app replacement, provider
request, credential renewal or interactive permission request occurred during
this incident fix.

#### First offline checkpoint QA result

The independent code review found and corrected race/freshness defects before
closeout: a 429 concurrent with account switching or clock rollback lost its
service delay; an optional five-hour reset expiring in transit discarded a valid
weekly observation; display expiry left the state current; and a temporary
missing identity obscured a still-unresolved authentication refusal. Regression
tests cover each case, including cancelled replies and actual A-to-B-to-A input
transitions. These are synthetic implementation findings, not claimed causes of
the installed product's acquisition failure.

| Check | Result |
| --- | --- |
| Full Swift suite | PASS, 362 tests / 12 suites; 61 new candidate tests |
| Browser extension fixtures | PASS, 216 tests |
| Browser installer fixtures | PASS, 81 tests; isolated synthetic HOME |
| Native-host integration fixtures | PASS, 7 tests; no real browser/profile |
| Strict Swift format | PASS |
| Product-dependency isolation | PASS, current manifest and four intentional leak fixtures |
| Release/distribution policy | PASS |
| Bundle build/verification | PASS; launch/window/provider-trigger checks skipped; temporary artifacts removed |
| Live Desktop authentication/usage | NOT RUN; permission and product gates remain open |

The selected Xcode could not run because its license had not been accepted.
No agreement or global toolchain setting was changed. Validation used the
already installed Command Line Tools (Swift 6.3.2). Its Testing framework needed
explicit search/runtime paths; this per-command setup passed the full suite:

```bash
env DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

No framework-path workaround is committed to the package or CI. One local
manifest-check attempt timed out while SwiftPM was holding its build lock;
running it after the build completed passed. The coordinator is in-memory only;
production integration would also need a durable nonsecret service-backoff
deadline so restarting the app cannot evade a rate limit.

[codenotch-release]: https://github.com/vinzdg/codenotch/releases/tag/v1.19.0
[codenotch-source]: https://github.com/vinzdg/codenotch/blob/00833690311067354c77951fcaaf6ffca774916e/Sources/Providers/ClaudeDesktopUsageCache.swift
[codenotch-caller]: https://github.com/vinzdg/codenotch/blob/00833690311067354c77951fcaaf6ffca774916e/Sources/Providers/ClaudeOAuthProvider.swift
[switcher-release]: https://github.com/kevinchau/claude-switcher/releases/tag/v0.6.0
[switcher-source]: https://github.com/kevinchau/claude-switcher/blob/ff8351eef28fade30b80f8b673b0686c0b41fb90/Sources/ClaudeSwitcherCore/UsageHistory.swift
[hud-release]: https://github.com/leeguooooo/claude-code-usage-bar/releases/tag/v3.43.5
[hud-source]: https://github.com/leeguooooo/claude-code-usage-bar/blob/b929d30a9f520773d0823bcb738059c9658f7561/src/claude_statusbar/hud_data.py
[monitor-release]: https://github.com/theDanButuc/Claude-Usage-Monitor/releases/tag/v2.2.1
[monitor-login]: https://github.com/theDanButuc/Claude-Usage-Monitor/blob/9c67bc22c563f4b487cb6497237f7c3bac3173e6/ClaudeUsageMonitor/LoginWindowController.swift
[monitor-source]: https://github.com/theDanButuc/Claude-Usage-Monitor/blob/9c67bc22c563f4b487cb6497237f7c3bac3173e6/ClaudeUsageMonitor/Services/ClaudeAPIService.swift
[widget-release]: https://github.com/thinshaw/claude-usage-widget/releases/tag/v0.1.0
[widget-source]: https://github.com/thinshaw/claude-usage-widget/blob/126bfc75b639debc07be218f2db16217bd6aa3bb/Sources/ClaudeAIUsageProvider.swift
[limit-reset]: https://support.claude.com/en/articles/17007452-what-is-a-limit-reset
[electron-ax]: https://www.electronjs.org/docs/latest/tutorial/accessibility
[ax-enumerator]: https://github.com/milika/claude-auto-resume/blob/1dcf1553e347a50ed4a882e81694f834b3d790f3/Sources/ClaudeAutoResumeAX/AXWindowEnumerator.swift
[ax-detector]: https://github.com/milika/claude-auto-resume/blob/1dcf1553e347a50ed4a882e81694f834b3d790f3/Sources/ClaudeAutoResumeAX/RateLimitDetector.swift
[apple-ax]: https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification?language=objc
[electron-ipc]: https://www.electronjs.org/docs/latest/tutorial/ipc
[desktop-extensions]: https://www.anthropic.com/engineering/desktop-extensions
[statusline]: https://code.claude.com/docs/en/statusline
[desktop-code]: https://code.claude.com/docs/en/desktop
