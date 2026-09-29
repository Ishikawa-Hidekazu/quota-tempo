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

The browser tool refused `chrome://extensions/` under its URL policy. There was no
CDP, OS-automation, alternate-browser, or policy workaround. Loading the unpacked
prototype requires a user action. The extension has not been installed or connected,
native-host registration has not been applied, and the installed QuotaTempo app has
not been replaced. Test bundles are local development artifacts, not notarized releases.

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
