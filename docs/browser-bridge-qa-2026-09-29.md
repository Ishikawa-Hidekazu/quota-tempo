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

Remaining release gates:

1. Load the exact prototype extension, register its exact ID, and confirm a live
   normalized success from web sign-in while Claude Code remains signed out.
2. Compare W, exact reset, P, and difference with the official usage display and
   confirm at least two automatic refreshes without manual Refresh.
3. Verify live browser restart, sleep/wake, lost tab, sign-out, account changes, and
   failure recovery. The web endpoints are undocumented and not transactionally
   account-bound; before/after identity checks are a mitigation, not an official guarantee.
4. Verify a real weekly rollover obtains a new provider timestamp, never a projected one.
5. Perform installed-app UI QA and clean-Mac/second-Mac QA, independent review,
   and normal signing/notarization/release acceptance before deployment.
6. Resolve the provider-use review for the exact browser integration before
   distribution. User consent and the absence of cookie extraction do not, by
   themselves, establish provider approval for undocumented endpoints.

**Decision: not ready for release.** Automated implementation QA has passed, but
live extension-to-installed-app acquisition has not. Desktop-only reliability is
still a separate unresolved requirement; the browser route must not be advertised
as resolving it. Do not merge/release Draft PR #42 on the strength of these results.
