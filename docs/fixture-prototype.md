# Fixture-only Prototype

The prototype is a native macOS menu-bar view backed exclusively by bundled JSON fixtures and an injectable clock.

## Components

- `QuotaTempoCore`: provider-neutral snapshot types, deterministic weekly planning math, localization, and SwiftUI menu content.
- `QuotaTempo`: a `MenuBarExtra` shell that loads the bundled `baseline` fixture.
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
swift test
./scripts/render-fixture-proof.sh
```

## Safety boundary

The fixture renderer target contains no network client, provider subprocess, provider-home lookup, credential reader, Keychain access, session reader, telemetry, updater, or persistence layer. It reads only package-bundled fixture resources. The production app target includes the separately documented Sparkle updater and local provider adapters; those components are outside this fixture-only boundary.

The visual and accessibility copy is comparison-only. It does not recommend, select, or route work to a provider.
