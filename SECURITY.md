# Security policy

## Supported version

Security fixes are currently prepared for the QuotaTempo 0.1.x line.

## Reporting

Do not include credentials, tokens, cookies, authentication files, provider responses, prompts, transcripts, or personal quota values in a report. Send a minimal report to [h@ishikawa.co](mailto:h@ishikawa.co). Do not open a public issue containing sensitive reproduction material.

## Security boundaries

QuotaTempo must:

- validate bounded recognized quota metadata before display;
- reject symlink-selected and oversized local provider inputs;
- leave provider sign-in and credential refresh to the official provider apps;
- keep Automatic acquisition free of credential, cookie and Keychain reads;
- require explicit opt-in consent and a separate user-initiated macOS permission
  action for Desktop authentication access; keep that material in memory only;
- bound child-process time and combined output;
- store only normalized non-Desktop observations, consent/source preferences and
  allowlisted scheduling metadata; never persist Desktop observations or authentication;
- protect normalized storage with owner-only directory and file permissions;
- fail closed on malformed, stale, or changed provider data;
- avoid telemetry and session recording, and never inspect prompts or conversations;
- keep Desktop, browser and local/CLI account observations separate, reject late
  results after revocation, and preserve provider wait deadlines across restarts.

The optional Claude Desktop connection uses bounded reads of Desktop's existing
encrypted authentication, selected organization and protection key, solely for
account validation and usage retrieval. It never writes to those provider stores.
The exact access, consent, retention and removal contract is in [Privacy](PRIVACY.md).
Provider changes may prevent QuotaTempo from retrieving usage data.

Release preparation requires tests, static shell checks, deterministic app-bundle verification, code-signature verification, artifact SHA-256 verification, embedded release-metadata matching, developer-path rejection, and a clean source tree. Public distribution additionally requires Developer ID signing and Apple notarization.

Update archives are delivered through Sparkle over the official HTTPS appcast and must carry a valid EdDSA signature for the public key embedded in QuotaTempo. The release workflow uses an explicitly named owner-managed Keychain account and fails before signing if its public key does not match the embedded key. The private update key must never be committed, printed, or passed as a command-line argument. Appcast and Homebrew Cask generation both require a stable, Developer ID-signed, notarized artifact that passes full release verification.
