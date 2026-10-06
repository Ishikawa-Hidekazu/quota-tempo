# Code comparison cryptography build

Build-only dependencies are pinned in `package-lock.json`. Install with
`npm ci --ignore-scripts`; no lifecycle scripts are needed. Run `npm run build`
to regenerate `../transport-crypto.mjs` and its third-party notice.
Neither npm nor Node is invoked by the installed Mods plugin.

The browser-targeted bundle uses `hpke` and the pure-JavaScript
`@panva/hpke-noble` adapters with DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
and ChaCha20-Poly1305. Native decryption uses Apple's CryptoKit HPKE.
No custom curve, KDF, AEAD, or HPKE implementation is maintained here.

Safety review (2026-10-06): upstream repositories and npm package identity
match; MIT licenses; runtime dependencies do not require install scripts.
`esbuild-wasm` is build-only. The isolated build is safe-to-try with synthetic
values and no account, auth, provider, transcript, or browser access. An audit
of a Noble release is not an audit of this pinned dependency set or protocol.
The checked-in bundle is locally generated, not remotely loaded at runtime.

Sources: [HPKE](https://github.com/panva/hpke),
[Noble adapters](https://github.com/panva/hpke/tree/v1.1.7/examples/noble-suite),
[Noble](https://github.com/paulmillr/noble-curves),
[esbuild](https://github.com/evanw/esbuild),
[CryptoKit](https://developer.apple.com/documentation/cryptokit/hpke).
