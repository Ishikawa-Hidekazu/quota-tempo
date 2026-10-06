import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { packPlugin, PLUGIN_FILES } from "./package-code-comparison-plugin.mjs";
import { applyManagement } from "./manage-code-comparison-plugin.mjs";

// Opt-in official CLI test, never a normal-user plugin/configuration operation.
const executable = process.argv[2];
const checksum = "03d66745e3bb69ec727d66023696f3820bc0a00a8a5ba725eb6706d0c67cbe69";
if (process.platform !== "darwin" || !executable || !path.isAbsolute(executable)) {
  console.error("Use on macOS with the verified official 2.1.289 darwin-arm64 binary path.");
  process.exit(1);
}
const binary = fs.lstatSync(executable);
assert.ok(binary.isFile() && !binary.isSymbolicLink() && binary.uid === process.getuid());
assert.equal(createHash("sha256").update(fs.readFileSync(executable)).digest("hex"), checksum);
execFileSync("/usr/bin/codesign", ["--verify", "--strict", executable], { stdio: "ignore" });

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../experiments/claude-mods-usage");
const root = fs.mkdtempSync("/private/tmp/quotatempo-lifecycle-fixture-");
fs.chmodSync(root, 0o700);
const home = path.join(root, "home"), project = path.join(root, "project");
fs.mkdirSync(home, { mode: 0o700 }); fs.mkdirSync(project, { mode: 0o700 });
const originalHome = fs.realpathSync(os.homedir());
const policy = `(version 1) (allow default) (deny network*)
  (deny file-read* file-write* (subpath ${JSON.stringify(originalHome)}))`;
const env = { HOME: home, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "en_US.UTF-8",
  TMPDIR: root, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", DISABLE_AUTOUPDATER: "1" };
const calls = [];
const runner = async (file, argv, cwd) => {
  assert.equal(file, executable);
  assert.equal(cwd, project);
  if (argv[0] !== "--version" && argv[1] !== "validate") {
    assert.equal(argv[0], "plugin");
    assert.deepEqual(argv.slice(argv.indexOf("--scope"), argv.indexOf("--scope") + 2), ["--scope", "local"]);
  }
  calls.push(argv[0] === "--version" ? "version" : argv.slice(0, 3).join(" "));
  try {
    const stdout = execFileSync("/usr/bin/sandbox-exec", ["-p", policy, file, ...argv], {
      cwd, env, encoding: "utf8", timeout: 60000, maxBuffer: 262144, stdio: ["ignore", "pipe", "pipe"] });
    if (argv[0] === "--version") return { ok: /^2\.1\.289 \(Claude Code\)\s*$/.test(stdout) };
    return { ok: true };
  } catch { return { ok: false }; }
};

try {
  const packageDirectory = path.join(root, "v1");
  await packPlugin({ source, destination: packageDirectory });
  assert.equal((await runner(executable, ["plugin", "validate", packageDirectory], project)).ok, true);
  const base = { project, executable, packageDirectory, receiptDirectory: path.join(root, "receipt"),
    localTrial: true, sessionsClosed: true };
  assert.equal((await applyManagement({ ...base, action: "install" }, { runner })).status, "ready");
  assert.equal((await applyManagement({ ...base, action: "update" }, { runner })).status, "ready");
  assert.equal((await applyManagement({ ...base, action: "disable" }, { runner })).status, "disabled");
  assert.equal((await applyManagement({ ...base, action: "enable" }, { runner })).status, "ready");
  const enabledCalls = calls.length;
  await assert.rejects(applyManagement({ ...base, action: "enable" }, { runner }), /plugin_already_enabled/);
  assert.equal(calls.length, enabledCalls);
  assert.equal((await applyManagement({ ...base, action: "disable" }, { runner })).status, "disabled");

  // A synthetic higher version exercises staged upgrade, not a release claim.
  const version = JSON.parse(fs.readFileSync(path.join(source, ".claude-plugin/plugin.json"), "utf8")).version;
  const nextVersion = version.split(".").map((part, index) => index === 2 ? Number(part) + 1 : part).join(".");
  const staged = path.join(root, "staged-source"); fs.mkdirSync(staged, { mode: 0o700 });
  for (const relative of PLUGIN_FILES) {
    const destination = path.join(staged, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
    fs.copyFileSync(path.join(source, relative), destination);
    fs.chmodSync(destination, 0o600);
  }
  for (const relative of [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"]) {
    const filename = path.join(staged, relative), manifest = JSON.parse(fs.readFileSync(filename, "utf8"));
    if (relative.endsWith("/plugin.json")) manifest.version = nextVersion;
    else {
      manifest.metadata.version = nextVersion;
      for (const plugin of manifest.plugins) if (plugin.version) plugin.version = nextVersion;
    }
    fs.writeFileSync(filename, JSON.stringify(manifest));
  }
  const upgradedDirectory = path.join(root, "v2");
  await packPlugin({ source: staged, destination: upgradedDirectory });
  const upgraded = { ...base, packageDirectory: upgradedDirectory };
  assert.equal((await applyManagement({ ...upgraded, action: "update" }, { runner })).status, "disabled");
  assert.equal((await applyManagement({ ...upgraded, action: "uninstall" }, { runner })).status, "removed");
  const removedCalls = calls.length;
  await assert.rejects(applyManagement({ ...upgraded, action: "enable" }, { runner }), /reconciliation_required/);
  await assert.rejects(applyManagement({ ...upgraded, action: "install" }, { runner }), /receipt_exists/);
  assert.equal(calls.length, removedCalls);
  console.log(JSON.stringify({ status: "passed", checks: ["package_validate", "install", "refresh",
    "disable", "enable", "ready_enable_rejected", "disable_again", "staged_upgrade",
    "uninstall", "removed_enable_rejected", "install_replay_rejected"], commandCount: calls.length,
    networkAllowed: false, normalHomeAllowed: false, runtimeAccepted: false }));
} finally {
  const stat = fs.lstatSync(root);
  assert.ok(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid() && (stat.mode & 0o777) === 0o700);
  fs.rmSync(root, { recursive: true });
}
