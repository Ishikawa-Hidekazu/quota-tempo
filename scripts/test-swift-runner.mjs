#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../", import.meta.url)));
const runner = join(root, "scripts/test-swift.sh");
const packager = join(root, "scripts/build-app-bundle.sh");
const previewEnvironment = "QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW";

function fixture(t, { clt = true, framework = true, interop = true } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "QuotaTempo Swift Runner "));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const bin = join(directory, "bin");
  const home = join(directory, "home");
  const temporary = join(directory, "tmp");
  for (const path of [bin, home, temporary]) mkdirSync(path);
  const developer = join(directory, clt ? "Developer Tools/CommandLineTools" : "Xcode.app/Contents/Developer");
  mkdirSync(developer, { recursive: true });
  const frameworks = join(developer, "Library/Developer/Frameworks");
  const libraries = join(developer, "Library/Developer/usr/lib");
  if (framework) {
    mkdirSync(join(frameworks, "Testing.framework"), { recursive: true });
    writeFileSync(join(frameworks, "Testing.framework/Testing"), "synthetic framework, never loaded\n");
  }
  if (interop) {
    mkdirSync(libraries, { recursive: true });
    writeFileSync(join(libraries, "lib_TestingInterop.dylib"), "synthetic runtime, never loaded\n");
  }
  const log = join(directory, "calls.jsonl");
  const stub = join(directory, "fake-tool.mjs");
  writeFileSync(stub, `import { appendFileSync } from "node:fs";
const [tool, ...args] = process.argv.slice(2);
appendFileSync(process.env.TEST_CALL_LOG, JSON.stringify({
  tool, args,
  developer: process.env.DEVELOPER_DIR ?? null,
  preview: process.env.QUOTATEMPO_DESKTOP_INTEGRATION_PREVIEW ?? null,
  libraryPath: process.env.DYLD_LIBRARY_PATH ?? null,
  frameworkPath: process.env.DYLD_FRAMEWORK_PATH ?? null,
  fallbackLibraryPath: process.env.DYLD_FALLBACK_LIBRARY_PATH ?? null,
}) + "\\n");
if (tool === "swift") {
  // Stop a packaging regression before any real build or subsequent bundle work.
  if (args[0] !== "test") process.exit(99);
  process.stdout.write("synthetic swift stdout\\n");
  process.stderr.write("synthetic swift stderr\\n");
  process.exit(Number(process.env.TEST_SWIFT_STATUS));
}
if (tool === "xcode-select" && args.length === 1 && args[0] === "-p") {
  process.stdout.write(process.env.TEST_SELECTED_DEVELOPER + "\\n");
  process.exit(0);
}
process.exit(98);
`);
  for (const tool of ["swift", "xcode-select", "xcrun", "xcodebuild", "sudo", "launchctl", "defaults"]) {
    writeFileSync(join(bin, tool), `#!/bin/sh\nexec "$TEST_NODE" "$TEST_TOOL_STUB" ${tool} "$@"\n`, { mode: 0o755 });
  }
  // Do not inherit credentials, shell startup hooks, or the real user's HOME.
  const env = {
    PATH: `${bin}:/usr/bin:/bin`, HOME: home, TMPDIR: temporary,
    DEVELOPER_DIR: developer,
    TEST_NODE: process.execPath, TEST_TOOL_STUB: stub, TEST_CALL_LOG: log,
    TEST_SELECTED_DEVELOPER: developer, TEST_SWIFT_STATUS: "0",
  };
  const watchedKeys = ["DEVELOPER_DIR", previewEnvironment, "PATH", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"];
  const inherited = watchedKeys.map((key) => [key, process.env[key]]);
  const run = (script, args = [], overrides = {}) => {
    const childEnv = { ...env, ...overrides };
    for (const key of Object.keys(childEnv)) if (childEnv[key] === undefined) delete childEnv[key];
    const result = spawnSync("/bin/bash", [script, ...args], {
      cwd: home, env: childEnv, encoding: "utf8", timeout: 10_000, maxBuffer: 65_536,
    });
    assert.ifError(result.error);
    assert.equal(result.signal, null);
    for (const [key, value] of inherited) {
      assert(process.env[key] === value, `Must not mutate the caller's ${key}`);
    }
    return result;
  };
  const calls = () => existsSync(log)
    ? readFileSync(log, "utf8").trim().split("\n").map((line) => JSON.parse(line)) : [];
  return { directory, developer, frameworks, libraries, run, calls };
}

function expectedFlags(f) {
  return [
    "-Xswiftc", `-F${f.frameworks}`, "-Xlinker", `-F${f.frameworks}`,
    "-Xlinker", "-rpath", "-Xlinker", f.frameworks,
    "-Xlinker", "-rpath", "-Xlinker", f.libraries,
  ];
}

function assertSwift(call, f, args, preview = null) {
  assert.deepEqual(call, {
    tool: "swift", args: ["test", "--package-path", root, ...args], developer: f.developer, preview,
    libraryPath: null, frameworkPath: null, fallbackLibraryPath: null,
  });
}

for (const status of [0, 37]) {
  test(`CLT forwards both framework/rpath flags, exact arguments, streams and exit ${status}`, (t) => {
    const f = fixture(t);
    const args = ["--filter", "Suite.test with spaces", "--scratch-path", join(f.directory, "build output"), "", "$HOME", "*.swift"];
    const result = f.run(runner, args, { TEST_SWIFT_STATUS: String(status), [previewEnvironment]: "1" });
    assert.equal(result.status, status, result.stderr);
    assert.equal(result.stdout, "synthetic swift stdout\n");
    assert.equal(result.stderr, "synthetic swift stderr\n");
    assert.equal(f.calls().length, 1, "An explicit developer directory must not call xcode-select");
    assertSwift(f.calls()[0], f, [...expectedFlags(f), ...args], "1");
  });
}

for (const [name, runtime] of [
  ["framework", { framework: false }],
  ["interop dylib", { interop: false }],
  ["both runtime locations", { framework: false, interop: false }],
]) {
  test(`CLT rejects missing ${name} before launching Swift`, (t) => {
    const f = fixture(t, runtime);
    const result = f.run(runner, ["--filter", "SyntheticTests"]);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /Swift Testing runtime is incomplete/);
    assert.deepEqual(f.calls(), []);
  });
}

for (const name of ["framework", "interop"]) {
  test(`CLT rejects a wrong-type ${name} runtime path before launching Swift`, (t) => {
    const f = fixture(t);
    const path = name === "framework" ? join(f.frameworks, "Testing.framework") : join(f.libraries, "lib_TestingInterop.dylib");
    rmSync(path, { recursive: true });
    if (name === "framework") writeFileSync(path, "not a framework directory\n");
    else mkdirSync(path);
    const result = f.run(runner);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Swift Testing runtime is incomplete/);
    assert.deepEqual(f.calls(), []);
  });
}

for (const args of [["--skip-build"], ["--filter", "SyntheticTests", "--skip-build"]]) {
  test(`CLT refuses --skip-build at argument ${args.indexOf("--skip-build") + 1}`, (t) => {
    const f = fixture(t);
    const result = f.run(runner, args);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /Do not skip the build with Command Line Tools/);
    assert.deepEqual(f.calls(), []);
  });
}

test("Xcode forwards arguments without CLT runtime checks or injected flags", (t) => {
  const f = fixture(t, { clt: false, framework: false, interop: false });
  const args = ["--skip-build", "--filter", "SyntheticTests"];
  const result = f.run(runner, args);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(f.calls().length, 1);
  assertSwift(f.calls()[0], f, args);
});

for (const clt of [true, false]) {
  for (const source of ["environment", "selection"]) {
    test(`trailing slash is normalized from ${source} (${clt ? "CLT" : "Xcode"})`, (t) => {
      const f = fixture(t, { clt, framework: clt, interop: clt });
      const overrides = source === "environment"
        ? { DEVELOPER_DIR: `${f.developer}/` }
        : { DEVELOPER_DIR: undefined, TEST_SELECTED_DEVELOPER: `${f.developer}/` };
      const result = f.run(runner, [], overrides);
      assert.equal(result.status, 0, result.stderr);
      const calls = f.calls();
      assert.equal(calls.length, source === "environment" ? 1 : 2);
      if (source === "selection") {
        assert.equal(calls[0].tool, "xcode-select");
        assert.deepEqual(calls[0].args, ["-p"]);
      }
      assertSwift(calls.at(-1), f, clt ? expectedFlags(f) : []);
    });
  }
  test(`unset DEVELOPER_DIR reads selection once, without changing it (${clt ? "CLT" : "Xcode"})`, (t) => {
    const f = fixture(t, { clt, framework: clt, interop: clt });
    const result = f.run(runner, [], { DEVELOPER_DIR: undefined });
    assert.equal(result.status, 0, result.stderr);
    const calls = f.calls();
    assert.equal(calls.length, 2);
    assert.equal(calls[0].tool, "xcode-select");
    assert.deepEqual(calls[0].args, ["-p"]);
    assert.equal(calls[0].developer, null);
    assertSwift(calls[1], f, clt ? expectedFlags(f) : []);
  });
}

test("distribution packaging rejects preview before creating output or launching Swift", (t) => {
  const f = fixture(t);
  const parent = join(f.directory, "new distribution output");
  const output = join(parent, "QuotaTempo.app");
  const before = readdirSync(f.directory);
  const result = f.run(packager, [output], { [previewEnvironment]: "1" });
  assert.equal(result.status, 2);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /Desktop integration preview cannot be packaged/);
  assert.deepEqual(f.calls(), [], "Packaging must fail before any Swift or developer selection command");
  assert.equal(existsSync(output), false);
  assert.equal(existsSync(parent), false, "Packaging must not create the output's parent or staging directories");
  assert.deepEqual(readdirSync(f.directory), before);
});
