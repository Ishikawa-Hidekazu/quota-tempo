#!/usr/bin/env node
// Explicit macOS headless acceptance against disposable copies, never the installed app.
import fs from "node:fs";
import { cp } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import path from "node:path";

const flag = "--code-comparison-package-validation";
const identifier = "co.ishikawa.QuotaTempo.CodeComparisonPreview";
const packageFiles = [
  ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json",
  "hooks/register.mjs", "producer.mjs", "protocol.mjs", "transport-crypto.mjs",
  "THIRD_PARTY_NOTICES.txt",
];
const cases = [];
const owned = new Map();
let root;
let environment;
let cleanupComplete = true;
const fail = (reason) => { throw new Error(reason); };
const exists = (file) => {
  try { fs.lstatSync(file); return true; }
  catch (error) { if (error.code === "ENOENT") return false; throw error; }
};
const type = (info) => info.isDirectory() ? "directory" : info.isFile() ? "file"
  : info.isSymbolicLink() ? "symlink" : "other";
const same = (a, b) => a.dev === b.dev && a.ino === b.ino && a.uid === b.uid && type(a) === type(b);
function remember(file) {
  const info = fs.lstatSync(file);
  if (info.uid !== process.getuid() || type(info) === "other") fail("unsafe_owned_entry");
  owned.set(file, info);
  return info;
}
function checkOwned(file) {
  const expected = owned.get(file);
  const actual = fs.lstatSync(file);
  if (!expected || !same(expected, actual) || actual.mode !== expected.mode) fail("owned_identity_changed");
  return actual;
}
function mkdir(file) {
  fs.mkdirSync(file, { mode: 0o700 });
  remember(file);
  if ((fs.lstatSync(file).mode & 0o7777) !== 0o700) fail("private_directory_required");
}
function inventory(directory) {
  const entries = new Map();
  function walk(file) {
    if (entries.size >= 20000) fail("inventory_limit");
    const info = fs.lstatSync(file);
    if (info.uid !== process.getuid() || type(info) === "other") fail("unsafe_copy_entry");
    entries.set(file, info);
    if (info.isDirectory()) for (const name of fs.readdirSync(file)) walk(path.join(file, name));
  }
  walk(directory);
  return entries;
}
function recordTree(directory, replacements = new Set()) {
  checkOwned(path.dirname(directory));
  const entries = inventory(directory);
  // A codesign operation may replace only these already-owned signing entries.
  for (const [file, old] of owned) if (file === directory || file.startsWith(directory + "/")) {
    const current = entries.get(file);
    if (!current || (!same(old, current) && !replacements.has(file))) fail("copy_identity_changed");
  }
  for (const [file, info] of entries) owned.set(file, info);
  // Preserve framework symlinks without permitting tools to follow outside the copy.
  for (const [file, info] of entries) if (info.isSymbolicLink()) {
    const target = fs.realpathSync(file);
    if (target !== directory && !target.startsWith(directory + "/")) fail("external_copy_symlink");
  }
}
function readRegular(file, limit) {
  const info = checkOwned(file);
  if (!info.isFile() || info.nlink !== 1 || info.size <= 0 || info.size > limit) fail("invalid_resource");
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    if (!same(info, fs.fstatSync(fd))) fail("resource_identity_changed");
    const bytes = fs.readFileSync(fd);
    const after = fs.fstatSync(fd);
    if (!same(info, after) || after.size !== info.size || after.mtimeMs !== info.mtimeMs
      || after.ctimeMs !== info.ctimeMs || bytes.length !== info.size) fail("resource_changed");
    checkOwned(file);
    return bytes;
  } finally { fs.closeSync(fd); }
}
function writeRegular(file, bytes) {
  const info = checkOwned(file);
  if (!info.isFile() || info.nlink !== 1) fail("invalid_resource");
  const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW);
  try {
    if (!same(info, fs.fstatSync(fd))) fail("resource_identity_changed");
    fs.ftruncateSync(fd, 0);
    fs.writeFileSync(fd, bytes);
    fs.fsyncSync(fd);
    if (!same(info, fs.lstatSync(file))) fail("resource_identity_changed");
  } finally { fs.closeSync(fd); }
}
function runTool(executable, args) {
  return spawnSync(executable, args, {
    cwd: root, env: environment, stdio: "ignore", timeout: 35000, killSignal: "SIGKILL",
  });
}
function tool(executable, args) {
  const result = runTool(executable, args);
  return !result.error && result.signal === null && result.status === 0;
}
function verify(app) {
  return tool("/usr/bin/codesign", ["--verify", "--strict", "--deep", "--all-architectures", app]);
}
function signatureRejected(app) {
  const result = runTool("/usr/bin/codesign", ["--verify", "--strict", "--deep", "--all-architectures", app]);
  return !result.error && result.signal === null && Number.isInteger(result.status) && result.status > 0;
}
function plist(app) {
  const output = path.join(root, `plist-${randomUUID()}.json`);
  // Tools emit no output; the bounded, disposable conversion is owned metadata.
  if (!tool("/usr/bin/plutil", ["-convert", "json", "-o", output, path.join(app, "Contents/Info.plist")]))
    fail("plist_conversion_failed");
  remember(output);
  return JSON.parse(readRegular(output, 65536).toString("utf8"));
}
function preview(app) {
  const info = plist(app);
  if (info.CFBundleIdentifier !== identifier || info.QTReleaseChannel !== "code-comparison-preview"
    || info.QTCodeComparisonPluginBundled !== true
    || !/^[0-9a-f]{64}$/.test(info.QTCodeComparisonManifestDigest ?? "")
    || Object.hasOwn(info, "SUFeedURL") || Object.hasOwn(info, "SUPublicEDKey")) fail("not_code_preview");
  const executable = path.join(app, "Contents/MacOS/QuotaTempo");
  const binary = checkOwned(executable);
  if (!binary.isFile() || binary.nlink !== 1 || !(binary.mode & 0o111) || (binary.mode & 0o022))
    fail("unsafe_executable");
  return info;
}
async function copyApp(source, name) {
  const parent = path.join(root, name);
  mkdir(parent);
  const app = path.join(parent, "CodeComparisonPreview.app");
  await cp(source, app, { recursive: true, dereference: false, verbatimSymlinks: true,
    preserveTimestamps: true, force: false, errorOnExist: true });
  recordTree(app);
  return app;
}
function resultContract(result) {
  // Never relay errors, stderr, paths or raw child output. One fixed JSON object only.
  if (result.error || result.signal !== null || !Buffer.isBuffer(result.stdout)
    || result.stdout.length === 0 || result.stdout.length >= 512) fail("headless_contract_failed");
  const text = result.stdout.toString("utf8").trim();
  const value = JSON.parse(text);
  if (JSON.stringify(value) !== text) fail("headless_contract_failed");
  const keys = Object.keys(value).sort().join(",");
  if (result.status === 0 && keys === "liveCodeAccepted,passed,status,version"
    && value.status === "packageValidated" && value.passed === true
    && value.version === "0.0.4" && value.liveCodeAccepted === false) return true;
  if (result.status === 2 && keys === "passed,status"
    && value.status === "packageValidationFailed" && value.passed === false) return false;
  fail("headless_contract_failed");
}
function headless(app, malformed) {
  checkOwned(path.dirname(app));
  const executable = path.join(app, "Contents/MacOS/QuotaTempo");
  checkOwned(executable);
  const destination = `/private/tmp/qtc-package-validation-${randomUUID()}`;
  if (exists(destination)) fail("validation_destination_exists");
  if (fs.readdirSync(environment.HOME).length !== 0) fail("home_not_empty");
  const args = malformed ? malformed(destination) : [flag, "--private-test-directory", destination];
  // Every negative argv still selects the reserved headless branch, never SwiftUI.
  if (!args.some(argument => argument.startsWith(flag))) fail("unsafe_headless_arguments");
  const child = spawnSync(executable, args, {
    cwd: root, env: environment, timeout: 35000, killSignal: "SIGKILL", maxBuffer: 511,
    stdio: ["ignore", "pipe", "ignore"],
  });
  let passed;
  try { passed = resultContract(child); }
  catch (error) {
    if (exists(destination)) cleanupComplete = false;
    throw error;
  }
  // The child exclusively creates the unpredictable assigned destination. Unknown
  // outputs on timeout or a broken contract are retained, never adopted for cleanup.
  if (exists(destination)) {
    const info = fs.lstatSync(destination);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid()
      || (info.mode & 0o7777) !== 0o700) fail("unsafe_validation_output");
    remember(destination);
    const entries = inventory(destination);
    for (const [file, entry] of entries) owned.set(file, entry);
    if (malformed) fail("invalid_arguments_wrote_output");
  } else if (passed) fail("missing_validation_output");
  if (fs.readdirSync(environment.HOME).length !== 0) fail("home_was_modified");
  return passed;
}
async function check(name, action) {
  try { if (!(await action())) fail("unexpected_case_result"); cases.push({ name, status: "passed" }); return true; }
  catch { cases.push({ name, status: "failed" }); return false; }
}
function resign(app) {
  const info = plist(app);
  const file = path.join(app, "Contents/Info.plist");
  const commands = ["Set :QTCodeComparisonSigningMode local-ad-hoc"];
  if (Object.hasOwn(info, "QTCodeComparisonSigningTeam")) commands.push("Delete :QTCodeComparisonSigningTeam");
  for (const command of commands) if (!tool("/usr/libexec/PlistBuddy", ["-c", command, file])) return false;
  const executable = path.join(app, "Contents/MacOS/QuotaTempo");
  const args = ["--force", "--sign", "-", "--timestamp=none", "--identifier", identifier];
  if (!tool("/usr/bin/codesign", [...args, executable]) || !tool("/usr/bin/codesign", [...args, app])) return false;
  recordTree(app, new Set([file, executable, path.join(app, "Contents/_CodeSignature/CodeResources")]));
  return verify(app);
}
function tamper(app, selfConsistent) {
  const directory = path.join(app, "Contents/Resources/CodeComparisonPlugin");
  const file = path.join(directory, "hooks/register.mjs");
  writeRegular(file, Buffer.concat([readRegular(file, 256 * 1024),
    Buffer.from("\n// inert signed-package rejection fixture\n")]));
  if (!selfConsistent) return;
  const manifestPath = path.join(directory, "quotatempo-package.json");
  const manifest = JSON.parse(readRegular(manifestPath, 16384).toString("utf8"));
  if (manifest.releaseVersion !== "0.0.4" || manifest.schemaVersion !== 1
    || manifest.purpose !== "quotatempo-code-comparison-plugin"
    || Object.keys(manifest.files ?? {}).sort().join("\n") !== [...packageFiles].sort().join("\n"))
    fail("invalid_manifest");
  for (const relative of packageFiles) manifest.files[relative] = createHash("sha256")
    .update(readRegular(path.join(directory, relative), 256 * 1024)).digest("hex");
  const bytes = Buffer.from(JSON.stringify(manifest, null, 2) + "\n");
  writeRegular(manifestPath, bytes);
  const digest = createHash("sha256").update(bytes).digest("hex");
  if (!tool("/usr/libexec/PlistBuddy", ["-c", `Set :QTCodeComparisonManifestDigest ${digest}`,
    path.join(app, "Contents/Info.plist")])) fail("plist_pin_update_failed");
}
function cleanup() {
  // Preflight the complete known tree before deleting anything; never rm -rf a
  // replaced directory, follow a symlink, or adopt an unknown partial cp/sign result.
  try {
    for (const [file, expected] of owned) {
      const current = fs.lstatSync(file);
      if (!same(expected, current) || current.mode !== expected.mode) fail("cleanup_identity_changed");
      if (current.isDirectory()) for (const name of fs.readdirSync(file)) {
        if (!owned.has(path.join(file, name))) fail("cleanup_unknown_entry");
      }
    }
    for (const [file] of [...owned].sort((a, b) => b[0].split("/").length - a[0].split("/").length)) {
      for (let parent = path.dirname(file); owned.has(parent); parent = path.dirname(parent))
        checkOwned(parent);
      const info = checkOwned(file);
      if (info.isDirectory()) fs.rmdirSync(file); else fs.unlinkSync(file);
    }
  } catch { cleanupComplete = false; }
}

let rejected = false;
try {
  const args = process.argv.slice(2);
  if (process.platform !== "darwin" || args.length !== 2 || args[0] !== "--app"
    || !path.isAbsolute(args[1]) || !args[1].endsWith(".app") || /[\x00-\x1f\x7f]/.test(args[1])
    || args[1].split("/").some(part => part === "." || part === "..")) {
    rejected = true;
    fail("invalid_arguments");
  }
  const input = fs.lstatSync(args[1]);
  if (!input.isDirectory() || input.isSymbolicLink() || (input.mode & 0o022)) {
    rejected = true;
    fail("unsafe_input");
  }
  const source = fs.realpathSync(args[1]);
  root = `/private/tmp/qtc-signed-package-${randomUUID()}`;
  mkdir(root);
  for (const name of ["home", "tmp"]) mkdir(path.join(root, name));
  environment = { HOME: path.join(root, "home"), CFFIXED_USER_HOME: path.join(root, "home"),
    TMPDIR: path.join(root, "tmp"), PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LC_ALL: "C" };
  const clean = await copyApp(source, "clean");
  if (!(await check("cleanCopy", () => { preview(clean); return verify(clean) && headless(clean); })))
    fail("clean_baseline_failed");
  await check("resourceTamperRejected", async () => {
    const app = await copyApp(source, "tamper");
    if (!verify(app)) return false;
    tamper(app, false);
    // Only resources change. Never corrupt or run an invalid Mach-O executable.
    return signatureRejected(app) && headless(app) === false;
  });
  const rewritten = await copyApp(source, "self-consistent");
  if (!resign(rewritten)) {
    cases.push({ name: "adhocControl", status: "skipped" });
    cases.push({ name: "compiledPinRejected", status: "skipped" });
  } else if (await check("adhocControl", () => headless(rewritten))) {
    await check("compiledPinRejected", () => {
      tamper(rewritten, true);
      if (!resign(rewritten)) return false;
      return headless(rewritten) === false;
    });
  } else cases.push({ name: "compiledPinRejected", status: "skipped" });
  await check("worldWritableAncestorRejected", async () => {
    const app = await copyApp(source, "world-writable");
    if (!verify(app)) return false;
    const parent = path.dirname(app);
    const expected = checkOwned(parent);
    const fd = fs.openSync(parent, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
    try {
      if (!same(expected, fs.fstatSync(fd))) fail("ancestor_identity_changed");
      fs.fchmodSync(fd, 0o777);
      // This exact owned ancestor is writable only during the negative case.
      owned.set(parent, fs.fstatSync(fd));
      return headless(app) === false;
    } finally {
      try {
        fs.fchmodSync(fd, 0o700);
        owned.set(parent, expected);
      } finally { fs.closeSync(fd); }
    }
  });
  const invalid = [
    () => [flag],
    destination => [flag, "--wrong-directory", destination],
    () => [flag, "--private-test-directory", "relative"],
    () => [flag, "--private-test-directory", root],
    destination => [flag, "--private-test-directory", destination, "--extra"],
    destination => [flag + "=unexpected", "--private-test-directory", destination],
  ];
  for (let index = 0; index < invalid.length; index++)
    await check(`invalidArgv${index + 1}`, () => headless(clean, invalid[index]) === false);
} catch {
  if (!rejected && !cases.some(item => item.status === "failed")) cases.push({ name: "setup", status: "failed" });
} finally { cleanup(); }

const passed = cases.filter(item => item.status === "passed").length;
const failed = cases.filter(item => item.status === "failed").length;
const skipped = cases.filter(item => item.status === "skipped").length;
const status = rejected ? "rejected" : failed > 0 || !cleanupComplete ? "failed"
  : skipped > 0 ? "incomplete" : "passed";
process.stdout.write(JSON.stringify({ status, passed, failed, skipped, cleanupComplete,
  cases, liveAcceptance: false }) + "\n");
process.exitCode = status === "passed" ? 0 : 2;
