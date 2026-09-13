# Security policy

## Supported version

Security fixes are currently prepared for the public-beta 0.1.x line.

## Reporting

Do not include credentials, tokens, cookies, authentication files, provider responses, prompts, transcripts, or personal quota values in a report. Send a minimal report to [h@ishikawa.co](mailto:h@ishikawa.co). Do not open a public issue containing sensitive reproduction material.

## Security boundaries

QuotaTempo must:

- read only bounded recognized quota metadata;
- reject symlink-selected and oversized local provider inputs;
- keep provider authentication owned by the official provider processes;
- bound child-process time and combined output;
- store only normalized observations;
- protect normalized storage with owner-only directory and file permissions;
- fail closed on malformed, stale, or changed provider data;
- avoid telemetry, browser-cookie access, Keychain access, and session recording.

Release preparation requires tests, static shell checks, deterministic app-bundle verification, code-signature verification, artifact SHA-256 verification, embedded release-metadata matching, developer-path rejection, and a clean source tree. Public distribution additionally requires Developer ID signing and Apple notarization.

Update archives are delivered through Sparkle over the official HTTPS appcast and must carry a valid EdDSA signature for the public key embedded in QuotaTempo. The release workflow uses an explicitly named owner-managed Keychain account and fails before signing if its public key does not match the embedded key. The private update key must never be committed, printed, or passed as a command-line argument. Appcast and Homebrew Cask generation both require a stable, Developer ID-signed, notarized artifact that passes full release verification.
