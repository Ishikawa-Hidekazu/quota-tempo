#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const binary = `${root}dist/desktop-local-probe/QuotaTempoDesktopLocalProbe`;
const required = [
  "--consent-desktop-read-only", "--acknowledge-provider-permission-unconfirmed",
];
// Never include a fully authorized argument vector: this check must remain inert.
const cases = [
  [], [required[0]], [required[1]], ["--request-keychain-access"],
  [required[0], "--request-keychain-access"],
  [...required, "--unexpected"], [...required].reverse(),
  [...required, "--request-keychain-access", "--unexpected"],
];
for (const args of cases) {
  const output = execFileSync(binary, args, {
    cwd: root, encoding: "utf8", timeout: 10_000, maxBuffer: 4096,
  });
  assert.deepEqual(JSON.parse(output), { status: "explicit_local_consent_required" });
}
console.log(`desktop_local_probe_inert_arguments=PASS (${cases.length} cases)`);
