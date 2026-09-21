# Provider Freshness Contract

Status: implemented in the public-beta app.

## Decision

QuotaTempo should use one conservative freshness clock for both providers while naming what each timestamp means:

- `live`: the last valid observation is no more than 5 minutes old.
- `recent`: the last valid observation is more than 5 and no more than 30 minutes old.
- `stale`: the last valid observation is more than 30 minutes old.
- `unavailable`: no valid observation exists, the observation is future-dated, its reset has elapsed, or required fields are invalid.

The thresholds are QuotaTempo product defaults, not provider guarantees. Freshness is calculated from the last valid `capturedAt`, never from app uptime or the last failed attempt.

Stale data may retain `WEEKLY LEFT` as `W?`, a clearly labeled last-observed value. When its reset is still valid and in the future, it may also retain the independently reset-derived `TARGET NOW`, next checkpoint, and checkpoint target. It must not produce `VS TARGET`, capacity available until the checkpoint, five-hour risk, or any other result that combines the stale balance with the current plan. The UI distinguishes a confirmed reset from a permitted one-window estimate and explains that those balance-derived fields are waiting for a current observation. Once the reset elapses, every old-window value is hidden and the status names that transition even when the capture is stale.

## Minimal metadata

QuotaTempo may store only the normalized fields needed to render and diagnose freshness:

| Field | Persistence | Purpose |
| --- | --- | --- |
| `provider` | Yes | Identifies Codex or Claude. |
| `source` | Yes | Identifies the bounded Codex pull or recognized local Claude observation source. |
| `capturedAt` | Yes, after a valid observation | Drives freshness and the visible last-observed time. |
| normalized quota windows | Yes, after strict validation | Contains only remaining percentage, duration, reset time, and whether that reset is a one-window estimate. |
| `lastAttemptAt` | Yes for app-initiated refreshes | Distinguishes a refresh attempt from the capture time of the last valid observation. |
| `sourceState` | Yes | Exposes a small stable state without raw provider output. |
| `errorCode` | Optional, replaceable metadata | Stores only the stable `AcquisitionErrorCode` values defined by the app, including bounded-source, compatibility, and persistence failures. |
| `codexExecutableSource` | Optional, Codex only | Records only `desktop_bundled`, `user_local`, `package_manager`, or `system`; never a path. |
| `codexExecutableVersion` | Optional, Codex only | Records only a validated normalized `major.minor.patch` value; never raw command output. |

Raw provider output, command arguments, environment, credentials, tokens, cookies, Keychain values, authentication files, sessions, prompts, and transcripts are never stored.

Normalized snapshots use an explicit schema-version wrapper. RC13 accepts schema version 1 and one deliberate legacy unversioned RC12-or-earlier shape for upgrade continuity. Reads are limited to 64 KiB and reject symlinks, non-regular files, provider/source mismatches, invalid dates or quota windows, and inconsistent acquisition states before data reaches the planner.

## Shared source states

- `never_observed`: no valid snapshot has been received.
- `observation_succeeded`: the latest acquisition produced a valid snapshot.
- `access_restricted`: the provider explicitly reports that ordinary usage is unavailable; percentages and plan values are hidden.
- `attempt_timed_out`: a bounded provider pull timed out; an older valid snapshot may remain.
- `attempt_failed`: a provider refresh exited or decoded unsuccessfully; an older valid snapshot may remain.
- `awaiting_event` and `bridge_unavailable`: retained only for the retired, inactive Claude status-line bridge.

`sourceState` explains acquisition health. `freshness` explains the age of the last valid data. They are separate axes.

## Codex bounded-pull contract

The future Codex adapter is an explicit, bounded local pull through the installed official Codex executable. The candidate RPC shape is not treated as a permanent public API contract.

### Acquisition

- Trigger on app launch, every 15 minutes while the menu-bar label remains active, after system wake, on menu open after the provider-specific last-attempt guard, or explicit refresh. Claude local observations are additionally checked every minute while running; Codex retains its five-minute guard.
- Keep scheduling inside the menu-bar app; do not install a separate background daemon or login item.
- Allow one in-flight attempt per provider.
- Try no more than three recognized executable candidates. Each capability attempt has a 5-second timeout and 1 MiB combined output ceiling, strict recognized-field decoding, and process-tree termination. An explicit provider restriction stops fallback immediately.
- Prefer a desktop-bundled executable only after the outer app and nested executable pass the pinned identifier, Team ID, all-architecture, nested-code, and direct-nesting requirements. Then consider recognized user-local, package-manager, and system locations.
- After all candidates fail, run at most one bounded `--version` probe. Normalize only a strict semantic version and retain no raw output or local path.
- Record `lastAttemptAt` when the bounded attempt begins.
- Replace quota data and `capturedAt` only after the complete response validates.
- Never overwrite the last valid snapshot with a timeout, malformed response, or partial response.

### Result mapping

| Condition | Source state | Display behavior |
| --- | --- | --- |
| Valid pull succeeds | `observation_succeeded` | Use the new capture time and normal freshness rules. |
| Pull times out, no prior snapshot | `attempt_timed_out` | Unavailable; show `Refresh timed out`. |
| Pull times out, prior snapshot is live/recent | `attempt_timed_out` | Keep comparison values and show `Last refresh timed out`. |
| Pull fails or schema changes, no prior snapshot | `attempt_failed` | Unavailable; show `Codex data unavailable`. |
| Pull fails, prior snapshot is stale | `attempt_failed` | Show only stale last-observed weekly value and failed-attempt detail. |
| No recognized Codex installation exists | `attempt_failed` | Show an install/open recovery message. |
| A known `0.133.x` or earlier Codex version fails | `attempt_failed` | Show an update-specific recovery message. |
| The app-server protocol is incompatible | `attempt_failed` | Ask the user to update Codex and QuotaTempo. |
| Provider says ordinary usage is unavailable or a spend/rate restriction is active | `access_restricted` | Hide percentage, target, and checkpoint values; show `Access restricted`. |
| Reset time has passed | Any | Invalidate the quota window immediately; do not extrapolate a new window. |

The UI must show both `Captured` and, after a failed attempt, `Last refresh attempt`. A failed attempt does not make an old snapshot newer.

## Claude local-observation contract

V1 reads only recognized aggregate fields from Claude Desktop history and Claude Code's local usage cache. It does not install or activate a status-line bridge, launch Claude CLI, call an undocumented endpoint, or ask the user to enter quota data.

### Acquisition

- Read the two documented product paths named in `PRIVACY.md` with strict size and regular-file checks.
- Decode only the recognized history and `cachedUsageUtilization` structures.
- A valid observation from either local source succeeds independently; a malformed or oversized optional sibling source does not turn it into a failed refresh. Report a local read failure only when neither source yields a valid observation.
- Combine a newer utilization reading with an older reset only when both observations belong to the same quota window.
- Treat five-hour and seven-day windows as independently optional.
- Exclude model-specific weekly buckets and Extra Usage.
- If the last confirmed weekly reset has just elapsed and a newer Desktop observation belongs to the immediately following window, advance that exact reset by one seven-day duration and mark `P≈` as estimated.
- Never advance an estimated reset. If only utilization is safe and no one-window projection qualifies, keep `W` and show `P` and comparison as unavailable.

### Uncertainty contract

Claude freshness means `last observed on this Mac`, not guaranteed current account-wide state.

- No new local observation while Claude is unused is not an acquisition error and does not prove the quota is unchanged.
- Usage on another device may not appear until Claude updates one of the recognized local sources.
- A long interval without a valid local observation moves data from recent to stale.
- A current CLI compatibility check found no five-hour or weekly windows in `get_usage`; the experimental decoder stays disabled in V1.

### Result mapping

| Condition | Source state | Display behavior |
| --- | --- | --- |
| Complete valid local observation | `observation_succeeded` | Use normal freshness rules; label as observed on this Mac. |
| New weekly observation immediately after the last confirmed reset | `observation_succeeded` | Project the exact reset once, show `P≈`, and disclose the estimate basis. |
| Weekly utilization is valid but compatible reset is absent | `observation_succeeded` | Keep weekly left; show `Reset time unavailable` and no current comparison. |
| Five-hour window is valid but weekly is absent | `observation_succeeded` | Keep the independent immediate-risk warning when applicable; weekly plan remains unavailable. |
| No valid local observation | `attempt_failed` or `never_observed` | Keep any prior snapshot under age rules; otherwise unavailable. |
| No valid observation for more than 30 minutes | `observation_succeeded` | Stale; weekly left only, with no current comparison values. |
| Confirmed reset has passed and one-window projection qualifies | Any | Advance once and mark the plan estimated. |
| Estimated reset has passed | Any | Invalidate immediately; never chain an estimate. |

## User-facing copy

English is canonical. Japanese preserves the same uncertainty.

| State | English | Japanese |
| --- | --- | --- |
| Codex live | `Captured: Tue, Sep 8, 2026 at 1:10 PM` | `取得: 2026年9月8日(火) 13:10` |
| Codex failed refresh with usable prior data | `Last refresh attempt: Tue, Sep 8, 2026 at 1:15 PM` | `最終更新試行: 2026年9月8日(火) 13:15` |
| Claude live/recent | `Captured: Tue, Sep 8, 2026 at 1:05 PM` plus `Last observed on this Mac.` | `取得: 2026年9月8日(火) 13:05` と `このMacで最後に確認した値です。` |
| Valid balance, reset missing | `Reset time unavailable` | `リセット時刻未取得` |
| One-window reset projection | `Estimated from the last confirmed weekly reset` | `最後に確認した週間リセットからの推定` |
| Provider restriction | `Access restricted` | `アクセス制限中` |
| Stale | `Stale` with the exact captured timestamp | `更新待ち` と正確な取得日時 |
| Unavailable | `Usage unavailable` | `使用状況を取得できません` |

V1 intentionally uses absolute local timestamps rather than relative-time copy, avoiding a second clock-dependent formatting surface. The primary row must use text or symbols in addition to color. Detail must expose source, `Captured`, freshness, and any bounded acquisition failure. Raw error text is not shown.

## Alternatives considered

### Provider-specific time thresholds

Using a longer recent interval for Claude would keep more rows actionable while Claude is idle, but it would obscure other-device usage and make unlike freshness labels appear equivalent. Rejected for V1.

### Keep stale comparison values

This preserves more numbers, but `VS TARGET` and checkpoint headroom would look current when they are not. Rejected.

### Repeat the previous plan value

The plan changes continuously, so retaining its old displayed number would be misleading. Rejected. The accepted fallback recalculates from one projected weekly reset, marks every derived plan with `≈`, and stops after one window.

### Make every failed Codex attempt unavailable

This is simpler, but discards a still-recent valid snapshot and conflates acquisition health with data age. Rejected.

## Regression fixtures

- Codex success with no previous snapshot.
- Codex timeout with no previous snapshot.
- Codex timeout with live, recent, and stale previous snapshots.
- Codex malformed and oversized response with a preserved previous snapshot.
- Codex reset elapsed immediately after a prior valid snapshot.
- Claude local sources with weekly only, five-hour only, and both windows.
- Claude local observation followed by live, recent, and stale clock advances.
- Claude local sources unavailable with no snapshot and with a stale snapshot.
- Claude local observation with independently missing windows and an unsupported shape.
- Claude one-window weekly reset projection, exact-reset replacement, and refusal to chain an estimate.
- Future-dated timestamps and backward wall-clock movement.
- English and Japanese copy plus accessibility summaries for every source state.

## Acceptance criteria

- The state and freshness axes are independently tested.
- Failed acquisition never overwrites the last valid snapshot.
- Reset projection is limited to the immediately following weekly window, is visibly estimated, and never chains.
- Stale snapshots expose only a valid reset-derived plan and schedule; they expose no balance-derived comparison or capacity decision.
- Claude copy always states the local-machine observation boundary.
- Codex timeout and schema failures expose stable local error categories only.
- Persistence contains only the minimal normalized metadata listed above.
- No test or implementation reads provider secrets, authentication storage, sessions, prompts, or transcripts.
- No Claude provider process, endpoint, settings change, login item, release, or publication is introduced by the V1 Claude adapter.

## Approved V1 decision

Use shared 5-minute live and 30-minute recent thresholds, preserve recent data across a failed provider refresh, label every Claude value as last observed on this Mac, permit one visibly estimated weekly reset projection without chaining, and keep the retired status-line and experimental CLI paths inactive.
