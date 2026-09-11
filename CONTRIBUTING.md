# Contributing to QuotaTempo

Thanks for helping improve QuotaTempo. Small, focused changes are easiest to review.

## Before opening a change

- Search existing issues before creating a new one.
- Open an issue before starting a large behavioral or architectural change.
- Keep provider acquisition local, bounded, and fail-closed.
- Do not add telemetry, browser-cookie access, credential access, prompt or transcript collection, or automatic provider configuration.

## Development

Requirements: macOS 14 or later and Swift 6.

```bash
swift test
xcrun swift-format lint --strict --recursive Sources Tests
swift build -c release
bash -n scripts/*.sh
./scripts/test-release-policy.sh
./scripts/test-app-bundle.sh --skip-launch
git diff --check
```

Run ShellCheck and actionlint when available. Pull requests should explain the user-visible behavior, safety impact, and verification performed.

## Public reports

Never include credentials, tokens, cookies, provider source files, raw responses, prompts, transcripts, local private paths, or personal quota values in an issue or pull request. Use **Copy diagnostics** in QuotaTempo for the minimal support-safe state.

Security and privacy reports should follow [SECURITY.md](SECURITY.md) instead of a public issue when reproduction details could be sensitive.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
