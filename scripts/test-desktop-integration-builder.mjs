#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync,
  rmSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const builder = fileURLToPath(new URL("./build-desktop-integration-preview.sh", import.meta.url));
const source = readFileSync(builder, "utf8");
const team = "TESTTEAM01";
const identity = `Developer ID Application: Synthetic Fixture (${team})`;
const signingOptions = ["--sign-identity", identity, "--team-id", team];
const previewKey = "QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW";
const previewID = "co.ishikawa.QuotaTempo.DesktopIntegrationPreview";
const sparkleTargets = [
  "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc",
  "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc",
  "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
  "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
  "Contents/Frameworks/Sparkle.framework",
];

function pathExists(path) {
  try { lstatSync(path); return true; } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}

function fixture(t) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), "QuotaTempo Integration Builder ")));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const repo = join(directory, "synthetic repo");
  const bin = join(directory, "bin");
  const home = join(directory, "home");
  const temporary = join(directory, "tmp");
  const build = join(repo, "fake build");
  const output = join(directory, "new output", "Preview.app");
  const defaultOutput = join(repo, "dist/QuotaTempoDesktopIntegration.app");
  const script = join(repo, "scripts/build-desktop-integration-preview.sh");
  for (const path of [bin, home, temporary, build, dirname(script), join(repo, "packaging")]) {
    mkdirSync(path, { recursive: true });
  }
  // Stub the sole absolute tool in a disposable copy. Production gains no test
  // override, and all other external commands resolve through an allowlist PATH.
  assert.equal(source.match(/\/usr\/libexec\/PlistBuddy/g)?.length, 1);
  writeFileSync(script, source.replace("/usr/libexec/PlistBuddy", '"$TEST_PLIST_BUDDY"'));
  for (const [name, path] of Object.entries({
    dirname: "/usr/bin/dirname", mkdir: "/bin/mkdir", mktemp: "/usr/bin/mktemp",
    rm: "/bin/rm", rmdir: "/bin/rmdir", install: "/usr/bin/install", cp: "/bin/cp",
  })) symlinkSync(path, join(bin, name));

  writeFileSync(join(build, "QuotaTempo"), "synthetic binary: never executable code\n");
  for (const target of sparkleTargets.slice(0, 4)) {
    const path = join(build, target.replace("Contents/Frameworks/", ""));
    mkdirSync(dirname(path), { recursive: true });
    if (target.endsWith("Autoupdate")) writeFileSync(path, "synthetic autoupdate\n");
    else mkdirSync(path);
  }
  writeFileSync(join(repo, "packaging/Info.plist"), JSON.stringify({
    CFBundleIdentifier: "co.ishikawa.QuotaTempo", QTReleaseChannel: "stable",
    CFBundleIconFile: "QuotaTempo", SUFeedURL: "synthetic", SUPublicEDKey: "synthetic",
  }));
  for (const document of ["PRIVACY.md", "LICENSE", "UPDATES.md", "SUPPORT.md", "THIRD_PARTY_NOTICES.md"]) {
    writeFileSync(join(repo, document), "synthetic resource\n");
  }
  const license = join(repo, ".build/desktop-integration/artifacts/sparkle/Sparkle/LICENSE");
  mkdirSync(dirname(license), { recursive: true });
  writeFileSync(license, "synthetic Sparkle license\n");
  for (const language of ["en", "ja"]) {
    const path = join(repo, `Sources/QuotaTempoCore/Resources/${language}.lproj`);
    mkdirSync(path, { recursive: true });
    writeFileSync(join(path, "Localizable.strings"), "synthetic localization\n");
  }

  const log = join(directory, "calls.jsonl");
  const stub = join(directory, "fake-tool.mjs");
  writeFileSync(stub, `import {
  appendFileSync, cpSync, existsSync, mkdirSync, readFileSync, renameSync, symlinkSync, writeFileSync,
} from "node:fs";
const [tool, ...args] = process.argv.slice(2);
const env = process.env;
appendFileSync(env.TEST_CALL_LOG, JSON.stringify({
  tool, args, preview: env.QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW ?? null,
}) + "\\n");
const fail = (phase) => {
  if (env.TEST_FAIL_PHASE === phase) {
    process.stderr.write("synthetic failure: " + phase + "\\n");
    process.exit(67);
  }
};
if (tool === "swift" && args[0] === "build") {
  const showPath = args.includes("--show-bin-path");
  fail(showPath ? "bin-path" : "build");
  if (showPath) process.stdout.write(env.TEST_BUILD + "\\n");
} else if (tool === "install_name_tool") {
  fail("rpath");
} else if (tool === "ditto") {
  fail("framework-copy");
  cpSync(args[0], args[1], { recursive: true });
} else if (tool === "PlistBuddy" && args[0] === "-c") {
  fail("plist");
  const [operation, key, ...value] = args[1].split(" ");
  const plist = JSON.parse(readFileSync(args[2], "utf8"));
  if (operation === "Set") plist[key.slice(1)] = value.join(" ");
  else if (operation === "Delete") delete plist[key.slice(1)];
  else process.exit(98);
  writeFileSync(args[2], JSON.stringify(plist));
} else if (tool === "codesign") {
  if (!existsSync(args.at(-1))) process.exit(98);
  if (args.includes("--sign")) {
    const calls = readFileSync(env.TEST_CALL_LOG, "utf8").trim().split("\\n").map(JSON.parse);
    fail("sign-" + calls.filter((c) => c.tool === "codesign" && c.args.includes("--sign")).length);
  } else if (args.includes("--verify")) {
    if (args.includes("--test-requirement")) {
      fail("requirement");
      const requirement = args[args.indexOf("--test-requirement") + 1];
      // Simulate rejection, not Apple's cryptographic verification.
      if (env.TEST_CERT_TEAM && !requirement.includes('subject.OU] = "' + env.TEST_CERT_TEAM + '"')) {
        process.exit(68);
      }
    } else {
      fail("deep-verify");
      if (env.TEST_LATE_OUTPUT_KIND === "directory") mkdirSync(env.TEST_OUTPUT);
      else if (env.TEST_LATE_OUTPUT_KIND === "file") writeFileSync(env.TEST_OUTPUT, "preserve me");
      else if (env.TEST_LATE_OUTPUT_KIND === "symlink") symlinkSync(env.TEST_LINK_TARGET, env.TEST_OUTPUT);
    }
  } else process.exit(98);
} else if (tool === "mv") {
  fail("publish");
  renameSync(args[0], args[1]);
  fail("publish-after-move");
} else process.exit(99);
`);
  for (const tool of ["swift", "install_name_tool", "ditto", "PlistBuddy", "codesign", "mv"]) {
    writeFileSync(join(bin, tool), `#!/bin/sh\nexec "$TEST_NODE" "$TEST_TOOL_STUB" ${tool} "$@"\n`, { mode: 0o755 });
  }
  // No inherited credentials, real HOME, shell startup hooks, or fallback PATH.
  const env = {
    PATH: bin, HOME: home, TMPDIR: temporary, LC_ALL: "C",
    TEST_NODE: process.execPath, TEST_TOOL_STUB: stub, TEST_CALL_LOG: log,
    TEST_BUILD: build, TEST_OUTPUT: output, TEST_PLIST_BUDDY: join(bin, "PlistBuddy"),
  };
  const run = (args = [], overrides = {}) => {
    const previousPreview = process.env[previewKey];
    const result = spawnSync("/bin/bash", [script, ...args], {
      cwd: home, env: { ...env, ...overrides }, encoding: "utf8", timeout: 15_000,
      maxBuffer: 65_536,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    assert.equal(process.env[previewKey], previousPreview);
    return result;
  };
  const calls = () => existsSync(log)
    ? readFileSync(log, "utf8").trim().split("\n").map((line) => JSON.parse(line)) : [];
  const noStage = (path = output) => {
    const parent = dirname(path);
    if (existsSync(parent)) {
      assert.equal(readdirSync(parent).some((name) => name.startsWith(".DesktopIntegration.")), false);
    }
  };
  return { directory, repo, home, build, output, defaultOutput, run, calls, noStage };
}

const invalidCases = [
  ["empty output", [""]], ["blank output", ["   "]], ["control in output", ["bad\npath"]],
  ["two outputs", ["one.app", "two.app"]], ["unknown flag", ["--notarize"]],
  ["help with signing", ["--help", ...signingOptions]],
  ["missing identity", ["--sign-identity"]], ["missing team", ["--team-id"]],
  ["blank identity", ["--sign-identity", " ", "--team-id", team]],
  ["empty identity", ["--sign-identity", "", "--team-id", team]],
  ["blank team", ["--sign-identity", identity, "--team-id", " "]],
  ["empty team", ["--sign-identity", identity, "--team-id", ""]],
  ["option used as value", ["--sign-identity", "--team-id", team]],
  ["identity alone", ["--sign-identity", identity]],
  ["team alone", ["--team-id", team]],
  ["duplicate identity", [...signingOptions, "--sign-identity", identity]],
  ["duplicate team", [...signingOptions, "--team-id", team]],
  ["ad-hoc identity as option", ["--sign-identity", "-", "--team-id", team]],
  ["hash identity", ["--sign-identity", "0".repeat(40), "--team-id", team]],
  ["wrong certificate type", ["--sign-identity", `Developer ID Installer: Fixture (${team})`, "--team-id", team]],
  ["empty identity name", ["--sign-identity", `Developer ID Application:  (${team})`, "--team-id", team]],
  ["blank identity name", ["--sign-identity", `Developer ID Application:    (${team})`, "--team-id", team]],
  ["identity leading space", ["--sign-identity", ` ${identity}`, "--team-id", team]],
  ["identity trailing space", ["--sign-identity", `${identity} `, "--team-id", team]],
  ["control in identity", ["--sign-identity", `Developer ID Application: Fake\nName (${team})`, "--team-id", team]],
  ["mismatched team", ["--sign-identity", identity, "--team-id", "OTHERTEAM2"]],
  ["lowercase team", ["--sign-identity", identity, "--team-id", team.toLowerCase()]],
  ["short team", ["--sign-identity", identity, "--team-id", "TEAM"]],
  ["long team", ["--sign-identity", identity, "--team-id", `${team}0`]],
  ["requirement injection", ["--sign-identity", identity, "--team-id", '" or true']],
  ["trailing separator", ["--"]], ["extra output after separator", ["one.app", "--", "two.app"]],
];
for (const [name, args] of invalidCases) {
  test(`rejects ${name} before building or creating output`, (t) => {
    const f = fixture(t);
    const result = f.run(args);
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /Usage:/);
    assert.equal(result.stdout, "");
    assert.deepEqual(f.calls(), []);
    assert.equal(existsSync(dirname(f.output)), false);
    assert.equal(existsSync(dirname(f.defaultOutput)), false);
    assert.deepEqual(readdirSync(f.home), []);
  });
}

test("help is side-effect free and states the local-only default", (t) => {
  const f = fixture(t);
  const result = f.run(["--help"]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Default signing is ad-hoc/);
  assert.match(result.stdout, /Never launches, installs, notarizes/);
  assert.deepEqual(f.calls(), []);
  assert.equal(existsSync(dirname(f.defaultOutput)), false);
});

for (const kind of ["file", "directory", "symlink", "dangling symlink"]) {
  test(`never replaces an existing ${kind}`, (t) => {
    const f = fixture(t);
    mkdirSync(dirname(f.output));
    const target = join(f.directory, "existing target");
    if (kind === "file") writeFileSync(f.output, "preserve me");
    else if (kind === "directory") mkdirSync(f.output);
    else {
      if (kind === "symlink") writeFileSync(target, "preserve me");
      symlinkSync(target, f.output);
    }
    const before = lstatSync(f.output);
    const result = f.run([f.output, ...signingOptions]);
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /Existing apps are never replaced/);
    assert.equal(lstatSync(f.output).ino, before.ino);
    if (kind === "file") assert.equal(readFileSync(f.output, "utf8"), "preserve me");
    if (kind === "directory") assert.deepEqual(readdirSync(f.output), []);
    if (kind === "symlink") assert.equal(readFileSync(target, "utf8"), "preserve me");
    assert.deepEqual(f.calls(), []);
    f.noStage();
  });
}

function checkBuild(f, output, signing, result) {
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, new RegExp(`signing=${signing}\\nnotarized=false`));
  assert.match(result.stdout, /Not launched, installed, notarized, or release-approved/);
  const calls = f.calls();
  const swift = calls.filter((call) => call.tool === "swift");
  const buildArgs = ["build", "--package-path", f.repo, "--scratch-path", join(f.repo, ".build/desktop-integration")];
  assert.deepEqual(swift.map((call) => call.args), [
    [...buildArgs, "--product", "QuotaTempo"], [...buildArgs, "--show-bin-path"],
  ]);
  for (const call of calls) assert.equal(call.preview, call.tool === "swift" ? "1" : null);
  const plist = JSON.parse(readFileSync(join(output, "Contents/Info.plist"), "utf8"));
  assert.equal(plist.CFBundleIdentifier, previewID);
  assert.equal(plist.CFBundleName, "QuotaTempoDesktopIntegration");
  assert.equal(plist.CFBundleDisplayName, "QuotaTempo Desktop Integration");
  assert.equal(plist.QTReleaseChannel, "desktop-integration-preview");
  for (const key of ["CFBundleIconFile", "SUFeedURL", "SUPublicEDKey"]) assert.equal(key in plist, false);
  assert.deepEqual(readdirSync(output), ["Contents"]);
  const signs = calls.filter((call) => call.tool === "codesign" && call.args.includes("--sign"));
  const stage = signs.at(-1).args.at(-1);
  assert.equal(pathExists(stage), false);
  assert.equal(calls.at(-1).tool, "mv", "Publish only after all signature checks");
  assert.deepEqual(calls.at(-1).args, [join(stage, "Contents"), join(output, "Contents")]);
  f.noStage(output);
  return { calls, signs, stage };
}

test("default output remains ad-hoc and ignores signing environment variables", (t) => {
  const f = fixture(t);
  const result = f.run([], { SIGN_IDENTITY: identity, TEAM_ID: team, QUOTATEMPO_SIGN_IDENTITY: identity });
  const { calls, signs, stage } = checkBuild(f, f.defaultOutput, "ad-hoc", result);
  assert.deepEqual(signs.map((call) => call.args), [
    ["--force", "--sign", "-", "--timestamp=none", join(stage, "Contents/MacOS/QuotaTempo")],
    ["--force", "--sign", "-", "--timestamp=none", stage],
  ]);
  assert.deepEqual(calls.filter((call) => call.tool === "codesign" && call.args.includes("--verify"))
    .map((call) => call.args), [["--verify", "--deep", "--strict", stage]]);
});

test("supports relative output with spaces and an explicit end-of-options separator", (t) => {
  const f = fixture(t);
  const output = join(f.home, "-local preview.app");
  checkBuild(f, output, "ad-hoc", f.run(["--", "-local preview.app"]));
});

for (const order of ["output-first", "options-first"]) {
  test(`explicit Developer ID signing is inside-out with runtime, timestamp and a final team requirement (${order})`, (t) => {
    const f = fixture(t);
    const args = order === "output-first" ? [f.output, ...signingOptions]
      : ["--team-id", team, "--sign-identity", identity, f.output];
    const { calls, signs, stage } = checkBuild(f, f.output, "developer-id", f.run(args));
    const targets = [...sparkleTargets.map((target) => join(stage, target)), join(stage, "Contents/MacOS/QuotaTempo"), stage];
    assert.deepEqual(signs.map((call) => call.args), targets.map((target, index) => [
      "--force", "--options", "runtime", "--sign", identity, "--timestamp",
      ...(index === 1 ? ["--preserve-metadata=entitlements"] : []), target,
    ]));
    assert.deepEqual(calls.filter((call) => call.tool === "codesign" && call.args.includes("--verify"))
      .map((call) => call.args), [
      ["--verify", "--deep", "--strict", stage],
      ["--verify", "--strict", "--test-requirement",
        '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
          + ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
          + ` and certificate leaf[subject.OU] = "${team}" and identifier "${previewID}"`, stage],
    ]);
  });
}

for (const phase of [
  "build", "bin-path", "rpath", "framework-copy", "plist",
  ...Array.from({ length: 7 }, (_, index) => `sign-${index + 1}`),
  "deep-verify", "requirement", "publish", "publish-after-move",
]) {
  test(`cleans staging and partial output on ${phase} failure`, (t) => {
    const f = fixture(t);
    const result = f.run([f.output, ...signingOptions], { TEST_FAIL_PHASE: phase });
    assert.equal(result.status, 67, result.stderr);
    assert.doesNotMatch(result.stdout, /Built local integration preview|signing=developer-id/);
    assert.equal(pathExists(f.output), false);
    assert.deepEqual(readdirSync(dirname(f.output)), []);
    f.noStage();
  });
}

for (const phase of ["sign-1", "sign-2", "deep-verify"]) {
  test(`ad-hoc signing also cleans staging on ${phase} failure`, (t) => {
    const f = fixture(t);
    const result = f.run([f.output], { TEST_FAIL_PHASE: phase });
    assert.equal(result.status, 67, result.stderr);
    assert.doesNotMatch(result.stdout, /Built local integration preview|signing=ad-hoc/);
    assert.equal(pathExists(f.output), false);
    f.noStage();
  });
}

test("rejects a final signature from a different team without publishing", (t) => {
  const f = fixture(t);
  const result = f.run([f.output, ...signingOptions], { TEST_CERT_TEAM: "OTHERTEAM2" });
  assert.equal(result.status, 68, result.stderr);
  assert.equal(pathExists(f.output), false);
  assert.equal(f.calls().some((call) => call.tool === "mv"), false);
  f.noStage();
});

for (const kind of ["file", "directory", "symlink"]) {
  test(`does not overwrite a ${kind} created while signing`, (t) => {
    const f = fixture(t);
    const target = join(f.directory, "late target");
    writeFileSync(target, "preserve target");
    const result = f.run([f.output, ...signingOptions], {
      TEST_LATE_OUTPUT_KIND: kind, TEST_LINK_TARGET: target,
    });
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stdout, /Built local integration preview/);
    assert.equal(pathExists(f.output), true);
    if (kind === "file") assert.equal(readFileSync(f.output, "utf8"), "preserve me");
    if (kind === "directory") assert.deepEqual(readdirSync(f.output), []);
    if (kind === "symlink") assert.equal(lstatSync(f.output).isSymbolicLink(), true);
    assert.equal(readFileSync(target, "utf8"), "preserve target");
    assert.equal(f.calls().some((call) => call.tool === "mv"), false);
    f.noStage();
  });
}
