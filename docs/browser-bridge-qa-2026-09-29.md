# Browser bridge prototype QA

Date: 2026-09-29. Branch: `codex/claude-browser-bridge`, based on public main
`843eed4`. This is unreleased work, independent of Desktop-cache Draft PR #42.

## What was checked

- Isolated content acquisition, old/new usage shapes, account-before/after checks,
  ownership pinning, background polling, native-message framing and atomic storage.
- Whole-source selection in the app model, minute-clock W/P updates, disconnection,
  sign-out, account changes, stale observations, and elapsed weekly resets.
- Installation/removal dry runs, filesystem failure injection, rollback, symlinks,
  malformed files, and recovery of a corrupt normalized browser record.
- Native host packaging, signing/verification hooks, and deterministic app bundles.
- Five shipped competitors' pinned source implementations and documented limitations
  in [the research report](claude-acquisition-research.md).

## Automated results

Environment: Apple silicon macOS, Node.js 22.22.1, Swift Testing 1902.
All data in these tests is synthetic; tests do not contact Claude or read a real
provider login, browser session, or conversation.

| Command | Result |
| --- | --- |
| `swift test` | PASS, 281 tests / 9 suites, including 47 browser tests |
| `node --test BrowserExtension/tests/*.test.cjs` | PASS, 20 tests |
| `node scripts/test-browser-bridge-installer.mjs` | PASS, 81 tests including subtests |
| `node scripts/test-browser-host.mjs` | PASS, 5 process-level tests |
| `xcrun swift-format lint --strict --recursive Sources Tests` | PASS |
| `scripts/test-release-policy.sh` | PASS |
| `scripts/test-app-bundle.sh --skip-launch` | PASS, app/provider launch checks intentionally skipped |
| `scripts/test-package-reproducibility.sh` | PASS, two identical packages from a clean checkout; bundled native host signature verified |
| Shell syntax, ShellCheck, and `git diff --check` | PASS |

The native process test passes an extension-parser fixture through a fragmented
native frame to the real debug host and validates the resulting normalized record.
A debug-only fixture-directory argument isolates it from the user's Application
Support directory. That argument is absent from release builds.

## Findings fixed during review

- Disconnected and older connection generations could re-enable observations:
  added explicit handshakes, sequences, and retained revocation tombstones.
- Account mismatch could leave the previous quota displayed: revoke old windows
  without accepting the new owner.
- A slow partial frame could monopolize the write lock: frame input now precedes
  the short, bounded exclusive update lock.
- Future/skewed clocks could block sign-out: order by sequence, clamp small future
  skew, preserve original capture times, and make value-free ACK retries idempotent.
- Dangling symlinks could trigger local fallback: reject unsafe paths before absence checks.
- Installation errors could leave half-changed registration: prevalidate both targets,
  stage writes, and roll back recoverable errors; test incomplete recovery reporting.
- Delayed content responses could appear freshly captured: reject expired requests
  and preserve content capture time rather than worker-delivery time.
- Failed revocation delivery could strand old host values: retain a value-free pending
  control message and retry with the same generation/sequence before resuming.
- Browser restart used to require manual reconnection: preserve the selected account
  and generation and inspect an existing Claude tab without opening or focusing one.

## Live evidence and unverified work

A new background Chrome tab loaded the official Claude usage settings page using
the existing browser sign-in. Its visible UI contained weekly usage and a weekly
reset schedule. This proves only that the browser has a usable signed-in UI, not
that the experimental endpoint parser or native delivery works with that account.
No private quota values, identifiers, page snapshots, or response bodies are included here.

On September 29, the browser tool refused `chrome://extensions/` under its URL policy. There was no
CDP, OS-automation, alternate-browser, or policy workaround. Loading the unpacked
prototype requires a user action. The extension has not been installed or connected,
native-host registration has not been applied, and the installed QuotaTempo app has
not been replaced. Test bundles are local development artifacts, not notarized releases.

### September 30 registration follow-up

The owner supplied the unpacked extension ID. The staged extension still matches
the reviewed source, and the native host passes signature verification. Installer
dry run and explicit application succeeded; a metadata-only read-back confirms
the same single permitted extension origin in both registration files, pointing
to the local prototype bundle. The installed public app is unchanged.

GitHub CI and CodeQL for commit `7a90c21` all passed. The existing Claude usage
page remains available through the background Chrome extension connection.
No native observation file existed at the registration check: explicit Connect
and real extension-to-host delivery are still unverified. This is setup evidence,
not acquisition or installed-app acceptance.

### September 30 Connect follow-up

The owner loaded the unpacked extension and clicked Connect. The host persisted a
valid connection generation and a first observation with `status=unavailable`,
`source=claudeBrowser`, and no weekly or five-hour window. This proves that the
extension can deliver a control handshake and a value-free failed observation
to the native host. It does **not** prove that the live usage endpoint is
compatible or that W/P can be displayed.

The extension originally collapsed request failures and schema mismatches into
the same `unavailable` status. A bounded local diagnostic stage was added to its
popup; it forwards no response body, account identifier, cookie, token, or raw
error to the native host. A local fallback also hashes an email-only account
identity when the account API has no UUID; the raw address is never persisted
or forwarded. The extension tests now pass 24/24 and `git diff
--check` passes. Live diagnosis requires reloading the unpacked extension and
one explicit Reconnect on the existing Claude Web tab.

### September 30 compatibility and loaded-version follow-up

The popup screenshot still showed the original generic `Unavailable` message.
Source and staged files matched, but that alone did not establish the running
service worker's version. Prototype 0.1.1 now identifies both popup and worker
versions. A stale or unknown worker gets an explicit reload instruction. A lost
content response now records `responseTimeout` and uses bounded failure backoff
instead of silently starting another request every minute.

Independent synthetic verification found two parser incompatibilities against
[CodexBar's pinned public usage fixture](https://github.com/steipete/CodexBar/blob/25bba9b7fd9ce83c33053958f7366e23b2dc8a82/Tests/CodexBarTests/ClaudeWebUsageExtraWindowTests.swift#L281):

- The fixture uses microsecond fractions with explicit UTC offsets. The prototype
  accepted only `Z` and up to three fractional digits.
- Legacy windows and equivalent `limits` windows coexist, with `percent` in the
  latter. The prototype rejected their coexistence and did not recognize `percent`.

These are reproducible compatibility defects, not proof of the current account's
live failure cause. No authenticated response body was read or retained. The last
metadata-only host check still contained an unavailable observation and no quota.
The installed public app has not been replaced, and Desktop-only gates remain open.

Both defects are fixed in 0.1.1. Numeric offsets and up to nine fractional digits
are normalized to UTC milliseconds after strict calendar validation. Legacy and
`limits` windows merge only when their normalized values match; conflicts and
within-`limits` duplicates remain invalid. The parent added a native-process
regression that failed before the parser fix and passed afterward, including an
assertion that the stored reset is not estimated.

The independent worker review found that recovery tab events could bypass a timeout
backoff. Observation entry points now share expiration and retry-deadline checks;
browser startup restores a pending failure alarm without shortening its deadline.
Regression tests cover a tab event arriving before the expiration alarm, repeated
tab events during backoff, and startup during rate-limit backoff.
Independent read-only re-review confirmed the backoff finding is resolved, with
17/17 worker/popup tests and no additional finding in that reviewed scope.

Follow-up verification: 37/37 extension tests, 81/81 installer tests, 6/6 native-host
process tests, JavaScript syntax checks, and `git diff --check` pass. The earlier
commit `a8d31dc` also passed all GitHub CI/CodeQL checks. These automated results do
not replace the pending live 0.1.1 reload, observation, and installed-app QA.

### September 30 first successful live browser observation

After the compatibility update, the owner's popup changed to `Connected`.
A metadata-only native record check confirmed `status=ok`, `source=claudeBrowser`,
a fresh capture time, weekly and five-hour windows, provider reset timestamps,
and no acquisition error. Neither reset is marked estimated. Private percentages,
timestamps, identifiers, and response bodies are omitted here.

The screenshot showed popup 0.1.1 but `worker unknown`, so this success does not
establish that the entire updated worker is active. User reload confirmation,
two automatic refreshes, official-display comparison, installed-app UI, and
rollover acceptance remain pending. No public app replacement or release occurred.

### September 30 reload recovery and local preview follow-up

The owner's extension-details screenshot confirmed version 0.1.1 and the expected
unpacked source. Successful observation sequences had advanced, but that alone did
not establish automatic polling: tab activity or owner actions can also trigger
acquisition. After reload, a later metadata-only check still showed the same record
more than two normal polling intervals later. The precise live worker state was
not inspected; no browser storage, raw responses, or credentials were read.

A synthetic reload regression reproduced a separate concrete defect: persisted
connection state could outlive its Chrome alarm, and only browser startup restored
polling. Version 0.1.2 checks for a missing alarm on every worker initialization,
as recommended by the [Chrome alarms documentation](https://developer.chrome.com/docs/extensions/reference/api/alarms).
It preserves the existing connection, capture timestamp, failure deadline, in-flight
expiry, and bounded revocation retries. Initialization only arms the alarm; a normal
due event performs acquisition. Early or queued events cannot bypass a newer deadline.
This fix is not yet proven to explain or repair the live stopped record.

The parent verified a real normalized observation through `LiveQuotaModel`, the
planner, menu-title formatter, and an offscreen `QuotaMenuView` render. Weekly
remaining usage and the weekly reset schedule matched the official visible Claude
usage page. The first temporary test asserted subsecond identity across the existing
second-resolution normalized codec and failed; after comparing with the codec's
actual encoded/decoded result, the import check passed. No capture time was rewritten
to appear fresher. Temporary test code, its private bitmap, and copied records were
removed after inspection. The full unchanged Swift suite then passed 281/281.

A separately named, ad-hoc-signed local preview bundle was prepared with automatic
updating disabled. The running public app was stopped and the preview started without
requesting an application window or activation. The public installed bundle was not
modified. A read-back confirmed the preview persisted a successful `claudeBrowser`
observation with the original capture time and non-estimated reset. This verifies
running-app ingestion, not an observed click/popover flow or notarized deployment.
Rollback snapshots are retained locally, outside Git. The preview must not be mistaken
for a public release.

Reload-recovery synthetic tests pass 57/57. Live automatic polling with 0.1.2 remains
pending its manual Chrome reload. CI/CodeQL for the earlier `4a3f9ff` revision all passed;
that result does not cover these new changes.

### September 30 automatic polling and reset-boundary follow-up

After the owner reported reloading 0.1.2, a bounded metadata-only check observed:

- One automatic success 302 seconds after the previous capture. The preview app
  imported it about 61 seconds after capture, retaining the exact weekly reset.
- The next scheduled acquisition failed shortly after the prior five-hour reset
  elapsed. Failure delivery preserved the last successful capture timestamp; it
  did not make that observation look fresh. The two-cycle uninterrupted check failed.
- A subsequent scheduled acquisition recovered without Refresh or Reconnect and
  supplied a new provider five-hour reset. The preview imported it automatically.
- The official CLI's authentication-status command reported signed out. Only its
  boolean result was inspected. Browser sign-in, not CLI authentication, supplied
  the successful observations.

No raw response, browser storage, authentication value, or conversation was read.
The failure stage was not captured, so reset timing alone does not prove the live
failure's exact cause. An additional hidden browser-page check was not available;
no foreground, OS-control, or alternate-browser fallback was used.

An independently reproducible parser defect did reject a valid weekly observation
when its optional five-hour window had just elapsed. Prototype 0.1.3 omits only a
well-formed expired optional window, after checking mixed-schema consistency.
Invalid percentages/dates, duplicate or conflicting windows, and an elapsed weekly
reset still fail closed. It never supplies a guessed next reset or balance. Tests
cover before/at/after reset, recovery to a newly supplied timestamp, both schemas,
and parser-to-native-host delivery of the surviving exact weekly observation. The
worker also handles a valid optional reset expiring between parsing and delivery;
its required weekly window and account pin must still validate.

Independent review also found two worker-stop persistence defects: retries could
exceed their budget if the worker stopped while awaiting an ACK, and a successful
revocation could clear its pending control before terminal state was saved. The
candidate reserves retries before sending and commits revocation completion with
its terminal/recovery state. By-value storage and crash-boundary regressions cover
initial send, retry, ACK, storage commits, alarm updates, and explicit reconnection.

Extension Node QA passed 153/153 tests, including the by-value worker-stop and
rollover regressions. Independent read-only review of the parser changes found
no further issue in that scope; the parent reviewed the worker changes.

Swift QA initially failed one existing five-second shell-wrapper test with a
timeout. The focused test passed without a code change, and the subsequent full
suite passed 281/281. This is a transient test failure, not evidence of a fixed
wrapper defect. Installer QA passed 81/81, native-host process QA passed 7/7,
Swift lint and release-policy checks passed, and app-bundle QA passed with the
provider-trigger and application-window checks deliberately skipped.

The active 0.1.2 observation above must not be counted as live acceptance of the
0.1.3 candidate. The following separate round begins after the owner's 0.1.3
reload confirmation.

### September 30 0.1.3 owner reload follow-up

The owner confirmed completing the requested 0.1.3 reload. The staged extension
matches the source at `fe789c5`; the live worker version is based on that owner
confirmation, not on reading Chrome storage. All GitHub CI and CodeQL checks for
that commit passed. The official CLI still reported signed out when checked in
this round; only the parsed authentication boolean was exposed.

A bounded read-only check of the normalized bridge and app records passed two
consecutive no-click automatic updates at 302- and 301-second intervals. The
running preview imported each same capture, owner fingerprint, weekly percentage
and non-estimated reset about 17 and 16 seconds after capture, respectively.
Neither interval contained a failed observation or a changed connection generation.
No Refresh, Reconnect, browser interaction, credential access, or provider request
was initiated by the QA observer. Application integration tests passed 9/9 using
isolated synthetic fixtures; these tests do not constitute live popover QA.
The owner also supplied a current menu-bar screenshot showing numeric Claude
weekly remaining, target, and difference, without unavailable/stale markers.
This is real menu-bar display evidence, not a screenshot of synthetic fixtures.
The screenshot and its private values are not included in the repository.
The check ended successfully and its temporary observer was removed. The public
installed app's strict signature verification passed; no installed bundle,
registration, provider authentication, browser setting, or release was changed.

**Local checkpoint: PASS for menu-bar W/P/difference and two automatic imports
with browser sign-in and CLI signed out.** This short run crossed neither a
five-hour nor a weekly reset and is not a long-duration reliability guarantee.

Remaining release gates:

1. Repeat exact-version acquisition and full popover acceptance on a clean or
   second Mac, comparing W, the reset timestamp, P, and the difference against
   the official usage display and the planning calculation. Local registration,
   browser-signed-in/CLI-signed-out acquisition,
   two automatic imports, and the owner's menu-bar display check are complete.
2. Verify a live five-hour rollover with 0.1.3 retains eligible weekly values
   without inventing a new optional window; that boundary is tested synthetically
   but was not crossed during the successful live follow-up.
3. Verify live browser restart, sleep/wake, lost tab, sign-out, account changes, and
   failure recovery. The web endpoints are undocumented and not transactionally
   account-bound; before/after identity checks are a mitigation, not an official guarantee.
4. Verify a real weekly rollover obtains a new provider timestamp, never a projected one.
5. Perform installed-app UI QA and clean-Mac/second-Mac QA, independent review,
   and normal signing/notarization/release acceptance before deployment.
6. Resolve the provider-use review for the exact browser integration before
   distribution. User consent and the absence of cookie extraction do not, by
   themselves, establish provider approval for undocumented endpoints.

**Decision: not ready for release.** Live ingestion, automatic polling, and recovery
by a local preview are verified, but uninterrupted reset-boundary behavior and
installed release UI acceptance are not. Desktop-only reliability is
still a separate unresolved requirement; the browser route must not be advertised
as resolving it. Do not merge/release Draft PR #42 on the strength of these results.

### September 30 pre-publicity hardening (0.1.4 candidate)

This round preserves the running 0.1.3 extension and the prior local preview.
It does not replace the installed app, extension staging directory, native-host
registration, or any provider sign-in. The changes below are a development
candidate, not live acceptance of version 0.1.4.

Independent review and synthetic reproductions found and corrected:

- Sign-out and organization-selection invalidations could lose delivery after a
  native-host ACK failure. They now use the same persisted finite retry protocol
  as account changes. Sign-out can resume ordinary backoff after delivery;
  ambiguous organizations remain blocked. Exhausting four retries still requires
  explicit recovery, rather than retrying indefinitely or silently reconnecting.
- Before/after identity checks could prove a different owner but discard that
  fact when usage validation failed. Rechecked hashes now trigger revocation
  independently of quota validity; invalid usage cannot establish a new pin.
- A pending connection handshake could become too old for an explicit retry.
  Explicit retry renews only its timestamp, not its profile, generation or
  sequence. Native duplicate acknowledgement still leaves the original record
  unchanged. Quota observations are not replayed or made fresh this way.
- A cache observation could be attributed to the surrounding, newer login record
  without checking its own `accountUuid`. Mismatches are now excluded and legacy
  unstamped caches cannot establish a verified Desktop reset join.
- Minute-only local imports could inherit another verified account's failure or
  clear a live failure using an estimated reset. Reproductions failed before the
  fix and pass afterward; only a fresh owned exact reset clears a same-account
  live failure. Capture time and the live-attempt clock remain separate.
- A live refresh arriving during a minute-only read could be discarded. A single
  coalesced pending request now survives that collision, with manual force taking
  priority and all acquisition/selection/source gates rechecked when drained.
  Deterministic paused-reader tests cover success, failure, throttling, source
  changes, and provider disabling without launching a real provider process.

The app imports changed allowlisted local metadata on its minute clock when the
browser route does not own the observation. It does not launch or resolve a CLI,
make a provider request, or advance source capture time. This reduces app-side
latency after Desktop writes data; it cannot cause Desktop to write a missing
reset timestamp. Synthetic tests cover missing local files and preservation of
prior live failures, not just the successful-import case.

A narrow read-only check of the still-running 0.1.3 path found successful recent
browser and app records, the same owner and weekly percentage, and a future
non-estimated reset. Capture/reset timestamp differences were below one second,
consistent with the app codec's ISO-8601 precision. This was a single checkpoint,
not an additional multi-cycle or rollover acceptance test.

The expanded [research record](claude-acquisition-research.md) pins five competitor
implementations and the official status-line, telemetry, and SDK contracts.
The metadata-only local check still found recent Desktop percentages but an
expired reset-bearing cache. No new strict Desktop-only exact-reset source was
established, and no upstream request was sent.

Current candidate verification:

| Check | Result |
| --- | --- |
| `swift test` | PASS, 301 tests / 10 suites |
| Extension Node tests | PASS, 216/216 |
| Installer Node tests | PASS, 81/81 |
| Native-host process integration | PASS, 7/7 |
| Strict Swift formatting | PASS for all changed Swift files |
| Release policy | PASS |
| App-bundle assembly | PASS, ad-hoc signatures/resources/determinism/temporary cleanup |
| Provider-trigger and application-window checks | SKIP, no live app/UI replacement or launch in this round |

Independent review reproduced the ownership/diagnostic issues above; the parent
also reviewed the extension changes and the model's bounded queue. Local/clock
tests were adjusted to the intentional new import contract. This changes neither
the existing exact-reset requirement nor the real-device release gates.
Follow-up regressions also cover an owner-unconfirmed Desktop sample after a
known account switch and a first observation replacing nonfailure waiting states;
neither may inherit an unrelated old status. These failed before their fixes.

**Decision remains not ready for release.** The live gates above, including exact
candidate acceptance, real rollover, restart/recovery, second-Mac and normal
release verification, remain open. No unsupported claim was promoted to a
Desktop-only guarantee.

### September 30: browser tab absence

A fresh Chrome extension inventory contained no `claude.ai` tab while the native
bridge record retained an older successful observation. Its capture timestamp
had not advanced. This is consistent with the existing `waitingForTab` recovery
path: it schedules another check but cannot fetch a new authenticated observation
without a Claude tab. The worker's private storage was not inspected, so this
does not prove every earlier missed refresh had the same cause.

The background-control connection did not support hidden tab creation; the
attempt was rejected before creation. No foreground, new-window, OS-input, or
alternative browser-control action was used. The owner was asked to open one
Claude usage tab and leave it open. Recovery remains unverified until a new
native observation arrives. No extension, native host, or installed app was
replaced. Browser tab-dependent recovery is not Desktop-only acquisition.
