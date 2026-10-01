#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const binary = `${root}dist/desktop-local-probe/QuotaTempoDesktopLocalProbe`;
const required = [
  "--consent-desktop-read-only", "--acknowledge-provider-permission-unconfirmed",
];
const application = readFileSync(`${root}scripts/desktop-preview-application.swift`, "utf8");
const entry = readFileSync(`${root}scripts/desktop-candidate-local-probe.swift`, "utf8");
assert.match(application, /item\.menu = menu\.menu/);
assert.doesNotMatch(application, /NSPopover|NSHosting|togglePopover|\.activate\(/);
assert.match(entry, /@MainActor static func main\(\) \{/);
assert.doesNotMatch(entry, /static func main\(\) async/);
// Never include a fully authorized argument vector: this check must remain inert.
const cases = [
  [], [required[0]], [required[1]], ["--request-keychain-access"],
  [required[0], "--request-keychain-access"],
  [...required, "--unexpected"], [...required].reverse(),
  [...required, "--request-keychain-access", "--unexpected"],
  ["--menu-bar-preview"], [required[0], "--menu-bar-preview"],
  [...required, "--menu-bar-preview", "--request-keychain-access"],
  [...required, "--menu-bar-preview", "--unexpected"],
  ["--menu-bar-preview-qa"], [required[1], "--menu-bar-preview-qa"],
  [...required, "--menu-bar-preview-qa", "--request-keychain-access"],
  [...required, "--render-preview-fixtures"],
  ["--render-preview-fixtures"],
];
for (const args of cases) {
  const output = execFileSync(binary, args, {
    cwd: root, encoding: "utf8", timeout: 10_000, maxBuffer: 4096,
  });
  assert.deepEqual(JSON.parse(output), { status: "explicit_local_consent_required" });
}
console.log(`desktop_local_probe_inert_arguments=PASS (${cases.length} cases)`);
