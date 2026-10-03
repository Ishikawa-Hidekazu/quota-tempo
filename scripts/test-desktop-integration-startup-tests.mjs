#!/usr/bin/env node

// No app, Swift build, codesign, Keychain, browser, OS permissions or real PID is
// used. The native tool/process boundary is simulated entirely in memory.
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import {
  chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync,
  statSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { parseArguments, runSmoke } from "./test-desktop-integration-startup.mjs";

const teamID = "TESTTEAM01";
const previewID = "co.ishikawa.QuotaTempo.DesktopIntegrationPreview";

function fixture(t, settings = {}) {
  const directory = mkdtempSync(join(tmpdir(), "quotatempo-startup-test-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const app = join(directory, "Explicit preview.app");
  const executable = join(app, "Contents/MacOS/QuotaTempo");
  mkdirSync(join(app, "Contents/MacOS"), { recursive: true });
  writeFileSync(executable, "not executable app code\n", { mode: 0o700 });
  const plist = join(app, "Contents/Info.plist");
  writeFileSync(plist, "synthetic metadata, parsed only by stub");
  const temporaryParent = join(directory, "temporary");
  mkdirSync(temporaryParent);
  const info = {
    CFBundleIdentifier: previewID, CFBundleExecutable: "QuotaTempo",
    CFBundlePackageType: "APPL", LSUIElement: true,
    QTReleaseChannel: "desktop-integration-preview", ...settings.info,
  };
  const tools = [];
  const launches = [];
  const signals = new EventEmitter();
  const kills = [];
  let clock = 0;
  let child;
  let ticked = false;
  let alive = true;
  let unreferenced = false;
  const runtime = {
    platform: "darwin", temporaryParent, signals, now: () => clock,
    spawnSync(command, args, options) {
      tools.push({ command, args, options });
      if (command === settings.failTool) {
        return { status: 1, stderr: "PRIVATE TOOL OUTPUT MUST NOT ESCAPE" };
      }
      if (settings.toolError) return { status: null, error: new Error("PRIVATE ERROR") };
      let stdout = "";
      if (command === "/usr/bin/plutil") stdout = settings.malformed ? "not-json" : JSON.stringify(info);
      if (command === "/usr/bin/xattr" && args[0] === (settings.quarantinedExecutable ? executable : app)) {
        stdout = settings.quarantined || settings.quarantinedExecutable ? "com.apple.quarantine\n" : "";
      }
      return { status: 0, stdout };
    },
    spawn(command, args, options) {
      launches.push({ command, args, options });
      child = new EventEmitter();
      child.pid = settings.noPID ? undefined : 12345; // Never passed to an OS API.
      child.kill = (signal) => {
        kills.push(signal);
        if (signal === 0) return alive && !settings.probeFailed;
        if (settings.killError) {
          child.emit("error", new Error("PRIVATE KILL ERROR"));
          return false;
        }
        if (settings.refusesStop || signal === "SIGTERM" && settings.ignoresTerm) return true;
        alive = false;
        child.emit("exit", null, signal);
        return true;
      };
      child.unref = () => { unreferenced = true; };
      return child;
    },
    async pause(ms) {
      clock += ms;
      if (!ticked) {
        ticked = true;
        if (settings.recordName) {
          const record = join(launches[0].args[2], settings.recordName);
          mkdirSync(dirname(record), { recursive: true });
          writeFileSync(record, "SYNTHETIC CONTENT MUST NOT BE READ OR OUTPUT");
        }
        if (settings.earlyExit) {
          alive = false;
          child.emit("exit", settings.earlyExit, null);
        }
        if (settings.spawnError) {
          alive = false;
          child.emit("error", new Error("PRIVATE SPAWN ERROR"));
        }
        if (settings.interrupt) signals.emit(settings.interrupt);
      }
    },
  };
  const args = ["--app", app, "--team-id", teamID];
  const run = (arguments_ = args, overrides = {}) => runSmoke(arguments_, { ...runtime, ...overrides });
  const noChildren = () => {
    assert.deepEqual(readdirSync(temporaryParent), []);
    assert.equal(signals.listenerCount("SIGINT"), 0);
    assert.equal(signals.listenerCount("SIGTERM"), 0);
  };
  return { app, executable, plist, temporaryParent, args, run, tools, launches, kills, noChildren,
    get clock() { return clock; }, get unreferenced() { return unreferenced; } };
}

test("help is inert and describes limited acceptance", async (t) => {
  const f = fixture(t);
  const result = await f.run(["--help"]);
  assert.equal(result.exitCode, 0);
  assert.match(result.help, /not live permission or release acceptance/);
  assert.deepEqual(f.tools, []);
  assert.deepEqual(f.launches, []);
  f.noChildren();
});

for (const args of [
  [], ["--app", "/tmp/Preview.app"], ["--team-id", teamID],
  ["--app", "relative.app", "--team-id", teamID],
  ["--app", "/tmp/Preview.app", "--team-id", "-"],
  ["--app", "/tmp/Preview.app", "--team-id", 'BAD"TEAM01'],
  ["--app", "/tmp/Preview\n.app", "--team-id", teamID],
  ["--app", "/tmp/Preview.app", "--team-id", teamID, "--app", "/tmp/Other.app"],
  ["--app", "/tmp/Preview.app", "--team-id", teamID, "--storage-directory", "/real/store"],
  ["--app", "/tmp/Preview.app", "--team-id", teamID, "--present-application-window"],
  ...["0", "4", "31", "Infinity", "5.5", "05"].map((seconds) => [
    "--app", "/tmp/Preview.app", "--team-id", teamID, "--seconds", seconds,
  ]),
]) {
  test(`rejects unsafe/incomplete arguments: ${JSON.stringify(args)}`, async (t) => {
    const f = fixture(t);
    assert.throws(() => parseArguments(args));
    const result = await f.run(args);
    assert.equal(result.reason, "invalid_arguments");
    assert.equal(result.exitCode, 1);
    assert.deepEqual(f.tools, []);
    assert.deepEqual(f.launches, []);
    f.noChildren();
  });
}

test("rejects non-macOS before running native tools", async (t) => {
  const f = fixture(t);
  assert.equal((await f.run(f.args, { platform: "linux" })).reason, "macos_required");
  assert.deepEqual(f.tools, []);
  assert.deepEqual(f.launches, []);
  f.noChildren();
});

for (const info of [
  { CFBundleIdentifier: "co.ishikawa.QuotaTempo" },
  { CFBundleExecutable: "Other" }, { CFBundlePackageType: "BNDL" },
  { LSUIElement: false }, { LSUIElement: "true" },
  { QTReleaseChannel: "stable" }, { SUFeedURL: "https://example.invalid/" },
  { SUPublicEDKey: "synthetic" },
]) {
  test(`rejects unexpected metadata: ${Object.keys(info)[0]}=${Object.values(info)[0]}`, async (t) => {
    const f = fixture(t, { info });
    assert.equal((await f.run()).reason, "unexpected_bundle_metadata");
    assert.deepEqual(f.launches, []);
    f.noChildren();
  });
}

for (const settings of [
  { failTool: "/usr/bin/codesign" }, { failTool: "/usr/bin/plutil" },
  { failTool: "/usr/bin/xattr" }, { toolError: true }, { malformed: true },
  { quarantined: true }, { quarantinedExecutable: true },
]) {
  test(`preflight failure never launches or exposes diagnostics: ${JSON.stringify(settings)}`, async (t) => {
    const f = fixture(t, settings);
    const result = await f.run();
    assert.equal(result.exitCode, 1);
    assert.doesNotMatch(JSON.stringify(result), /PRIVATE|not-json/);
    assert.deepEqual(f.launches, []);
    f.noChildren();
  });
}

for (const component of ["app", "executable", "plist"]) {
  test(`rejects a symlink ${component}`, async (t) => {
    const f = fixture(t);
    const path = f[component];
    const target = join(f.temporaryParent, "target");
    if (component === "app") mkdirSync(target);
    else writeFileSync(target, "not code", { mode: 0o700 });
    rmSync(path, { recursive: true });
    symlinkSync(target, path);
    const result = await f.run();
    assert.equal(result.reason, "unsafe_bundle_path");
    assert.deepEqual(f.tools, []);
    assert.deepEqual(f.launches, []);
    assert.equal(existsSync(target), true);
  });
}

test("rejects an absent or non-executable binary", async (t) => {
  const f = fixture(t);
  chmodSync(f.executable, 0o600);
  assert.equal((await f.run()).exitCode, 1);
  rmSync(f.executable);
  assert.equal((await f.run()).exitCode, 1);
  assert.deepEqual(f.launches, []);
  f.noChildren();
});

for (const seconds of [5, 30]) {
  test(`only exact supplied binary is launched with isolated state for ${seconds}s`, async (t) => {
    const f = fixture(t);
    const result = await f.run([...f.args, "--seconds", String(seconds)]);
    assert.equal(result.result, "PASS");
    assert.equal(result.observedSeconds, seconds);
    assert.equal(result.cleanup, "complete");
    assert.equal(result.livePermissionTested, false);
    assert.equal(result.rolloverTested, false);
    assert.equal(result.focusObserved, false);
    assert.equal(f.clock, seconds * 1_000);
    assert.equal(f.launches.length, 1);
    const launch = f.launches[0];
    const root = launch.options.cwd;
    assert.equal(launch.command, f.executable);
    assert.deepEqual(launch.args, [
      "--provider-disabled", "--storage-directory", join(root, "store"),
      "--exercise-provider-triggers",
      "-hasCompletedOnboarding", "YES", "-menuBarDisplayMode", "iconOnly",
    ]);
    assert.equal(launch.options.shell, false);
    assert.equal(launch.options.detached, false);
    assert.equal(launch.options.stdio, "ignore");
    assert.deepEqual(launch.options.env, {
      PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "C",
      HOME: join(root, "home"), TMPDIR: `${join(root, "tmp")}/`,
    });
    assert.deepEqual(f.kills.filter((signal) => signal !== 0), ["SIGTERM"]);
    assert.deepEqual(f.tools.map(({ command }) => command), [
      "/usr/bin/codesign", "/usr/bin/plutil", "/usr/bin/xattr", "/usr/bin/xattr",
    ]);
    const signature = f.tools[0];
    assert.deepEqual(signature.args.slice(0, 4), ["--verify", "--deep", "--strict", "--test-requirement"]);
    assert.match(signature.args[4], /anchor apple generic/);
    assert.match(signature.args[4], /1\.2\.840\.113635\.100\.6\.1\.13/);
    assert.match(signature.args[4], new RegExp(`subject.OU\\] = "${teamID}"`));
    assert.ok(signature.args[4].endsWith(`identifier "${previewID}"`));
    assert.equal(signature.args[5], f.app);
    for (const tool of f.tools) {
      assert.equal(tool.options.timeout, 10_000);
      assert.equal(tool.options.maxBuffer, 64 * 1024);
      assert.equal(tool.options.stdio[2], "ignore");
    }
    f.noChildren();
  });
}

test("temporary directories are private while the simulated child runs", async (t) => {
  const f = fixture(t);
  await f.run(f.args, { spawn(command, args, options) {
    for (const path of [options.cwd, args[2], options.env.HOME, options.env.TMPDIR]) {
      assert.equal(statSync(path).mode & 0o777, 0o700);
    }
    throw new Error("synthetic spawn failure");
  } });
  f.noChildren();
});

for (const [settings, reason] of [
  [{ earlyExit: 1 }, "early_exit"], [{ spawnError: true }, "spawn_failed"],
  [{ noPID: true }, "spawn_failed"], [{ probeFailed: true }, "early_exit"],
  [{ interrupt: "SIGINT" }, "interrupted"], [{ interrupt: "SIGTERM" }, "interrupted"],
]) {
  test(`process failure/interrupt cleans only its own child: ${JSON.stringify(settings)}`, async (t) => {
    const f = fixture(t, settings);
    const result = await f.run();
    assert.equal(result.reason, reason);
    assert.notEqual(result.exitCode, 0);
    assert.equal(result.cleanup, "complete");
    assert.equal(result.observedSeconds, 0);
    assert.equal(f.launches.length, 1);
    assert.doesNotMatch(JSON.stringify(result), /PRIVATE/);
    assert.deepEqual(f.kills.filter((signal) => signal !== 0),
      settings.earlyExit || settings.noPID ? [] : ["SIGTERM"]);
    f.noChildren();
  });
}

test("bounded own-child SIGKILL follows ignored SIGTERM", async (t) => {
  const f = fixture(t, { ignoresTerm: true });
  const result = await f.run();
  assert.equal(result.result, "PASS");
  assert.equal(result.cleanup, "complete");
  assert.deepEqual(f.kills.filter((signal) => signal !== 0), ["SIGTERM", "SIGKILL"]);
  assert.equal(f.clock, 7_000);
  f.noChildren();
});

test("unconfirmed child stop fails closed and retains its disposable directory", async (t) => {
  const f = fixture(t, { refusesStop: true });
  const result = await f.run();
  assert.equal(result.result, "FAIL");
  assert.equal(result.reason, "cleanup_failed");
  assert.equal(result.cleanup, "retained");
  assert.equal(existsSync(result.retainedDirectory), true);
  assert.deepEqual(f.kills.filter((signal) => signal !== 0), ["SIGTERM", "SIGKILL"]);
  assert.equal(f.clock, 9_000);
  assert.equal(f.unreferenced, true);
});

test("an error event with a valid PID is not proof of exit", async (t) => {
  const f = fixture(t, { killError: true });
  const result = await f.run();
  assert.equal(result.result, "FAIL");
  assert.equal(result.reason, "cleanup_failed");
  assert.equal(result.cleanup, "retained");
  assert.equal(existsSync(result.retainedDirectory), true);
  assert.deepEqual(f.kills.filter((signal) => signal !== 0), ["SIGTERM", "SIGKILL"]);
  assert.equal(f.clock, 9_000);
  assert.equal(f.unreferenced, true);
  assert.doesNotMatch(JSON.stringify(result), /PRIVATE/);
});

for (const recordName of [
  "codex.json", "claude.json", "DesktopConnection/desktop-throttle.json",
  "DesktopConnection/desktop-throttle.lock", "unexpected-record",
]) {
  test(`survival fails on synthetic storage writes: ${recordName}`, async (t) => {
    const f = fixture(t, { recordName });
    const result = await f.run();
    assert.equal(result.result, "FAIL");
    assert.equal(result.reason, "synthetic_storage_not_empty");
    assert.equal(result.observedSeconds, 5);
    assert.equal(result.cleanup, "complete");
    assert.deepEqual(f.kills.filter((signal) => signal !== 0), ["SIGTERM"]);
    assert.doesNotMatch(JSON.stringify(result), /SYNTHETIC CONTENT/);
    f.noChildren();
  });
}
