# Fixture-only Prototype

This page records the original fixture-only prototype. The current `QuotaTempo`
app uses live adapters and is not fixture-only. Use `QuotaTempoFixtureRenderer`
for isolated visual proof and the [user guide](user-guide.md) for the normal app.

## Components

- `QuotaTempoCore`: provider-neutral snapshot types, deterministic weekly planning math, localization, and SwiftUI menu content.
- Original `QuotaTempo` prototype: a `MenuBarExtra` shell that loaded the bundled `baseline` fixture; the current app no longer has this fixture-only boundary.
- `QuotaTempoFixtureRenderer`: renders the same SwiftUI menu content to reproducible PNG proof images.
- `QuotaTempoCoreTests`: calculation, state, boundary, localization, and fail-closed tests.

## Fixture matrix

| Fixture | Coverage |
| --- | --- |
| `baseline` | Codex below target, Claude above target, checkpoint detail, percentage points, five-hour immediate constraint |
| `degraded` | Codex unavailable and Claude stale with retained context |
| `on-target` | Exact target and positive 2-point tolerance boundary |
| `all-unavailable` | Both providers unavailable with no comparison values |
| `one-provider` | One fresh Codex provider without an inferred Claude row |
| test-only `malformed-missing-reset` | Missing weekly reset timestamp; decoding fails closed |

Additional tests construct invalid, expired, future-dated, short-duration, exact-checkpoint, final-checkpoint, timezone-offset, and rounding inputs directly against the deterministic core.

## Reproduction

```bash
swift format lint --recursive Package.swift Sources Tests
shellcheck scripts/render-fixture-proof.sh
swift build -c release
bash scripts/test-swift.sh
./scripts/render-fixture-proof.sh
```

Use the wrapper even for filtered tests. With Apple's Command Line Tools, scope
`DEVELOPER_DIR=/Library/Developer/CommandLineTools` to each Swift command as
described in [Contributing](../CONTRIBUTING.md#development).

## Safety boundary

The fixture renderer execution path does not invoke the linked core's network client, provider subprocess, provider-home lookup, credential reader, Keychain access, session reader, telemetry, updater, or persistence layer. Its entry point reads only package-bundled fixture resources. The production app target invokes the separately documented Sparkle updater and local provider adapters; those runtime paths are outside this fixture-only boundary.

The visual and accessibility copy is comparison-only. It does not recommend, select, or route work to a provider.
