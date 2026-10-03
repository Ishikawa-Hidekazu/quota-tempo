#!/usr/bin/env node

// Local synthetic startup only. Review the exact supplied preview's provenance
// before running; a valid signature is not proof that it was built from this tree.
// Source safety contract (QuotaTempoApp + DesktopIntegrationConfiguration):
// - BOTH flags are required: the delegate checks --provider-disabled itself.
// - acquisition, provider-selection preferences, consent restore, updater and
//   login items are disabled. Presentation still opens the real preview defaults
//   suite; YES/iconOnly argument overrides avoid onboarding writes. There are no
//   UI actions, and property initialization does not invoke didSet observers.
// - the controller initializer opens nothing; its scheduling path is temporary.
// - LSUIElement + the launch/reopen guards avoid presentation and activation.
// A transient menu-bar item is expected. This measures process survival, not UI
// readiness, focus, real consent/Keychain access, provider permission or rollover.

import { spawn, spawnSync } from "node:child_process";
import { constants, accessSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { setTimeout as pause } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const previewID = "co.ishikawa.QuotaTempo.DesktopIntegrationPreview";
const safeEnvironment = { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "C" };
const usage = [
  "Usage: node scripts/test-desktop-integration-startup.mjs --app /absolute/Preview.app --team-id TEAMID [--seconds 5..30]",
  "Requires an explicitly supplied, reviewed Developer ID integration preview; no default app or signing identity.",
  "Does not build, sign, install, notarize, open windows, request access, or stop an existing helper.",
  "Runs only with synthetic storage/providers disabled. All app output is discarded.",
  "PASS means bounded process survival and own-child cleanup, not live permission or release acceptance.",
].join("\n");

class SmokeError extends Error {}

function reject(reason) { throw new SmokeError(reason); }

export function parseArguments(args) {
  if (args.length === 1 && args[0] === "--help") return { help: true };
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!["--app", "--team-id", "--seconds"].includes(key)
      || key in options || !value || /[\x00-\x1f\x7f]/.test(value)) reject("invalid_arguments");
    options[key] = value;
  }
  const app = options["--app"];
  const teamID = options["--team-id"];
  const seconds = options["--seconds"] ?? "5";
  if (!app || !isAbsolute(app) || !app.endsWith(".app")
    || !/^[A-Z0-9]{10}$/.test(teamID ?? "")
    || !/^(?:[5-9]|[12][0-9]|30)$/.test(seconds)) reject("invalid_arguments");
  return { app: resolve(app), teamID, seconds: Number(seconds) };
}

function runTool(runtime, command, args, capture = false) {
  const result = runtime.spawnSync(command, args, {
    env: safeEnvironment, shell: false, encoding: "utf8",
    stdio: ["ignore", capture ? "pipe" : "ignore", "ignore"],
    maxBuffer: 64 * 1024, timeout: 10_000, killSignal: "SIGKILL",
  });
  if (result.error || result.status !== 0 || result.signal) reject("preflight_tool_failed");
  return result.stdout ?? "";
}

function verifyPreview(options, runtime) {
  if (runtime.platform !== "darwin") reject("macos_required");
  // No app lookup, copying, replacement, signing or changes to quarantine.
  for (const suffix of ["", "Contents", "Contents/MacOS"]) {
    if (!lstatSync(join(options.app, suffix)).isDirectory()) reject("unsafe_bundle_path");
  }
  const executable = join(options.app, "Contents/MacOS/QuotaTempo");
  const plist = join(options.app, "Contents/Info.plist");
  for (const path of [executable, plist]) {
    if (!lstatSync(path).isFile()) reject("unsafe_bundle_path");
  }
  accessSync(executable, constants.X_OK);
  const requirement = '=anchor apple generic'
    + ' and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
    + ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    + ` and certificate leaf[subject.OU] = "${options.teamID}"`
    + ` and identifier "${previewID}"`;
  runTool(runtime, "/usr/bin/codesign", [
    "--verify", "--deep", "--strict", "--test-requirement", requirement, options.app,
  ]);
  const info = JSON.parse(runTool(runtime, "/usr/bin/plutil", [
    "-convert", "json", "-o", "-", "--", plist,
  ], true));
  if (info.CFBundleIdentifier !== previewID || info.CFBundleExecutable !== "QuotaTempo"
    || info.CFBundlePackageType !== "APPL" || info.LSUIElement !== true
    || info.QTReleaseChannel !== "desktop-integration-preview"
    || "SUFeedURL" in info || "SUPublicEDKey" in info) reject("unexpected_bundle_metadata");
  for (const path of [options.app, executable]) {
    const names = runTool(runtime, "/usr/bin/xattr", [path], true).trim().split(/\r?\n/);
    if (names.includes("com.apple.quarantine")) reject("quarantined_bundle");
  }
  return executable;
}

// Dependency injection is module-only for synthetic tests. The CLI accepts no
// test override, environment-selected command, extra app arguments, or real store.
export async function runSmoke(args, overrides = {}) {
  const runtime = {
    spawn, spawnSync, platform: process.platform, now: () => performance.now(),
    pause, signals: process, temporaryParent: tmpdir(), ...overrides,
  };
  let root;
  let child;
  let exited = false;
  let spawnFailed = false;
  let interrupted = false;
  let reason = "unknown_failure";
  let observedSeconds = 0;
  let cleanup = "not_needed";
  const interrupt = () => { interrupted = true; };
  const hasValidPID = () => Number.isSafeInteger(child?.pid) && child.pid > 0;
  const stopped = () => exited || (spawnFailed && !hasValidPID());
  const waitForStop = async () => {
    const deadline = runtime.now() + 2_000;
    while (!stopped() && runtime.now() < deadline) await runtime.pause(50);
    return stopped();
  };

  try {
    const options = parseArguments(args);
    if (options.help) return { exitCode: 0, help: usage };
    const executable = verifyPreview(options, runtime);
    root = realpathSync(mkdtempSync(join(runtime.temporaryParent, "quotatempo-startup-")));
    const store = join(root, "store");
    const home = join(root, "home");
    const temporary = join(root, "tmp");
    for (const path of [store, home, temporary]) mkdirSync(path, { mode: 0o700 });
    runtime.signals.on("SIGINT", interrupt);
    runtime.signals.on("SIGTERM", interrupt);
    child = runtime.spawn(executable, [
      "--provider-disabled", "--storage-directory", store,
      "--exercise-provider-triggers",
      "-hasCompletedOnboarding", "YES", "-menuBarDisplayMode", "iconOnly",
    ], {
      cwd: root, shell: false, detached: false, stdio: "ignore",
      // HOME is defense in depth, not a macOS preferences/security sandbox.
      // Safety relies on the source guards above, not relocating Keychain.
      env: { ...safeEnvironment, HOME: home, TMPDIR: `${temporary}/` },
    });
    child.on("error", () => { spawnFailed = true; });
    child.on("exit", () => { exited = true; });
    if (!hasValidPID()) reject("spawn_failed");
    const deadline = runtime.now() + options.seconds * 1_000;
    while (true) {
      if (interrupted) reject("interrupted");
      if (spawnFailed) reject("spawn_failed");
      if (exited || !child.kill(0)) reject("early_exit");
      if (runtime.now() >= deadline) break;
      await runtime.pause(Math.min(100, deadline - runtime.now()));
    }
    observedSeconds = options.seconds;
    // The source contract leaves this new store entirely empty. Reject any
    // entry, including DesktopConnection (throttle records/lock), without
    // following links, recursing into directories, or reading file contents.
    if (!lstatSync(store).isDirectory() || readdirSync(store).length !== 0) {
      reject("synthetic_storage_not_empty");
    }
    reason = "process_survived";
  } catch (error) {
    // Never propagate tool/app output, filesystem errors or environment values.
    reason = error instanceof SmokeError ? error.message : "preflight_or_runtime_failed";
  } finally {
    try {
      if (hasValidPID() && !stopped()) {
        // ChildProcess owns this handle. Never discover, pkill, kill a process
        // group, or signal a PID taken from a file or an existing app/helper.
        child.kill("SIGTERM");
        if (!await waitForStop()) {
          child.kill("SIGKILL");
          if (!await waitForStop()) reject("child_stop_unconfirmed");
        }
      }
      if (root) {
        rmSync(root, { recursive: true, force: true });
        cleanup = "complete";
      }
    } catch {
      reason = "cleanup_failed";
      cleanup = "retained";
      child?.unref();
    }
    runtime.signals.removeListener("SIGINT", interrupt);
    runtime.signals.removeListener("SIGTERM", interrupt);
  }
  return {
    exitCode: reason === "process_survived" ? 0 : reason === "interrupted" ? 130 : 1,
    result: reason === "process_survived" ? "PASS" : "FAIL",
    scope: "synthetic_signed_background_process_survival", reason,
    observedSeconds, cleanup,
    ...(cleanup === "retained" ? { retainedDirectory: root } : {}),
    livePermissionTested: false, rolloverTested: false, focusObserved: false,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await runSmoke(process.argv.slice(2));
  process.stdout.write(`${result.help ?? JSON.stringify(result)}\n`);
  process.exitCode = result.exitCode;
}
