# Claude acquisition research

Research dates: 2026-09-29 and 2026-09-30. This is a source-based feasibility assessment, not a
runtime compatibility guarantee or a change to the [freshness contract](provider-freshness-contract.md).

## Requirement and status

The unresolved requirement is reliable Claude weekly remaining (`W`), today's
target remaining (`P`), and reset availability using an existing Claude Desktop
sign-in, with the standalone CLI signed out and **no new login**.

No additional publicly documented path examined here establishes that guarantee.
Desktop HTTP-cache work in Draft PR #42 remains experimental: organization-level
ownership and uncertain refresh behavior do not establish account-bound,
continuous availability. The browser extension prototype is tracked in a
separate pull request from Draft PR #42. A working browser-session bridge would
not, by itself, satisfy the Desktop-only requirement.

Research and any future observer must preserve these boundaries:

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
