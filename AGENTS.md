# Development verification

- Run Swift tests through `bash scripts/test-swift.sh`, including filtered tests
  and tests in temporary checkouts. Do not bypass the wrapper with `swift test`.
- When using Apple's Command Line Tools, scope `DEVELOPER_DIR` to that command.
  The wrapper adds both Swift Testing runtime paths. Missing
  `lib_TestingInterop.dylib` causes `swiftpm-testing-helper` to abort and can show
  a crash dialog even for a synthetic, network-free test.
- Do not accept an Xcode license, change the global developer selection, or
  disable crash reporting as a test workaround.
- Normal Desktop integration is explicitly opt-in. Follow the current
  release scope in `docs/claude-acquisition-research.md`, including signed-app
  acceptance, source isolation and distribution verification. Synthetic QA does
  not establish native acceptance or provider approval. The separate preview
  and headless acceptance entry point must stay out of public artifacts.
