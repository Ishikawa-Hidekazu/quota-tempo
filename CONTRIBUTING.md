# Contributing to QuotaTempo

Thanks for helping improve QuotaTempo. Small, focused changes are easiest to review.

## Before opening a change

- Search existing issues before creating a new one.
- Open an issue before starting a large behavioral or architectural change.
- Keep provider acquisition local, bounded, and fail-closed.
- Do not add telemetry, prompt or transcript collection, or automatic provider configuration. Do not expand cookie, credential or Keychain access beyond the explicitly consented [Desktop connection boundary](PRIVACY.md#opt-in-claude-desktop-connection); changes to that boundary require a separate privacy review.

## Development

Requirements: macOS 14 or later and Swift 6.

```bash
bash scripts/test-swift.sh
xcrun swift-format lint --strict --recursive Sources Tests
swift build -c release
bash -n scripts/*.sh
./scripts/test-release-policy.sh
./scripts/test-app-bundle.sh --skip-launch
git diff --check
```

Use the test wrapper for filtered tests as well. When using Apple's Command Line
Tools, scope `DEVELOPER_DIR=/Library/Developer/CommandLineTools` to each Swift
command; do not change the global developer selection or accept an Xcode license
as a test workaround. The wrapper supplies the Swift Testing runtime paths.

Run ShellCheck and actionlint when available. Pull requests should explain the user-visible behavior, safety impact, and verification performed.

## Public reports

Never include credentials, tokens, cookies, provider source files, raw responses, prompts, transcripts, local private paths, or personal quota values in an issue or pull request. Use **Copy diagnostics** in QuotaTempo for the minimal support-safe state.

Security and privacy reports should follow [SECURITY.md](SECURITY.md) instead of a public issue when reproduction details could be sensitive.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
