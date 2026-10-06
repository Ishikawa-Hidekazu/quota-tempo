import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { flag, malformedArguments, parseArguments, resultContract, runHarness,
  sandboxPolicy } from "./test-code-comparison-startup.mjs";

const success = { status: "startupValidated", passed: true, providersDisabled: true,
  guiStarted: false, liveCodeAccepted: false };
const failure = { status: "startupValidationFailed", passed: false };
const response = (value, status = value.passed ? 0 : 2) => ({ status, signal: null,
  stdout: Buffer.from(JSON.stringify(value)) });
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function fixture(t, changes = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "qtc-startup-synthetic-")));
  const identity = fs.lstatSync(root);
  t.after(() => {
    const current = fs.lstatSync(root);
    assert.equal(current.ino, identity.ino);
    assert.equal(current.dev, identity.dev);
    fs.rmSync(root, { recursive: true });
  });
  const app = path.join(root, "Preview.app");
  fs.mkdirSync(path.join(app, "Contents/MacOS"), { recursive: true, mode: 0o755 });
  const binary = path.join(app, "Contents/MacOS/QuotaTempo");
  fs.writeFileSync(binary, "synthetic inert fixture, never executed", { mode: 0o755 });
  fs.writeFileSync(path.join(app, "Contents/Info.plist"), "inert synthetic metadata", { mode: 0o644 });
  const home = path.join(root, "normal-home");
  const temporaryParent = path.join(root, "temporary");
  fs.mkdirSync(home, { mode: 0o700 });
  fs.mkdirSync(temporaryParent, { mode: 0o700 });
  const info = { CFBundleIdentifier: "co.ishikawa.QuotaTempo.CodeComparisonPreview",
    CFBundleExecutable: "QuotaTempo", QTReleaseChannel: "code-comparison-preview",
    QTCodeComparisonPluginBundled: true, QTCodeComparisonManifestDigest: "a".repeat(64),
    ...changes.info };
  const calls = [];
  let children = 0;
  const spawnSync = (command, argv, options) => {
    calls.push({ command, argv, options });
    if (command === "/usr/bin/codesign") return { status: changes.signatureFailure ? 1 : 0, signal: null };
    if (command === "/usr/bin/plutil") return response(info, 0);
    assert.equal(command, "/usr/bin/sandbox-exec");
    children += 1;
    assert.equal(argv[0], "-p");
    assert.equal(argv[2], binary);
    assert.match(argv[1], /\(deny network\*\)/);
    assert.ok(argv[1].includes(JSON.stringify(home)));
    assert.equal(options.timeout, 30000);
    assert.equal(options.killSignal, "SIGKILL");
    assert.equal(options.maxBuffer, 511);
    assert.equal(options.shell, false);
    assert.deepEqual(options.stdio, ["ignore", "pipe", "ignore"]);
    assert.deepEqual(Object.keys(options.env).sort(), ["CFFIXED_USER_HOME", "HOME", "LC_ALL", "PATH", "TMPDIR"]);
    assert.equal(options.env.HOME, options.env.CFFIXED_USER_HOME);
    assert.notEqual(options.env.HOME, home);
    assert.equal(fs.readdirSync(options.env.HOME).length, 0);
    assert.equal(fs.lstatSync(options.env.HOME).mode & 0o7777, 0o700);
    const childArgs = argv.slice(3);
    assert.ok(childArgs.some(value => value.startsWith(flag)));
    const valid = childArgs.length === 3 && childArgs[0] === flag
      && childArgs[1] === "--private-test-directory";
    if (changes.child) return changes.child({ valid, childArgs, options, children, temporaryParent });
    if (valid) {
      const destination = childArgs[2];
      assert.match(path.basename(destination), /^qtc-startup-validation-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
      assert.equal(fs.existsSync(destination), false);
      fs.mkdirSync(destination, { mode: 0o700 });
      fs.mkdirSync(path.join(destination, "support"), { mode: 0o700 });
      // Each invocation must start with a fresh HOME even if Foundation writes private preferences.
      fs.writeFileSync(path.join(options.env.HOME, "synthetic-preferences"), "inert");
      return response(success);
    }
    return response(failure);
  };
  const run = (runtimeOverrides = {}) => runHarness(["--app", app], { platform: "darwin", normalHome: home,
    temporaryParent, spawnSync, ...changes.runtime, ...runtimeOverrides });
  return { root, app, binary, temporaryParent, calls, run, get children() { return children; } };
}

test("CLI accepts only an explicit absolute app", () => {
  assert.equal(parseArguments(["--app", "/private/tmp/Preview.app"]), "/private/tmp/Preview.app");
  for (const args of [[], ["--help"], ["--app", "Preview.app"], ["--app", "/a/../Preview.app"],
    ["--app", "/tmp/Preview.app", "--app", "/tmp/Other.app"], ["--app", "/tmp/a\n.app"]]) {
    assert.throws(() => parseArguments(args));
  }
});

test("sandbox denies all network and both normal HOME aliases", () => {
  const policy = sandboxPolicy("/Users/synthetic", "/canonical/synthetic");
  assert.match(policy, /deny network\*/);
  assert.match(policy, /deny file-read\* file-write\*/);
  assert.ok(policy.includes('"/Users/synthetic"'));
  assert.ok(policy.includes('"/canonical/synthetic"'));
  assert.throws(() => sandboxPolicy("/", "/"));
});

test("only exact bounded success and argument-rejection JSON are accepted", () => {
  assert.equal(resultContract(response(success)), true);
  assert.equal(resultContract(response(failure)), false);
  const invalid = [response({ ...success, providersDisabled: false }), response({ ...success, guiStarted: true }),
    response({ ...success, liveCodeAccepted: true }), response({ ...success, extra: true }),
    response(success, 2), response(failure, 0), response({ status: "startupValidationDeadlineExceeded", passed: false }),
    { ...response(success), signal: "SIGKILL" }, { ...response(success), error: new Error("private") },
    { ...response(success), stdout: Buffer.alloc(512, 32) },
    { ...response(success), stdout: Buffer.from(`log\n${JSON.stringify(success)}`) },
    { ...response(failure), stdout: Buffer.from('{"status":"startupValidationFailed","passed":false,"passed":false}') }];
  for (const result of invalid) assert.throws(() => resultContract(result));
});

test("every malformed argv retains the reserved headless prefix", () => {
  for (const malformed of malformedArguments) assert.ok(malformed("/private/tmp/synthetic")
    .some(value => value.startsWith(flag)));
});

test("seven synthetic cases pass with signature verification and owned cleanup", t => {
  const f = fixture(t);
  const result = f.run();
  assert.equal(result.status, "passed");
  assert.equal(result.passed, 7);
  assert.equal(result.failed, 0);
  assert.equal(result.skipped, 0);
  assert.equal(result.cleanupComplete, true);
  assert.equal(result.liveAcceptance, false);
  assert.equal(f.children, 7);
  assert.deepEqual(fs.readdirSync(f.temporaryParent), []);
  const signatures = f.calls.filter(call => call.command === "/usr/bin/codesign");
  assert.deepEqual(signatures.map(call => call.argv), [f.app, f.binary].map(file =>
    ["--verify", "--strict", "--deep", "--all-architectures", file]));
});

for (const [name, info] of Object.entries({ normalApp: { CFBundleIdentifier: "co.ishikawa.QuotaTempo" },
  wrongChannel: { QTReleaseChannel: "stable" }, noBundle: { QTCodeComparisonPluginBundled: false },
  wrongExecutable: { CFBundleExecutable: "Other" }, missingPin: { QTCodeComparisonManifestDigest: "" },
  updateFeed: { SUFeedURL: "" }, updaterKey: { SUPublicEDKey: "" } })) {
  test(`reject ${name} before any app execution`, t => {
    const f = fixture(t, { info });
    assert.equal(f.run().status, "failed");
    assert.equal(f.children, 0);
    assert.deepEqual(fs.readdirSync(f.temporaryParent), []);
  });
}

test("invalid signature, non-Mac and unsafe binary never execute", t => {
  for (const changes of [{ signatureFailure: true }, { runtime: { platform: "linux" } }, {}]) {
    const f = fixture(t, changes);
    if (Object.keys(changes).length === 0) fs.chmodSync(f.binary, 0o777);
    assert.equal(f.run().status, "failed");
    assert.equal(f.children, 0);
  }
});

test("normal HOME and its canonical alias explicitly reject the app without tools or child execution", t => {
  const f = fixture(t);
  const alias = path.join(f.root, "home-alias");
  fs.symlinkSync(f.root, alias);
  for (const normalHome of [f.root, alias]) {
    const result = f.run({ normalHome });
    assert.equal(result.status, "failed");
    assert.deepEqual(result.cases, [{ name: "appUnderHomeUnsupported", status: "failed" }]);
    assert.equal(result.cleanupComplete, true);
    assert.equal(result.liveAcceptance, false);
    assert.equal(f.calls.length, 0);
    assert.deepEqual(fs.readdirSync(f.temporaryParent), []);
  }
});

test("unknown child output stops further launches and retains unadopted outputs", t => {
  const f = fixture(t, { child: ({ childArgs }) => {
    fs.mkdirSync(childArgs[2], { mode: 0o700 });
    return { status: null, signal: "SIGKILL", stdout: Buffer.alloc(0) };
  } });
  const result = f.run();
  assert.equal(result.status, "failed");
  assert.equal(result.cleanupComplete, false);
  assert.equal(f.children, 1);
  assert.equal(fs.readdirSync(f.temporaryParent).filter(name => name.startsWith("qtc-startup-validation-")).length, 1);
});

test("replaced owned HOME inode is retained and cannot produce PASS", t => {
  const f = fixture(t, { child: ({ childArgs, options }) => {
    fs.renameSync(options.env.HOME, `${options.env.HOME}-original`);
    fs.mkdirSync(options.env.HOME, { mode: 0o700 });
    fs.mkdirSync(childArgs[2], { mode: 0o700 });
    return response(success);
  } });
  assert.equal(f.run().cleanupComplete, false);
  assert.equal(f.children, 1);
  assert.ok(fs.readdirSync(f.temporaryParent).some(name => name.startsWith("qtc-startup-harness-")));
});

test("success without an exclusively created validation root fails", t => {
  const f = fixture(t, { child: () => response(success) });
  assert.equal(f.run().status, "failed");
  assert.equal(f.children, 1);
});

test("native startup prefix is trapped before App.main and exact composition stays isolated", () => {
  const entry = fs.readFileSync(path.join(repo, "Sources/QuotaTempoApp/QuotaTempoEntryPoint.swift"), "utf8");
  assert.ok(entry.indexOf("if requestsCodeStartupValidation(arguments)") < entry.indexOf("QuotaTempoApp.main()"));
  assert.match(entry, /hasPrefix\("--code-comparison-startup-validation"\)/);
  assert.match(entry, /#if DESKTOP_INTEGRATION_PREVIEW[\s\S]*CodeComparisonStartupValidation\.run\(arguments\)/);
  const native = fs.readFileSync(path.join(repo, "Sources/QuotaTempoApp/CodeComparisonStartupValidation.swift"), "utf8");
  assert.match(native, /mkdirat\(parent, root\.lastPathComponent, 0o700\)/);
  assert.match(native, /QuotaTempoAppDefaults\.defaults === UserDefaults\.standard/);
  assert.match(native, /let app = QuotaTempoApp\(/);
  assert.match(native, /arguments: \["QuotaTempo", "--provider-disabled"\]/);
  assert.match(native, /supportDirectory: root\.appendingPathComponent/);
  assert.match(native, /defaults: defaults/);
  assert.match(native, /defaults\.removePersistentDomain\(forName: suite\)/);
});

test("CI uses the same temporary preview after signed resource acceptance", () => {
  const ci = fs.readFileSync(path.join(repo, ".github/workflows/ci.yml"), "utf8");
  assert.ok(ci.includes("node --test scripts/test-code-comparison-startup.test.mjs"));
  assert.match(ci, /test-code-comparison-signed-package\.mjs --app "\$temporary\/CodeComparison\.app"\n\s+node scripts\/test-code-comparison-startup\.mjs --app "\$temporary\/CodeComparison\.app"/);
});
