import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { verifyPackage } from "./package-code-comparison-plugin.mjs";

const ACTIONS = new Set(["install", "update", "disable", "enable", "uninstall"]);
const ID = /^quotatempo-usage-probe@quotatempo-code-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const PRIVATE = "quotatempo-code-plugin-management";

function fail(reason) { throw Object.assign(new Error(reason), { reason }); }

function directoryIdentity(value, privateOnly = false) {
  if (typeof value !== "string" || !path.isAbsolute(value) || path.normalize(value) !== value
      || /[\x00-\x1f\x7f]/.test(value)) fail("unsafe_path");
  let current = "/";
  for (const component of value.split("/").filter(Boolean)) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink() || ![0, process.getuid()].includes(stat.uid)
        || ((stat.mode & 0o022) !== 0 && !(stat.uid === 0 && (stat.mode & 0o1000)))) fail("unsafe_path");
  }
  const stat = fs.lstatSync(value);
  if (stat.uid !== process.getuid() || (privateOnly && (stat.mode & 0o777) !== 0o700)) fail("unsafe_path");
  return { device: stat.dev, inode: stat.ino };
}

function executableIdentity(value) {
  directoryIdentity(path.dirname(value));
  const stat = fs.lstatSync(value);
  if (!stat.isFile() || stat.isSymbolicLink() || ![0, process.getuid()].includes(stat.uid)
      || (stat.mode & 0o6022) || !(stat.mode & 0o111)) fail("unsafe_executable");
  return { device: stat.dev, inode: stat.ino, size: stat.size, modified: stat.mtimeMs };
}

function same(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

function versionNumbers(value) {
  if (typeof value !== "string" || !/^\d+\.\d+\.\d+$/.test(value)) fail("invalid_package_version");
  return value.split(".").map(Number);
}

function newer(a, b) {
  const left = versionNumbers(a), right = versionNumbers(b);
  for (let i = 0; i < 3; i++) if (left[i] !== right[i]) return left[i] > right[i];
  return false;
}

function readRecord(directory, filename) {
  directoryIdentity(directory, true);
  const name = path.join(directory, filename);
  const fd = fs.openSync(name, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || stat.nlink !== 1
        || (stat.mode & 0o777) !== 0o600 || stat.size > 8192) fail("unsafe_receipt");
    return JSON.parse(fs.readFileSync(fd, "utf8"));
  } finally { fs.closeSync(fd); }
}

function readReceipt(directory) {
    const record = readRecord(directory, "receipt.json");
    if (record.schemaVersion !== 1 || record.purpose !== PRIVATE
        || !ID.test(record.pluginID) || !Array.isArray(record.retainedPluginIDs)
        || record.retainedPluginIDs.length > 32 || !record.retainedPluginIDs.every(id => ID.test(id))
        || !["ready", "disabled", "removed", "running", "attentionRequired"].includes(record.status)) fail("invalid_receipt");
    return record;
}

function syncDirectory(directory) {
  const fd = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function saveRecord(directory, filename, record) {
  directoryIdentity(directory, true);
  const temporary = path.join(directory, `receipt-${randomUUID()}.tmp`);
  const fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  try {
    fs.writeFileSync(fd, JSON.stringify(record) + "\n");
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  try { fs.renameSync(temporary, path.join(directory, filename)); syncDirectory(directory); }
  catch (error) { try { fs.unlinkSync(temporary); } catch {} throw error; }
}

export async function runCommand(executable, argv, project, { timeoutMs = 60000,
  spawnProcess = spawn, killGroup = pid => process.kill(-pid, "SIGKILL") } = {}) {
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60000) fail("invalid_timeout");
  // Official CLI handles its own settings. Its stdout/stderr never become evidence.
  const env = { HOME: process.env.HOME, PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "en_US.UTF-8",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", DISABLE_AUTOUPDATER: "1" };
  return new Promise(resolve => {
    const versionOnly = argv.length === 1 && argv[0] === "--version";
    const child = spawnProcess(executable, argv, { cwd: project, env, detached: true,
      stdio: ["ignore", versionOnly ? "pipe" : "ignore", "ignore"] });
    let output = "", timedOut = false, settled = false, exitGrace, exited = false,
      outputEnded = !versionOnly, exitCode;
    const finish = result => {
      if (settled) return;
      settled = true; clearTimeout(deadline); clearTimeout(exitGrace);
      resolve(result);
    };
    const unconfirmed = () => {
      child.stdout?.destroy(); child.unref();
      finish({ ok: false, terminationUnconfirmed: true });
    };
    const stopGroup = () => {
      try { killGroup(child.pid); return true; }
      catch (error) { return error.code === "ESRCH"; }
    };
    const maybeFinish = () => {
      if (!exited || !outputEnded) return;
      const version = /^2\.1\.(\d+) \(Claude Code\)\s*$/.exec(output);
      finish({ ok: !timedOut && exitCode === 0 && (!versionOnly || (!!version && Number(version[1]) >= 287)) });
    };
    const requestStop = () => {
      timedOut = true;
      if (!stopGroup()) { unconfirmed(); return; }
      clearTimeout(exitGrace);
      exitGrace = setTimeout(unconfirmed, 1000);
    };
    const deadline = setTimeout(requestStop, timeoutMs);
    child.stdout?.on("data", chunk => {
      if (output.length + chunk.length > 256) { requestStop(); return; }
      output += chunk.toString("utf8");
    });
    child.stdout?.on("end", () => { outputEnded = true; maybeFinish(); });
    child.stdout?.on("error", requestStop);
    child.on("error", () => finish({ ok: false }));
    child.on("exit", code => {
      exited = true; exitCode = code;
      if (!stopGroup()) { unconfirmed(); return; }
      if (!outputEnded) { clearTimeout(exitGrace); exitGrace = setTimeout(unconfirmed, 1000); }
      maybeFinish();
    });
  });
}

function projectLedger(project) { return path.join(project, ".quotatempo-code-plugin-management"); }

function ledgerState(project, allowEmpty = false) {
  const directory = projectLedger(project);
  if (!fs.existsSync(directory)) return null;
  directoryIdentity(directory, true);
  if (!fs.existsSync(path.join(directory, "state.json"))) {
    if (allowEmpty) return null;
    fail("missing_project_ledger");
  }
  const state = readRecord(directory, "state.json");
  if (state.schemaVersion !== 1 || state.purpose !== PRIVATE || state.project !== project
      || typeof state.receiptDirectory !== "string") fail("invalid_project_ledger");
  return state;
}

export async function planManagement({ action, project, executable, packageDirectory, receiptDirectory }, { allowEmptyLedger = false } = {}) {
  if (!ACTIONS.has(action)) fail("invalid_action");
  const projectIdentity = directoryIdentity(project);
  const executableStamp = executableIdentity(executable);
  directoryIdentity(path.dirname(receiptDirectory), true);
  let previous;
  const ledger = ledgerState(project, allowEmptyLedger);
  if (ledger && ["running", "attentionRequired"].includes(ledger.status)) fail("reconciliation_required");
  if (action === "install") {
    if (ledger && ledger.status !== "removed") fail("project_already_managed");
    if (fs.existsSync(receiptDirectory)) fail("receipt_exists");
  } else {
    const receipt = readReceipt(receiptDirectory);
    const { receiptDirectory: boundReceipt, ...canonical } = ledger ?? {};
    if (boundReceipt !== receiptDirectory || !same(canonical, receipt)) fail("project_ledger_mismatch");
    previous = canonical;
    if (!ledger || ledger.receiptDirectory !== receiptDirectory || ledger.status !== previous.status
        || !same(ledger.projectIdentity, projectIdentity)) fail("project_ledger_mismatch");
    if (!["ready", "disabled"].includes(previous.status)) fail("reconciliation_required");
    if (previous.project !== project || !same(previous.projectIdentity, projectIdentity)
        || previous.executable !== executable) fail("binding_changed");
  }
  const packaged = await verifyPackage(packageDirectory);
  if (!ID.test(packaged.pluginID)) fail("invalid_package_identity");
  let commands;
  if (action === "install") {
    commands = [["plugin", "marketplace", "add", packageDirectory, "--scope", "local"],
      ["plugin", "install", packaged.pluginID, "--scope", "local"]];
  } else if (action === "update" && packaged.pluginID !== previous.pluginID) {
    if (!newer(packaged.version, previous.packageVersion)) fail("newer_package_required");
    if (previous.retainedPluginIDs.includes(packaged.pluginID)) fail("package_already_managed");
    commands = [["plugin", "marketplace", "add", packageDirectory, "--scope", "local"],
      ["plugin", "install", packaged.pluginID, "--scope", "local"],
      ...(previous.status === "disabled" ? [["plugin", "disable", packaged.pluginID, "--scope", "local"]] : []),
      ["plugin", "uninstall", previous.pluginID, "--scope", "local", "--keep-data"]];
  } else {
    if (packaged.pluginID !== previous.pluginID || previous.packageDirectory !== packageDirectory
        || previous.packageVersion !== packaged.version || previous.packageDigest !== packaged.packageDigest) fail("binding_changed");
    if (action === "enable" && previous.status !== "disabled") fail("plugin_already_enabled");
    commands = [["plugin", action, packaged.pluginID, "--scope", "local",
      ...(action === "uninstall" ? ["--keep-data"] : [])],
      ...(action === "update" && previous.status === "disabled"
        ? [["plugin", "disable", packaged.pluginID, "--scope", "local"]] : [])];
  }
  return { action, project, projectIdentity, executable, executableStamp, packageDirectory,
    packageVersion: packaged.version, packageDigest: packaged.packageDigest,
    receiptDirectory, pluginID: packaged.pluginID, commands, previous };
}

export async function applyManagement(options, { runner = runCommand } = {}) {
  if ((options.consentLocalManagement !== true && options.localTrial !== true)
      || options.sessionsClosed !== true) fail("explicit_trial_ack_required");
  const plan = await planManagement(options);
  const ledgerDirectory = projectLedger(plan.project);
  let createdLedger = false;
  try { fs.mkdirSync(ledgerDirectory, { mode: 0o700 }); createdLedger = true; syncDirectory(plan.project); }
  catch (error) { if (error.code !== "EEXIST") throw error; }
  directoryIdentity(ledgerDirectory, true);
  const lock = path.join(ledgerDirectory, "operation.lock");
  let locked;
  let preserveLock = false;
  try { locked = fs.openSync(lock, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600); }
  catch { fail("operation_locked"); }
  try {
    fs.fsyncSync(locked); syncDirectory(ledgerDirectory);
    // Revalidate after acquiring the exclusive lock, before any CLI mutation.
    await planManagement(options, { allowEmptyLedger: createdLedger });
    if (plan.action === "install") { fs.mkdirSync(plan.receiptDirectory, { mode: 0o700 }); syncDirectory(path.dirname(plan.receiptDirectory)); }
    if (plan.previous && !same(readReceipt(plan.receiptDirectory), plan.previous)) fail("receipt_changed");
    if (!same(directoryIdentity(plan.project), plan.projectIdentity)
        || !same(executableIdentity(plan.executable), plan.executableStamp)) fail("binding_changed");
    const record = { schemaVersion: 1, purpose: PRIVATE, project: plan.project,
      projectIdentity: plan.projectIdentity, executable: plan.executable,
      packageDirectory: plan.packageDirectory, packageVersion: plan.packageVersion, packageDigest: plan.packageDigest,
      pluginID: plan.pluginID,
      retainedPluginIDs: [...new Set([...(plan.previous?.retainedPluginIDs ?? []), plan.pluginID])],
      operationID: randomUUID(), action: plan.action, status: "running", completedSteps: 0, pendingStep: null,
      previousBinding: plan.previous ? { pluginID: plan.previous.pluginID,
        packageDirectory: plan.previous.packageDirectory, packageVersion: plan.previous.packageVersion,
        packageDigest: plan.previous.packageDigest, status: plan.previous.status } : null,
      activeBinding: plan.previous?.activeBinding ?? null,
      steps: plan.commands.map(argv => ({ command: argv[1] === "marketplace" ? "marketplace_add" : argv[1],
        pluginID: argv[1] === "marketplace" ? plan.pluginID : argv[2], status: "pending" })) };
    if (record.retainedPluginIDs.length > 32) fail("receipt_capacity");
    const checkpoint = () => {
      // The project ledger is canonical. A lost/changed secondary receipt cannot authorize replay.
      saveRecord(ledgerDirectory, "state.json", { ...record, receiptDirectory: plan.receiptDirectory });
      saveRecord(plan.receiptDirectory, "receipt.json", record);
    };
    checkpoint();
    const preflight = await runner(plan.executable, ["--version"], plan.project);
    if (!preflight.ok) {
      record.status = "attentionRequired";
      record.reason = "compatible_cli_required";
      preserveLock = preflight.terminationUnconfirmed === true;
      record.terminationUnconfirmed = preserveLock;
      checkpoint();
      fail("compatible_cli_required");
    }
    for (let index = 0; index < plan.commands.length; index++) {
      const rechecked = await verifyPackage(plan.packageDirectory);
      if (rechecked.pluginID !== plan.pluginID || rechecked.version !== plan.packageVersion
          || rechecked.packageDigest !== plan.packageDigest
          || !same(directoryIdentity(plan.project), plan.projectIdentity)
          || !same(executableIdentity(plan.executable), plan.executableStamp)) fail("binding_changed");
      record.pendingStep = index;
      record.steps[index].status = "inFlight";
      checkpoint();
      let result;
      try { result = await runner(plan.executable, plan.commands[index], plan.project); }
      catch { result = { ok: false }; }
      if (!result.ok) {
        record.status = "attentionRequired";
        preserveLock = result.terminationUnconfirmed === true;
        record.terminationUnconfirmed = preserveLock;
        checkpoint();
        return { status: "attentionRequired", completedSteps: index, retryAllowed: false };
      }
      record.completedSteps = index + 1;
      record.pendingStep = null;
      record.steps[index].status = "complete";
      checkpoint();
    }
    record.status = plan.action === "disable" || (plan.action === "update" && plan.previous.status === "disabled")
      ? "disabled" : plan.action === "uninstall" ? "removed" : "ready";
    record.activeBinding = record.status === "removed" ? null : { pluginID: record.pluginID,
      packageDirectory: record.packageDirectory, packageVersion: record.packageVersion,
      packageDigest: record.packageDigest, status: record.status };
    checkpoint();
    return { status: record.status, completedSteps: record.completedSteps, runtimeAccepted: false,
      marketplacesRetained: true };
  } finally {
    fs.closeSync(locked);
    if (!preserveLock) { fs.unlinkSync(lock); syncDirectory(ledgerDirectory); }
  }
}

async function main(argv) {
  const action = argv.shift();
  const flags = { action };
  const values = { "--project": "project", "--cli": "executable", "--package": "packageDirectory", "--receipt": "receiptDirectory" };
  const toggles = { "--apply": "apply", "--consent-local-management": "consentLocalManagement",
    "--local-trial": "localTrial", "--code-sessions-closed": "sessionsClosed" };
  while (argv.length) {
    const key = argv.shift();
    if (values[key] && argv.length && flags[values[key]] === undefined) flags[values[key]] = argv.shift();
    else if (toggles[key] && flags[toggles[key]] === undefined) flags[toggles[key]] = true;
    else fail("invalid_arguments");
  }
  if (Object.values(values).some(key => typeof flags[key] !== "string")) fail("invalid_arguments");
  if (flags.apply) return applyManagement(flags);
  const plan = await planManagement(flags);
  return { status: "planOnly", action: plan.action, scope: "local", project: plan.project,
    commands: plan.commands, requiresClosedSessions: true, requiresExplicitConsent: true };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try { console.log(JSON.stringify(await main(process.argv.slice(2)))); }
  catch (error) { console.log(JSON.stringify({ status: "stopped", reason: error.reason ?? "local_operation_failed" })); process.exitCode = 1; }
}
