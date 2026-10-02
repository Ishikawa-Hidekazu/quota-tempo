# Development verification

- Run Swift tests through `bash scripts/test-swift.sh`, including filtered tests
  and tests in temporary checkouts. Do not bypass the wrapper with `swift test`.
- When using Apple's Command Line Tools, scope `DEVELOPER_DIR` to that command.
  The wrapper adds both Swift Testing runtime paths. Missing
  `lib_TestingInterop.dylib` causes `swiftpm-testing-helper` to abort and can show
  a crash dialog even for a synthetic, network-free test.
- Do not accept an Xcode license, change the global developer selection, or
  disable crash reporting as a test workaround.
- Desktop integration remains a local preview until the release gates in
  `docs/claude-acquisition-research.md` are satisfied. Synthetic QA does not
  establish signed-app acceptance or provider permission.
