#!/usr/bin/env node
// Explicit reviewed preview outside normal HOME only (no Downloads acceptance).
// Module injection is exclusively for synthetic tests.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

export const flag = "--code-comparison-startup-validation";
const identifier = "co.ishikawa.QuotaTempo.CodeComparisonPreview";
const reject = () => { throw new Error("acceptance_failed"); };
const kind = info => info.isDirectory() ? "directory" : info.isFile() ? "file" : "other";
const same = (a, b) => a.dev === b.dev && a.ino === b.ino && a.uid === b.uid
  && a.mode === b.mode && kind(a) === kind(b);

export function parseArguments(args) {
  if (args.length !== 2 || args[0] !== "--app" || typeof args[1] !== "string"
    || !path.isAbsolute(args[1]) || !args[1].endsWith(".app")
    || /[\x00-\x1f\x7f]/.test(args[1])
    || args[1].split("/").some(part => part === "." || part === "..")) reject();
  return args[1];
}

export function sandboxPolicy(home, canonicalHome) {
  if (![home, canonicalHome].every(value => path.isAbsolute(value) && value !== "/")) reject();
  return `(version 1) (allow default) (deny network*)\n`
    + [...new Set([home, canonicalHome])].map(value =>
      `(deny file-read* file-write* (subpath ${JSON.stringify(value)}))`).join("\n");
}

export function resultContract(result) {
  if (result.error || result.signal !== null || !Buffer.isBuffer(result.stdout)
    || result.stdout.length < 1 || result.stdout.length >= 512) reject();
  const text = result.stdout.toString("utf8").trim();
  const value = JSON.parse(text);
  if (JSON.stringify(value) !== text) reject();
  const keys = Object.keys(value).sort().join(",");
  if (result.status === 0 && keys === "guiStarted,liveCodeAccepted,passed,providersDisabled,status"
    && value.status === "startupValidated" && value.passed === true
    && value.providersDisabled === true && value.guiStarted === false
    && value.liveCodeAccepted === false) return true;
  if (result.status === 2 && keys === "passed,status"
    && value.status === "startupValidationFailed" && value.passed === false) return false;
  reject();
}

export const malformedArguments = [
  () => [flag],
  () => [flag, "--private-test-directory"],
  destination => [flag, "--private-test-directory", destination, "--unexpected"],
  destination => [flag, flag, "--private-test-directory", destination],
  destination => ["--private-test-directory", destination, flag],
  destination => [`${flag}=unexpected`, "--private-test-directory", destination],
];

export function runHarness(args, overrides = {}) {
  const runtime = { spawnSync, platform: process.platform, temporaryParent: "/private/tmp",
    normalHome: os.homedir(), uuid: randomUUID, ...overrides };
  const owned = new Map();
  const cases = [];
  let cleanupComplete = true;
  let root;
  let environment;
  let preflightCase = "preflight";
  const exists = file => {
    try { fs.lstatSync(file); return true; }
    catch (error) { if (error.code === "ENOENT") return false; throw error; }
  };
  const check = file => {
    const info = fs.lstatSync(file);
    if (!owned.has(file) || !same(owned.get(file), info)) reject();
    return info;
  };
  const remember = file => {
    const info = fs.lstatSync(file);
    if (info.uid !== process.getuid() || kind(info) === "other"
      || (info.isFile() && info.nlink !== 1)) reject();
    owned.set(file, info);
  };
  const mkdir = file => {
    fs.mkdirSync(file, { mode: 0o700 });
    remember(file);
    if ((check(file).mode & 0o7777) !== 0o700) reject();
  };
  const inventory = directory => {
    const entries = new Map();
    const walk = file => {
      if (entries.size >= 10000) reject();
      const info = fs.lstatSync(file);
      if (info.uid !== process.getuid() || kind(info) === "other"
        || (info.isFile() && info.nlink !== 1)) reject();
      if (owned.has(file) && !same(owned.get(file), info)) reject();
      entries.set(file, info);
      if (info.isDirectory()) for (const name of fs.readdirSync(file)) walk(path.join(file, name));
    };
    walk(directory);
    for (const [file, info] of entries) owned.set(file, info);
  };
  const tool = (command, argv, capture = false) => {
    const result = runtime.spawnSync(command, argv, {
      cwd: root, env: environment, shell: false, timeout: 10000, killSignal: "SIGKILL",
      maxBuffer: 65536, stdio: ["ignore", capture ? "pipe" : "ignore", "ignore"],
    });
    if (result.error || result.signal !== null || result.status !== 0) reject();
    return result;
  };
  const verify = app => {
    // Refuse symlinked/writable bundle components; framework symlinks remain untouched.
    for (const suffix of ["", "Contents", "Contents/MacOS"]) {
      const info = fs.lstatSync(path.join(app, suffix));
      if (!info.isDirectory() || (info.mode & 0o022)) reject();
    }
    const executable = path.join(app, "Contents/MacOS/QuotaTempo");
    const binary = fs.lstatSync(executable);
    const plist = fs.lstatSync(path.join(app, "Contents/Info.plist"));
    if (!binary.isFile() || binary.nlink !== 1 || !(binary.mode & 0o111)
      || (binary.mode & 0o022) || !plist.isFile() || plist.nlink !== 1
      || plist.size < 1 || plist.size > 65536 || (plist.mode & 0o022)) reject();
    const signatureFlags = ["--verify", "--strict", "--deep", "--all-architectures"];
    tool("/usr/bin/codesign", [...signatureFlags, app]);
    tool("/usr/bin/codesign", [...signatureFlags, executable]);
    const output = tool("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--",
      path.join(app, "Contents/Info.plist")], true).stdout;
    if (!Buffer.isBuffer(output) || output.length > 65536) reject();
    const info = JSON.parse(output.toString("utf8"));
    if (info.CFBundleIdentifier !== identifier || info.CFBundleExecutable !== "QuotaTempo"
      || info.QTReleaseChannel !== "code-comparison-preview"
      || info.QTCodeComparisonPluginBundled !== true
      || !/^[0-9a-f]{64}$/.test(info.QTCodeComparisonManifestDigest ?? "")
      || Object.hasOwn(info, "SUFeedURL") || Object.hasOwn(info, "SUPublicEDKey")) reject();
    if (!same(binary, fs.lstatSync(executable)) || !same(plist, fs.lstatSync(path.join(app, "Contents/Info.plist")))) reject();
    return executable;
  };
  const runCase = (name, action) => {
    try { if (!action()) reject(); cases.push({ name, status: "passed" }); }
    catch { cases.push({ name, status: "failed" }); }
  };
  try {
    const app = parseArguments(args);
    if (runtime.platform !== "darwin" || fs.realpathSync(app) !== app) reject();
    const canonicalHome = fs.realpathSync(runtime.normalHome);
    const policy = sandboxPolicy(runtime.normalHome, canonicalHome);
    // Do not weaken normal-HOME denial to execute a Downloads app. Supply an
    // independently prepared private temporary copy; this harness never copies it.
    if ([runtime.normalHome, canonicalHome].some(home => app === home || app.startsWith(`${home}/`))) {
      preflightCase = "appUnderHomeUnsupported";
      reject();
    }
    root = path.join(runtime.temporaryParent, `qtc-startup-harness-${runtime.uuid()}`);
    mkdir(root);
    const home = path.join(root, "home");
    const temporary = path.join(root, "tmp");
    mkdir(home);
    mkdir(temporary);
    environment = { HOME: home, CFFIXED_USER_HOME: home, TMPDIR: `${temporary}/`,
      PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LC_ALL: "C" };
    const executable = verify(app);
    const invoke = malformed => {
      check(root);
      const privateRoot = path.join(root, `child-${runtime.uuid()}`);
      mkdir(privateRoot);
      const childHome = path.join(privateRoot, "home");
      const childTemporary = path.join(privateRoot, "tmp");
      mkdir(childHome);
      mkdir(childTemporary);
      const childEnvironment = { ...environment, HOME: childHome, CFFIXED_USER_HOME: childHome,
        TMPDIR: `${childTemporary}/` };
      if (fs.readdirSync(childHome).length !== 0) reject();
      const uuid = runtime.uuid();
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid)) reject();
      const destination = path.join(runtime.temporaryParent, `qtc-startup-validation-${uuid}`);
      if (exists(destination)) reject();
      const argv = malformed ? malformed(destination) : [flag, "--private-test-directory", destination];
      if (!argv.some(argument => argument.startsWith(flag))) reject();
      const child = runtime.spawnSync("/usr/bin/sandbox-exec", ["-p", policy, executable, ...argv], {
        cwd: privateRoot, env: childEnvironment, shell: false, timeout: 30000, killSignal: "SIGKILL",
        maxBuffer: 511, stdio: ["ignore", "pipe", "ignore"],
      });
      let passed;
      try {
        passed = resultContract(child);
        if (exists(destination)) {
          const info = fs.lstatSync(destination);
          if (!info.isDirectory() || info.uid !== process.getuid()
            || (info.mode & 0o7777) !== 0o700) reject();
          inventory(destination);
          if (malformed) reject();
        } else if (passed) reject();
        // Only a bounded, recognized response authorizes adopting newly created private outputs.
        inventory(root);
      } catch {
        cleanupComplete = false;
        throw new Error("headless_failed");
      }
      return malformed ? !passed : passed;
    };
    runCase("cleanStartup", () => invoke());
    // Stop on unknown output/timeout; do not execute any more children after losing ownership.
    if (cleanupComplete) for (const [index, malformed] of malformedArguments.entries()) {
      runCase(`invalidArguments${index + 1}`, () => invoke(malformed));
      if (!cleanupComplete) break;
    }
  } catch { cases.push({ name: preflightCase, status: "failed" }); }
  finally {
    try {
      for (const [file] of owned) {
        const info = check(file);
        if (info.isDirectory()) for (const name of fs.readdirSync(file)) {
          if (!owned.has(path.join(file, name))) reject();
        }
      }
      for (const [file] of [...owned].sort((a, b) => b[0].split("/").length - a[0].split("/").length)) {
        for (let parent = path.dirname(file); owned.has(parent); parent = path.dirname(parent)) check(parent);
        const info = check(file);
        if (info.isDirectory()) fs.rmdirSync(file); else fs.unlinkSync(file);
        owned.delete(file);
      }
    } catch { cleanupComplete = false; }
  }
  const passed = cases.filter(item => item.status === "passed").length;
  const failed = cases.length - passed;
  const status = failed === 0 && passed === 7 && cleanupComplete ? "passed" : "failed";
  return { status, passed, failed, skipped: 0, cleanupComplete, cases, liveAcceptance: false };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = runHarness(process.argv.slice(2));
  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exitCode = result.status === "passed" ? 0 : 2;
}
