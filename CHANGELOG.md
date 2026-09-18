# Changelog

## 0.1.3 — Claude observation refresh

- Checks Claude local observations approximately once per minute while the app is running, reducing the delay after Claude Desktop writes a new valid usage sample.
- Keeps Codex polling unchanged and does not treat an unchanged or stale Claude sample as current.

## 0.1.2 — menu popover positioning fix

- Caps the menu-bar popover height so macOS can keep it attached to the status item.
- Keeps the complete operational view reachable through scrolling without shrinking the independent application window.

## 0.1.1 — updater verification release

- Publishes the first signed update after the 0.1.0 bridge release so GitHub, Sparkle, and Homebrew upgrade paths can be verified end to end.
- Aligns the version reported to the Codex app-server with the installed QuotaTempo version.

## 0.1.0 — stable bridge release

- Adds user-initiated, EdDSA-signed Sparkle update checks while keeping automatic installation disabled.
- Adds guarded appcast and Homebrew Cask generation for stable, Developer ID-signed, Apple-notarized artifacts only.
- Pins the release identity, Sparkle signing account, update feed, and embedded public key verification boundary.
- Adds same-clean-checkout package reproducibility coverage and documents the independent-clone Mach-O UUID boundary.

## 0.1.0-rc.19 — public beta candidate

- Publishes QuotaTempo under the MIT License with public-beta support and update terms.
- Adds a direct download path, public contribution guidance, and GitHub issue templates.
- Aligns the first-run completion label with the visible **Got It** button.
- Carries forward the signed, notarized, and non-owner-tested RC18 application behavior.

## 0.1.0-rc.18 — release candidate

- Keeps the operational popover and independent window within the active screen's visible height while preserving a scrollable small-screen fallback.
- Preserves the implicit Full display mode for existing users and uses Icon only for new installations.
- Refreshes state whenever the menu is presented and restores minimized application windows.

## 0.1.0-rc.17 — superseded before distribution

- Added the focused first-run window, Finder reopen behavior, Icon-only new-install default, and visible display-mode guidance.
- Was superseded by RC18 after small-screen acceptance identified an unreachable popover footer.

## 0.1.0-rc.16 — release candidate

- Restores first-launch login-item registration when macOS reports the main app as `notFound` before its first Background Task Management record exists.
- Avoids constructing the system login-item service for app copies outside the supported system or user Applications folder.

## 0.1.0-rc.15 — unreleased

- Prevents isolated QA and release verification from querying or rewriting the owner's macOS login-item record.
- Enables login launch only from a stable system or user Applications folder and explains when the app must be moved first.
- Marks stale weekly balances with `?`, distinguishes confirmed and one-window-estimated reset explanations, and reports an elapsed reset explicitly even when the observation is stale.

## 0.1.0-rc.14 — unreleased

- Keeps the reset-derived current plan and checkpoint schedule visible after the last observed weekly balance becomes stale.
- Withholds stale-balance differences and available-capacity calculations, and explains that those fields are waiting for a current balance.
- Continues to hide planning data after the known reset expires and preserves the one-window-only estimate boundary.

## 0.1.0-rc.13 — unreleased

- Selects only verified official desktop Codex bundles first, then falls back across a bounded set of compatible local CLI candidates without bypassing provider usage restrictions.
- Distinguishes missing, launch, known-old, protocol, timeout, output-limit, and temporary Codex failures and exposes support-safe installation provenance.
- Bounds and validates normalized local state, preserves the explicit RC12 legacy schema, and treats a missing login-item service as unavailable.
- Pins the QuotaTempo bundle and Developer ID team identities in release metadata and verification.
- Keeps display language separate from regional date ordering and adds a canonical manual-update destination.
- Runs CI for `codex/**` release-development branches as well as `main`.

## 0.1.0-rc.12 — unreleased

- Prefers the current Codex executable bundled with an official desktop app over an older package-manager installation.
- Presents the cached menu state immediately while normalized storage and provider preparation run away from the main actor.
- Explains that Claude Code must supply local reset metadata before QuotaTempo can calculate `P` from a Claude Desktop-only balance.

## 0.1.0-rc.11 — unreleased

- Adds the localized weekday to every detailed date and time, making weekly resets and planning checkpoints easier to distinguish at a glance.

## 0.1.0-rc.10 — unreleased

- Applies the scrollable minimum and maximum height contract to the first-run guide as well as the operational popover, preventing clipped onboarding content and completion actions.
- Adds English and Japanese first-run fixture proofs and compressed-layout regression coverage for both onboarding languages.
- Removes an owner-local rollback path from repository release evidence while keeping the rollback artifact recorded outside the public tree.

## 0.1.0-rc.9 — unreleased

- Shows the provider's weekly reset separately from the next 24-hour planning checkpoint.
- Labels a projected Claude weekly reset as estimated and withholds missing, elapsed, or unsafe reset timestamps.

## 0.1.0-rc.8 — unreleased

- Keeps the operational popover at a usable height after macOS supplies a compressed layout proposal when reopening a long-running menu-bar item.
- Adds a regression test that reproduces the previous 36-point collapsed popover and verifies the minimum content height.

## 0.1.0-rc.7 — unreleased

- Treats recognized-but-empty Claude Desktop and Claude Code usage sources as unavailable rather than malformed, while preserving strict errors for malformed data.
- Restores the stable release pipeline by accepting the required Developer ID-signed, pre-notarization intermediate and requiring notarization only for final public-artifact verification.
- Adds an executable release-policy matrix test and runs it in CI.

## 0.1.0-rc.6 — unreleased

- Treats a valid Claude Desktop-only observation as a successful refresh when the optional Claude Code cache is absent.
- Projects a Claude weekly reset only when the post-reset remaining balance increases, preventing a stale low balance from being attached to a new estimated window.
- Hides a balance from an elapsed quota window and distinguishes that transition from an unknown or implausible reset time.
- Keeps the compact estimated-reset marker attached to the plan basis (`P≈`) rather than the measured weekly balance.
- Adds an in-app **Legal** menu for the bundled license, privacy policy, update policy, third-party notices, and support route.
- Extends release verification to require the bundled third-party notices.

## 0.1.0-rc.5 — unreleased

- Adds a compact first-run guide that explains provider selection, `W`, `P`, `P≈`, and the comparison arrows; it can be reopened from **How to read**.
- Adds an opt-in **Launch at login** control backed by the macOS login-item service. It remains off until the user enables it, treats the system's first-seen `notFound` state as registrable, and reports when System Settings approval is required.
- Adds **Copy diagnostics**, producing a support-safe report with app version and provider acquisition states while excluding quota percentages, reset times, local paths, credentials, and session content.
- Rejects pre-Unix Claude capture timestamps, records safe local-source failure categories, and raises the bounded Claude cache ceiling to match the history source.
- Keeps a fresh weekly balance visible when its reset time is expired or otherwise unusable, while withholding target calculations instead of treating the entire provider as unavailable.
- Adds a scroll-bounded operational view and a Quit action to first-run guidance, removes single-provider menu-bar dead space, and closes subprocess pipes through DispatchSource cancellation handlers.
- Adds application-composition tests for provider selection and login-item settings, reloads the one-minute planning clock away from the main actor, and stores normalized observations with owner-only permissions.
- Minimizes the distributed app by excluding development fixtures and the rollback-only Claude bridge, rejects ad-hoc stable packaging, and adds a non-overwriting notarization/stapling verification path.

## 0.1.0-rc.4 — unreleased

- Let users enable Codex, Claude, or both while requiring at least one provider.
- Remove disabled providers from acquisition, the popover, and the menu-bar label without deleting normalized observations.
- Select previously observed providers on first launch and preserve explicit choices across launches.
- Project Claude's last confirmed weekly reset by one window only and mark the resulting plan as `P≈`.

## 0.1.0-rc.3 — unreleased

- Fail closed when Codex reports a reached rate limit, spend-control restriction, or disallowed ordinary usage even if percentages remain present.
- Disable the unverified Claude CLI quota fallback in the V1 release path after a live `get_usage` check returned no quota windows; retain automatic local Claude Desktop and Claude Code observations.
- Replace third-party provider artwork with neutral SF Symbols and bundle private-beta license, privacy, support, and update terms.
- Add visible refresh progress, app version, privacy, and support links to the popover.
- Gracefully terminate registered provider process trees when the app exits and remove the ineffective post-spawn process-group setup.
- Resolve Codex symlinks before launch, align status thresholds with displayed rounding, keep five-hour risk independent of the weekly window, and harden menu-bar QA startup discovery.
- Explain that `P` is an even seven-day plan; configurable work schedules remain a post-V1 option.

## 0.1.0-rc.2 — unreleased

- Added reset-relative weekly target and checkpoint calculations for Codex and Claude.
- Added bounded Codex app-server and local-first Claude acquisition.
- Added Full, Compact, and Icon only menu-bar modes.
- Added provider marks, English and Japanese copy, source/freshness detail, Refresh, and Quit controls.
- Added low-frequency 15-minute provider refresh and immediate refresh after system wake, independent of whether the popover is open.
- Distinguished a valid weekly observation with an unknown reset from a fully unavailable provider, and retained failed reset-acquisition metadata alongside the usable balance.
- Added an original macOS application icon, deterministic development bundles, RC-specific archive identity, and signed release-candidate packaging verification.
- Made ad-hoc RC archives byte-identical across repeated builds in the same clean checkout by normalizing timestamps and entry order; independent fresh clones are outside this guarantee because the linker may generate different Mach-O UUIDs.
- Added a signed Sparkle update feed and Homebrew Cask generation path that accepts only stable, Developer ID-signed, notarized artifacts after full release verification.
- Kept Sparkle update checks user-initiated and disabled automatic download and installation.
- Hardened provider subprocesses against early-exit SIGPIPE, incomplete process-group termination, and user-managed Codex installation paths.
- Preserved atomic-save failures as visible in-memory acquisition state instead of silently reverting to an older snapshot.
- Aligned popover and menu-bar provider deduplication, accumulated partial bridge input reads, and applied distributable app-bundle permissions.
- Corrected the generated Claude status-line sentinel, preserved valid quota windows when a sibling window is invalid or expired, and bounded post-exit subprocess pipe draining.
- Prevented older Claude observations from replacing newer stored data, made process-tree termination resilient when process-group setup races, and removed development resource lookup's working-directory dependency.
- Serialized subprocess pipe capture through one bounded collector, retained in-memory snapshots as refresh inputs after persistence failure, and corrected the initial Claude state to never-observed.
- Unified rounded comparison values across the popover and menu bar, classified Codex process availability failures correctly, restored legacy snapshot fallback after a malformed named bucket, and retained Claude utilization when only its reset is unusable.
- Applied one wall-clock deadline to nonblocking provider input and process completion, made JSON response detection incremental, moved blocking provider work off the Swift cooperative pool, and added stable missing-settings lifecycle errors.
- Serialized response-triggered standard-input closure with nonblocking writes and guarded process-tree signaling against an already-finished child.
- Preserved a newer Claude observation's own reset, required a weekly Codex window before accepting a named bucket, and kept independent five-hour risk warnings when the weekly reset is unknown.
- Replaced the composite menu-bar image whenever its formatted value changes, so a background reset-time update becomes visible without opening the popover.
- Fixed release packaging with a caller-supplied relative output directory.
