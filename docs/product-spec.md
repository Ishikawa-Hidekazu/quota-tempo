# QuotaTempo Product Specification

Status: public-beta baseline

## Product contract

QuotaTempo helps people who use Codex, Claude, or both allocate weekly AI capacity. It converts a provider-reported weekly remaining percentage and reset time into a current target, a signed buffer, and the capacity available before the next reset-relative checkpoint.

This is an allocation planner, not a general usage monitor, token-cost dashboard, session recorder, account switcher, or automated model router.

V1 is comparison-only. It presents observed weekly capacity, confirmed or visibly estimated current targets, signed target differences, checkpoint capacity, status, source, and freshness. It does not recommend a provider, issue instructions such as `Use Claude today`, infer the user's work, or optimize provider selection. The user remains responsible for the final choice.

Users may enable Codex, Claude, or both. At least one provider must remain enabled. A disabled provider is absent from the popover, menu-bar label, and acquisition schedule; its last normalized observation is retained so re-enabling it does not destroy local history. A temporarily unavailable provider is not automatically disabled. On the first launch, QuotaTempo selects providers with an existing valid observation; if no provider can be detected, both remain visible so the user can choose explicitly.

The first launch focuses an independent application window so opening QuotaTempo always has a visible result even when its menu-bar item is obscured by a notch or other status items. The first-run guide explains provider selection, `W`, `P`, the visible `P≈` estimate marker, the comparison arrows, the local-data boundary, and all three menu-bar display modes. Completing the guide is an app-only preference. It can be reopened from the operational view and must not block later configuration. Opening the app again while it is already running brings the same application window forward. Login launch remains silent after onboarding.

Login launch is opt-in and off by default. QuotaTempo uses the macOS `SMAppService` main-app login-item mechanism only from `/Applications` or the user's `Applications` folder, reflects the operating system's current state, and reports when approval is required but not yet active in System Settings. Temporary, translocated, downloaded, and provider-disabled QA copies must not query or mutate that service. It must never add itself to Login Items merely by launching, updating, or detecting providers.

The support action generates a metadata-only diagnostic report. It may include the QuotaTempo version, macOS version, enabled provider names, normalized source kind, a normalized Codex executable provenance and semantic version when available, freshness, source state, and stable acquisition error code. It must exclude quota percentages, reset and capture timestamps, local paths, credentials, raw provider data, prompts, transcripts, and session content.

## Competitive boundary

CodexBar is the primary reference implementation for provider acquisition, pace calculations, and macOS menu-bar behavior. QuotaTempo does not depend on, bundle, fork, or auto-discover CodexBar.

QuotaTempo must earn its separate product boundary by remaining weekly-first and decision-focused:

- How much capacity should remain now?
- Which provider currently has headroom?
- How much is available before the next checkpoint?
- Is a short-window limit the immediate constraint?

## Provider-neutral snapshot

A future snapshot should contain only:

- provider identifier
- source kind
- captured timestamp
- weekly used or remaining percentage
- weekly window duration
- weekly reset timestamp
- optional five-hour window with the same bounded fields
- source freshness state

Unknown and absent fields remain unavailable. They are never inferred from token history, cost, model name, or another provider window. The only exception is a visibly marked weekly reset projected once from Claude's last confirmed reset; that estimate cannot chain.

## Codex acquisition candidate

Use the installed official `codex app-server` as a bounded child process and call `account/rateLimits/read` after initialization. Try at most three ordered candidates, preferring an executable nested directly in a verified official ChatGPT or Codex desktop app, then recognized user-local toolchain, package-manager, and system locations. A desktop candidate is eligible only when Security.framework validates its Apple Developer ID chain, exact bundle and nested-code identifiers, Team Identifier `2DC432GLL2`, strict code validity, and a symlink-free direct nesting path. A capability failure may advance to the next candidate, but an explicit account restriction stops fallback.

Each app-server attempt retains the existing five-second subprocess ceiling. After every eligible candidate fails, QuotaTempo runs one two-second, 4 KiB `--version` probe against the failure selected for display; successful acquisition never pays for this probe. The only version empirically established as incompatible is `0.133.0`, while `0.153.4` was observed working on the same product path. Therefore only versions less than or equal to `0.133.0` are labeled **Version too old**. Versions from `0.134.0` through the unproven interval keep the observed launch, protocol, timeout, or temporary-failure category rather than receiving an unsupported update claim.

Required boundaries:

- Do not open or parse Codex authentication files.
- Parse only recognized quota fields from a bounded response.
- Enforce timeout, output-size, schema, and process-termination limits.
- Preserve output-ceiling failures as a distinct safety category and apply a deterministic final-failure priority across candidates.
- Classify windows by reported duration rather than primary/secondary position.
- Treat missing and changed upstream shapes as unavailable.
- Persist no raw provider response, executable path, or raw version output. Store only normalized provenance and a strict three-part semantic version when available for the current attempt.

This adapter is implemented in the public-beta app.

## Claude acquisition

QuotaTempo uses bounded Claude Desktop history and Claude Code cache files first. Its noninteractive `get_usage` experiment returned no quota windows, so when those local observations lack current reset times it can launch the installed, signed-in Claude Code CLI in a bounded PTY and read `/usage` without CodexBar or manual entry. A current complete local cache avoids an unnecessary probe; automatic refresh is scheduled every 15 minutes with a 14-minute jitter guard, and explicit Refresh always probes. After a probe, QuotaTempo parses only the rendered current-session and all-model weekly rows, accepting a reset only when its timezone and time-window placement are unambiguous. It does not combine Desktop utilization with an unverified cache account in this path. The probe does not set Claude Code's nonessential-traffic suppression because that setting blocks the usage request itself.

Required boundaries:

- Do not read credentials, tokens, cookies, Keychain values, browser state, prompts, transcripts, or session contents.
- Reject symlink-selected and oversized local sources.
- Keep the old noninteractive `get_usage` decoder test-only; it is not the `/usage` acquisition path.
- Bound PTY time and output, disable tools, hooks, MCP configuration, Remote Control startup, and auto-update, and terminate the process tree.
- Reject stale or loading usage panels and reject ambiguous reset times; a failed probe retains a prior exact, still-current observation and its older captured time regardless of whether it came from the CLI or local cache rather than making it current.
- Tolerate independently absent windows and fail closed when utilization and reset metadata cannot be safely reconciled.
- Persist only normalized percentages, reset timestamps, the reset-estimate marker, source, freshness, and acquisition state.

The previously tested Claude `statusLine` bridge remains rollback-only code and is not activated by current onboarding. Claude model-specific buckets and Extra Usage remain out of scope because no stable third-party contract has been established.

## Calculation contract

Given current time `now`, reset time `resetAt`, window duration `duration`, and `remaining` in the range 0 through 100:

```text
timeRemaining = clamp(resetAt - now, 0, duration)
targetNow = 100 * timeRemaining / duration
vsTarget = remaining - targetNow
```

`vsTarget` is measured in percentage points (`pts`). Positive values mean capacity is above target; negative values mean capacity is below target.

Default status tolerance:

- above target: greater than `+2 pts`
- on target: from `-2 pts` through `+2 pts`
- below target: less than `-2 pts`
- reset unknown: a valid weekly balance exists, but no safe reset timestamp is available for plan calculations
- unavailable: incomplete, invalid, expired, or stale input

The tolerance is a product default, not a provider rule.

## Reset-relative checkpoints

Checkpoints divide the weekly window into 24-hour intervals counted backward from `resetAt`. They do not use local midnight.

For the next checkpoint after `now`:

```text
nextCheckpoint = earliest reset-relative 24-hour boundary after now
checkpointTarget = 100 * (resetAt - nextCheckpoint) / duration
availableUntilThen = max(remaining - checkpointTarget, 0)
```

If the reset occurs before another full checkpoint, the next checkpoint is the reset and its target is zero.

## Freshness

Every displayed value must expose a source and capture time.

- `live`: captured recently through a supported adapter
- `recent`: still inside the product freshness interval
- `stale`: retained for context but excluded from current comparison decisions
- `unavailable`: no valid snapshot

The recommended V1 defaults are `live` through 5 minutes, `recent` through 30 minutes, and `stale` after 30 minutes. A capture time in the future is invalid and hides all comparison values. These values are product defaults, not provider guarantees. Codex freshness measures time since the last valid bounded pull. Claude freshness measures time since the last valid recognized local observation on this Mac; it does not prove account-wide freshness or visibility into another device.

Acquisition health and snapshot freshness are separate. A failed provider attempt does not overwrite or refresh a prior valid snapshot. Attempt time remains separate from the capture time of the last valid observation. See [Provider Freshness Contract](provider-freshness-contract.md) for the recommended state machine, metadata boundary, copy, alternatives, and pre-live acceptance criteria.

## Menu-bar information architecture

The menu-bar label has three user-selectable modes. The selection is app-owned and persists across launches. A new installation defaults to Icon only so the item is less likely to be obscured on crowded or notched menu bars. An existing installation that completed onboarding under the earlier implicit Full default retains Full when it has no explicit saved mode:

```text
Full       Cx W34/P48 ↓14 · Cl W60/P48 ↑12
Compact    Cx 34↓14 · Cl 60↑12
Icon only  [neutral metronome glyph]
```

- On screen, the Full and Compact modes replace `Cx` and `Cl` with neutral monochrome SF Symbols. Provider logos are not bundled. The text forms above remain the canonical plain-text and VoiceOver representation.
- `W` is weekly capacity left.
- `P` is the continuous reset-relative plan at the current instant, assuming capacity is consumed evenly across the provider's seven-day window.
- `P≈` means Claude's last confirmed exact weekly reset was advanced by exactly one seven-day duration. An estimate is never used to generate another estimate; a new exact reset removes the marker automatically.
- `↑`, `↓`, and `=0` express the signed difference without recommending a provider.
- Missing weekly capacity renders the provider as `—`.
- Missing reset-relative comparison data that has neither a confirmed reset nor an eligible one-window projection preserves weekly capacity, renders plan and difference as `—`, and labels the detail state **Reset time unavailable**. For a Claude Desktop-only observation, explain that Claude Code must first produce compatible local reset metadata before `P` can be calculated. Stale data remains a separate state.
- When the last weekly balance is stale but its confirmed or one-window estimated reset is still valid and in the future, retain the reset-derived `P`, next checkpoint, and checkpoint target. Keep `VS TARGET` and capacity available until the checkpoint unavailable because they depend on the stale balance, and explain that they are waiting for a current balance. An estimated stale plan remains marked `P≈` and cannot be extended into another estimate.
- After the known reset elapses without a new observation, hide the old balance and every planning value. Do not advance the reset or assume a restored balance.
- The label is derived only from normalized snapshots and the one-minute planning clock. It must not start a provider refresh merely to repaint the title.
- A change in the formatted label is also a change in its rendered image identity. Background acquisition and the one-minute clock must update the closed menu-bar label without requiring the user to open the popover.
- Provider selection and menu-bar display mode are independent. A single enabled provider renders one segment without an unavailable placeholder for the disabled provider.

The popover explains the abbreviations and retains the unabridged comparison:

The operational popover caps its viewport at 720 points so AppKit can keep the window attached to the menu-bar status item. Its viewport is also clamped from the screen's visible height with room for view padding, window chrome, and a bottom safety margin. The complete content remains reachable inside a visible ScrollView. The independent application window is not subject to the popover cap: it uses the larger content range, updates its size when onboarding ends, refreshes state whenever it is presented, and exposes the same controls if the status item is obscured.

Primary table:

```text
WEEKLY LEFT / TARGET NOW / VS TARGET
```

Detail:

```text
Weekly reset / Next checkpoint / Checkpoint target / Available until then / Status
```

**Weekly reset** is the provider window's end time. **Next checkpoint** is the next 24-hour planning boundary counted backward from that reset. They must be displayed as separate rows. Every detailed date and time includes a weekday in the selected language and locale order. A projected Claude reset is labeled **Weekly reset (estimated)**; missing, elapsed, or implausible reset times render as unavailable rather than being inferred.

Five-hour quota appears only in detail or as an immediate-risk warning when it is the binding constraint. The app must not synthesize a missing five-hour window.

The fixture prototype marks the five-hour window as an immediate constraint when 15% or less remains and reset is more than 30 minutes away. The warning is informational and does not recommend a provider. The threshold is a prototype default, not a provider rule.

English is the canonical product copy. Japanese copy should preserve meaning rather than abbreviations:

| English | Japanese |
| --- | --- |
| Weekly left | 週間残量 |
| Target now | 現在目標 |
| Vs target | 目標差 |
| Weekly reset | 週間リセット |
| Weekly reset (estimated) | 週間リセット（推定） |
| Next checkpoint | 次の区切り |
| Checkpoint target | 区切り時の目標 |
| Available until then | それまで利用可能 |
| Above target | 目標より余裕あり |
| On target | 目標どおり |
| Below target | 目標を下回る |
| Stale | 更新待ち |

## Fixture prototype acceptance history

The first prototype must:

- contain no live provider adapter or provider subprocess
- make no network request
- read no home-directory provider state
- use deterministic fixtures and an injectable clock
- render two-provider, one-provider, unavailable, stale, and five-hour-risk states
- verify current target, reset-relative checkpoints, signed `pts`, and tolerance boundaries
- cover invalid percentages, missing reset, elapsed reset, unexpected duration, clock changes, and provider-specific missing windows
- expose source and freshness in detail
- include accessibility labels independent of color and arrow direction
- contain no telemetry, updater, account switching, prompt routing, session history, package, or release automation
- contain no provider recommendation, task inference, or provider-selection optimization

These constraints remain regression requirements for fixture rendering in the public-beta implementation.

## Open design decisions

- Validate the five-hour immediate-risk threshold and language with fixture usability review.
- Configurable work schedules are deferred beyond V1. V1 intentionally shows a neutral even seven-day baseline and explains that assumption; it does not claim to model each user's working days.
- The live app persists the minimal normalized schema defined in [Provider Freshness Contract](provider-freshness-contract.md). Any incompatible future schema requires an explicit versioning and migration decision.
