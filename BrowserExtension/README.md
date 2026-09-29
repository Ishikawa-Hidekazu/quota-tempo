# QuotaTempo Claude browser bridge prototype

This is an opt-in MV3 Chrome extension prototype. It is disabled until **Connect** is clicked in the popup on an existing `https://claude.ai/` tab. It never opens or focuses a tab. The selected account and organization stay pinned; changing either requires an explicit **Reconnect**. **Disconnect** stops polling and sends a `disconnected` envelope. After Chrome restarts, an enabled connection preserves its pin, connection generation, and sequence. It checks an existing Claude tab before resuming and waits for one to appear if none is available. It does not create a fresh connection generation on startup.

The extension uses an isolated content script to fetch only `/api/account` (before and after), `/api/organizations`, and the sole organization's `/api/organizations/{uuid}/usage`, with the page's existing sign-in context. It requests no cookies permission, reads no cookie/token/credential values, and does not scrape DOM, prompts, or transcripts. Fetches are same-origin, `credentials: include`, `cache: no-store`, `redirect: error`, with a 15-second total timeout and bounded response bodies. These Claude endpoints and response shapes are not a documented third-party API; live compatibility and account-switch behavior have not yet been verified.

Only SHA-256 fingerprints and normalized usage windows cross from the content script to the worker. The worker stores only connection metadata: one stable random `profileID`, a random `connectionID` for each explicit Connect, a persisted sequence, selected tab ID, pinned fingerprints, status, retry timing, and an in-flight request ID. It stores no raw response or usage window. A pending `accountChanged` or `disconnected` retry stores only the value-free control envelope. The native host must independently validate every envelope, pin profile and connection generation, reject old-generation messages after disconnect, and never merge an observation into another profile or account. The native host is bundled with the QuotaTempo app; this directory contains only the extension.

The expected host name is `co.ishikawa.quotatempo`. Each observation uses one `chrome.runtime.sendNativeMessage` call. Every schema-1 envelope includes `profileID`, `connectionID`, a safe nonnegative integer `sequence`, an ISO UTC `observedAt`, status, three nullable fingerprints, and nullable weekly/five-hour windows. Explicit Connect sends value-free `connected` at sequence 0 and waits for `{ "ok": true }` before requesting usage. Each later new message increments and persists the sequence before sending. A missing or invalid ACK is shown as a host error; successful usage is never replayed. A lost ACK for `connected`, `accountChanged`, or `disconnected` can be retried with the exact same value-free envelope, sequence, and timestamp; the native host must ACK exact duplicates idempotently. `accountChanged` retries are bounded to four attempts with 15/30/60/120-second delays, then stop for manual resolution. Explicit Reconnect awaits `disconnected` before creating a new generation. Reinstallation changes `profileID`; a disabled native record can transfer to the new profile through a new `connected` generation. Native replay tombstones are bounded to 128 reconnect cycles; use the installer removal recovery path if the bound record cannot be reused.

## Setup and recovery

Use the final Chrome extension ID, which must be the ID allowed by the native host manifest. These commands do not load or manipulate Chrome; installation and removal are dry runs unless `--apply` is supplied:

```sh
node scripts/install-browser-bridge.mjs --extension-id ID --app /absolute/path/QuotaTempo.app
node scripts/install-browser-bridge.mjs --extension-id ID --app /absolute/path/QuotaTempo.app --apply
```

For corruption or reinstall recovery, inspect the removal dry run first, then explicitly apply it:

```sh
node scripts/install-browser-bridge.mjs --remove
node scripts/install-browser-bridge.mjs --remove --apply
```

Removal deletes only the recognized bridge host manifest, configuration, and normalized browser observation record. It does not repair Chrome or install the extension. Reconnect after reinstall requires a new explicit Connect.

Load `BrowserExtension/` as an unpacked extension in Chrome manually, then use the popup's **Connect** on an existing Claude tab. The setup commands above only register the native host; they do not install the Chrome extension. No Chrome installation or browser interaction is part of this prototype handoff.

`ok` requires one unambiguous all-model weekly window with a finite 0-100 percentage and exact reset in `(now, now + 8 days]`. Input dates may use `Z` or a numeric timezone offset and up to nine fractional digits; output is normalized to UTC milliseconds without estimating a new reset. The optional five-hour window may be absent or null; if present, it must reset within six hours. Equivalent legacy and `limits` windows are accepted only when their normalized percentages and reset timestamps match. Usage keys are `utilization`, `used_percentage`, or `percent`, exactly one per window. Model-scoped windows are ignored. Multiple organizations, conflicting windows, duplicate `limits` buckets, invalid dates, and malformed responses fail closed. Content replies are accepted only for the matching request ID before its 60-second expiry. The content script timestamps fetch completion; the worker preserves that timestamp rather than assigning delivery time. Normal polling is five minutes; failed or missing replies back off to at most 60 minutes, with HTTP 429 starting at 15 minutes. Disabling clears the alarm.

Prototype 0.1.1 displays both popup and worker versions. After updating unpacked files, reload QuotaTempo once in `chrome://extensions`, reopen its popup on a Claude tab, and use **Reconnect**. Both versions must show `0.1.1`. The popup reports a bounded acquisition stage on failure; `responseTimeout` means the selected tab did not deliver a timely content response. Updating files on disk alone does not prove that Chrome has replaced its running worker.

Run synthetic tests without loading the extension or accessing a real account:

```sh
node --test BrowserExtension/tests/*.test.cjs
```

At the September 30 compatibility follow-up, the extension's synthetic Node tests pass (37/37), installer tests pass (81/81), and isolated native-host process tests pass (6/6). The earlier parent integration run passed 281/281 Swift tests; Swift implementation is unchanged in this follow-up. One live browser observation now reached the native host successfully with weekly/five-hour usage and non-estimated provider reset timestamps. The popup showed 0.1.1 but an unknown worker version, so a complete worker reload, automatic refresh, and installed-app display remain unverified. The account parser also accepts a validated email-only identity from `/api/account`, hashes it locally, and never forwards the address. See the [QA record](../docs/browser-bridge-qa-2026-09-29.md) for the remaining release gates.
