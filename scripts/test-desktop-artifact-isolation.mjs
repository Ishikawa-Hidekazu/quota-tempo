#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync,
  rmSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const checker = fileURLToPath(new URL("./check-desktop-artifact-isolation.sh", import.meta.url));
const root = fileURLToPath(new URL("../", import.meta.url));
const requiredRefusal = [
  "--desktop-acceptance", "--consent-desktop-read-only",
  "--acknowledge-provider-permission-unconfirmed",
  '{"status":"desktopAcceptanceNotIncluded","passed":false}',
];
// Independent expectations: removing a marker from the checker must fail QA.
const requiredInclusion = [
  "DesktopConnectionController", "DesktopIntegrationControls",
  "desktopConnection.consentRevision", "QuotaTempo-DesktopCandidate/",
  "quotatempo.desktop.account.v1:", "Claude Safe Storage",
  "https://api.anthropic.com/api/oauth/profile", "https://api.anthropic.com/api/oauth/usage",
];
const requiredCodeRefusal = [
  "--code-comparison-startup-validation", "--code-comparison-package-validation",
  '{"status":"startupValidationNotIncluded","passed":false}',
  '{"status":"codePackageValidationNotIncluded","passed":false}',
];
const requiredCodeInclusion = [
  "CodeComparisonIPCBridge", "CodeComparisonEncryption", "CodeComparisonPluginPackage",
  "CodeUsageComparisonController", "CodeUsageComparisonControls",
  "QuotaTempo.CodeComparison.IPC", "QuotaTempo.CodeComparison.response.v3",
];
const required = [...requiredRefusal, ...requiredInclusion, ...requiredCodeRefusal, ...requiredCodeInclusion];
const candidateMarkers = [
  "QuotaTempoDesktopCandidate", "DesktopConnectionController", "DesktopIntegrationControls",
  "DesktopAcceptanceCommand", "DesktopUsageHTTPTransport", "DesktopCredentialLease",
  "desktopConnection.consentRevision", "QuotaTempo-DesktopCandidate/",
  "quotatempo.desktop.account.v1:",
  "Claude Safe Storage", "https://api.anthropic.com/api/oauth/profile",
  "https://api.anthropic.com/api/oauth/usage",
];
const previewOnly = [
  "DesktopAcceptanceCommand", "DesktopAcceptanceRunner", "DesktopAcceptanceConnecting",
  "DesktopCandidateLocalProbe", "DesktopPreviewApplication", "DesktopPreviewModel",
  "DesktopPreviewMenu", "DesktopPreviewInstanceLock", "DesktopPreviewTermination",
  "desktop-local-preview", "desktop-preview.lock", "QuotaTempo.preview-termination",
  "QuotaTempo Desktop Preview",
];
const codeComparisonMarkers = [
  "CodeComparison", "CodeUsageComparison", "CodeComparisonIPCBridge", "CodeComparisonIPCSession",
  "CodeComparisonEncryption", "CodeUsageComparisonController", "CodeUsageComparisonControls",
  "CodeComparisonStartupValidation", "startupValidated",
  "QuotaTempo.CodeComparison.IPC", "QuotaTempo.CodeComparison.response.v3",
  "quotatempo-mods-comparison", "quotatempo-usage-probe", "quotatempo-code-comparison-plugin",
  "quotatempo-code-plugin-management", "probe-grant.json", "bridge.sock",
  "_$s13QuotaTempoApp23CodeComparisonIPCBridgeCMa",
];
const codePreviewOnly = [
  "CodeComparisonStartupValidation", "CodeComparisonPackageValidation", "CodeComparisonOfficialWireTests",
  "startupValidated", "startupValidationDeadlineExceeded", "packageValidationDeadlineExceeded", "packageValidated",
];
const packageFiles = [
  ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json", "hooks/register.mjs",
  "producer.mjs", "protocol.mjs", "transport-crypto.mjs", "THIRD_PARTY_NOTICES.txt",
];
const toolFiles = ["manage-code-comparison-plugin.mjs", "package-code-comparison-plugin.mjs"];
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const allowed = [
  "Claude Desktop", "claudeDesktopHistory", "Library/Application Support/Claude",
  "--code-comparison-startup-validation",
  '{"status":"startupValidationNotIncluded","passed":false}',
];

function fixture(t) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), "QuotaTempo Artifact QA ")));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const app = join(directory, "Public App.app");
  const main = join(app, "Contents/MacOS/QuotaTempo");
  const host = join(app, "Contents/MacOS/QuotaTempoBrowserHost");
  const bin = join(directory, "bin");
  const temporary = join(directory, "tmp");
  const home = join(directory, "home");
  for (const path of [bin, temporary, home, dirname(main), join(app, "Contents/Resources")]) {
    mkdirSync(path, { recursive: true });
  }
  for (const path of [app, join(app, "Contents"), join(app, "Contents/Resources")]) chmodSync(path, 0o755);
  const packageRoot = join(app, "Contents/Resources/CodeComparisonPlugin");
  for (const path of [packageRoot, join(packageRoot, ".claude-plugin"), join(packageRoot, "hooks")]) {
    mkdirSync(path, { mode: 0o755 });
  }
  const native = readFileSync(join(root, "Sources/QuotaTempoApp/CodeComparisonPluginPackage.swift"), "utf8");
  const marketplace = native.match(/static let nativeMarketplaceName = "([^"]+)"/)[1];
  writeFileSync(join(app, "Contents/Info.plist"), readFileSync(join(root, "packaging/Info.plist")), { mode: 0o644 });
  const packageBytes = Object.fromEntries(packageFiles.map(file => [file,
    readFileSync(join(root, "experiments/claude-mods-usage", file))]));
  const market = JSON.parse(packageBytes[packageFiles[1]].toString("utf8"));
  packageBytes[packageFiles[1]] = Buffer.from(JSON.stringify({ ...market, name: marketplace }, null, 2) + "\n");
  for (const file of packageFiles) writeFileSync(join(packageRoot, file), packageBytes[file], { mode: 0o644 });
  writeFileSync(join(packageRoot, "quotatempo-package.json"), JSON.stringify({
    schemaVersion: 1, purpose: "quotatempo-code-comparison-plugin", releaseVersion: "0.0.4",
    files: Object.fromEntries(packageFiles.map(file => [file, hash(packageBytes[file])])),
  }, null, 2) + "\n", { mode: 0o644 });
  const toolRoot = join(app, "Contents/Resources/CodePluginTools");
  mkdirSync(toolRoot, { mode: 0o755 });
  for (const tool of toolFiles) writeFileSync(join(toolRoot, tool), readFileSync(join(root, "scripts", tool)), { mode: 0o644 });
  for (const [name, path] of Object.entries({
    grep: "/usr/bin/grep", find: "/usr/bin/find", mktemp: "/usr/bin/mktemp", rm: "/bin/rm",
    node: process.execPath,
    dirname: "/usr/bin/dirname",
    plutil: "/usr/bin/plutil",
  })) symlinkSync(path, join(bin, name));
  function artifact(path, markers, mode = 0o755) {
    mkdirSync(dirname(path), { recursive: true });
    // NUL-delimited binary bytes, never a runnable fixture or a Swift build.
    writeFileSync(path, Buffer.concat([
      Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 0]),
      Buffer.from(markers.join("\0") + "\0", "utf8"),
    ]));
    chmodSync(path, mode);
  }
  artifact(main, [...required, ...allowed]);
  artifact(host, allowed);
  writeFileSync(join(app, "Contents/Resources/PRIVACY.md"),
    [...candidateMarkers, ...previewOnly, ...codeComparisonMarkers].join("\n"), { mode: 0o644 });
  const run = (args = [app]) => {
    // No inherited HOME, credentials, shell hooks, or fallback PATH. In
    // particular, no Swift, UI, browser, signing or network tool is available.
    const result = spawnSync("/bin/bash", [checker, ...args], {
      cwd: home, env: { PATH: bin, HOME: home, TMPDIR: temporary, LC_ALL: "C" },
      encoding: "utf8", timeout: 10_000, maxBuffer: 65_536,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    assert.deepEqual(readdirSync(temporary), [], "Inspection must clean up its file manifest");
    return result;
  };
  const stub = (name, body) => {
    rmSync(join(bin, name));
    writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  };
  return { app, main, host, bin, packageRoot, toolRoot, artifact, run, stub };
}

function rejected(result, message) {
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.doesNotMatch(result.stdout, /desktop_compiled_artifact_isolation=PASS/);
  if (message) assert.match(result.stderr, message);
}

test("normal opt-in connection, reserved refusal and legacy history coexist; documentation is not code", (t) => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "desktop_compiled_artifact_isolation=PASS\n");
});

test("shared implementation is allowed in the main binary, including unstripped symbols", (t) => {
  const f = fixture(t);
  f.artifact(f.main, [...required, ...candidateMarkers.filter((marker) => marker !== "DesktopAcceptanceCommand"),
    "_$s26QuotaTempoDesktopCandidate27DesktopConnectionControllerCMa",
    "DesktopPreviewServing", "DesktopPreviewPresentation", "QuotaTempoDesktopPreview"]);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "desktop_compiled_artifact_isolation=PASS\n");
});

for (const marker of requiredRefusal) {
  test(`missing public refusal marker: ${marker}`, (t) => {
    const f = fixture(t);
    f.artifact(f.main, required.filter((item) => item !== marker));
    // A marker in the host or docs cannot satisfy the main binary's contract.
    f.artifact(f.host, [marker]);
    rejected(f.run(), /Public Desktop refusal marker missing/);
  });
}

for (const marker of requiredInclusion) {
  test(`missing main connection inclusion marker: ${marker}`, (t) => {
    const f = fixture(t);
    f.artifact(f.main, required.filter((item) => item !== marker));
    // Presence elsewhere cannot substitute for inclusion in the main binary.
    f.artifact(f.host, [marker]);
    rejected(f.run(), /Desktop connection inclusion marker missing/);
  });
}
for (const [markers, message] of [[requiredCodeRefusal, /Public Code refusal marker missing/],
  [requiredCodeInclusion, /Code comparison inclusion marker missing/]]) {
  for (const marker of markers) test(`missing main Code contract: ${marker}`, (t) => {
    const f = fixture(t);
    f.artifact(f.main, required.filter(item => item !== marker));
    f.artifact(f.host, [marker]);
    rejected(f.run(), message);
  });
}
test("normal Code implementations and optional tools are allowed only in their canonical locations", (t) => {
  const f = fixture(t);
  f.artifact(f.main, [...required, ...codeComparisonMarkers.filter(marker => !codePreviewOnly.includes(marker))]);
  assert.equal(f.run().status, 0);
});
for (const marker of codePreviewOnly) test(`Code preview implementation in main: ${marker}`, (t) => {
  const f = fixture(t);
  f.artifact(f.main, [...required, marker]);
  rejected(f.run(), /Code comparison implementation found/);
});

test("a legacy main with only reserved refusal markers must not pass", (t) => {
  const f = fixture(t);
  f.artifact(f.main, [...requiredRefusal, ...allowed]);
  rejected(f.run(), /Desktop connection inclusion marker missing/);
});

for (const marker of previewOnly) {
  test(`preview-only implementation in main binary: ${marker}`, (t) => {
    const f = fixture(t);
    f.artifact(f.main, [...required, marker]);
    rejected(f.run(), /Desktop preview-only implementation found/);
  });
}

for (const [path, mode] of [
  ["Contents/MacOS/QuotaTempoBrowserHost", 0o755],
  ["Contents/Helpers/unstripped helper", 0o755],
  ["Contents/Resources/group executable", 0o410],
  ["Contents/Resources/other executable", 0o401],
  ["Contents/Frameworks/Hidden.framework/Versions/A/Hidden", 0o644],
  ["Contents/Resources/hidden\ncode.o", 0o644],
  ["Contents/Resources/hidden.a", 0o644],
  ["Contents/Resources/hidden.so", 0o644],
  ["Contents/Frameworks/hidden.dylib", 0o644],
]) {
  for (const marker of codeComparisonMarkers) {
    test(`Code comparison leak ${marker} in ${JSON.stringify(path)}`, (t) => {
      const f = fixture(t);
      f.artifact(join(f.app, path), [...(path.endsWith("MacOS/QuotaTempo") ? required : []), marker], mode);
      rejected(f.run(), /Code comparison implementation found/);
    });
  }
}

const pluginMaterialPaths = [
  "Contents/Resources/CodeComparisonPlugin", "Contents/Resources/CodeComparisonPlugin/THIRD_PARTY_NOTICES.txt",
  "Contents/Resources/CodePluginTools", "Contents/Resources/nested/CodePluginTools/module.mjs",
  "Contents/Resources/nested/CodeComparisonPlugin/producer.mjs",
  "Contents/Resources/.claude-plugin", "Contents/Resources/nested/.claude-plugin/plugin.json",
  "Contents/Resources/plugin.json", "Contents/Resources/marketplace.json",
  "Contents/Resources/quotatempo-package.json", "Contents/Resources/hooks/hooks.json",
  "Contents/Resources/producer.mjs", "Contents/Resources/deep/module\nname.mjs",
  "Contents/Helpers/module.mjs", "Contents/Resources/.quotatempo-code-plugin-management",
  "Contents/Resources/probe-grant.json", "Contents/Resources/bridge.sock",
  "Contents/Resources/CodeComparisonIPC.swift", "Contents/Resources/CodeUsageComparison.swift",
  "Contents/Resources/CodeComparisonStartupValidation.swift",
  "Contents/Resources/CodeComparisonStartupValidationTests.swift",
  "Contents/Resources/Other.swift", "Contents/Resources/test-code-comparison-startup.js",
  "Contents/Resources/official-ipc-client.js", "Contents/Resources/node_modules",
  "Contents/Resources/crypto-build", "Contents/Resources/.git",
  "Contents/Resources/CodeComparison", "Contents/Resources/CodeComparisonIPC", "Contents/Resources/CodeComparisonPlugins",
];
for (const path of pluginMaterialPaths) {
  for (const kind of ["file", "directory", "symlink", "dangling-symlink"]) {
    test(`plugin material ${kind} fails closed: ${JSON.stringify(path)}`, (t) => {
      const f = fixture(t);
      const destination = join(f.app, path);
      rmSync(destination, { recursive: true, force: true });
      mkdirSync(dirname(destination), { recursive: true });
      if (kind === "file") writeFileSync(destination, "{}", { mode: 0o644 });
      else if (kind === "directory") mkdirSync(destination);
      else symlinkSync(kind === "symlink" ? f.host : join(f.app, "absent"), destination);
      rejected(f.run(), /Code comparison plugin material found|invalid_public_code_resources|ENOENT/);
    });
  }
}

test("normal browser JS, JSON manifests and documents do not trigger the plugin-material gate", (t) => {
  const f = fixture(t);
  for (const path of [
    "Contents/Resources/BrowserExtension/manifest.json", "Contents/Resources/BrowserExtension/worker.js",
    "Contents/Resources/BrowserExtension/protocol.js", "Contents/Resources/BrowserExtension/popup.js",
    "Contents/Resources/BrowserExtension/content.js", "Contents/Resources/BrowserExtension/popup.html",
    "Contents/Resources/BrowserBridge/native-messaging.json", "Contents/Resources/UPDATES.md",
  ]) {
    const destination = join(f.app, path);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, "QuotaTempoBrowserHost\nclaude.ai\n", { mode: 0o644 });
  }
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
});

for (const [name, mutate] of [
  ["missing immutable plugin", f => rmSync(f.packageRoot, { recursive: true })],
  ["missing optional tools", f => rmSync(f.toolRoot, { recursive: true })],
  ["extra plugin file", f => writeFileSync(join(f.packageRoot, "debug.js"), "synthetic", { mode: 0o644 })],
  ["extra plugin directory", f => mkdirSync(join(f.packageRoot, "unexpected"))],
  ["extra plugin hook", f => writeFileSync(join(f.packageRoot, "hooks/extra.mjs"), "synthetic", { mode: 0o644 })],
  ["extra tool", f => writeFileSync(join(f.toolRoot, "debug.mjs"), "synthetic", { mode: 0o644 })],
  ["modified tool", f => writeFileSync(join(f.toolRoot, toolFiles[0]), "synthetic")],
  ["modified payload", f => writeFileSync(join(f.packageRoot, "producer.mjs"), "synthetic")],
  ["writable package", f => chmodSync(f.packageRoot, 0o777)],
  ["private package modes in public artifact", f => chmodSync(f.packageRoot, 0o700)],
  ["executable tool", f => chmodSync(join(f.toolRoot, toolFiles[0]), 0o755)],
  ["private payload mode", f => chmodSync(join(f.packageRoot, "producer.mjs"), 0o600)],
  ["symlink package directory", f => {
    rmSync(join(f.packageRoot, "hooks"), { recursive: true });
    symlinkSync(f.toolRoot, join(f.packageRoot, "hooks"));
  }],
  ["symlink tool", f => {
    rmSync(join(f.toolRoot, toolFiles[0]));
    symlinkSync(join(root, "scripts", toolFiles[0]), join(f.toolRoot, toolFiles[0]));
  }],
  ["self-consistent replacement manifest is not the compiled pin", f => {
    const file = join(f.packageRoot, "producer.mjs");
    writeFileSync(file, "synthetic replacement");
    const manifestPath = join(f.packageRoot, "quotatempo-package.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.files["producer.mjs"] = hash(readFileSync(file));
    writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
  }],
  ["signed digest declaration mismatch", f => {
    const file = join(f.app, "Contents/Info.plist");
    writeFileSync(file, readFileSync(file, "utf8").replace(/22024700344b34c645f47906425d90a375a46e14c1e3e17c90a729393215766c/g, "0".repeat(64)));
  }],
  ["wrong release signing team declaration", f => {
    const file = join(f.app, "Contents/Info.plist");
    writeFileSync(file, readFileSync(file, "utf8").replace("<string>local-ad-hoc</string>",
      "<string>developer-id</string><key>QTCodeComparisonSigningTeam</key><string>WRONGTEAM1</string>"));
  }],
  ["preview identity must not become a public release", f => {
    const file = join(f.app, "Contents/Info.plist");
    writeFileSync(file, readFileSync(file, "utf8").replace("co.ishikawa.QuotaTempo</string>", "co.ishikawa.QuotaTempo.CodeComparisonPreview</string>"));
  }],
]) test(`public resource rejection: ${name}`, t => {
  const f = fixture(t);
  mutate(f);
  rejected(f.run(), /invalid_public_code_resources|ENOENT/);
});

test("candidate Swift mangled symbol is rejected without demangling", (t) => {
  const f = fixture(t);
  f.artifact(f.host, ["_$s26QuotaTempoDesktopCandidate27DesktopConnectionControllerCMa"]);
  rejected(f.run(), /Desktop candidate or preview-only implementation found/);
});

for (const [path, mode] of [
  ["Contents/MacOS/QuotaTempoBrowserHost", 0o755],
  ["Contents/Helpers/nested candidate", 0o700],
  ["Contents/Resources/hidden executable", 0o410],
  ["Contents/Resources/other executable", 0o401],
  ["Contents/Frameworks/Candidate.framework/Versions/A/Candidate", 0o755],
  ["Contents/Frameworks/Candidate.framework/Versions/B/Candidate", 0o644],
  ["Contents/MacOS/unexpected-code", 0o644],
  ["Contents/Frameworks/libCandidate.dylib", 0o644],
  ["Contents/Resources/candidate.so", 0o644],
  ["Contents/Resources/candidate.a", 0o644],
  ["Contents/Resources/candidate\nobject.o", 0o644],
]) {
  for (const marker of new Set([...candidateMarkers, ...previewOnly])) {
    test(`isolated leak ${marker} in ${JSON.stringify(path)}`, (t) => {
      const f = fixture(t);
      // Exactly one leak per case: no other marker can accidentally mask a gap.
      f.artifact(join(f.app, path), [marker], mode);
      rejected(f.run(), /Desktop candidate or preview-only implementation found/);
    });
  }
  test(`clean nested artifact remains allowed: ${JSON.stringify(path)}`, (t) => {
    const f = fixture(t);
    f.artifact(join(f.app, path), allowed, mode);
    const result = f.run();
    assert.equal(result.status, 0, result.stderr);
  });
}

test("another artifact named QuotaTempo is not exempted as the main binary", (t) => {
  const f = fixture(t);
  f.artifact(join(f.app, "Contents/Helpers/QuotaTempo"), [...requiredRefusal, ...requiredInclusion]);
  rejected(f.run(), /Desktop candidate or preview-only implementation found/);
});
test("a second artifact named QuotaTempo cannot acquire Code comparison", (t) => {
  const f = fixture(t);
  f.artifact(join(f.app, "Contents/Helpers/QuotaTempo"), requiredCodeInclusion);
  rejected(f.run(), /Code comparison implementation found/);
});

for (const name of ["main", "host"]) {
  for (const kind of ["missing", "directory", "symlink", "non-executable"]) {
    test(`${kind} ${name} executable fails closed`, (t) => {
      const f = fixture(t);
      if (kind === "non-executable") chmodSync(f[name], 0o644);
      else {
        rmSync(f[name]);
        if (kind === "directory") mkdirSync(f[name]);
        if (kind === "symlink") symlinkSync(f[name === "main" ? "host" : "main"], f[name]);
      }
      rejected(f.run(), /Missing regular bundle executable/);
    });
  }
}

for (const tool of ["grep", "find", "mktemp", "node", "plutil"]) {
  test(`missing ${tool} fails closed`, (t) => {
    const f = fixture(t);
    rmSync(join(f.bin, tool));
    rejected(f.run());
  });
}

test("grep error after emitting an apparent refusal match fails closed", (t) => {
  const f = fixture(t);
  f.stub("grep", "printf '%s\\n' '--desktop-acceptance'\nexit 2");
  rejected(f.run(), /Unable to inspect Public Desktop refusal/);
});

test("grep error after emitting an apparent inclusion match fails closed", (t) => {
  const f = fixture(t);
  f.stub("grep", `for arg in "$@"; do
  if [[ "$arg" == DesktopConnectionController ]]; then
    printf '%s\\n' DesktopConnectionController
    exit 2
  fi
done
exec /usr/bin/grep "$@"`);
  rejected(f.run(), /Unable to inspect Desktop connection inclusion/);
});

test("grep error during main preview exclusion fails closed", (t) => {
  const f = fixture(t);
  f.stub("grep", `for arg in "$@"; do
  if [[ "$arg" == DesktopAcceptanceCommand ]]; then exit 2; fi
done
exec /usr/bin/grep "$@"`);
  rejected(f.run(), /Unable to inspect compiled artifact/);
});

test("grep error during Code exclusion fails closed", (t) => {
  const f = fixture(t);
  f.stub("grep", `for arg in "$@"; do
  if [[ "$arg" == CodeComparisonStartupValidation ]]; then exit 2; fi
done
exec /usr/bin/grep "$@"`);
  rejected(f.run(), /Unable to inspect Code comparison artifact/);
});

test("grep error during candidate exclusion fails closed", (t) => {
  const f = fixture(t);
  f.stub("grep", `for arg in "$@"; do
  if [[ "$arg" == QuotaTempoDesktopCandidate ]]; then exit 2; fi
done
exec /usr/bin/grep "$@"`);
  rejected(f.run(), /Unable to inspect compiled artifact/);
});

test("candidate beyond the first read buffer is still rejected", (t) => {
  const f = fixture(t);
  f.artifact(f.host, ["A".repeat(262_144), "QuotaTempo-DesktopCandidate/0.1"]);
  rejected(f.run(), /Desktop candidate or preview-only implementation found/);
});

test("preview implementation beyond the first read buffer in main is rejected", (t) => {
  const f = fixture(t);
  f.artifact(f.main, [...required, "A".repeat(262_144), "DesktopAcceptanceCommand"]);
  rejected(f.run(), /Desktop preview-only implementation found/);
});

test("Code IPC beyond the first read buffer is still rejected", (t) => {
  const f = fixture(t);
  f.artifact(f.host, ["A".repeat(262_144), "QuotaTempo.CodeComparison.IPC"]);
  rejected(f.run(), /Code comparison implementation found/);
});

test("all grep checks require complete reads, not early match exits", (t) => {
  const f = fixture(t);
  f.stub("grep", `for arg in "$@"; do
  case "$arg" in -q*|-m*|--quiet|--silent|--max-count*) exit 2 ;; esac
done
exec /usr/bin/grep "$@"`);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
});

test("a disappearing artifact fails closed", (t) => {
  const f = fixture(t);
  f.stub("find", `printf '%s\\0' "$1/MacOS/QuotaTempo" "$1/missing.dylib"`);
  rejected(f.run(), /Unable to inspect compiled artifact/);
});

test("find error after a partial file listing fails closed", (t) => {
  const f = fixture(t);
  f.stub("find", 'printf "%s\\0" "$1/MacOS/QuotaTempo"\nexit 2');
  rejected(f.run());
});

test("empty find output fails closed", (t) => {
  const f = fixture(t);
  f.stub("find", "exit 0");
  rejected(f.run(), /No compiled bundle artifacts found/);
});

test("an unterminated find record fails closed", (t) => {
  const f = fixture(t);
  f.stub("find", 'printf "%s\\0%s\\0%s" "$1/MacOS/QuotaTempo" "$1/MacOS/QuotaTempoBrowserHost" "$1/unread.dylib"');
  rejected(f.run(), /Incomplete compiled artifact listing/);
});

for (const missing of ["QuotaTempo", "QuotaTempoBrowserHost"]) {
  test(`find must enumerate the required ${missing} executable`, (t) => {
    const f = fixture(t);
    const remaining = missing === "QuotaTempo" ? "QuotaTempoBrowserHost" : "QuotaTempo";
    f.stub("find", `printf '%s\\0' "$1/MacOS/${remaining}"`);
    rejected(f.run(), /Required executables missing from compiled artifact listing/);
  });
}

test("mktemp failure fails closed", (t) => {
  const f = fixture(t);
  f.stub("mktemp", "exit 2");
  rejected(f.run());
});

test("cleanup utility failure cannot report a pass", (t) => {
  const f = fixture(t);
  f.stub("rm", '/bin/rm "$@"\nexit 2');
  rejected(f.run());
});

test("invalid arguments fail closed", (t) => {
  const f = fixture(t);
  for (const args of [[], [""], ["missing.app"], [f.app, "--skip"]]) {
    rejected(f.run(args), /Usage:/);
  }
});

test("both bundle and release QA check artifacts even when launch is skipped", () => {
  for (const [name, calls] of [
    ["test-app-bundle.sh", ['bash "$repo_root/scripts/check-desktop-artifact-isolation.sh" "$first"',
      'bash "$repo_root/scripts/check-desktop-artifact-isolation.sh" "$second"']],
    ["verify-release.sh", ['bash "$(dirname "$0")/check-desktop-artifact-isolation.sh" "$app"']],
  ]) {
    const source = readFileSync(new URL(`./${name}`, import.meta.url), "utf8");
    for (const call of calls) {
      assert(source.includes(`\n${call}\n`), `${name} must run the artifact gate unconditionally`);
      assert(source.indexOf(call) < source.indexOf('if [[ "$skip_launch" == false ]]'));
    }
    assert.match(source, /set -euo pipefail/);
  }
});
