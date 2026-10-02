#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const args = process.argv.slice(2);
assert.ok(args.length === 0 || (args.length === 1
  && ["--validation-only", "--repair-synthetic-only"].includes(args[0])));
const binary = `${root}dist/desktop-local-probe/${args.length ? "validation/" : ""}QuotaTempoDesktopLocalProbe`;
const required = [
  "--consent-desktop-read-only", "--acknowledge-provider-permission-unconfirmed",
];
const application = readFileSync(`${root}scripts/desktop-preview-application.swift`, "utf8");
const entry = readFileSync(`${root}scripts/desktop-candidate-local-probe.swift`, "utf8");
assert.match(application, /item\.menu = menu\.menu/);
assert.doesNotMatch(application, /NSPopover|NSHosting|togglePopover|\.activate\(/);
assert.match(entry, /@MainActor static func main\(\) \{/);
assert.doesNotMatch(entry, /static func main\(\) async/);

// Compile only the actual repair handler against a synthetic store. No real
// helper, store, credentials, transport, or provider UI is linked or invoked.
const store = readFileSync(
  `${root}Sources/QuotaTempoDesktopCandidate/DesktopThrottleStore.swift`, "utf8");
const declarations = ["DesktopThrottleStoreError", "DesktopThrottleRecoveryResult"].map((name) => {
  const match = store.match(new RegExp(`enum ${name}:[^\\n]+ \\{\\n[\\s\\S]*?\\n\\}`));
  assert.ok(match, `missing ${name}`);
  return match[0];
});
const repairStart = entry.indexOf("    if repair {\n");
const repairEnd = entry.indexOf("    let throttleStore:", repairStart);
assert.ok(repairStart >= 0 && repairEnd > repairStart);
const repairCases = [
  ["notNeeded", "scheduling_state_fresh_no_repair_needed"],
  ["preserved", "scheduling_state_preserved"],
  ["repaired", "scheduling_state_repaired_recheck_required"],
  ["unsupportedVersion", "scheduling_state_requires_newer_version"],
  ["locked", "scheduling_repair_unavailable_close_preview_first"],
  ["unsafePath", "scheduling_repair_unsafe_path"],
  ["invalidRecord", "scheduling_repair_invalid_record"],
  ["ioFailure", "scheduling_repair_io_failure"],
  ["unavailable", "scheduling_repair_unavailable"],
  ["missingRecord", "scheduling_repair_missing_record"],
  ["changed", "scheduling_repair_changed"],
  ["inputTooLarge", "scheduling_repair_input_too_large"],
  ["unknown", "scheduling_repair_unavailable"],
];
const fixture = mkdtempSync(join(tmpdir(), "QuotaTempo-Repair-Handler-Synthetic-"));
try {
  const source = join(fixture, "repair.swift");
  const executable = join(fixture, "repair-synthetic");
  writeFileSync(source, `import Foundation
${declarations.join("\n")}
enum DesktopThrottleFileStore {
  static func recoverApplicationSupport(now: Date) throws -> DesktopThrottleRecoveryResult {
    switch CommandLine.arguments[1] {
${repairCases.slice(0, 4).map(([name]) => `    case "${name}": return .${name}`).join("\n")}
${repairCases.slice(4, -1).map(([name]) => `    case "${name}": throw DesktopThrottleStoreError.${name}`).join("\n")}
    default: throw NSError(domain: "synthetic-private-diagnostic", code: 1)
    }
  }
}
@main struct RepairSynthetic {
  static func main() {
    let repair = true
${entry.slice(repairStart, repairEnd)}
    fatalError("repair handler must return")
  }
}
`);
  execFileSync("xcrun", ["swiftc", "-swift-version", "6", "-parse-as-library", source, "-o", executable], {
    cwd: fixture, encoding: "utf8", timeout: 120_000,
  });
  for (const [name, status] of repairCases) {
    const output = execFileSync(executable, [name], {
      cwd: fixture, encoding: "utf8", timeout: 10_000, maxBuffer: 4096,
    });
    assert.deepEqual(JSON.parse(output), { status });
  }
} finally {
  rmSync(fixture, { recursive: true, force: true });
}
console.log(`desktop_local_probe_synthetic_repair=PASS (${repairCases.length} cases)`);
if (args[0] === "--repair-synthetic-only") process.exit(0);

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
  ["--keychain-status-only"], ["--recheck-connection-once"],
  [required[0], "--recheck-connection-once"],
  [...required, "--recheck-connection-once", "--unexpected"],
  ["--repair-scheduling-state"], [required[0], "--repair-scheduling-state"],
  [...required, "--repair-scheduling-state", "--unexpected"],
];
for (const args of cases) {
  const output = execFileSync(binary, args, {
    cwd: root, encoding: "utf8", timeout: 10_000, maxBuffer: 4096,
  });
  assert.deepEqual(JSON.parse(output), { status: "explicit_local_consent_required" });
}
console.log(`desktop_local_probe_inert_arguments=PASS (${cases.length} cases)`);
